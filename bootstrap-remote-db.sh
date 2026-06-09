#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — Bootstrap Remote MySQL
# =============================================================================
# Creates/checks the remote auth and picsure schemas plus application users.
# This is only for DB_MODE=remote and is separate from normal migrations.
#
# Usage:
#   ./bootstrap-remote-db.sh
#   ./bootstrap-remote-db.sh --check
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

LOG_PREFIX="remote-db"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

CHECK_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=true ;;
    -h|--help)
      sed -n '2,9p' "$0"
      exit 0
      ;;
    *)
      error "Unknown option: $arg"
      exit 1
      ;;
  esac
done

require_env_var() {
  picsure_require_env_var "$1" "$1 is required for remote DB bootstrap."
}

mysql_root() {
  docker run --rm -i \
    -e MYSQL_PWD="${DB_ROOT_PASSWORD}" \
    mysql:8.0 \
    mysql -h "${DB_HOST}" -P "${DB_PORT:-3306}" -u "${DB_ROOT_USER:-root}" "$@"
}

mysql_app() {
  local user="$1"
  local password="$2"
  local database="$3"

  docker run --rm \
    -e MYSQL_PWD="$password" \
    mysql:8.0 \
    mysql -h "${DB_HOST}" -P "${DB_PORT:-3306}" -u "$user" "$database" -e "SELECT 1;" >/dev/null
}

count_query() {
  local query="$1"
  mysql_root -N -B -e "$query"
}

check_existing_app_user() {
  local user="$1"
  local password="$2"
  local database="$3"

  local user_count
  user_count="$(count_query "SELECT COUNT(*) FROM mysql.user WHERE User='${user}';")"
  if [ "$user_count" = "0" ]; then
    warn "User '$user' does not exist yet; bootstrap would create it."
    return 0
  fi

  local schema_count
  schema_count="$(count_query "SELECT COUNT(*) FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${database}';")"
  if [ "$schema_count" = "0" ]; then
    warn "Schema '$database' does not exist yet; cannot test '$user' connectivity."
    return 0
  fi

  if mysql_app "$user" "$password" "$database"; then
    info "User '$user' can connect to schema '$database'."
  else
    error "User '$user' exists but cannot connect to schema '$database'."
    return 1
  fi
}

run_check() {
  local failed=false

  info "Checking remote MySQL admin connectivity..."
  mysql_root -e "SELECT CURRENT_USER(), VERSION();" >/dev/null
  info "Admin connection succeeded as ${DB_ROOT_USER:-root}@${DB_HOST}:${DB_PORT:-3306}."

  if mysql_root -e "SHOW GRANTS FOR CURRENT_USER();" >/dev/null 2>&1; then
    info "Admin grants are readable."
  else
    warn "Could not read SHOW GRANTS for current admin user."
  fi

  if count_query "SELECT COUNT(*) FROM mysql.user;" >/dev/null 2>&1; then
    info "Admin can inspect mysql.user."
  else
    error "Admin cannot inspect mysql.user; bootstrap cannot verify/create users safely."
    return 1
  fi

  for schema in auth picsure; do
    schema_count="$(count_query "SELECT COUNT(*) FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${schema}';")"
    if [ "$schema_count" = "1" ]; then
      info "Schema '$schema' exists."
    else
      warn "Schema '$schema' does not exist yet; bootstrap would create it."
    fi
  done

  check_existing_app_user "picsure" "$DB_PICSURE_PASSWORD" "picsure" || failed=true
  check_existing_app_user "auth" "$DB_AUTH_PASSWORD" "auth" || failed=true
  check_existing_app_user "airflow" "$DB_AIRFLOW_PASSWORD" "auth" || failed=true
  check_existing_app_user "airflow" "$DB_AIRFLOW_PASSWORD" "picsure" || failed=true

  if [ "$failed" = true ]; then
    return 1
  fi

  info "Remote DB check complete."
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

if [ "$CHECK_ONLY" = "true" ]; then
  run_check
  exit 0
fi

info "Ensuring remote MySQL schemas and users exist..."
mysql_root <<SQL
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
