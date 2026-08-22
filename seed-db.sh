#!/usr/bin/env bash
# =============================================================================
# PIC-SURE — Seed Database
# =============================================================================
# Runs AFTER docker compose up -d and ./run-migrations.sh. Requires the Flyway
# migrations to have been applied, then seeds the database with:
#   - Admin user
#   - Introspection token
#
# Usage:
#   docker compose up -d
#   ./run-migrations.sh
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

# Source .env
if [ ! -f "$SCRIPT_DIR/.env" ]; then
  error ".env not found. Run ./init.sh first."
  exit 1
fi
set -a
# shellcheck disable=SC1091
source "$SCRIPT_DIR/.env"
set +a

# db_mysql: run mysql as root. The HOST shell expands the password into
# docker's environment via the env-prefix assignment — never into its argv —
# and the BARE `-e MYSQL_PWD` (no =value) tells docker to forward the variable
# from its own environment into the container, so host ps shows only the name.
# (`-e MYSQL_PWD="$pass"` would expand the value into host argv.) The -i flag
# lets callers stream SQL on stdin, so secret-bearing statements (e.g. the
# introspection token, the admin email) stay out of argv as well.
db_mysql() {
  if [ "${DB_MODE:-local}" = "remote" ]; then
    MYSQL_PWD="${DB_ROOT_PASSWORD}" docker run --rm -i \
      -e MYSQL_PWD \
      mysql:8.0 \
      mysql -h "${DB_HOST}" -P "${DB_PORT:-3306}" -u "${DB_ROOT_USER:-root}" "$@"
  else
    MYSQL_PWD="${DB_ROOT_PASSWORD}" docker exec -i \
      -e MYSQL_PWD \
      picsure-db mysql -uroot "$@"
  fi
}

# sql_escape_quotes: double single quotes for safe interpolation into a SQL
# string literal (bash-3.2-safe). Values come from the trusted .env, but an
# apostrophe in e.g. ADMIN_EMAIL would otherwise break the statement.
sql_escape_quotes() {
  # Pattern \' matches a literal single quote; replacement '' is two literal
  # single quotes. (Bash 3.2 takes \' in the replacement literally as a
  # backslash-quote, so do not escape the quotes on the replacement side.)
  printf '%s' "${1//\'/''}"
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

# ---------------------------------------------------------------------------
# 1. Precondition — migrations must already be applied
# ---------------------------------------------------------------------------
# Everything below is plain DML: it writes into tables that only the Flyway
# passes create, and it depends on rows (roles, connections, privileges) that
# the project-specific pass inserts. Probing the custom history table covers
# both passes — the project-specific migrations are DML against core tables, so
# they cannot have succeeded unless the core pass ran first. Fail here rather
# than part-way through an INSERT.
#
# Recovery from a partly-applied run belongs to Flyway, not to this script:
# ./run-migrations.sh --repair clears the failed history rows; running
# ./run-migrations.sh again then applies the migrations.
# type <> 'BASELINE': the custom passes run with -baselineOnMigrate=true, so a
# pass that failed on its first real migration (and was then repaired) leaves a
# successful baseline marker behind — a row that proves nothing was applied.
MIGRATED=$(db_mysql -N -e \
  "SELECT LEAST(
     (SELECT COUNT(*) FROM auth.flyway_custom_schema_history WHERE success=1 AND version IS NOT NULL AND type <> 'BASELINE'),
     (SELECT COUNT(*) FROM picsure.flyway_custom_schema_history WHERE success=1 AND version IS NOT NULL AND type <> 'BASELINE'));" \
  2>/dev/null || echo "0")

if [ -z "$MIGRATED" ] || [ "$MIGRATED" = "0" ]; then
  error "Database migrations have not been applied — there is nothing to seed against."
  error "Run './run-migrations.sh' first, then re-run ./seed-db.sh."
  error "If a previous run failed part-way: './run-migrations.sh --repair' clears the"
  error "failed history rows, then './run-migrations.sh' applies the migrations."
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Admin User
# ---------------------------------------------------------------------------

ADMIN_EMAIL="${ADMIN_EMAIL:-}"

if [ -n "$ADMIN_EMAIL" ]; then
  # Escape single quotes so an apostrophe in the (trusted) email cannot break
  # the SQL string literal. The same escaped value is also valid inside the
  # JSON literal, since JSON does not treat single quotes specially.
  ADMIN_EMAIL_SQL=$(sql_escape_quotes "$ADMIN_EMAIL")

  # Check if user already exists
  EXISTING=$(db_mysql -N -e \
    "SELECT COUNT(*) FROM auth.user WHERE email='$ADMIN_EMAIL_SQL';" 2>/dev/null || echo "0")

  if [ "$EXISTING" = "0" ]; then
    info "Creating admin user: $ADMIN_EMAIL"
    USER_UUID=$(uuidgen | tr '[:lower:]' '[:upper:]' | sed 's/-//g')

    # SQL is fed on stdin (not -e argv) so the email never reaches the host
    # process listing.
    db_mysql 2>/dev/null <<SQL || { error "Failed to create admin user $ADMIN_EMAIL (are migrations applied?)."; exit 1; }
      INSERT INTO auth.user (uuid, auth0_metadata, general_metadata, acceptedTOS, connectionId, email, matched, subject, is_active, long_term_token)
      VALUES (
        UNHEX('$USER_UUID'), NULL, '{"email":"$ADMIN_EMAIL_SQL"}', NULL,
        (SELECT uuid FROM auth.connection WHERE label='Google'),
        '$ADMIN_EMAIL_SQL', 0, NULL, 1, NULL
      );
      INSERT INTO auth.user_role (user_id, role_id)
      VALUES (UNHEX('$USER_UUID'), UNHEX('002DC366B0D8420F998F885D0ED797FD'));
      INSERT INTO auth.user_role (user_id, role_id)
      VALUES (UNHEX('$USER_UUID'), UNHEX('797FD002DC366B0D8420F998F885D0ED'));
SQL

    info "Admin user created with Top Admin + User roles."
  else
    info "Admin user $ADMIN_EMAIL already exists. Skipping."
  fi
else
  warn "ADMIN_EMAIL not set in .env. No admin user created."
fi

# ---------------------------------------------------------------------------
# 3. Introspection Token in DB
# ---------------------------------------------------------------------------

INTRO_TOKEN="${PICSURE_INTROSPECTION_TOKEN:-}"

if [ -n "$INTRO_TOKEN" ]; then
  INTRO_TOKEN_SQL=$(sql_escape_quotes "$INTRO_TOKEN")
  # Feed the UPDATE on stdin so the token (a secret) never appears in the host
  # process listing.
  db_mysql 2>/dev/null <<SQL || { error "Failed to sync introspection token to database."; exit 1; }
    UPDATE auth.application SET token='$INTRO_TOKEN_SQL' WHERE name='PICSURE';
SQL
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
info "    docker compose restart psama"
echo ""
