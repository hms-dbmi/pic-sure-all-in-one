#!/bin/bash
# =============================================================================
# PIC-SURE Dictionary Flyway Migration Runner
# =============================================================================
# Runs the dictionary Postgres migrations (monorepo
# services/picsure-dictionary/db/flyway) against dictionary-db.
#
# The baseline DDL (services/picsure-dictionary/db/schema.sql) is applied once
# by the Postgres initdb hook and creates everything inside the `dict` schema.
# Flyway therefore runs against the connection's *default* schema (`public`),
# which stays empty apart from flyway_schema_history.  That keeps `migrate`
# honest on a fresh database — the default schema is empty, so Flyway applies
# V1 onward with no baseline instead of silently baselining over V1.  Every
# statement in the migrations is explicitly `dict.`-qualified, so the search
# path does not matter.
#
# This script runs inside the flyway-dictionary-init container.
# =============================================================================

set -euo pipefail

FLYWAY="/flyway/flyway"
ACTION="${FLYWAY_ACTION:-migrate}"
DB_HOST="${POSTGRES_HOST:-dictionary-db}"
DB_PORT="${POSTGRES_PORT:-5432}"
DB_NAME="${POSTGRES_DB:-dictionary}"
MIGRATIONS_DIR="/migrations/dictionary"

if [ "$ACTION" != "migrate" ] && [ "$ACTION" != "repair" ] && [ "$ACTION" != "check" ]; then
  echo "[flyway-dict] FLYWAY_ACTION must be 'migrate', 'repair', or 'check'." >&2
  exit 1
fi

has_sql() {
  [ -d "$1" ] && find "$1" -maxdepth 1 -type f -name "*.sql" | grep -q .
}

if ! has_sql "$MIGRATIONS_DIR"; then
  echo "[flyway-dict] Missing required dictionary migrations at $MIGRATIONS_DIR." >&2
  echo "[flyway-dict] Run ./clone-repos.sh or set PICSURE_SRC." >&2
  exit 1
fi

if [ -z "${POSTGRES_USER:-}" ] || [ -z "${POSTGRES_PASSWORD:-}" ]; then
  echo "[flyway-dict] POSTGRES_USER and POSTGRES_PASSWORD are required." >&2
  echo "[flyway-dict] Run ./init.sh to generate config/dictionary/dictionary.env." >&2
  exit 1
fi

if [ "$ACTION" = "check" ]; then
  echo "[flyway-dict] Dictionary migration inputs look valid."
  exit 0
fi

echo "[flyway-dict] Running dictionary Postgres migrations ($ACTION)..."

# No -schemas and no -baselineOnMigrate, matching the reference: Flyway writes
# flyway_schema_history into the default schema and applies V1 onward.
args=("-locations=filesystem:$MIGRATIONS_DIR" -connectRetries=60)
if [ "$ACTION" = "migrate" ]; then
  # The reference's repair pass omits this flag; only migrate carries it.
  args+=(-validateMigrationNaming=true)
fi

# Credentials travel through Flyway's own environment variables rather than the
# -user=/-password= argv flags, so they never surface in a process listing.
FLYWAY_URL="jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}" \
FLYWAY_USER="$POSTGRES_USER" \
FLYWAY_PASSWORD="$POSTGRES_PASSWORD" \
  "$FLYWAY" "${args[@]}" "$ACTION"

echo "[flyway-dict] Dictionary migrations complete."
