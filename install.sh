#!/usr/bin/env bash
set -euo pipefail

# ── Rallly Self-Hosted Installer ────────────────────────────────
# Usage: curl -fsSL https://get.rallly.co | bash

REPO_URL="https://github.com/lukevella/rallly-selfhosted.git"
REPO_TARBALL="https://github.com/lukevella/rallly-selfhosted/archive/refs/heads/main.tar.gz"
DEFAULT_INSTALL_DIR="/opt/rallly"

# ── Helpers ─────────────────────────────────────────────────────

print_banner() {
  cat <<'EOF'

  ┌─────────────────────────────────────┐
  │         Rallly Self-Hosted          │
  │         Installation Script         │
  └─────────────────────────────────────┘

EOF
}

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

# ── Preflight Checks ───────────────────────────────────────────

preflight() {
  info "Running preflight checks..."
  echo ""

  # Check Docker
  if ! command -v docker &>/dev/null; then
    error "Docker is not installed."
    echo ""
    read -rp "  Install Docker now? [Y/n]: " install_docker
    if [[ "${install_docker:-Y}" =~ ^[Yy]$ ]]; then
      info "Installing Docker..."
      curl -fsSL https://get.docker.com | sh
      ok "Docker installed."
    else
      error "Docker is required. Please install it and try again."
      exit 1
    fi
  else
    ok "Docker is installed."
  fi

  # Check Docker is running
  if ! docker info &>/dev/null; then
    error "Docker is not running. Please start Docker and try again."
    exit 1
  fi

  # Check Docker version (need 19.03+ for API 1.40)
  local docker_version
  docker_version="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0")"
  local docker_major docker_minor
  docker_major="$(echo "$docker_version" | cut -d. -f1)"
  docker_minor="$(echo "$docker_version" | cut -d. -f2)"
  if [ "$docker_major" -lt 19 ] || { [ "$docker_major" -eq 19 ] && [ "$docker_minor" -lt 3 ]; }; then
    error "Docker $docker_version is too old. Version 19.03 or later is required."
    exit 1
  else
    ok "Docker $docker_version meets minimum version (19.03+)."
  fi

  # Check Docker Compose v2
  if ! docker compose version &>/dev/null; then
    error "Docker Compose v2 is not available."
    error "Please update Docker or install the compose plugin."
    exit 1
  else
    ok "Docker Compose v2 is available."
  fi

  # Check openssl
  if ! command -v openssl &>/dev/null; then
    error "openssl is not installed. It is needed to generate secrets."
    exit 1
  else
    ok "openssl is available."
  fi

  # Check ports 80/443 — only strictly required for the bundled Traefik.
  # Warn rather than fail so users with an existing reverse proxy can still
  # install and switch to PROXY_MODE=external during setup.
  local port_busy=false
  for port in 80 443; do
    if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
       lsof -iTCP:"$port" -sTCP:LISTEN &>/dev/null 2>&1; then
      echo "  ! Port $port is in use."
      port_busy=true
    fi
  done
  if [ "$port_busy" = true ]; then
    echo "    If you're using an existing reverse proxy (Caddy, Nginx, ...),"
    echo "    choose 'external' at the reverse proxy prompt during setup."
    echo "    Otherwise, stop the conflicting service before continuing."
  else
    ok "Ports 80 and 443 are available."
  fi

  echo ""
}

# ── Download ────────────────────────────────────────────────────

download() {
  local install_dir="$1"

  # Check for existing installation
  if [ -f "$install_dir/docker-compose.yml" ]; then
    info "Existing installation found at $install_dir"
    read -rp "  Update files while keeping your .env? [Y/n]: " update
    if [[ "${update:-Y}" =~ ^[Yy]$ ]]; then
      # Preserve .env and backups
      local tmp_env="" tmp_backups=""
      if [ -f "$install_dir/.env" ]; then
        tmp_env="$(mktemp)"
        cp "$install_dir/.env" "$tmp_env"
      fi
      if [ -d "$install_dir/backups" ]; then
        tmp_backups="$(mktemp -d)"
        cp -r "$install_dir/backups/"* "$tmp_backups/" 2>/dev/null || true
      fi

      download_files "$install_dir"

      # Restore preserved files
      if [ -n "$tmp_env" ]; then
        cp "$tmp_env" "$install_dir/.env"
        rm "$tmp_env"
      fi
      if [ -n "$tmp_backups" ]; then
        mkdir -p "$install_dir/backups"
        cp -r "$tmp_backups/"* "$install_dir/backups/" 2>/dev/null || true
        rm -rf "$tmp_backups"
      fi

      ok "Files updated. Your .env and backups have been preserved."
      return 0
    else
      error "Installation cancelled."
      exit 0
    fi
  fi

  download_files "$install_dir"
}

download_files() {
  local install_dir="$1"
  mkdir -p "$install_dir"

  if command -v git &>/dev/null; then
    info "Downloading via git..."
    if [ -d "$install_dir/.git" ]; then
      git -C "$install_dir" pull --quiet
    else
      git clone --quiet "$REPO_URL" "$install_dir"
    fi
  else
    info "Downloading archive..."
    curl -fsSL "$REPO_TARBALL" | tar -xz --strip-components=1 -C "$install_dir"
  fi

  chmod +x "$install_dir/rallly.sh"
  ok "Downloaded to $install_dir"
}

# ── Main ────────────────────────────────────────────────────────

main() {
  # When invoked via `curl … | bash`, stdin is the script body, so `read`
  # hits EOF and `set -e` exits before any prompt runs. Reattach stdin to
  # the user's terminal; child commands (rallly.sh setup) inherit it too.
  if [ ! -t 0 ]; then
    if [ -r /dev/tty ]; then
      exec < /dev/tty
    else
      error "No interactive terminal available. Download install.sh and run it directly."
      exit 1
    fi
  fi

  print_banner

  preflight

  prompt INSTALL_DIR "Install directory" "$DEFAULT_INSTALL_DIR"
  echo ""

  download "$INSTALL_DIR"

  # Run setup if no .env exists
  if [ ! -f "$INSTALL_DIR/.env" ]; then
    "$INSTALL_DIR/rallly.sh" setup
  else
    ok "Using existing configuration at $INSTALL_DIR/.env"
  fi

  # Start services
  echo ""
  info "Starting Rallly..."
  "$INSTALL_DIR/rallly.sh" start

  echo ""
  cat <<EOF

  ┌─────────────────────────────────────────────────┐
  │  Installation complete!                         │
  │                                                 │
  │  Note: It may take a minute for the SSL         │
  │  certificate to be provisioned.                 │
  └─────────────────────────────────────────────────┘

  Manage your instance:
    cd $INSTALL_DIR
    ./rallly.sh status    — check service status
    ./rallly.sh logs      — view logs
    ./rallly.sh update    — update to latest version
    ./rallly.sh backup    — back up the database
    ./rallly.sh help      — see all commands

EOF

  # Exit from inside main: when the script is run via `curl | bash`,
  # bash reads commands from the pipe (stdin). `main` redirects stdin
  # to /dev/tty for prompts, so any `exit` *after* `main` would never
  # be read — bash would block on /dev/tty waiting for input.
  exit 0
}

main
