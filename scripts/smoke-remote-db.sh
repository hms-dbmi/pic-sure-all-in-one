#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — Remote DB Smoke Test
# =============================================================================
# Exercises the remote DB bootstrap and migration input check against a
# disposable MySQL container exposed on a host port.
#
# Usage:
#   ./scripts/smoke-remote-db.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
BACKUP_ENV=""
CONTAINER_NAME="${REMOTE_DB_SMOKE_CONTAINER:-picsure-remote-db-smoke}"
PORT="${REMOTE_DB_SMOKE_PORT:-33061}"
ROOT_PASSWORD="${REMOTE_DB_SMOKE_ROOT_PASSWORD:-SmokeRootPass123}"
DB_HOST_VALUE=""

cleanup() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  if [ -n "$BACKUP_ENV" ] && [ -f "$BACKUP_ENV" ]; then
    mv "$BACKUP_ENV" "$ENV_FILE"
  else
    rm -f "$ENV_FILE"
  fi
}
trap cleanup EXIT

cd "$SCRIPT_DIR"

if [ -f "$ENV_FILE" ]; then
  BACKUP_ENV="$(mktemp)"
  cp "$ENV_FILE" "$BACKUP_ENV"
fi

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker run -d \
  --name "$CONTAINER_NAME" \
  -e MYSQL_ROOT_PASSWORD="$ROOT_PASSWORD" \
  mysql:8.0 >/dev/null

DB_HOST_VALUE="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER_NAME")"

cat > "$ENV_FILE" <<EOF
AUTH0_CLIENT_ID=smoke-client
AUTH0_CLIENT_SECRET=smoke-secret
AUTH0_TENANT=avillachlab
ADMIN_EMAIL=smoke@example.org
AUTH_MODE=required
DB_MODE=remote
DB_HOST=$DB_HOST_VALUE
DB_PORT=3306
DB_ROOT_USER=root
DB_ROOT_PASSWORD=$ROOT_PASSWORD
DB_PICSURE_PASSWORD=smoke-picsure-password
DB_AUTH_PASSWORD=smoke-auth-password
DB_AIRFLOW_PASSWORD=smoke-airflow-password
PICSURE_APPLICATION_ID=00000000-0000-0000-0000-000000000001
PICSURE_RESOURCE_ID=00000000-0000-0000-0000-000000000002
PICSURE_VIZ_RESOURCE_ID=00000000-0000-0000-0000-000000000003
PICSURE_INTROSPECTION_TOKEN=smoke-token
COMPOSE_PROJECT_NAME=picsure
EOF

echo "[remote-db-smoke] Waiting for disposable MySQL..."
./scripts/db-wait.sh

echo "[remote-db-smoke] Checking remote DB before bootstrap..."
./bootstrap-remote-db.sh --check

echo "[remote-db-smoke] Bootstrapping remote DB..."
./bootstrap-remote-db.sh

echo "[remote-db-smoke] Checking remote DB after bootstrap..."
./bootstrap-remote-db.sh --check

echo "[remote-db-smoke] Checking migration inputs..."
./run-migrations.sh --check

echo "[remote-db-smoke] Verifying schemas and users..."
verify_count="$(docker run --rm \
  -e MYSQL_PWD="$ROOT_PASSWORD" \
  mysql:8.0 \
  mysql -h "$DB_HOST_VALUE" -P 3306 -uroot -N -e "
    SELECT COUNT(*) FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME IN ('auth', 'picsure');
    SELECT COUNT(*) FROM mysql.user WHERE User IN ('auth', 'picsure', 'airflow');
  " | tr '\n' ' ')"

if [ "$verify_count" != "2 3 " ]; then
  echo "[remote-db-smoke] Expected 2 schemas and 3 users, got: $verify_count" >&2
  exit 1
fi

echo "[remote-db-smoke] Complete"
