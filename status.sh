#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — Status
# =============================================================================
# Read-only summary of local configuration, release refs, repo state, Compose
# services, and migration readiness.
#
# Usage:
#   ./status.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
PICSURE_ROOT="$SCRIPT_DIR"
export PICSURE_ROOT

LOG_PREFIX="status"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

# shellcheck source=scripts/picsure-compose.sh
source "$SCRIPT_DIR/scripts/picsure-compose.sh"

ok() { echo -e "${PICSURE_GREEN}[ok]${PICSURE_NC} $*"; }
warn() { echo -e "${PICSURE_YELLOW}[warn]${PICSURE_NC} $*"; }
bad() { echo -e "${PICSURE_RED}[bad]${PICSURE_NC} $*"; }

section() {
  echo ""
  echo "== $* =="
}

ref_value() {
  local key="$1"
  printf '%s' "${!key:-main}"
}

repo_status_line() {
  local repo_dir="$1"
  local env_name="$2"
  local ref
  local name

  ref="$(ref_value "$env_name")"
  name="$(basename "$repo_dir")"

  if [ ! -d "$repo_dir/.git" ]; then
    printf '  %-34s missing target=%s\n' "$name" "$ref"
    return 0
  fi

  local current
  current="$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  if [ "$current" = "HEAD" ]; then
    current="$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null || echo detached)"
  fi

  local state="clean"
  if ! git -C "$repo_dir" diff --quiet || ! git -C "$repo_dir" diff --cached --quiet; then
    state="dirty"
  fi

  printf '  %-34s current=%-18s target=%-18s %s\n' "$name" "$current" "$ref" "$state"
}

docker_reachable() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

cd "$SCRIPT_DIR"

section "Environment"
if [ -f "$ENV_FILE" ]; then
  ok ".env found"
  picsure_load_env "$ENV_FILE"
else
  warn ".env missing; run: cp .env.example .env"
fi

echo "  COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-picsure}"
echo "  DB_MODE=${DB_MODE:-local}"
if [ "${DB_MODE:-local}" = "remote" ]; then
  echo "  DB_HOST=${DB_HOST:-unset}"
  echo "  DB_PORT=${DB_PORT:-3306}"
fi
echo "  AUTH_MODE=${AUTH_MODE:-required}"
echo "  PICSURE_IMAGE_TAG=${PICSURE_IMAGE_TAG:-LATEST}"

section "Release Control"
echo "  repo:   ${RELEASE_CONTROL_REPO:-https://github.com/hms-dbmi/pic-sure-baseline-release-control}"
echo "  branch: ${RELEASE_CONTROL_BRANCH:-main}"
if [ -n "${RELEASE_CONTROL_COMMIT:-}" ]; then
  echo "  commit: ${RELEASE_CONTROL_COMMIT}"
elif [ -d "$SCRIPT_DIR/.data/release-control/.git" ]; then
  echo "  commit: $(git -C "$SCRIPT_DIR/.data/release-control" rev-parse HEAD 2>/dev/null || echo unknown)"
else
  echo "  commit: unknown"
fi

for key in \
  PICSURE_REF \
  HPDS_REF \
  PSAMA_REF \
  FRONTEND_REF \
  MIGRATIONS_REF \
  DICTIONARY_REF \
  DICTIONARY_ETL_REF \
  VISUALIZATION_REF \
  LOGGING_REF \
  LOGGING_CLIENT_REF; do
  printf '  %-24s %s\n' "$key" "$(ref_value "$key")"
done

section "Repos"
repo_status_line "$SCRIPT_DIR/repos/pic-sure" "PICSURE_REF"
repo_status_line "$SCRIPT_DIR/repos/pic-sure-hpds" "HPDS_REF"
repo_status_line "$SCRIPT_DIR/repos/pic-sure-auth-microapp" "PSAMA_REF"
repo_status_line "$SCRIPT_DIR/repos/PIC-SURE-Frontend" "FRONTEND_REF"
repo_status_line "$SCRIPT_DIR/repos/PIC-SURE-Migrations" "MIGRATIONS_REF"
repo_status_line "$SCRIPT_DIR/repos/picsure-dictionary" "DICTIONARY_REF"
repo_status_line "$SCRIPT_DIR/repos/picsure-dictionary-etl" "DICTIONARY_ETL_REF"
repo_status_line "$SCRIPT_DIR/repos/PIC-SURE-Logging" "LOGGING_REF"
repo_status_line "$SCRIPT_DIR/repos/PIC-SURE-Logging-Client" "LOGGING_CLIENT_REF"
repo_status_line "$SCRIPT_DIR/repos/pic-sure-visualization-resource" "VISUALIZATION_REF"

section "Compose"
if ! command -v docker >/dev/null 2>&1; then
  bad "docker command not found"
elif ! docker compose version >/dev/null 2>&1; then
  bad "docker compose is unavailable"
elif ! docker_reachable; then
  warn "Docker daemon is not reachable; skipping service status"
else
  if picsure_compose config --quiet; then
    ok "Compose config is valid"
  else
    bad "Compose config is invalid"
  fi

  echo ""
  picsure_compose ps
fi

section "Database"
if [ ! -f "$ENV_FILE" ]; then
  warn "Skipping database checks because .env is missing"
elif [ "${DB_MODE:-local}" = "remote" ]; then
  echo "  remote MySQL: ${DB_HOST:-unset}:${DB_PORT:-3306}"
  echo "  run non-mutating check: ./bootstrap-remote-db.sh --check"
else
  echo "  bundled MySQL service: picsure-db"
fi

section "Migrations"
if [ ! -f "$ENV_FILE" ]; then
  warn "Skipping migration input check because .env is missing"
else
  migration_output="$(mktemp "${TMPDIR:-/tmp}/picsure-status-migrations.XXXXXX")"
  if ./run-migrations.sh --check >"$migration_output" 2>&1; then
    ok "Migration inputs look valid"
  else
    bad "Migration input check failed"
    cat "$migration_output"
  fi
  rm -f "$migration_output"
fi
