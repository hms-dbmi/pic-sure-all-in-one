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
# The authenticated probe below gets its own budget rather than sharing
# RETRIES: it only starts once the container is healthy, so time already spent
# waiting for health is not its to spend.
AUTH_RETRIES="$RETRIES"

if [ "${DB_MODE:-local}" = "remote" ]; then
  info "Waiting for remote MySQL at ${DB_HOST:-unset}:${DB_PORT:-3306}..."
  # Env-prefix + bare -e: the host shell puts the password in docker's
  # environment (not argv); docker forwards it by name into the container.
  until MYSQL_PWD="${DB_ROOT_PASSWORD:-}" docker run --rm \
    -e MYSQL_PWD \
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
  until [ "$(picsure_service_health picsure-db)" = healthy ]; do
    RETRIES=$((RETRIES - 1))
    if [ "$RETRIES" -le 0 ]; then
      error "picsure-db did not become healthy in time."
      error "Check logs: docker compose logs picsure-db"
      exit 1
    fi
    sleep "$SLEEP_SECONDS"
  done

  # "healthy" is not "ready to authenticate". The Compose healthcheck is
  # `mysqladmin ping`, which reports alive on access-denied AND against the
  # socket-only temporary server the mysql entrypoint runs while it initialises
  # an empty datadir (logged as "ready for connections ... port: 0"). On a
  # first install that lands seconds before root can log in, so a caller that
  # immediately runs a real query — init.sh's credential check — sees a
  # spurious failure on a brand-new volume.
  #
  # Probe over TCP to 127.0.0.1 rather than the container socket: the temporary
  # server runs with --skip-networking, so an answer on 3306 also proves the
  # entrypoint has finished (root grants applied, docker-entrypoint-initdb.d
  # scripts run) and the real mysqld is the one serving.
  info "Waiting for picsure-db to accept authenticated connections..."
  while ! probe_error="$(picsure_db_exec_mysql -h 127.0.0.1 -e "SELECT 1;" 2>&1)"; do
    # Access denied is a definitive answer from a fully started server: the
    # wait is over either way, and retrying would burn the whole budget before
    # anyone hears why. Not fatal here — this script's contract stays
    # "reachable" (the ping healthcheck also passed on access-denied before
    # this loop existed), and init.sh owns the stale-volume diagnosis with the
    # actionable message. Ours would be swallowed anyway: init.sh sends this
    # script's output to /dev/null unless --verbose/--log.
    if [[ "$probe_error" == *"Access denied"* ]]; then
      warn "picsure-db is accepting connections but rejected DB_ROOT_PASSWORD."
      break
    fi

    AUTH_RETRIES=$((AUTH_RETRIES - 1))
    if [ "$AUTH_RETRIES" -le 0 ]; then
      error "picsure-db did not accept an authenticated connection in time."
      error "Last error: $probe_error"
      error "Check logs: docker compose logs picsure-db"
      exit 1
    fi
    sleep "$SLEEP_SECONDS"
  done
fi

info "Database is ready."
