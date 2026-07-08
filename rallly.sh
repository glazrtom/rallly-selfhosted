#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# Read specific values from .env without executing it as shell. `source` would
# treat values containing $(...), backticks, or globs as code — risky for
# user-supplied fields like SMTP_PWD. Docker Compose reads .env on its own.
read_env() {
  [ -f "$ENV_FILE" ] || return 0
  awk -F= -v key="$1" '
    /^[[:space:]]*#/ { next }
    $1 == key { sub(/^[^=]+=/, ""); val = $0 }
    END { print val }
  ' "$ENV_FILE"
}

PROXY_MODE="$(read_env PROXY_MODE)"
S3_ENDPOINT="$(read_env S3_ENDPOINT)"
DATABASE_URL="$(read_env DATABASE_URL)"
DOMAIN="$(read_env DOMAIN)"
POSTGRES_VERSION="$(read_env POSTGRES_VERSION)"

# Compose file selection: base, plus the external-proxy override when the
# user is bringing their own reverse proxy (PROXY_MODE=external).
_compose_files=("$SCRIPT_DIR/docker-compose.yml")
if [ "${PROXY_MODE:-bundled}" = "external" ]; then
  _compose_files+=("$SCRIPT_DIR/docker-compose.external-proxy.yml")
fi
COMPOSE_FILE="$(IFS=:; echo "${_compose_files[*]}")"
export COMPOSE_FILE
unset _compose_files

# Enable bundled services unless the user has pointed Rallly at external
# providers in .env. Setting S3_ENDPOINT to a non-Garage endpoint disables
# the bundled Garage container; setting DATABASE_URL disables the bundled
# Postgres container; PROXY_MODE=external disables the bundled Traefik.
_profiles=()
if [ -z "${S3_ENDPOINT:-}" ] || [ "${S3_ENDPOINT}" = "http://garage:3900" ]; then
  _profiles+=("bundled-storage")
fi
if [ -z "${DATABASE_URL:-}" ]; then
  _profiles+=("bundled-db")
fi
if [ "${PROXY_MODE:-bundled}" != "external" ]; then
  _profiles+=("bundled-proxy")
fi
COMPOSE_PROFILES="$(IFS=,; echo "${_profiles[*]-}")"
export COMPOSE_PROFILES
unset _profiles

# ── Helpers ─────────────────────────────────────────────────────

info()  { echo "  → $*"; }
error() { echo "  ✗ $*" >&2; }
ok()    { echo "  ✓ $*"; }

prompt() {
  local var_name="$1" prompt_text="$2" default="${3:-}"
  local input
  if [ -n "$default" ]; then
    printf "  %s [%s]: " "$prompt_text" "$default"
  else
    printf "  %s: " "$prompt_text"
  fi
  read -r input
  eval "$var_name=\"${input:-$default}\""
}

prompt_secret() {
  local var_name="$1" prompt_text="$2"
  local input="" char
  printf "  %s: " "$prompt_text"
  while IFS= read -rsn1 char; do
    if [[ -z "$char" ]]; then
      break
    elif [[ "$char" == $'\x7f' || "$char" == $'\b' ]]; then
      if [[ -n "$input" ]]; then
        input="${input%?}"
        printf '\b \b'
      fi
    else
      input+="$char"
      printf '*'
    fi
  done
  echo ""
  eval "$var_name=\"$input\""
}

generate_secret() {
  openssl rand -hex "$1" 2>/dev/null
}

check_docker() {
  if ! command -v docker &>/dev/null; then
    error "Docker is not installed."
    exit 1
  fi
  if ! docker compose version &>/dev/null; then
    error "Docker Compose v2 is not available."
    exit 1
  fi
}

# Set or update a KEY=value line in .env, preserving everything else.
upsert_env() {
  local key="$1" value="$2"
  [ -f "$ENV_FILE" ] || return 0
  if grep -q "^${key}=" "$ENV_FILE"; then
    local tmp
    tmp="$(mktemp)"
    awk -v key="$key" -v val="$value" -F= '
      $1 == key && !/^[[:space:]]*#/ { print key "=" val; next }
      { print }
    ' "$ENV_FILE" > "$tmp"
    mv "$tmp" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

# Default major version for the bundled Postgres on fresh installs.
# Existing data volumes are never moved to this — they stay pinned to the
# major that initialised them until explicitly upgraded.
PG_DEFAULT_MAJOR=18

# The compose-managed volume name for the bundled db: <project>_db-data.
db_volume_name() {
  local project="${COMPOSE_PROJECT_NAME:-$(read_env COMPOSE_PROJECT_NAME)}"
  if [ -z "$project" ]; then
    # Replicate Docker Compose's default project name: directory basename,
    # lowercased, invalid characters stripped.
    project="$(basename "$SCRIPT_DIR" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9_-]//g' -e 's/^[_-]*//')"
  fi
  echo "${project}_db-data"
}

# Read the PostgreSQL major version out of an existing data volume.
# Pre-18 layout has PG_VERSION at the volume root; 18+ images keep it
# at <major>/docker/PG_VERSION.
detect_volume_pg_version() {
  local volume="$1"
  docker run --rm -v "${volume}:/pgdata:ro" alpine:3 sh -c \
    'cat /pgdata/PG_VERSION 2>/dev/null || cat /pgdata/*/docker/PG_VERSION 2>/dev/null' \
    | sort -n | tail -n1 | tr -d '[:space:]'
}

# Pin the bundled Postgres major version. Existing data volumes keep the
# version they were initialized with (read from PG_VERSION — a manually
# upgraded install stays on its own major); fresh installs get 18. The pin
# is persisted as POSTGRES_VERSION in .env so it is stable across runs and
# never floats.
ensure_postgres_pin() {
  if [ -n "${DATABASE_URL:-}" ]; then
    # External database — the bundled db service never starts, but compose
    # still interpolates its config. Export parse-only values; don't touch
    # the user's .env.
    POSTGRES_VERSION="${POSTGRES_VERSION:-$PG_DEFAULT_MAJOR}"
  elif [ -z "${POSTGRES_VERSION:-}" ]; then
    local volume contents
    volume="$(db_volume_name)"
    # Distinguish "volume doesn't exist" from "can't reach the daemon" —
    # otherwise a stopped daemon would look like a fresh install and pin
    # the new default major over an existing volume's data.
    if ! docker volume ls -q &>/dev/null; then
      error "Cannot query Docker volumes — is the Docker daemon running?"
      exit 1
    fi
    if docker volume inspect "$volume" &>/dev/null; then
      # `|| true`: under `set -eo pipefail` a volume without a readable
      # PG_VERSION would abort the script before the fallbacks below run.
      POSTGRES_VERSION="$(detect_volume_pg_version "$volume" || true)"
      if [ -n "$POSTGRES_VERSION" ]; then
        info "Existing database volume detected — pinning PostgreSQL $POSTGRES_VERSION."
      elif contents="$(docker run --rm -v "${volume}:/pgdata:ro" alpine:3 ls -A /pgdata 2>/dev/null)" && [ -z "$contents" ]; then
        # Volume exists but Postgres never initialised it — safe to treat
        # as a fresh install.
        POSTGRES_VERSION="$PG_DEFAULT_MAJOR"
        info "Empty database volume — provisioning PostgreSQL $POSTGRES_VERSION."
      else
        error "Found an existing database volume ($volume) but could not read its PostgreSQL version."
        error "Set POSTGRES_VERSION in $ENV_FILE manually (e.g. POSTGRES_VERSION=14) and try again."
        exit 1
      fi
    else
      POSTGRES_VERSION="$PG_DEFAULT_MAJOR"
      info "No existing database volume — provisioning PostgreSQL $POSTGRES_VERSION."
    fi
    upsert_env POSTGRES_VERSION "$POSTGRES_VERSION"
  fi

  case "$POSTGRES_VERSION" in
    ''|*[!0-9]*)
      error "Invalid POSTGRES_VERSION '$POSTGRES_VERSION' in $ENV_FILE — expected a major version number (e.g. 14)."
      exit 1
      ;;
  esac

  if [ "$POSTGRES_VERSION" -ge 18 ]; then
    POSTGRES_DATA_MOUNT=/var/lib/postgresql
  else
    POSTGRES_DATA_MOUNT=/var/lib/postgresql/data
  fi
  if [ -z "${DATABASE_URL:-}" ]; then
    upsert_env POSTGRES_DATA_MOUNT "$POSTGRES_DATA_MOUNT"
  fi
  export POSTGRES_VERSION POSTGRES_DATA_MOUNT
}

# ── Commands ────────────────────────────────────────────────────

cmd_setup() {
  if [ -f "$ENV_FILE" ]; then
    info "Existing .env found."
    read -rp "  Overwrite with new configuration? [y/N]: " overwrite
    if [[ ! "${overwrite:-N}" =~ ^[Yy]$ ]]; then
      ok "Keeping existing configuration."
      return 0
    fi
  fi

  if ! command -v openssl &>/dev/null; then
    error "openssl is required to generate secrets. Please install it and try again."
    exit 1
  fi

  echo ""
  echo "  ── Configuration ──"
  echo ""

  prompt DOMAIN "Domain name (e.g. rallly.example.com)"
  prompt INITIAL_ADMIN_EMAIL "Admin email (used to log in to the control panel)"
  prompt SUPPORT_EMAIL "Support email shown to users" "$INITIAL_ADMIN_EMAIL"

  echo ""
  echo "  ── Reverse Proxy ──"
  echo ""
  echo "  1) bundled  — Traefik on this host handles HTTPS (ports 80/443 required)"
  echo "  2) external — You already have a reverse proxy; publish web on a host port"
  echo ""
  prompt PROXY_CHOICE "Choose [1/2]" "1"
  if [ "$PROXY_CHOICE" = "2" ]; then
    PROXY_MODE=external
    prompt WEB_PORT "Host port binding for web" "127.0.0.1:3000"
  else
    PROXY_MODE=bundled
    prompt ACME_EMAIL "Email for SSL certificates" "$INITIAL_ADMIN_EMAIL"
  fi

  echo ""
  echo "  ── Email (SMTP) ──"
  echo ""
  prompt SMTP_HOST "SMTP host"
  prompt SMTP_PORT "SMTP port" "587"
  prompt SMTP_USER "SMTP username"
  prompt_secret SMTP_PWD "SMTP password"

  # Implicit TLS on 465; STARTTLS/plain on everything else (587, 25, 2525, ...)
  if [ "$SMTP_PORT" = "465" ]; then
    SMTP_SECURE=true
  else
    SMTP_SECURE=false
  fi

  echo ""
  info "Generating secrets..."

  local secret_password postgres_password s3_access_key s3_secret_key garage_rpc_secret
  secret_password="$(generate_secret 32)"
  postgres_password="$(generate_secret 24)"
  s3_access_key="$(generate_secret 16)"
  s3_secret_key="$(generate_secret 32)"
  garage_rpc_secret="$(generate_secret 32)"

  {
    cat <<ENVEOF
# Rallly Self-Hosted Configuration
# Generated by rallly.sh setup on $(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── Domain ──
DOMAIN=$DOMAIN

# ── Reverse Proxy ──
PROXY_MODE=$PROXY_MODE
ENVEOF

    if [ "$PROXY_MODE" = "bundled" ]; then
      cat <<ENVEOF
ACME_EMAIL=$ACME_EMAIL
ENVEOF
    else
      cat <<ENVEOF
WEB_PORT=$WEB_PORT
ENVEOF
    fi

    cat <<ENVEOF

# ── App Settings ──
SECRET_PASSWORD=$secret_password
SUPPORT_EMAIL=$SUPPORT_EMAIL
INITIAL_ADMIN_EMAIL=$INITIAL_ADMIN_EMAIL

# ── SMTP ──
SMTP_HOST=$SMTP_HOST
SMTP_PORT=$SMTP_PORT
SMTP_SECURE=$SMTP_SECURE
SMTP_USER=$SMTP_USER
SMTP_PWD=$SMTP_PWD

# ── Auto-configured ──
POSTGRES_PASSWORD=$postgres_password
S3_ACCESS_KEY_ID=$s3_access_key
S3_SECRET_ACCESS_KEY=$s3_secret_key
GARAGE_RPC_SECRET=$garage_rpc_secret
ENVEOF
  } > "$ENV_FILE"

  chmod 600 "$ENV_FILE"
  ok "Configuration saved to $ENV_FILE"
}

cmd_start() {
  check_docker
  if [ ! -f "$ENV_FILE" ]; then
    error "No .env file found. Run './rallly.sh setup' first."
    exit 1
  fi
  ensure_postgres_pin
  docker compose up -d
  echo ""
  echo "Rallly is starting at https://${DOMAIN:-localhost}"
  echo "Run './rallly.sh logs' to watch startup progress."
}

cmd_stop() {
  check_docker
  docker compose down
  echo "Rallly has been stopped."
}

cmd_restart() {
  check_docker
  docker compose restart
  echo "Rallly has been restarted."
}

cmd_update() {
  check_docker
  # Update repo files if this is a git clone
  if [ -d "$SCRIPT_DIR/.git" ]; then
    echo "Updating configuration files..."
    git -C "$SCRIPT_DIR" pull --ff-only || {
      error "Could not update repo files. You may need to run: git -C $SCRIPT_DIR pull manually."
    }
    echo ""
  fi
  ensure_postgres_pin
  echo "Pulling latest images..."
  docker compose pull
  echo ""
  echo "Recreating containers..."
  docker compose up -d --remove-orphans
  echo ""
  echo "Update complete."
  docker compose ps
}

cmd_logs() {
  check_docker
  local service="${1:-}"
  if [ -n "$service" ]; then
    docker compose logs -f --tail=100 "$service"
  else
    docker compose logs -f --tail=100
  fi
}

cmd_status() {
  check_docker
  docker compose ps
}

cmd_backup() {
  check_docker
  local backup_dir="$SCRIPT_DIR/backups"
  local timestamp
  timestamp="$(date +%Y%m%d_%H%M%S)"
  local backup_file="$backup_dir/rallly_${timestamp}.sql.gz"

  mkdir -p "$backup_dir"

  ensure_postgres_pin

  echo "Backing up database..."
  if [ -z "${DATABASE_URL:-}" ]; then
    docker compose exec -T db \
      pg_dump -U postgres rallly | gzip > "$backup_file"
  else
    # External Postgres — run pg_dump in a throwaway container. pg_dump
    # can dump any server up to its own major version; for newer servers
    # run pg_dump manually with a matching client.
    docker run --rm -i "postgres:${POSTGRES_VERSION}-alpine" \
      pg_dump "$DATABASE_URL" | gzip > "$backup_file"
  fi

  echo "Backup saved to: $backup_file"
}

cmd_help() {
  cat <<EOF
Rallly Management CLI

Usage: ./rallly.sh <command> [options]

Commands:
  setup          Interactive configuration and secret generation
  start          Start all services
  stop           Stop all services
  restart        Restart all services
  update         Pull latest images and restart
  logs [service] Stream logs (optionally for a specific service)
  status         Show service status
  backup         Back up the database to ./backups/
  help           Show this help message

Services: traefik, web, db, garage
EOF
}

case "${1:-help}" in
  setup)   cmd_setup ;;
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_restart ;;
  update)  cmd_update ;;
  logs)    cmd_logs "${2:-}" ;;
  status)  cmd_status ;;
  backup)  cmd_backup ;;
  help|*)  cmd_help ;;
esac
