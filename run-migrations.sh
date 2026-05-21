#!/usr/bin/env bash
# =============================================================================
# PIC-SURE — Run Database Migrations
# =============================================================================
# Runs the Compose Flyway init service on demand.
#
# Usage:
#   ./run-migrations.sh
#   ./run-migrations.sh --check
#   ./run-migrations.sh --repair
#   ./run-migrations.sh --no-restart
#   ./run-migrations.sh --bootstrap-remote-db
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
PICSURE_ROOT="$SCRIPT_DIR"
export PICSURE_ROOT

# shellcheck source=scripts/picsure-compose.sh
source "$SCRIPT_DIR/scripts/picsure-compose.sh"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[migrate]${NC} $*"; }
warn()  { echo -e "${YELLOW}[migrate]${NC} $*"; }
error() { echo -e "${RED}[migrate]${NC} $*" >&2; }

ACTION="migrate"
RESTART_APPS=true

has_sql() {
  [ -d "$1" ] && find "$1" -maxdepth 1 -type f -name "*.sql" | grep -q .
}

require_sql_dir() {
  local dir="$1"
  local label="$2"

  if ! has_sql "$dir"; then
    error "Missing required $label migrations at $dir"
    return 1
  fi

  info "$label migrations: $dir"
}

require_env_var() {
  local name="$1"

  if [ -z "${!name:-}" ]; then
    error "$name is required. Run ./init.sh or set it in .env."
    return 1
  fi
}

check_remote_db_env() {
  local failed=false

  if [ "${DB_MODE:-local}" != "remote" ]; then
    return 0
  fi

  info "Remote DB mode enabled."
  require_env_var "DB_HOST" || failed=true
  require_env_var "DB_PORT" || failed=true
  require_env_var "DB_ROOT_PASSWORD" || failed=true
  require_env_var "DB_PICSURE_PASSWORD" || failed=true
  require_env_var "DB_AUTH_PASSWORD" || failed=true
  require_env_var "DB_AIRFLOW_PASSWORD" || failed=true

  if [ "$failed" = true ]; then
    return 1
  fi
}

check_legacy_tokens() {
  local dir="$1"
  local label="$2"

  if grep -R -n "__APPLICATION_UUID__\|__RESOURCE_UUID__" "$dir" --include="*.sql"; then
    error "Legacy UUID tokens remain in $label migrations."
    return 1
  fi
}

run_check() {
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  local migration_name="${MIGRATION_NAME:-Baseline}"
  local migrations_src="${MIGRATIONS_SRC:-./repos/PIC-SURE-Migrations}"
  local psama_src="${PSAMA_SRC:-./repos/pic-sure-auth-microapp}"
  local wildfly_src="${WILDFLY_SRC:-./repos/pic-sure}"
  local auth_dir="$psama_src/pic-sure-auth-db/db/sql"
  local picsure_dir="$wildfly_src/pic-sure-api-data/src/main/resources/db/sql"
  local project_auth_dir="$migrations_src/$migration_name/auth"
  local project_picsure_dir="$migrations_src/$migration_name/picsure"
  local failed=false

  info "Checking migration inputs for MIGRATION_NAME=$migration_name"

  require_env_var "PICSURE_APPLICATION_ID" || failed=true
  require_env_var "PICSURE_RESOURCE_ID" || failed=true
  require_env_var "PICSURE_VIZ_RESOURCE_ID" || failed=true
  check_remote_db_env || failed=true

  require_sql_dir "$auth_dir" "core auth" || failed=true
  require_sql_dir "$picsure_dir" "core picsure" || failed=true
  require_sql_dir "$project_picsure_dir" "project picsure" || failed=true
  require_sql_dir "$project_auth_dir" "project auth" || failed=true

  if [ "$failed" = false ]; then
    check_legacy_tokens "$project_picsure_dir" "project picsure" || failed=true
    check_legacy_tokens "$project_auth_dir" "project auth" || failed=true
  fi

  picsure_compose config --quiet || failed=true

  if [ "$failed" = true ]; then
    error "Migration check failed."
    exit 1
  fi

  info "Migration inputs look valid."
  exit 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)
      ACTION="check"
      RESTART_APPS=false
      ;;
    --repair)
      ACTION="repair"
      ;;
    --no-restart)
      RESTART_APPS=false
      ;;
    --bootstrap-remote-db)
      "$SCRIPT_DIR/bootstrap-remote-db.sh"
      exit 0
      ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      error "Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

if [ ! -f "$ENV_FILE" ]; then
  error ".env not found. Run ./init.sh first."
  exit 1
fi

cd "$SCRIPT_DIR"
picsure_load_env "$ENV_FILE"

if [ "$ACTION" = "check" ]; then
  run_check
fi

info "Waiting for database..."
"$SCRIPT_DIR/scripts/db-wait.sh"

info "Running Flyway $ACTION..."
picsure_compose rm -sf flyway-init >/dev/null 2>&1 || true
FLYWAY_ACTION="$ACTION" picsure_compose up --no-deps --force-recreate --exit-code-from flyway-init flyway-init

if [ "$ACTION" = "migrate" ] && [ "$RESTART_APPS" = true ]; then
  running_services="$(picsure_compose ps --services --filter status=running 2>/dev/null || true)"
  restart_targets=()
  if echo "$running_services" | grep -qx "wildfly"; then
    restart_targets+=("wildfly")
  fi
  if echo "$running_services" | grep -qx "psama"; then
    restart_targets+=("psama")
  fi

  if [ "${#restart_targets[@]}" -gt 0 ]; then
    info "Restarting services to pick up migrated data: ${restart_targets[*]}"
    picsure_compose restart "${restart_targets[@]}"
  else
    warn "wildfly and psama are not running; skipping app restarts."
  fi
fi

info "Flyway $ACTION complete."
