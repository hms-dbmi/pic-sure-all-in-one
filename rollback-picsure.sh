#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACT_FILE="${AIO_ROLLOUT_CONTRACT_FILE:-$SCRIPT_DIR/initial-configuration/jenkins/jenkins-docker/banner-rollout-contract.json}"
START_SCRIPT="${AIO_START_SCRIPT:-$SCRIPT_DIR/start-picsure.sh}"
EXPECTED_CONTRACT_COMMIT="0178bbd2d1753e07dcead77a6d0e8ca37bf76dd8"
EXPECTED_CONTRACT_SHA256="f8cb265d735b757872391e04fdcd5b999b785eaa427ca13f8f2eefd493715359"

usage() {
  echo "Usage: $0 <rollback-state.json>" >&2
}

fail() {
  echo "ERROR: $*" >&2
  exit 2
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

json_value() {
  jq -er "$1" "$STATE_FILE"
}

require_exact_image() {
  local key=$1
  local image
  image=$(json_value ".rollbackImages.${key}")
  if [[ "$image" != *:* || "$image" == *":LATEST" || "$image" == *":latest" ]]; then
    fail "rollbackImages.$key must name an exact, non-LATEST local image tag"
  fi
  docker image inspect "$image" >/dev/null
  printf '%s\n' "$image"
}

[[ $# -eq 1 ]] || { usage; exit 2; }
STATE_FILE=$1
[[ -f "$STATE_FILE" ]] || fail "rollback state file not found: $STATE_FILE"
[[ -f "$CONTRACT_FILE" ]] || fail "rollout contract not found: $CONTRACT_FILE"
command -v jq >/dev/null 2>&1 || fail "jq is required"

actual_contract_sha=$(sha256_file "$CONTRACT_FILE")
[[ "$actual_contract_sha" == "$EXPECTED_CONTRACT_SHA256" ]] || fail "local rollout contract checksum does not match backend $EXPECTED_CONTRACT_COMMIT"
[[ "$(json_value '.schemaVersion')" == "1" ]] || fail "unsupported rollback state schema"
[[ "$(json_value '.contractSourceCommit')" == "$EXPECTED_CONTRACT_COMMIT" ]] || fail "rollback state uses the wrong backend contract commit"
[[ "$(json_value '.contractSha256')" == "$EXPECTED_CONTRACT_SHA256" ]] || fail "rollback state uses the wrong contract checksum"
[[ "$(json_value '.forwardSchemaRetained')" == "true" ]] || fail "rollback must retain the forward schema"
[[ "$(json_value '.downMigrationRequested')" == "false" ]] || fail "database down-migrations are forbidden"

for index in 0 1 2; do
  expected=$(jq -er ".rollbackPhases[$index]" "$CONTRACT_FILE")
  actual=$(json_value ".completedPhases[$index]")
  [[ "$actual" == "$expected" ]] || fail "rollback precondition $index must be $expected"
done
[[ "$(json_value '.completedPhases | length')" == "3" ]] || fail "rollback state must attest exactly the three pre-backend phases"

# The existing AIO fail-closed freeze is a stopped public entrypoint. The
# attestation alone is insufficient, so also verify that httpd is not running.
if docker container inspect httpd >/dev/null 2>&1; then
  httpd_running=$(docker inspect --format='{{.State.Running}}' httpd)
  [[ "$httpd_running" != "true" ]] || fail "httpd is running; banner management writes are not fail closed"
fi

frontend_image=$(require_exact_image frontend)
frontend_latest_id=$(docker image inspect --format='{{.Id}}' hms-dbmi/pic-sure-frontend:LATEST)
frontend_rollback_id=$(docker image inspect --format='{{.Id}}' "$frontend_image")
[[ "$frontend_latest_id" == "$frontend_rollback_id" ]] || fail "frontend LATEST is not the attested rollback image"

psama_image=$(require_exact_image psama)
operations_image=$(require_exact_image operations)
query_image=$(require_exact_image query)
gateway_image=$(require_exact_image gateway)

docker tag "$psama_image" hms-dbmi/psama:LATEST
docker tag "$operations_image" hms-dbmi/pic-sure-operations-service:LATEST
docker tag "$query_image" hms-dbmi/pic-sure-hpds-query-service:LATEST
docker tag "$gateway_image" hms-dbmi/pic-sure-gateway:LATEST

# Keep httpd down while a backend below the targeting-capable feed boundary is
# active. start-picsure.sh still recreates PSAMA and health-gates the backend.
AIO_PUBLISH_FRONTEND=false "$START_SCRIPT"

if docker container inspect httpd >/dev/null 2>&1; then
  httpd_running=$(docker inspect --format='{{.State.Running}}' httpd)
  [[ "$httpd_running" != "true" ]] || fail "httpd restarted during fail-closed rollback"
fi

echo "Rollback backend started with the forward schema retained; httpd remains stopped."
