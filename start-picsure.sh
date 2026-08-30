#!/usr/bin/env bash
# shellcheck disable=SC1091

# A note to developers: if you use /usr/local/docker-config to refer to a place on the host file system
# 99 times out of 100 you are WRONG and you have just made a bug. Please:
# - Consider using $DOCKER_CONFIG_DIR instead
# - Challenge your own understanding of where files are located in docker and on the host file system and
# how that does or doesn't change the commands you run when inside Jenkins

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_CONFIG_DIR="${DOCKER_CONFIG_DIR:-/usr/local/docker-config}"
# Use this for file system checks. Use DOCKER_CONFIG_DIR for docker commands.
# Except for --env_file commands, which refer to the current file system, not the root fs
CURRENT_FS_DOCKER_CONFIG_DIR="${CURRENT_FS_DOCKER_CONFIG_DIR:-$DOCKER_CONFIG_DIR}"
AIO_HEALTH_TIMEOUT_SECONDS="${AIO_HEALTH_TIMEOUT_SECONDS:-180}"
AIO_HEALTH_POLL_SECONDS="${AIO_HEALTH_POLL_SECONDS:-2}"

fail() {
  echo "ERROR: $*" >&2
  exit 2
}

default_rollout_file() {
  local filename=$1
  if [[ -f "$SCRIPT_DIR/$filename" ]]; then
    printf '%s/%s\n' "$SCRIPT_DIR" "$filename"
  else
    printf '%s/initial-configuration/jenkins/jenkins-docker/%s\n' "$SCRIPT_DIR" "$filename"
  fi
}

require_httpd_frozen() {
  local restart_policy
  if docker container inspect httpd >/dev/null 2>&1; then
    [[ "$(docker inspect --format='{{.State.Running}}' httpd)" != "true" ]] || fail "httpd is running; banner management writes are not fail closed"
    restart_policy=$(docker inspect --format='{{.HostConfig.RestartPolicy.Name}}' httpd)
    [[ "$restart_policy" == "no" ]] || fail "httpd restart policy is $restart_policy; banner management writes are not restart-proof fail closed"
  fi
}

validate_rollback_state() {
  local state_file=$1
  local contract_file
  local source_file
  local expected_contract_commit
  local expected_contract_sha
  local actual_contract_sha
  local phase0
  local phase1
  local phase2
  local key
  local image
  local attested_id
  local actual_id
  local active_id
  local active_image

  [[ -f "$state_file" ]] || fail "rollback state file not found: $state_file"
  contract_file="${AIO_ROLLOUT_CONTRACT_FILE:-$(default_rollout_file banner-rollout-contract.json)}"
  source_file="${AIO_ROLLOUT_SOURCE_FILE:-$(default_rollout_file banner-rollout-source.json)}"
  [[ -f "$contract_file" ]] || fail "rollout contract not found: $contract_file"
  [[ -f "$source_file" ]] || fail "rollout contract source metadata not found: $source_file"
  [[ -f "$SCRIPT_DIR/aio-sha256.sh" ]] || fail "checksum helper not found: $SCRIPT_DIR/aio-sha256.sh"
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  # shellcheck source=aio-sha256.sh
  . "$SCRIPT_DIR/aio-sha256.sh"

  expected_contract_commit=$(jq -er '.contractSourceCommit | select(type == "string" and test("^[0-9a-f]{40}$"))' "$source_file") || fail "rollout source metadata is invalid: $source_file"
  expected_contract_sha=$(jq -er '.contractSha256 | select(type == "string" and test("^[0-9a-f]{64}$"))' "$source_file") || fail "rollout source metadata is invalid: $source_file"
  actual_contract_sha=$(sha256_file "$contract_file") || exit $?
  [[ "$actual_contract_sha" == "$expected_contract_sha" ]] || fail "local rollout contract checksum does not match backend $expected_contract_commit"
  phase0=$(jq -er '.rollbackPhases[0]' "$contract_file") || fail "rollout contract is missing rollback phase 0"
  phase1=$(jq -er '.rollbackPhases[1]' "$contract_file") || fail "rollout contract is missing rollback phase 1"
  phase2=$(jq -er '.rollbackPhases[2]' "$contract_file") || fail "rollout contract is missing rollback phase 2"

  jq -e \
    --arg commit "$expected_contract_commit" \
    --arg checksum "$expected_contract_sha" \
    --arg phase0 "$phase0" \
    --arg phase1 "$phase1" \
    --arg phase2 "$phase2" '
      .schemaVersion == 1 and
      .contractSourceCommit == $commit and
      .contractSha256 == $checksum and
      .completedPhases == [$phase0, $phase1, $phase2] and
      .forwardSchemaRetained == true and
      .downMigrationRequested == false
    ' "$state_file" >/dev/null || fail "rollback state does not match the current fail-closed contract"

  require_httpd_frozen

  for key in frontend psama operations query gateway; do
    image=$(jq -er ".rollbackImages.${key}" "$state_file") || fail "rollbackImages.$key is missing"
    [[ "$image" == *:* && "$image" != *":LATEST" && "$image" != *":latest" ]] || fail "rollbackImages.$key must name an exact, non-LATEST local image tag"
    attested_id=$(jq -er ".rollbackImageIds.${key}" "$state_file") || fail "rollbackImageIds.$key is missing"
    [[ "$attested_id" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "rollbackImageIds.$key must be a sha256 image ID"
    actual_id=$(docker image inspect --format='{{.Id}}' "$image") || fail "rollback image is unavailable: $image"
    [[ "$actual_id" == "$attested_id" ]] || fail "rollback image $image changed after operator attestation"
    case "$key" in
      frontend) active_image="hms-dbmi/pic-sure-frontend:LATEST" ;;
      psama) active_image="hms-dbmi/psama:LATEST" ;;
      operations) active_image="hms-dbmi/pic-sure-operations-service:LATEST" ;;
      query) active_image="hms-dbmi/pic-sure-hpds-query-service:LATEST" ;;
      gateway) active_image="hms-dbmi/pic-sure-gateway:LATEST" ;;
    esac
    active_id=$(docker image inspect --format='{{.Id}}' "$active_image") || fail "rollback target image is unavailable: $active_image"
    [[ "$active_id" == "$attested_id" ]] || fail "$active_image is not the attested rollback image"
  done
}

START_MODE=forward
ROLLBACK_STATE_FILE=""
case "$#:$1" in
  0:)
    ;;
  1:--forward)
    ;;
  2:--rollback-state)
    START_MODE=rollback
    ROLLBACK_STATE_FILE=$2
    ;;
  *)
    fail "usage: $0 [--forward | --rollback-state <rollback-state.json>]"
    ;;
esac

for value_name in AIO_HEALTH_TIMEOUT_SECONDS AIO_HEALTH_POLL_SECONDS; do
  [[ "${!value_name}" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: $value_name must be a positive integer." >&2; exit 2; }
done
for value_name in AIO_PUBLISH_FRONTEND AIO_RECREATE_PSAMA_AFTER_BACKEND AIO_ROLLBACK_STATE_VERIFIED; do
  [[ -z "${!value_name+x}" ]] || fail "$value_name is caller-controlled and no longer supported"
done
[[ -z "${AIO_GATEWAY_HEALTH_MODE+x}" ]] || fail "AIO_GATEWAY_HEALTH_MODE is caller-controlled and no longer supported"

if [[ "$START_MODE" == "rollback" ]]; then
  validate_rollback_state "$ROLLBACK_STATE_FILE"
  AIO_PUBLISH_FRONTEND=false
  AIO_RECREATE_PSAMA_AFTER_BACKEND=true
  GATEWAY_HEALTH_COMMAND='wget -q --spider http://127.0.0.1:8080/actuator/health/liveness || exit 1'
else
  AIO_PUBLISH_FRONTEND=true
  AIO_RECREATE_PSAMA_AFTER_BACKEND=false
  GATEWAY_HEALTH_COMMAND='wget -q --spider http://127.0.0.1:8080/operations/banners/active/v2 || exit 1'
fi

stop_and_remove_container() {
  local container_name=$1

  if ! docker container inspect "$container_name" >/dev/null 2>&1; then
    return 0
  fi
  docker stop "$container_name" && docker rm "$container_name"
}

assert_container_running() {
  local container_name=$1
  local running
  running=$(docker inspect --format='{{.State.Running}}' "$container_name") || return 1
  if [[ "$running" != "true" ]]; then
    echo "ERROR: $container_name did not remain running." >&2
    return 1
  fi
}

wait_for_container_health() {
  local container_name=$1
  local elapsed=0
  local health

  while (( elapsed < AIO_HEALTH_TIMEOUT_SECONDS )); do
    health=$(docker inspect --format='{{.State.Health.Status}}' "$container_name") || return 1
    case "$health" in
      healthy)
        return 0
        ;;
      unhealthy)
        echo "ERROR: $container_name reported unhealthy." >&2
        return 1
        ;;
    esac
    sleep "$AIO_HEALTH_POLL_SECONDS"
    ((elapsed += AIO_HEALTH_POLL_SECONDS))
  done
  echo "ERROR: $container_name did not become healthy within $AIO_HEALTH_TIMEOUT_SECONDS seconds." >&2
  return 1
}

require_file() {
  local path=$1
  if [[ ! -f "$path" ]]; then
    echo "ERROR: required rollout configuration is missing: $path" >&2
    return 1
  fi
}

if [ -f "$CURRENT_FS_DOCKER_CONFIG_DIR/setProxy.sh" ]; then
   . "$CURRENT_FS_DOCKER_CONFIG_DIR/setProxy.sh"
fi

# Optional services
[[ -d "$CURRENT_FS_DOCKER_CONFIG_DIR/hpds" ]] && INCLUDE_HPDS=true || INCLUDE_HPDS=false
echo "INCLUDE_HPDS=$INCLUDE_HPDS"
[[ -d "$CURRENT_FS_DOCKER_CONFIG_DIR/dictionary" ]] && INCLUDE_DICTIONARY=true || INCLUDE_DICTIONARY=false
echo "INCLUDE_DICTIONARY=$INCLUDE_DICTIONARY"
[[ -d "$CURRENT_FS_DOCKER_CONFIG_DIR/dictionary/dump" ]] && INCLUDE_AGG_DICT=true || INCLUDE_AGG_DICT=false
echo "INCLUDE_AGG_DICT=$INCLUDE_AGG_DICT"
[[ -d "$CURRENT_FS_DOCKER_CONFIG_DIR/passthru" ]] && INCLUDE_PASSTHRU=true || INCLUDE_PASSTHRU=false
echo "INCLUDE_PASSTHRU=$INCLUDE_PASSTHRU"
[[ -d "$CURRENT_FS_DOCKER_CONFIG_DIR/logging" ]] && INCLUDE_LOGGING=true || INCLUDE_LOGGING=false
echo "INCLUDE_LOGGING=$INCLUDE_LOGGING"
[[ -d "$CURRENT_FS_DOCKER_CONFIG_DIR/visualization" ]] && INCLUDE_VISUALIZATION=true || INCLUDE_VISUALIZATION=false
echo "INCLUDE_VISUALIZATION=$INCLUDE_VISUALIZATION"
[[ -d "$CURRENT_FS_DOCKER_CONFIG_DIR/gateway" ]] && INCLUDE_GATEWAY=true || INCLUDE_GATEWAY=false
echo "INCLUDE_GATEWAY=$INCLUDE_GATEWAY"
[[ -d "$CURRENT_FS_DOCKER_CONFIG_DIR/operations" ]] && INCLUDE_OPERATIONS=true || INCLUDE_OPERATIONS=false
echo "INCLUDE_OPERATIONS=$INCLUDE_OPERATIONS"
[[ -d "$CURRENT_FS_DOCKER_CONFIG_DIR/query" ]] && INCLUDE_QUERY=true || INCLUDE_QUERY=false
echo "INCLUDE_QUERY=$INCLUDE_QUERY"

# The gateway-era AIO cannot safely publish a banner-capable frontend without
# every authorization and request-path service. Fail before changing containers.
require_file "$CURRENT_FS_DOCKER_CONFIG_DIR/httpd/httpd.env" || exit 2
require_file "$CURRENT_FS_DOCKER_CONFIG_DIR/httpd/httpd-vhosts.conf" || exit 2
require_file "$CURRENT_FS_DOCKER_CONFIG_DIR/psama/psama.env" || exit 2
require_file "$CURRENT_FS_DOCKER_CONFIG_DIR/operations/operations.env" || exit 2
require_file "$CURRENT_FS_DOCKER_CONFIG_DIR/query/query.env" || exit 2
require_file "$CURRENT_FS_DOCKER_CONFIG_DIR/gateway/gateway.env" || exit 2

# Docker Volumes
export PICSURE_BANNER_VOLUME="-v $DOCKER_CONFIG_DIR/httpd/banner_config.json:/usr/local/apache2/htdocs/picsureui/settings/banner_config.json"
export PSAMA_TRUSTSTORE_VOLUME="-v $DOCKER_CONFIG_DIR/psama/application.truststore:/usr/local/tomcat/conf/application.truststore"
if [ -f "$DOCKER_CONFIG_DIR/httpd/custom_httpd_volumes" ]; then
	CUSTOM_HTTPD_VOLUMES=$(cat "$DOCKER_CONFIG_DIR/httpd/custom_httpd_volumes")
	export CUSTOM_HTTPD_VOLUMES
fi

# Debug Ports
echo "This script sets debug ports if you set specific variables"
echo "Example: if you set HPDS_DEBUG_PORT=5005, it will expose 5005 on the hpds container"
echo "You will still have to manually edit the corrosponding .env file"
echo "So that Java knows to support remote debugging"
echo "Looking for ports in the following vars:"
echo "  HPDS_DEBUG_PORT, PSAMA_DEBUG_PORT, DICTIONARY_DEBUG_PORT"
echo "  AGGREGATE_DEBUG_PORT, PASSTHRU_DEBUG_PORT"
HPDS_DEBUG="${HPDS_DEBUG_PORT:+-p $HPDS_DEBUG_PORT:$HPDS_DEBUG_PORT }"
PSAMA_DEBUG="${PSAMA_DEBUG_PORT:+-p $PSAMA_DEBUG_PORT:$PSAMA_DEBUG_PORT }"
DICTIONARY_DEBUG="${DICTIONARY_DEBUG_PORT:+-p $DICTIONARY_DEBUG_PORT:$DICTIONARY_DEBUG_PORT }"
AGGREGATE_DEBUG="${AGGREGATE_DEBUG_PORT:+-p $AGGREGATE_DEBUG_PORT:$AGGREGATE_DEBUG_PORT }"
PASSTHRU_DEBUG="${PASSTHRU_DEBUG_PORT:+-p $PASSTHRU_DEBUG_PORT:$PASSTHRU_DEBUG_PORT }"


# Docker networks
# External network. Can talk to the internet
docker network inspect picsure >/dev/null 2>&1 || docker network create picsure
# Internal networks. Cannot talk to the internet
docker network inspect dictionary >/dev/null 2>&1 || docker network create --internal dictionary
docker network inspect hpds >/dev/null 2>&1 || docker network create --internal hpds


# Start Commands

# When logging is enabled, every Java service that uses pic-sure-logging-client
# (hpds, psama, dictionary-api) gets LOGGING_API_KEY and
# LOGGING_SERVICE_URL injected as individual -e flags sourced from logging.env.
# We deliberately do NOT pass logging.env as a second --env-file to those
# containers because it also contains PSL-only config (PORT, ENVIRONMENT, etc.)
# whose names collide with other frameworks (e.g. Spring Boot reads PORT).
# pic-sure-logging itself still gets the full file via --env-file.
if $INCLUDE_LOGGING; then
  set -a
  . "$CURRENT_FS_DOCKER_CONFIG_DIR/logging/logging.env"
  set +a
  LOGGING_ENVS="-e LOGGING_API_KEY=$LOGGING_API_KEY -e LOGGING_SERVICE_URL=$LOGGING_SERVICE_URL"
  if [[ -z "${LOGGING_API_KEY:-}" ]]; then
    echo "WARNING: Logging is enabled but LOGGING_API_KEY is empty in logging.env"
  fi
  if [[ -z "${LOGGING_SERVICE_URL:-}" ]]; then
    echo "WARNING: Logging is enabled but LOGGING_SERVICE_URL is empty in logging.env"
  fi
  docker stop pic-sure-logging && docker rm pic-sure-logging
  docker run --name=pic-sure-logging --restart always \
    --network=picsure \
    --env-file "$CURRENT_FS_DOCKER_CONFIG_DIR/logging/logging.env" \
    -v "$DOCKER_CONFIG_DIR/log/logging-docker-logs/:/app/logs" \
    -d hms-dbmi/pic-sure-logging:LATEST \
    || exit 2
else
  LOGGING_ENVS=""
  echo "Logging disabled (no $DOCKER_CONFIG_DIR/logging/ directory)"
fi


if $INCLUDE_HPDS; then
  docker stop hpds && docker rm hpds
  # shellcheck disable=SC2086
  docker run --name=hpds --restart always --network=picsure --network=hpds \
    -v "$DOCKER_CONFIG_DIR/hpds:/opt/local/hpds" \
    -v "$DOCKER_CONFIG_DIR/hpds/all:/opt/local/hpds/all" \
    -v "$DOCKER_CONFIG_DIR"/log/hpds-logs/:/var/log/ \
    -v "$DOCKER_CONFIG_DIR/hpds_csv/:/usr/local/docker-config/hpds_csv/" \
    $HPDS_DEBUG \
    -v "$DOCKER_CONFIG_DIR/aws_uploads/:/gic_query_results/" \
    --env-file "$CURRENT_FS_DOCKER_CONFIG_DIR/hpds/hpds.env" \
    $LOGGING_ENVS \
    -d hms-dbmi/pic-sure-hpds:LATEST \
    || exit 2
fi

start_psama() {
  stop_and_remove_container psama || return 2
  # shellcheck disable=SC2086
  docker run --name=psama --restart always \
    --network=picsure \
    --health-cmd='wget -q --spider http://127.0.0.1:8090/auth/actuator/health || exit 1' \
    --health-interval=10s --health-timeout=5s --health-start-period=30s --health-retries=5 \
    --env-file "$CURRENT_FS_DOCKER_CONFIG_DIR/psama/psama.env" \
    $LOGGING_ENVS \
    -v "$DOCKER_CONFIG_DIR/log/psama-docker-logs/:/var/log/" \
    $PSAMA_DEBUG \
    $PSAMA_TRUSTSTORE_VOLUME \
    -d hms-dbmi/psama:LATEST \
    || return 2
  assert_container_running psama
}

if [[ "$AIO_RECREATE_PSAMA_AFTER_BACKEND" == "false" ]]; then
  start_psama || exit 2
fi


# WildFly is no longer part of the all-in-one (the rewrite's gateway + services replaced it).
# Remove a leftover container from an older deployment so it cannot keep serving legacy paths.
docker stop wildfly 2>/dev/null; docker rm wildfly 2>/dev/null || true

if $INCLUDE_OPERATIONS; then
  stop_and_remove_container pic-sure-operations-service || exit 2
  docker run --name=pic-sure-operations-service --restart always --network=picsure \
    --health-cmd='wget -q --spider http://127.0.0.1:8080/operations/actuator/health/readiness || exit 1' \
    --health-interval=10s --health-timeout=5s --health-start-period=60s --health-retries=6 \
    --env-file "$CURRENT_FS_DOCKER_CONFIG_DIR/operations/operations.env" \
    -d hms-dbmi/pic-sure-operations-service:LATEST \
    || exit 2
  assert_container_running pic-sure-operations-service || exit 2
fi

if $INCLUDE_QUERY; then
  stop_and_remove_container pic-sure-hpds-query-service || exit 2
  docker run --name=pic-sure-hpds-query-service --restart always --network=picsure \
    --health-cmd='wget -q --spider http://127.0.0.1:8080/actuator/health/liveness || exit 1' \
    --health-interval=10s --health-timeout=5s --health-start-period=60s --health-retries=6 \
    --env-file "$CURRENT_FS_DOCKER_CONFIG_DIR/query/query.env" \
    -d hms-dbmi/pic-sure-hpds-query-service:LATEST \
    || exit 2
  assert_container_running pic-sure-hpds-query-service || exit 2
fi

if $INCLUDE_GATEWAY; then
  stop_and_remove_container gateway || exit 2
  docker run --name=gateway --restart always --network=picsure \
    --health-cmd="$GATEWAY_HEALTH_COMMAND" \
    --health-interval=10s --health-timeout=5s --health-start-period=60s --health-retries=6 \
    --env-file "$CURRENT_FS_DOCKER_CONFIG_DIR/gateway/gateway.env" \
    -d hms-dbmi/pic-sure-gateway:LATEST \
    || exit 2
  assert_container_running gateway || exit 2
fi

if $INCLUDE_DICTIONARY; then
  docker start dictionary-db
  docker stop dictionary-api && docker rm dictionary-api
  # shellcheck disable=SC2086
  docker run --name dictionary-api --restart always \
   --network=picsure --network=dictionary \
   $DICTIONARY_DEBUG \
    -v "$DOCKER_CONFIG_DIR/log/dictionary-docker-logs/:/var/log/" \
   --env-file "$CURRENT_FS_DOCKER_CONFIG_DIR/dictionary/dictionary.env" \
   $LOGGING_ENVS \
   -d avillach/dictionary-api:latest \
   || exit 2
fi

if $INCLUDE_AGG_DICT; then
  docker stop dictionary-dump && docker rm dictionary-dump
  # shellcheck disable=SC2086
  docker run --name dictionary-dump --restart always \
    --network=dictionary \
    --env-file "$CURRENT_FS_DOCKER_CONFIG_DIR/dictionary/dictionary.env" \
    $AGGREGATE_DEBUG \
    -v "$DOCKER_CONFIG_DIR/log/agg-dict-docker-logs/:/var/log/" \
    -v "$DOCKER_CONFIG_DIR/dictionary/dump/application.properties:/application.properties" \
    -d avillach/dictionary-dump:latest \
   || exit 2
fi

if $INCLUDE_PASSTHRU; then
  docker stop passthru && docker rm passthru
  # shellcheck disable=SC2086
  docker run --restart always --name passthru --network picsure --network dictionary \
    -v "$DOCKER_CONFIG_DIR/passthru/application.properties:/application.properties" \
    -v "$DOCKER_CONFIG_DIR/log/passthru-docker-logs/:/var/log/" \
    --env-file "$CURRENT_FS_DOCKER_CONFIG_DIR/passthru/passthru.env" \
    $PASSTHRU_DEBUG \
    -d hms-dbmi/pic-sure-passthru:LATEST \
    || exit 2
fi

if $INCLUDE_VISUALIZATION; then
  docker stop visualization && docker rm visualization
  # shellcheck disable=SC2086
  docker run --restart always --name visualization --network picsure \
    -v "$DOCKER_CONFIG_DIR/log/visualization-docker-logs/:/var/log/" \
    --env-file "$CURRENT_FS_DOCKER_CONFIG_DIR/visualization/visualization.env" \
    $LOGGING_ENVS \
    -d hms-dbmi/pic-sure-visualization:LATEST \
    || exit 2
fi

if [[ "$AIO_RECREATE_PSAMA_AFTER_BACKEND" == "true" ]]; then
  start_psama || exit 2
fi

wait_for_container_health psama || exit 2
wait_for_container_health pic-sure-operations-service || exit 2
wait_for_container_health pic-sure-hpds-query-service || exit 2
wait_for_container_health gateway || exit 2

if [[ "$AIO_PUBLISH_FRONTEND" == "true" ]]; then
  stop_and_remove_container httpd || exit 2
  # shellcheck disable=SC2086
  docker run --name=httpd --restart always --network=picsure \
      -v "$DOCKER_CONFIG_DIR"/log/httpd-docker-logs/:/app/logs/ \
      -v "$DOCKER_CONFIG_DIR"/httpd/cert:/usr/local/apache2/cert/ \
      -v "$DOCKER_CONFIG_DIR"/httpd/httpd-vhosts.conf:/usr/local/apache2/conf/extra/httpd-vhosts.conf \
      $CUSTOM_HTTPD_VOLUMES \
      -p 443:443 \
      --env-file "$CURRENT_FS_DOCKER_CONFIG_DIR"/httpd/httpd.env \
      $LOGGING_ENVS \
      -d hms-dbmi/pic-sure-frontend:LATEST \
      || exit 2
  assert_container_running httpd || exit 2
fi
