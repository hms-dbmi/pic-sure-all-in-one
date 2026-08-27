#!/usr/bin/env bash
set -euo pipefail

: "${DOCKER_CONFIG_DIR:?DOCKER_CONFIG_DIR must be set}"

sed_inplace() {
  if sed --version 2>/dev/null | grep -q "GNU sed"; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

env_value() {
  local key=$1
  local env_file=$2
  sed -n "s/^${key}=//p" "$env_file"
}

render_shared_secret() {
  local key=$1
  local placeholder=$2
  local byte_count=$3
  shift 3

  local resolved_value=""
  local env_file
  local current_value

  for env_file in "$@"; do
    if [ ! -f "$env_file" ]; then
      echo "ERROR: required service environment is missing: $env_file" >&2
      exit 2
    fi
    current_value="$(env_value "$key" "$env_file")"
    if [ -z "$current_value" ]; then
      echo "ERROR: $key is missing from $env_file" >&2
      exit 2
    fi
    if [ "$current_value" != "$placeholder" ]; then
      if [ -n "$resolved_value" ] && [ "$resolved_value" != "$current_value" ]; then
        echo "ERROR: $key differs between service environments" >&2
        exit 2
      fi
      resolved_value="$current_value"
    fi
  done

  if [ -z "$resolved_value" ]; then
    resolved_value="$(openssl rand -hex "$byte_count")"
  fi

  for env_file in "$@"; do
    sed_inplace "s|^${key}=${placeholder}$|${key}=${resolved_value}|" "$env_file"
  done
}

GATEWAY_ENV="$DOCKER_CONFIG_DIR/gateway/gateway.env"
OPERATIONS_ENV="$DOCKER_CONFIG_DIR/operations/operations.env"
QUERY_ENV="$DOCKER_CONFIG_DIR/query/query.env"
LOGGING_ENV="$DOCKER_CONFIG_DIR/logging/logging.env"

render_shared_secret \
  QUERY_SERVICE_INTERNAL_TOKEN __QUERY_SERVICE_INTERNAL_TOKEN__ 32 \
  "$GATEWAY_ENV" "$OPERATIONS_ENV" "$QUERY_ENV"
render_shared_secret \
  PICSURE_APPLICATION_TOKEN __PICSURE_APPLICATION_TOKEN__ 32 \
  "$GATEWAY_ENV" "$OPERATIONS_ENV" "$QUERY_ENV"
render_shared_secret \
  LOGGING_API_KEY __LOGGING_API_KEY__ 32 \
  "$GATEWAY_ENV" "$LOGGING_ENV"
render_shared_secret \
  AGGREGATE_OBFUSCATION_SALT __AGGREGATE_OBFUSCATION_SALT__ 16 \
  "$QUERY_ENV"

# mysql-docker/setup.sh owns this value, not this script. Catch it here because an
# unrendered password only surfaces later as operations-service failing to connect.
if grep -q '^SPRING_DATASOURCE_PASSWORD=__PICSURE_MYSQL_PASSWORD__$' "$OPERATIONS_ENV"; then
  echo "ERROR: SPRING_DATASOURCE_PASSWORD is still unrendered in $OPERATIONS_ENV" >&2
  echo "Run mysql-docker/setup.sh, or set it to match the picsure MySQL user." >&2
  exit 2
fi
