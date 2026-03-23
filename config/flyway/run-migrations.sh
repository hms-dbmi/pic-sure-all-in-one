#!/bin/bash
# =============================================================================
# PIC-SURE Flyway Migration Runner
# =============================================================================
# Runs all database migrations in order:
#   1. Auth schema migrations (from pic-sure-auth-microapp)
#   2. PIC-SURE schema migrations (from pic-sure)
#   3. Project-specific migrations (if configured)
#
# This script runs inside the flyway-init container.
# =============================================================================

set -e

FLYWAY="/flyway/flyway"
DB_URL_BASE="jdbc:mysql://${DB_HOST:-picsure-db}:${DB_PORT:-3306}"
DB_USER="root"
DB_PASS="${DB_ROOT_PASSWORD}"

echo "[flyway] Starting PIC-SURE database migrations..."

# -------------------------------------------------------------------------
# 1. Auth schema migrations
# -------------------------------------------------------------------------
if [ -d "/migrations/auth" ] && [ "$(ls -A /migrations/auth 2>/dev/null)" ]; then
  echo "[flyway] Running auth schema migrations..."
  $FLYWAY \
    -url="${DB_URL_BASE}/auth?useSSL=false&allowPublicKeyRetrieval=true" \
    -user="$DB_USER" \
    -password="$DB_PASS" \
    -schemas=auth \
    -locations="filesystem:/migrations/auth" \
    -baselineOnMigrate=true \
    -ignoreMigrationPatterns="*:missing" \
    migrate
  echo "[flyway] Auth migrations complete."
else
  echo "[flyway] No auth migrations found. Skipping."
fi

# -------------------------------------------------------------------------
# 2. PIC-SURE schema migrations
# -------------------------------------------------------------------------
if [ -d "/migrations/picsure" ] && [ "$(ls -A /migrations/picsure 2>/dev/null)" ]; then
  echo "[flyway] Running picsure schema migrations..."
  $FLYWAY \
    -url="${DB_URL_BASE}/picsure?useSSL=false&allowPublicKeyRetrieval=true" \
    -user="$DB_USER" \
    -password="$DB_PASS" \
    -schemas=picsure \
    -locations="filesystem:/migrations/picsure" \
    -baselineOnMigrate=true \
    -ignoreMigrationPatterns="*:missing" \
    migrate
  echo "[flyway] PIC-SURE migrations complete."
else
  echo "[flyway] No picsure migrations found. Skipping."
fi

# -------------------------------------------------------------------------
# 3. Project-specific migrations (optional)
# -------------------------------------------------------------------------
if [ -d "/migrations/custom/auth" ] && [ "$(ls -A /migrations/custom/auth 2>/dev/null)" ]; then
  echo "[flyway] Running project-specific auth migrations..."
  $FLYWAY \
    -url="${DB_URL_BASE}/auth?useSSL=false&allowPublicKeyRetrieval=true" \
    -user="$DB_USER" \
    -password="$DB_PASS" \
    -schemas=auth \
    -locations="filesystem:/migrations/custom/auth" \
    -baselineOnMigrate=true \
    -ignoreMigrationPatterns="*:missing" \
    -table=flyway_custom_schema_history \
    migrate
fi

if [ -d "/migrations/custom/picsure" ] && [ "$(ls -A /migrations/custom/picsure 2>/dev/null)" ]; then
  echo "[flyway] Running project-specific picsure migrations..."
  $FLYWAY \
    -url="${DB_URL_BASE}/picsure?useSSL=false&allowPublicKeyRetrieval=true" \
    -user="$DB_USER" \
    -password="$DB_PASS" \
    -schemas=picsure \
    -locations="filesystem:/migrations/custom/picsure" \
    -baselineOnMigrate=true \
    -ignoreMigrationPatterns="*:missing" \
    -table=flyway_custom_schema_history \
    migrate
fi

echo "[flyway] All migrations complete."
