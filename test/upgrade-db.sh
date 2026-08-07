#!/usr/bin/env bash
# End-to-end test for `rallly.sh upgrade-db`.
#
# Run this before bumping PG_DEFAULT_MAJOR in rallly.sh, and after changing
# anything that touches the upgrade path or how .env is rewritten. The
# upgrade runs against real installs and is hard to undo, so the happy path
# is worth re-verifying whenever the target major moves — the 17→18 bump
# already needed a PGDATA relocation (POSTGRES_DATA_MOUNT).
#
#   ./test/upgrade-db.sh            # test the repo this script lives in
#   ./test/upgrade-db.sh /some/repo # or point it elsewhere
#
# Builds a throwaway install on PostgreSQL 14 with known data, runs the real
# upgrade command, and asserts the data survived and the pins moved. Requires
# Docker. Takes ~1 minute once the postgres images are cached.
#
# Safe to run alongside a real install: everything happens under its own
# COMPOSE_PROJECT_NAME, in a temp directory, and is torn down on exit.
#
# Covers the happy path only. The fail_upgrade branches — pg_dump failing,
# the new database not starting, a bad restore — are NOT exercised, so the
# "nothing was switched over" guarantee is currently unverified.
set -uo pipefail

# Default to the repo containing this script, so it works from a clean clone.
REPO="${1:-$(cd "$(dirname "$(realpath "$0")")/.." && pwd)}"
WORK="$(mktemp -d)"
PROJECT="upgradedbtest"

if [ ! -f "$REPO/rallly.sh" ]; then
  echo "✗ No rallly.sh found in $REPO" >&2
  exit 1
fi
if ! docker compose version &>/dev/null; then
  echo "✗ Docker Compose v2 is required to run this test." >&2
  exit 1
fi

pass=0; fail=0
ok()   { echo "  ✓ $*"; pass=$((pass+1)); }
bad()  { echo "  ✗ $*"; fail=$((fail+1)); }
step() { echo ""; echo "── $* ──"; }

cleanup() {
  step "Cleanup"
  (cd "$WORK" 2>/dev/null && COMPOSE_PROJECT_NAME="$PROJECT" docker compose down -v --remove-orphans &>/dev/null)
  for v in $(docker volume ls -q --filter "name=^${PROJECT}_" 2>/dev/null); do
    docker volume rm "$v" &>/dev/null && echo "  removed volume $v"
  done
  # Keep the working directory when the test failed — the upgrade log and the
  # dump artifact are the evidence you need to diagnose it.
  if [ "$fail" -eq 0 ]; then
    rm -rf "$WORK"
  else
    echo "  kept working directory for inspection: $WORK"
  fi
  echo "  done"
}
trap cleanup EXIT

# ── Setup: a PG14 install with known data ────────────────────────
step "Provision a PostgreSQL 14 install"
# $WORK was created by mktemp -d above.
cp "$REPO/rallly.sh" "$REPO/docker-compose.yml" "$REPO/docker-compose.external-proxy.yml" "$WORK"/
mkdir -p "$WORK/config" && cp "$REPO/config/garage.toml" "$WORK/config/" 2>/dev/null
cd "$WORK"

cat > .env <<EOF
DOMAIN=localhost:3999
PROXY_MODE=external
WEB_PORT=127.0.0.1:3999
NEXT_PUBLIC_BASE_URL=http://localhost:3999
COMPOSE_PROJECT_NAME=$PROJECT
SECRET_PASSWORD=test-secret-password-at-least-32ch
SUPPORT_EMAIL=test@example.com
INITIAL_ADMIN_EMAIL=test@example.com
SMTP_HOST=localhost
SMTP_PORT=1025
SMTP_SECURE=false
SMTP_USER=
SMTP_PWD=
POSTGRES_PASSWORD=testpassword123
POSTGRES_VERSION=14
POSTGRES_DATA_MOUNT=/var/lib/postgresql/data
S3_ACCESS_KEY_ID=testaccesskey
S3_SECRET_ACCESS_KEY=testsecretkey
GARAGE_RPC_SECRET=testrpcsecret
EOF
chmod 600 .env

export COMPOSE_PROJECT_NAME="$PROJECT"
export COMPOSE_FILE="$WORK/docker-compose.yml:$WORK/docker-compose.external-proxy.yml"
export COMPOSE_PROFILES=bundled-db

docker compose up -d db &>/dev/null
for _ in $(seq 1 45); do
  docker compose exec -T db pg_isready -q -h 127.0.0.1 -U postgres 2>/dev/null && break
  sleep 2
done

server_major() {
  docker compose exec -T db psql -tA -U postgres -d rallly -c "SHOW server_version" 2>/dev/null | cut -d. -f1
}
[ "$(server_major)" = "14" ] && ok "database is on PostgreSQL 14" || bad "expected PG14, got $(server_major)"

# Seed data that exercises what a dump/restore can plausibly mangle:
# unicode, quotes, NULLs, timestamps, and a sequence whose value must survive.
step "Seed known data"
docker compose exec -T db psql -q -v ON_ERROR_STOP=1 -U postgres -d rallly <<'SQL' &>/dev/null
CREATE TABLE polls (
  id SERIAL PRIMARY KEY,
  title TEXT NOT NULL,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO polls (title, notes) VALUES
  ('Team offsite', 'quotes '' and "double"'),
  ('Café ☕ planning — ünïcode', NULL),
  ('Backslash \ and newline'||chr(10)||'second line', 'ok');
CREATE TABLE votes (id SERIAL PRIMARY KEY, poll_id INT REFERENCES polls(id), choice TEXT);
INSERT INTO votes (poll_id, choice) SELECT 1, 'yes' FROM generate_series(1, 500);
SQL

fingerprint() {
  docker compose exec -T db psql -tA -v ON_ERROR_STOP=1 -U postgres -d rallly -c "
    SELECT (SELECT count(*) FROM polls) || '|' ||
           (SELECT count(*) FROM votes) || '|' ||
           (SELECT md5(string_agg(title || coalesce(notes,'<null>'), '~' ORDER BY id)) FROM polls) || '|' ||
           (SELECT last_value FROM polls_id_seq)" 2>/dev/null | tr -d '[:space:]'
}
BEFORE="$(fingerprint)"
[ -n "$BEFORE" ] && ok "seeded, fingerprint: $BEFORE" || bad "could not fingerprint seed data"

OLD_VOL="${PROJECT}_db-data"
docker volume inspect "$OLD_VOL" &>/dev/null && ok "PG14 volume exists ($OLD_VOL)" || bad "missing $OLD_VOL"

# ── The upgrade ──────────────────────────────────────────────────
step "Run ./rallly.sh upgrade-db"
UPGRADE_LOG="$WORK/upgrade.log"
if printf 'y\n' | ./rallly.sh upgrade-db > "$UPGRADE_LOG" 2>&1; then
  ok "upgrade-db exited 0"
else
  bad "upgrade-db exited non-zero (see $UPGRADE_LOG)"
  tail -25 "$UPGRADE_LOG" | sed 's/^/    /'
fi
grep -q "Restore verified" "$UPGRADE_LOG" && ok "reported 'Restore verified'" || bad "no 'Restore verified' in output"

# ── Assertions ───────────────────────────────────────────────────
step "Verify the outcome"
[ "$(server_major)" = "18" ] && ok "database now on PostgreSQL 18" || bad "expected PG18, got $(server_major)"

AFTER="$(fingerprint)"
if [ "$BEFORE" = "$AFTER" ]; then
  ok "data intact (counts, content hash, and sequence all match)"
else
  bad "data changed across the upgrade"
  echo "    before: $BEFORE"
  echo "    after:  $AFTER"
fi

# A restored sequence must keep issuing non-conflicting ids.
# -q suppresses the "INSERT 0 1" command tag, which would otherwise be
# concatenated onto the returned id.
NEWID="$(docker compose exec -T db psql -qtA -U postgres -d rallly \
  -c "INSERT INTO polls (title) VALUES ('post-upgrade') RETURNING id" 2>/dev/null | tr -d '[:space:]')"
[ "$NEWID" = "4" ] && ok "sequence continues correctly (new id=$NEWID)" \
  || bad "expected next id 4, got '$NEWID' — sequence not restored"

grep -q '^POSTGRES_VERSION=18$'                        .env && ok "POSTGRES_VERSION pinned to 18"      || bad "POSTGRES_VERSION not 18"
grep -q '^POSTGRES_DATA_MOUNT=/var/lib/postgresql$'    .env && ok "POSTGRES_DATA_MOUNT updated for 18" || bad "POSTGRES_DATA_MOUNT wrong"
grep -q '^POSTGRES_VOLUME=db-data-pg18$'               .env && ok "POSTGRES_VOLUME switched"           || bad "POSTGRES_VOLUME wrong"
[ "$(grep -c '^POSTGRES_VERSION=' .env)" = "1" ] && ok "no duplicate POSTGRES_VERSION lines" || bad "duplicate POSTGRES_VERSION lines"
[ "$(stat -f '%Lp' .env 2>/dev/null || stat -c '%a' .env)" = "600" ] && ok ".env still mode 600" || bad ".env permissions changed"

docker volume inspect "$OLD_VOL" &>/dev/null && ok "old PG14 volume retained for rollback" || bad "old volume was deleted"
ls backups/rallly_pg14_to_pg18_*.sql.gz &>/dev/null && ok "rollback dump written to ./backups" || bad "no dump artifact"
if compgen -G "backups/*.sql.gz" >/dev/null; then
  DUMPPERM="$(stat -f '%Lp' backups/*.sql.gz 2>/dev/null | head -1 || stat -c '%a' backups/*.sql.gz | head -1)"
  [ "$DUMPPERM" = "600" ] && ok "dump is private (mode $DUMPPERM)" || bad "dump mode $DUMPPERM, expected 600"
fi

# ── Idempotency ──────────────────────────────────────────────────
step "Re-run on an already-upgraded install"
RERUN="$(./rallly.sh upgrade-db 2>&1)"
grep -q "already on major 18" <<<"$RERUN" && ok "second run is a no-op" || bad "second run did not short-circuit"

# ── Result ───────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════"
echo "  passed: $pass    failed: $fail"
echo "════════════════════════════════════"
[ "$fail" -eq 0 ]
