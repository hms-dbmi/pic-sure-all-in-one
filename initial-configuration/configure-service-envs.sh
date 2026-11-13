#!/usr/bin/env bash
set -euo pipefail

: "${DOCKER_CONFIG_DIR:?DOCKER_CONFIG_DIR must be set}"

env_value() {
  local key=$1
  local env_file=$2
  sed -n "s/^${key}=//p" "$env_file" | tail -n 1 | tr -d '\r'
}

shared_secret_value() {
  local key=$1
  local placeholder=$2
  local missing_key=$3
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
      if [ "$missing_key" = allow ] && ! grep -q "^${key}=" "$env_file"; then
        continue
      fi
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

  printf '%s\n' "$resolved_value"
}

replace_placeholder() {
  local key=$1
  local placeholder=$2
  local value=$3
  local env_file=$4
  local temp_file

  if ! tr -d '\r' < "$env_file" | grep -qxF "${key}=${placeholder}"; then
    return 0
  fi

  temp_file="$(mktemp "${env_file}.render.XXXXXX")"
  RENDERED_VALUE="$value" awk -v key="$key" -v placeholder="$placeholder" '
    {
      line = $0
      sub(/\r$/, "", line)
      if (line == key "=" placeholder) {
        print key "=" ENVIRON["RENDERED_VALUE"]
      } else {
        print
      }
    }
  ' "$env_file" > "$temp_file"
  cat "$temp_file" > "$env_file"
  rm -f "$temp_file"
}

render_shared_secret() {
  local key=$1
  local placeholder=$2
  local byte_count=$3
  shift 3

  local resolved_value
  local env_file

  resolved_value="$(shared_secret_value "$key" "$placeholder" require "$@")"
  if [ -z "$resolved_value" ]; then
    resolved_value="$(openssl rand -hex "$byte_count")"
  fi

  for env_file in "$@"; do
    replace_placeholder "$key" "$placeholder" "$resolved_value" "$env_file"
  done
}

ensure_placeholder() {
  local key=$1
  local placeholder=$2
  shift 2

  local env_file
  for env_file in "$@"; do
    if grep -q "^${key}=" "$env_file"; then
      continue
    fi
    if [ -s "$env_file" ] && [ -n "$(tail -c 1 "$env_file")" ]; then
      echo >> "$env_file"
    fi
    echo "${key}=${placeholder}" >> "$env_file"
  done
}

GATEWAY_ENV="$DOCKER_CONFIG_DIR/gateway/gateway.env"
OPERATIONS_ENV="$DOCKER_CONFIG_DIR/operations/operations.env"
QUERY_ENV="$DOCKER_CONFIG_DIR/query/query.env"
LOGGING_ENV="$DOCKER_CONFIG_DIR/logging/logging.env"

INTERNAL_TOKEN_ENVS=("$QUERY_ENV")
for optional_env in \
  "$DOCKER_CONFIG_DIR/hpds/hpds.env" \
  "$DOCKER_CONFIG_DIR/dictionary/dictionary.env" \
  "$DOCKER_CONFIG_DIR/visualization/visualization.env"; do
  if [ -f "$optional_env" ]; then
    INTERNAL_TOKEN_ENVS+=("$optional_env")
  fi
done

render_shared_secret \
  QUERY_SERVICE_INTERNAL_TOKEN __QUERY_SERVICE_INTERNAL_TOKEN__ 32 \
  "$GATEWAY_ENV" "$OPERATIONS_ENV" "$QUERY_ENV"
render_shared_secret \
  PICSURE_APPLICATION_TOKEN __PICSURE_APPLICATION_TOKEN__ 32 \
  "$GATEWAY_ENV" "$OPERATIONS_ENV" "$QUERY_ENV"
render_shared_secret \
  LOGGING_API_KEY __LOGGING_API_KEY__ 32 \
  "$GATEWAY_ENV" "$OPERATIONS_ENV" "$LOGGING_ENV"
render_shared_secret \
  AGGREGATE_OBFUSCATION_SALT __AGGREGATE_OBFUSCATION_SALT__ 16 \
  "$QUERY_ENV"
if [ ! -f "$QUERY_ENV" ]; then
  echo "ERROR: required service environment is missing: $QUERY_ENV" >&2
  exit 2
fi
shared_secret_value \
  PICSURE_INTERNAL_TOKEN __PICSURE_INTERNAL_TOKEN__ allow \
  "${INTERNAL_TOKEN_ENVS[@]}" > /dev/null
ensure_placeholder \
  PICSURE_INTERNAL_TOKEN __PICSURE_INTERNAL_TOKEN__ \
  "${INTERNAL_TOKEN_ENVS[@]}"
render_shared_secret \
  PICSURE_INTERNAL_TOKEN __PICSURE_INTERNAL_TOKEN__ 32 \
  "${INTERNAL_TOKEN_ENVS[@]}"

# mysql-docker/setup.sh owns this value, not this script. Catch it here because an
# unrendered password only surfaces later as operations-service failing to connect.
if grep -q '^SPRING_DATASOURCE_PASSWORD=__PICSURE_MYSQL_PASSWORD__$' "$OPERATIONS_ENV"; then
  echo "ERROR: SPRING_DATASOURCE_PASSWORD is still unrendered in $OPERATIONS_ENV" >&2
  echo "Run mysql-docker/setup.sh, or set it to match the picsure MySQL user." >&2
  exit 2
fi
