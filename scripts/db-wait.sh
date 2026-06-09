#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — Wait for Database
# =============================================================================
#
# Usage:
#   ./scripts/db-wait.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
PICSURE_ROOT="$SCRIPT_DIR"
export PICSURE_ROOT

LOG_PREFIX="db-wait"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

# shellcheck source=scripts/picsure-compose.sh
source "$SCRIPT_DIR/scripts/picsure-compose.sh"

if [ ! -f "$ENV_FILE" ]; then
  error ".env not found. Run: cp .env.example .env"
  exit 1
fi

picsure_load_env "$ENV_FILE"

RETRIES="${DB_WAIT_RETRIES:-30}"
SLEEP_SECONDS="${DB_WAIT_SLEEP_SECONDS:-2}"

if [ "${DB_MODE:-local}" = "remote" ]; then
  info "Waiting for remote MySQL at ${DB_HOST:-unset}:${DB_PORT:-3306}..."
  until docker run --rm \
    -e MYSQL_PWD="${DB_ROOT_PASSWORD:-}" \
    mysql:8.0 \
    mysql -h "${DB_HOST}" -P "${DB_PORT:-3306}" -u "${DB_ROOT_USER:-root}" -e "SELECT 1;" >/dev/null 2>&1; do
    RETRIES=$((RETRIES - 1))
    if [ "$RETRIES" -le 0 ]; then
      error "Remote MySQL did not become reachable in time."
      exit 1
    fi
    sleep "$SLEEP_SECONDS"
  done
else
  info "Starting bundled picsure-db if needed..."
  picsure_compose up -d picsure-db >/dev/null
  info "Waiting for bundled picsure-db to become healthy..."
  until docker inspect --format='{{.State.Health.Status}}' picsure-db 2>/dev/null | grep -q healthy; do
    RETRIES=$((RETRIES - 1))
    if [ "$RETRIES" -le 0 ]; then
      error "picsure-db did not become healthy in time."
      error "Check logs: docker compose logs picsure-db"
      exit 1
    fi
    sleep "$SLEEP_SECONDS"
  done
fi

info "Database is ready."
