#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — Bootstrap Remote MySQL
# =============================================================================
# Creates/checks the remote auth and picsure schemas plus application users.
# This is only for DB_MODE=remote and is separate from normal migrations.
#
# Usage:
#   ./bootstrap-remote-db.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[remote-db]${NC} $*"; }
error() { echo -e "${RED}[remote-db]${NC} $*" >&2; }

require_env_var() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    error "$name is required for remote DB bootstrap."
    return 1
  fi
}

if [ ! -f "$ENV_FILE" ]; then
  error ".env not found. Run: cp .env.example .env"
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [ "${DB_MODE:-local}" != "remote" ]; then
  error "DB_MODE must be remote to run this command."
  exit 1
fi

failed=false
require_env_var "DB_HOST" || failed=true
require_env_var "DB_PORT" || failed=true
require_env_var "DB_ROOT_PASSWORD" || failed=true
require_env_var "DB_PICSURE_PASSWORD" || failed=true
require_env_var "DB_AUTH_PASSWORD" || failed=true
require_env_var "DB_AIRFLOW_PASSWORD" || failed=true

if [ "$failed" = true ]; then
  exit 1
fi

info "Waiting for remote MySQL..."
"$SCRIPT_DIR/scripts/db-wait.sh"

info "Ensuring remote MySQL schemas and users exist..."
docker run --rm -i \
  -e MYSQL_PWD="${DB_ROOT_PASSWORD}" \
  mysql:8.0 \
  mysql -h "${DB_HOST}" -P "${DB_PORT:-3306}" -u "${DB_ROOT_USER:-root}" <<SQL
CREATE DATABASE IF NOT EXISTS auth;
CREATE DATABASE IF NOT EXISTS picsure;
CREATE USER IF NOT EXISTS 'picsure'@'%' IDENTIFIED BY '${DB_PICSURE_PASSWORD}';
GRANT ALL PRIVILEGES ON picsure.* TO 'picsure'@'%';
CREATE USER IF NOT EXISTS 'auth'@'%' IDENTIFIED BY '${DB_AUTH_PASSWORD}';
GRANT ALL PRIVILEGES ON auth.* TO 'auth'@'%';
CREATE USER IF NOT EXISTS 'airflow'@'%' IDENTIFIED BY '${DB_AIRFLOW_PASSWORD}';
GRANT ALL PRIVILEGES ON auth.* TO 'airflow'@'%';
GRANT ALL PRIVILEGES ON picsure.* TO 'airflow'@'%';
FLUSH PRIVILEGES;
SQL

info "Remote DB bootstrap complete."
