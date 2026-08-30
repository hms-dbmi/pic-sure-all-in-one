#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACT_FILE="${AIO_ROLLOUT_CONTRACT_FILE:-$SCRIPT_DIR/initial-configuration/jenkins/jenkins-docker/banner-rollout-contract.json}"
SOURCE_FILE="${AIO_ROLLOUT_SOURCE_FILE:-$SCRIPT_DIR/initial-configuration/jenkins/jenkins-docker/banner-rollout-source.json}"
START_SCRIPT="${AIO_START_SCRIPT:-$SCRIPT_DIR/start-picsure.sh}"

usage() {
  echo "Usage: $0 <rollback-state.json>" >&2
}

fail() {
  echo "ERROR: $*" >&2
  exit 2
}

json_value() {
  jq -er "$1" "$STATE_FILE"
}

require_exact_image() {
  local key=$1
  local image
  local attested_id
  local actual_id
  image=$(json_value ".rollbackImages.${key}")
  if [[ "$image" != *:* || "$image" == *":LATEST" || "$image" == *":latest" ]]; then
    fail "rollbackImages.$key must name an exact, non-LATEST local image tag"
  fi
  docker image inspect "$image" >/dev/null
  attested_id=$(json_value ".rollbackImageIds.${key}")
  [[ "$attested_id" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "rollbackImageIds.$key must be a sha256 image ID"
  actual_id=$(docker image inspect --format='{{.Id}}' "$image")
  [[ "$actual_id" == "$attested_id" ]] || fail "rollback image $image changed after operator attestation"
  printf '%s\n' "$image"
}

require_httpd_frozen() {
  local running_error=$1
  local inspection
  if inspection=$(docker container inspect --format='{{.State.Running}} {{.HostConfig.RestartPolicy.Name}}' httpd 2>&1); then
    case "$inspection" in
      "false no")
        return
        ;;
      "true "*)
        fail "$running_error"
        ;;
      "false "*)
        fail "httpd restart policy is ${inspection#false }; banner management writes are not restart-proof fail closed"
        ;;
      *)
        fail "unexpected httpd inspection result: $inspection"
        ;;
    esac
  fi
  case "$inspection" in
    "Error response from daemon: No such container: httpd"|"Error: No such container: httpd")
      return
      ;;
    *)
      fail "could not inspect httpd: $inspection"
      ;;
  esac
}

[[ $# -eq 1 ]] || { usage; exit 2; }
STATE_FILE=$1
[[ -f "$STATE_FILE" ]] || fail "rollback state file not found: $STATE_FILE"
[[ -f "$CONTRACT_FILE" ]] || fail "rollout contract not found: $CONTRACT_FILE"
[[ -f "$SOURCE_FILE" ]] || fail "rollout contract source metadata not found: $SOURCE_FILE"
[[ -f "$SCRIPT_DIR/aio-sha256.sh" ]] || fail "checksum helper not found: $SCRIPT_DIR/aio-sha256.sh"
# shellcheck source=aio-sha256.sh
. "$SCRIPT_DIR/aio-sha256.sh"
command -v jq >/dev/null 2>&1 || fail "jq is required"

EXPECTED_CONTRACT_COMMIT=$(jq -er '.contractSourceCommit' "$SOURCE_FILE")
EXPECTED_CONTRACT_SHA256=$(jq -er '.contractSha256' "$SOURCE_FILE")
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

# The attestation alone is insufficient. A stopped container with its ordinary
# restart policy could republish the frontend after a daemon or host restart.
require_httpd_frozen "httpd is running; banner management writes are not fail closed"

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
# active. Recreate PSAMA only after the rolled-back backend is running, then
# health-gate the full request path.
"$START_SCRIPT" --rollback-state "$STATE_FILE"

require_httpd_frozen "httpd restarted during fail-closed rollback"

echo "Rollback backend started with the forward schema retained; httpd remains stopped."
