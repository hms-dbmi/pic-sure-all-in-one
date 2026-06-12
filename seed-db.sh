#!/usr/bin/env bash
# =============================================================================
# PIC-SURE — Seed Database
# =============================================================================
# Runs AFTER docker compose up -d. Seeds the database with:
#   1. Baseline project-specific migrations (roles, connections, privileges)
#   2. Admin user
#   3. Visualization resource entry
#
# Usage:
#   docker compose up -d
#   ./seed-db.sh
#
# This is idempotent — safe to re-run.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PICSURE_ROOT="$SCRIPT_DIR"
export PICSURE_ROOT

LOG_PREFIX="seed"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

# shellcheck source=scripts/picsure-compose.sh
source "$SCRIPT_DIR/scripts/picsure-compose.sh"

# Portable sed -i (macOS needs '' argument)
sed_in_place() {
  picsure_sed_in_place "$@"
}

# Source .env
if [ ! -f "$SCRIPT_DIR/.env" ]; then
  error ".env not found. Run ./init.sh first."
  exit 1
fi
set -a
# shellcheck disable=SC1091
source "$SCRIPT_DIR/.env"
set +a

db_mysql() {
  if [ "${DB_MODE:-local}" = "remote" ]; then
    docker run --rm \
      -e MYSQL_PWD="${DB_ROOT_PASSWORD}" \
      mysql:8.0 \
      mysql -h "${DB_HOST}" -P "${DB_PORT:-3306}" -u "${DB_ROOT_USER:-root}" "$@"
  else
    docker exec picsure-db mysql -uroot -p"${DB_ROOT_PASSWORD}" "$@"
  fi
}

# Check DB is running
if [ "${DB_MODE:-local}" = "remote" ]; then
  if ! db_mysql -e "SELECT 1;" >/dev/null 2>&1; then
    error "Remote MySQL is not reachable at ${DB_HOST:-unset}:${DB_PORT:-3306}."
    exit 1
  fi
else
  if ! docker inspect --format='{{.State.Health.Status}}' picsure-db 2>/dev/null | grep -q healthy; then
    error "picsure-db is not healthy. Run 'docker compose up -d' first."
    exit 1
  fi
fi

ROOT_PASS="${DB_ROOT_PASSWORD}"
APP_ID="${PICSURE_APPLICATION_ID}"
APP_ID_HEX=$(echo "$APP_ID" | tr '[:lower:]' '[:upper:]' | sed 's/-//g')
RESOURCE_ID="${PICSURE_RESOURCE_ID}"
RESOURCE_ID_HEX=$(echo "$RESOURCE_ID" | tr '[:lower:]' '[:upper:]' | sed 's/-//g')

# ---------------------------------------------------------------------------
# 1. Baseline Migrations
# ---------------------------------------------------------------------------

MIGRATIONS_SRC="${MIGRATIONS_SRC:-$SCRIPT_DIR/repos/PIC-SURE-Migrations}"

if [ -d "$MIGRATIONS_SRC/Baseline" ]; then
  info "Running Baseline project-specific migrations..."

  # Check each schema independently (success=1 versioned rows)
  ALREADY_AUTH=$(db_mysql -N -e \
    "SELECT COUNT(*) FROM auth.flyway_custom_schema_history WHERE success=1 AND version IS NOT NULL;" 2>/dev/null || echo "0")
  ALREADY_PICSURE=$(db_mysql -N -e \
    "SELECT COUNT(*) FROM picsure.flyway_custom_schema_history WHERE success=1 AND version IS NOT NULL;" 2>/dev/null || echo "0")

  # Always clean up any failed migration records so Flyway will retry on partial failures
  db_mysql -e \
    "DELETE FROM auth.flyway_custom_schema_history WHERE success=0;" 2>/dev/null || true
  db_mysql -e \
    "DELETE FROM picsure.flyway_custom_schema_history WHERE success=0;" 2>/dev/null || true

  # Build Flyway connection args (network + URLs) based on DB_MODE
  FLYWAY_NETWORK_ARGS=(--network "${COMPOSE_PROJECT_NAME:-picsure}_app")
  AUTH_FLYWAY_URL="jdbc:mysql://picsure-db:3306/auth?useSSL=false&allowPublicKeyRetrieval=true"
  PICSURE_FLYWAY_URL="jdbc:mysql://picsure-db:3306/picsure?useSSL=false&allowPublicKeyRetrieval=true"
  if [ "${DB_MODE:-local}" = "remote" ]; then
    FLYWAY_NETWORK_ARGS=()
    AUTH_FLYWAY_URL="jdbc:mysql://${DB_HOST}:${DB_PORT:-3306}/auth?useSSL=false&allowPublicKeyRetrieval=true"
    PICSURE_FLYWAY_URL="jdbc:mysql://${DB_HOST}:${DB_PORT:-3306}/picsure?useSSL=false&allowPublicKeyRetrieval=true"
  fi

  # Run auth baseline (skip if already applied)
  if [ "$ALREADY_AUTH" = "0" ] || [ "$ALREADY_AUTH" = "" ]; then
    info "Running auth baseline migrations..."
    # Prepare auth migrations (substitute application UUID).
    # Note: do NOT name this TMPDIR — that would change where mktemp itself works.
    AUTH_SQL_TMP=$(mktemp -d)
    cp "$MIGRATIONS_SRC/Baseline/auth/"*.sql "$AUTH_SQL_TMP/" 2>/dev/null || true
    sed_in_place "s/__APPLICATION_UUID__/$APP_ID_HEX/g" "$AUTH_SQL_TMP/"*.sql 2>/dev/null || true
    docker run --rm \
      ${FLYWAY_NETWORK_ARGS[@]+"${FLYWAY_NETWORK_ARGS[@]}"} \
      -v "$AUTH_SQL_TMP:/flyway/sql:ro" \
      flyway/flyway:latest \
      -url="$AUTH_FLYWAY_URL" \
      -user="${DB_ROOT_USER:-root}" -password="$ROOT_PASS" \
      -schemas=auth \
      -locations="filesystem:/flyway/sql" \
      -baselineOnMigrate=true \
      -ignoreMigrationPatterns="*:missing" \
      -table=flyway_custom_schema_history \
      migrate
    rm -rf "$AUTH_SQL_TMP"
    info "Auth baseline migrations applied."
  else
    info "Auth baseline migrations already applied. Skipping."
  fi

  # Run picsure baseline (skip if already applied)
  if [ "$ALREADY_PICSURE" = "0" ] || [ "$ALREADY_PICSURE" = "" ]; then
    info "Running picsure baseline migrations..."
    PICSURE_SQL_TMP=$(mktemp -d)
    cp "$MIGRATIONS_SRC/Baseline/picsure/"*.sql "$PICSURE_SQL_TMP/" 2>/dev/null || true
    sed_in_place "s/__RESOURCE_UUID__/$RESOURCE_ID_HEX/g" "$PICSURE_SQL_TMP/"*.sql 2>/dev/null || true
    # Fix hardcoded HPDS resource UUID to match ours
    sed_in_place "s/16A7B3241CBF4333B65B3EA2AF954313/$RESOURCE_ID_HEX/g" "$PICSURE_SQL_TMP/"*.sql 2>/dev/null || true
    docker run --rm \
      ${FLYWAY_NETWORK_ARGS[@]+"${FLYWAY_NETWORK_ARGS[@]}"} \
      -v "$PICSURE_SQL_TMP:/flyway/sql:ro" \
      flyway/flyway:latest \
      -url="$PICSURE_FLYWAY_URL" \
      -user="${DB_ROOT_USER:-root}" -password="$ROOT_PASS" \
      -schemas=picsure \
      -locations="filesystem:/flyway/sql" \
      -baselineOnMigrate=true \
      -ignoreMigrationPatterns="*:missing" \
      -table=flyway_custom_schema_history \
      migrate
    rm -rf "$PICSURE_SQL_TMP"
    info "Picsure baseline migrations applied."
  else
    info "Picsure baseline migrations already applied. Skipping."
  fi
else
  warn "PIC-SURE-Migrations repo not found at $MIGRATIONS_SRC"
  warn "Clone it: git clone https://github.com/hms-dbmi/PIC-SURE-Migrations.git"
  warn "Skipping Baseline migrations."
fi

# ---------------------------------------------------------------------------
# 2. Admin User
# ---------------------------------------------------------------------------

ADMIN_EMAIL="${ADMIN_EMAIL:-}"

if [ -n "$ADMIN_EMAIL" ]; then
  # Check if user already exists
  EXISTING=$(db_mysql -N -e \
    "SELECT COUNT(*) FROM auth.user WHERE email='$ADMIN_EMAIL';" 2>/dev/null || echo "0")

  if [ "$EXISTING" = "0" ]; then
    info "Creating admin user: $ADMIN_EMAIL"
    USER_UUID=$(uuidgen | tr '[:lower:]' '[:upper:]' | sed 's/-//g')

    db_mysql -e "
      INSERT INTO auth.user (uuid, auth0_metadata, general_metadata, acceptedTOS, connectionId, email, matched, subject, is_active, long_term_token)
      VALUES (
        UNHEX('$USER_UUID'), NULL, '{\"email\":\"$ADMIN_EMAIL\"}', NULL,
        (SELECT uuid FROM auth.connection WHERE label='Google'),
        '$ADMIN_EMAIL', 0, NULL, 1, NULL
      );
      INSERT INTO auth.user_role (user_id, role_id)
      VALUES (UNHEX('$USER_UUID'), UNHEX('002DC366B0D8420F998F885D0ED797FD'));
      INSERT INTO auth.user_role (user_id, role_id)
      VALUES (UNHEX('$USER_UUID'), UNHEX('797FD002DC366B0D8420F998F885D0ED'));
    " 2>/dev/null || { error "Failed to create admin user $ADMIN_EMAIL (are baseline migrations applied?)."; exit 1; }

    info "Admin user created with Top Admin + User roles."
  else
    info "Admin user $ADMIN_EMAIL already exists. Skipping."
  fi
else
  warn "ADMIN_EMAIL not set in .env. No admin user created."
fi

# ---------------------------------------------------------------------------
# 3. Visualization Resource
# ---------------------------------------------------------------------------

VIZ_ID="${PICSURE_VIZ_RESOURCE_ID:-}"

if [ -n "$VIZ_ID" ]; then
  VIZ_ID_HEX=$(echo "$VIZ_ID" | tr '[:lower:]' '[:upper:]' | sed 's/-//g')

  EXISTING=$(db_mysql -N -e \
    "SELECT COUNT(*) FROM picsure.resource WHERE uuid=UNHEX('$VIZ_ID_HEX');" 2>/dev/null || echo "0")

  if [ "$EXISTING" = "0" ]; then
    info "Creating visualization resource entry..."
    db_mysql -e "
      INSERT INTO picsure.resource (uuid, targetURL, resourceRSPath, description, name, token, hidden)
      VALUES (
        UNHEX('$VIZ_ID_HEX'), NULL, NULL,
        'PIC-SURE Visualization Resource', 'visualization', NULL, TRUE
      );
    " picsure 2>/dev/null || { error "Failed to create visualization resource (are migrations applied?)."; exit 1; }
    info "Visualization resource created."
  else
    info "Visualization resource already exists. Skipping."
  fi
fi

# ---------------------------------------------------------------------------
# 4. Introspection Token in DB
# ---------------------------------------------------------------------------

INTRO_TOKEN="${PICSURE_INTROSPECTION_TOKEN:-}"

if [ -n "$INTRO_TOKEN" ]; then
  db_mysql -e \
    "UPDATE auth.application SET token='$INTRO_TOKEN' WHERE name='PICSURE';" 2>/dev/null \
    || { error "Failed to sync introspection token to database."; exit 1; }
  info "Introspection token synced to database."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
info "======================================"
info "  Database seeded successfully!"
info "======================================"
info ""
info "  Restart services to pick up changes:"
info "    docker compose restart wildfly psama"
echo ""
