#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'find "$TEST_DIR" -depth -delete' EXIT

RUNTIME_CONFIG="$TEST_DIR/docker-config"
mkdir -p "$RUNTIME_CONFIG"
cp -R "$ROOT_DIR/initial-configuration/config/." "$RUNTIME_CONFIG/"

RENDERER="$ROOT_DIR/initial-configuration/configure-service-envs.sh"
if [ ! -x "$RENDERER" ]; then
  echo "FAIL: fresh service environment renderer is missing or not executable" >&2
  exit 1
fi

DOCKER_CONFIG_DIR="$RUNTIME_CONFIG" bash "$RENDERER"

env_value() {
  local key=$1
  local env_file=$2
  sed -n "s/^${key}=//p" "$env_file"
}

assert_rendered() {
  local key=$1
  local env_file=$2
  local placeholder=$3
  local value
  value="$(env_value "$key" "$env_file")"
  if [ -z "$value" ] || [ "$value" = "$placeholder" ]; then
    echo "FAIL: $key was not rendered in $env_file" >&2
    exit 1
  fi
}

GATEWAY_ENV="$RUNTIME_CONFIG/gateway/gateway.env"
OPERATIONS_ENV="$RUNTIME_CONFIG/operations/operations.env"
QUERY_ENV="$RUNTIME_CONFIG/query/query.env"
LOGGING_ENV="$RUNTIME_CONFIG/logging/logging.env"

for required_file in "$GATEWAY_ENV" "$OPERATIONS_ENV" "$QUERY_ENV" "$LOGGING_ENV"; do
  if [ ! -f "$required_file" ]; then
    echo "FAIL: required rendered environment is missing: $required_file" >&2
    exit 1
  fi
done

assert_rendered QUERY_SERVICE_INTERNAL_TOKEN "$GATEWAY_ENV" __QUERY_SERVICE_INTERNAL_TOKEN__
assert_rendered QUERY_SERVICE_INTERNAL_TOKEN "$OPERATIONS_ENV" __QUERY_SERVICE_INTERNAL_TOKEN__
assert_rendered QUERY_SERVICE_INTERNAL_TOKEN "$QUERY_ENV" __QUERY_SERVICE_INTERNAL_TOKEN__
gateway_internal_token="$(env_value QUERY_SERVICE_INTERNAL_TOKEN "$GATEWAY_ENV")"
if [ "$gateway_internal_token" != "$(env_value QUERY_SERVICE_INTERNAL_TOKEN "$OPERATIONS_ENV")" ] ||
   [ "$gateway_internal_token" != "$(env_value QUERY_SERVICE_INTERNAL_TOKEN "$QUERY_ENV")" ]; then
  echo "FAIL: gateway, operations, and query internal tokens differ" >&2
  exit 1
fi

assert_rendered PICSURE_APPLICATION_TOKEN "$GATEWAY_ENV" __PICSURE_APPLICATION_TOKEN__
assert_rendered PICSURE_APPLICATION_TOKEN "$OPERATIONS_ENV" __PICSURE_APPLICATION_TOKEN__
assert_rendered PICSURE_APPLICATION_TOKEN "$QUERY_ENV" __PICSURE_APPLICATION_TOKEN__
gateway_application_token="$(env_value PICSURE_APPLICATION_TOKEN "$GATEWAY_ENV")"
if [ "$gateway_application_token" != "$(env_value PICSURE_APPLICATION_TOKEN "$OPERATIONS_ENV")" ] ||
   [ "$gateway_application_token" != "$(env_value PICSURE_APPLICATION_TOKEN "$QUERY_ENV")" ]; then
  echo "FAIL: gateway, operations, and query actuator tokens differ" >&2
  exit 1
fi

assert_rendered LOGGING_API_KEY "$GATEWAY_ENV" __LOGGING_API_KEY__
assert_rendered LOGGING_API_KEY "$LOGGING_ENV" __LOGGING_API_KEY__
if [ "$(env_value LOGGING_API_KEY "$GATEWAY_ENV")" != "$(env_value LOGGING_API_KEY "$LOGGING_ENV")" ]; then
  echo "FAIL: gateway and logging API keys differ" >&2
  exit 1
fi

assert_rendered AGGREGATE_OBFUSCATION_SALT "$QUERY_ENV" __AGGREGATE_OBFUSCATION_SALT__
if [ "$(env_value TOKEN_INTROSPECTION_TOKEN "$GATEWAY_ENV")" != "__TOKEN_INTROSPECTION_TOKEN__" ]; then
  echo "FAIL: installer rendered the token reserved for the post-migration Jenkins job" >&2
  exit 1
fi

if [ "$(env_value PICSURE_ACTUATOR_EXPOSURE "$GATEWAY_ENV")" != "health,info" ] ||
   [ "$(env_value PICSURE_ACTUATOR_EXPOSURE "$OPERATIONS_ENV")" != "health" ] ||
   [ "$(env_value PICSURE_ACTUATOR_EXPOSURE "$QUERY_ENV")" != "health" ]; then
  echo "FAIL: Java service health exposure is incomplete" >&2
  exit 1
fi

INSTALLER="$ROOT_DIR/initial-configuration/install-dependencies-docker.sh"
if ! grep -Fq './configure-service-envs.sh' "$INSTALLER"; then
  echo "FAIL: the fresh installer does not render service environments" >&2
  exit 1
fi

GATEWAY_JOB="$ROOT_DIR/initial-configuration/jenkins/jenkins-docker/jobs/PIC-SURE Gateway Build and Deploy/config.xml"
QUERY_JOB="$ROOT_DIR/initial-configuration/jenkins/jenkins-docker/jobs/PIC-SURE HPDS Query Service Build and Deploy/config.xml"
DICTIONARY_JOB="$ROOT_DIR/initial-configuration/jenkins/jenkins-docker/jobs/PIC-SURE Dictionary API Build and Deploy/config.xml"
LOGGING_JOB="$ROOT_DIR/initial-configuration/jenkins/jenkins-docker/jobs/Configure Logging/config.xml"
PIC_SURE_PIPELINE="$ROOT_DIR/initial-configuration/jenkins/jenkins-docker/jobs/PIC-SURE Pipeline/config.xml"

if grep -Eq 'touch (.*)?(gateway|query)\.env' "$GATEWAY_JOB" "$QUERY_JOB"; then
  echo "FAIL: a service build job still creates an empty environment file" >&2
  exit 1
fi
if ! grep -Fq 'PICSURE_ACTUATOR_EXPOSURE=health' "$DICTIONARY_JOB"; then
  echo "FAIL: dictionary generated environment does not enable health" >&2
  exit 1
fi
if ! grep -Fq 'LOGGING_API_KEY=$NEW_API_KEY' "$LOGGING_JOB"; then
  echo "FAIL: Configure Logging does not update gateway.env" >&2
  exit 1
fi
if grep -Fq "build job: &apos;Configure Logging&apos;" "$PIC_SURE_PIPELINE"; then
  echo "FAIL: Configure Logging is still coupled to PIC-SURE Pipeline" >&2
  exit 1
fi

echo "Fresh service environment checks passed"
