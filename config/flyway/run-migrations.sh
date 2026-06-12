#!/bin/bash
# =============================================================================
# PIC-SURE Flyway Migration Runner
# =============================================================================
# Runs all database migrations in order:
#   1. Auth schema migrations (from pic-sure-auth-microapp)
#   2. PIC-SURE schema migrations (from pic-sure)
#   3. Project-specific PIC-SURE migrations
#   4. Project-specific auth migrations
#
# This script runs inside the flyway-init container.
# =============================================================================

set -euo pipefail

FLYWAY="/flyway/flyway"
DB_URL_BASE="jdbc:mysql://${DB_HOST:-picsure-db}:${DB_PORT:-3306}"
DB_USER="${DB_ROOT_USER:-root}"
DB_PASS="${DB_ROOT_PASSWORD:-}"
ACTION="${FLYWAY_ACTION:-migrate}"
APP_UUID="${PICSURE_APPLICATION_ID:-}"
RESOURCE_UUID="${PICSURE_RESOURCE_ID:-}"
VIZ_RESOURCE_UUID="${PICSURE_VIZ_RESOURCE_ID:-}"

if [ "$ACTION" != "migrate" ] && [ "$ACTION" != "repair" ] && [ "$ACTION" != "check" ]; then
  echo "[flyway] FLYWAY_ACTION must be 'migrate', 'repair', or 'check'." >&2
  exit 1
fi

has_sql() {
  [ -d "$1" ] && find "$1" -maxdepth 1 -type f -name "*.sql" | grep -q .
}

require_sql() {
  local dir="$1"
  local label="$2"

  if ! has_sql "$dir"; then
    echo "[flyway] Missing required $label migrations at $dir." >&2
    echo "[flyway] Run ./clone-repos.sh or set the relevant *_SRC/MIGRATIONS_SRC paths." >&2
    exit 1
  fi
}

require_project_uuids() {
  if [ -z "$APP_UUID" ] || [ -z "$RESOURCE_UUID" ] || [ -z "$VIZ_RESOURCE_UUID" ]; then
    echo "[flyway] PICSURE_APPLICATION_ID, PICSURE_RESOURCE_ID, and PICSURE_VIZ_RESOURCE_ID are required." >&2
    echo "[flyway] Run ./init.sh to generate them, or define them in .env." >&2
    exit 1
  fi
}

uuid_to_hex() {
  echo "$1" | tr '[:lower:]' '[:upper:]' | tr -d '-'
}

prepare_project_migrations() {
  local source_dir="$1"
  local label="$2"
  local target_dir="$3"
  local app_uuid_hex
  local resource_uuid_hex
  local viz_resource_uuid_hex

  app_uuid_hex="$(uuid_to_hex "$APP_UUID")"
  resource_uuid_hex="$(uuid_to_hex "$RESOURCE_UUID")"
  viz_resource_uuid_hex="$(uuid_to_hex "$VIZ_RESOURCE_UUID")"

  rm -rf "$target_dir"
  mkdir -p "$target_dir"
  cp -a "$source_dir"/. "$target_dir"/

  if grep -R -n "__APPLICATION_UUID__\|__RESOURCE_UUID__\|__VISUALIZATION_RESOURCE_UUID__" "$target_dir" --include="*.sql" >/dev/null; then
    echo "[flyway] $label migrations contain legacy Jenkins UUID tokens; substituting them in a temporary copy."
    find "$target_dir" -type f -name "*.sql" -print0 | while IFS= read -r -d '' file; do
      sed -i \
        -e "s/__APPLICATION_UUID__/$app_uuid_hex/g" \
        -e "s/__RESOURCE_UUID__/$resource_uuid_hex/g" \
        -e "s/__VISUALIZATION_RESOURCE_UUID__/$viz_resource_uuid_hex/g" \
        "$file"
    done
  fi

  if grep -R -n "__APPLICATION_UUID__\|__RESOURCE_UUID__\|__VISUALIZATION_RESOURCE_UUID__" "$target_dir" --include="*.sql"; then
    echo "[flyway] Legacy UUID tokens remain after substitution in $label migrations." >&2
    exit 1
  fi
}

run_flyway() {
  local schema="$1"
  local location="$2"
  local table_arg="${3:-}"

  local url="${DB_URL_BASE}/${schema}?useSSL=false&allowPublicKeyRetrieval=true"
  local cmd=(
    "$FLYWAY"
    "-url=$url"
    "-user=$DB_USER"
    "-password=$DB_PASS"
    "-schemas=$schema"
    "-locations=filesystem:$location"
    "-baselineOnMigrate=true"
    "-ignoreMigrationPatterns=*:missing"
  )

  if [ -n "$table_arg" ]; then
    cmd+=("-table=$table_arg")
  fi

  local app_uuid_hex
  local resource_uuid_hex
  local viz_resource_uuid_hex
  app_uuid_hex="$(uuid_to_hex "$APP_UUID")"
  resource_uuid_hex="$(uuid_to_hex "$RESOURCE_UUID")"
  viz_resource_uuid_hex="$(uuid_to_hex "$VIZ_RESOURCE_UUID")"

  cmd+=(
    "-placeholders.picsureApplicationUuid=$APP_UUID"
    "-placeholders.picsureApplicationUuidHex=$app_uuid_hex"
    "-placeholders.picsureResourceUuid=$RESOURCE_UUID"
    "-placeholders.picsureResourceUuidHex=$resource_uuid_hex"
    "-placeholders.picsureVisualizationResourceUuid=$VIZ_RESOURCE_UUID"
    "-placeholders.picsureVisualizationResourceUuidHex=$viz_resource_uuid_hex"
    "$ACTION"
  )

  "${cmd[@]}"
}

check_placeholders() {
  local dir="$1"
  local label="$2"
  local failed=false

  if grep -R -n "__APPLICATION_UUID__\|__RESOURCE_UUID__\|__VISUALIZATION_RESOURCE_UUID__" "$dir" --include="*.sql"; then
    echo "[flyway] Legacy UUID tokens remain in $label migrations." >&2
    failed=true
  fi

  if grep -R -n "\${picsure[A-Za-z]*Uuid" "$dir" --include="*.sql" >/dev/null; then
    echo "[flyway] $label migrations use PIC-SURE UUID placeholders."
  fi

  if [ "$failed" = true ]; then
    exit 1
  fi
}

echo "[flyway] Starting PIC-SURE database migrations ($ACTION)..."

require_sql "/migrations/auth" "auth schema"
require_sql "/migrations/picsure" "picsure schema"
require_sql "/migrations/custom/picsure" "project-specific picsure"
require_sql "/migrations/custom/auth" "project-specific auth"
require_project_uuids

PREPARED_ROOT="/tmp/picsure-project-migrations"
PREPARED_PICSURE="$PREPARED_ROOT/picsure"
PREPARED_AUTH="$PREPARED_ROOT/auth"
prepare_project_migrations "/migrations/custom/picsure" "project-specific picsure" "$PREPARED_PICSURE"
prepare_project_migrations "/migrations/custom/auth" "project-specific auth" "$PREPARED_AUTH"

if [ "$ACTION" = "check" ]; then
  check_placeholders "$PREPARED_PICSURE" "project-specific picsure"
  check_placeholders "$PREPARED_AUTH" "project-specific auth"
  echo "[flyway] Migration inputs look valid."
  exit 0
fi

if [ -z "$DB_PASS" ]; then
  echo "[flyway] DB_ROOT_PASSWORD is required." >&2
  exit 1
fi

echo "[flyway] Running auth schema migrations..."
run_flyway "auth" "/migrations/auth"
echo "[flyway] Auth migrations complete."

echo "[flyway] Running picsure schema migrations..."
run_flyway "picsure" "/migrations/picsure"
echo "[flyway] PIC-SURE migrations complete."

echo "[flyway] Running project-specific picsure migrations..."
run_flyway "picsure" "$PREPARED_PICSURE" "flyway_custom_schema_history"

echo "[flyway] Running project-specific auth migrations..."
run_flyway "auth" "$PREPARED_AUTH" "flyway_custom_schema_history"

echo "[flyway] All migrations complete."
