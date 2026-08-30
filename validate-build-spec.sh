#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SPEC=${1:-}

default_rollout_file() {
  local filename=$1
  if [[ -f "$SCRIPT_DIR/$filename" ]]; then
    printf '%s/%s\n' "$SCRIPT_DIR" "$filename"
  else
    printf '%s/initial-configuration/jenkins/jenkins-docker/%s\n' "$SCRIPT_DIR" "$filename"
  fi
}

CONTRACT_FILE="${AIO_ROLLOUT_CONTRACT_FILE:-$(default_rollout_file banner-rollout-contract.json)}"
SOURCE_FILE="${AIO_ROLLOUT_SOURCE_FILE:-$(default_rollout_file banner-rollout-source.json)}"

fail() {
  echo "ERROR: $*" >&2
  exit 2
}

for workflow_variable in AIO_WORKFLOW_SHA256_SCRIPT AIO_WORKFLOW_MODE AIO_WORKFLOW_MANIFEST AIO_WORKFLOW_REPO_ROOT AIO_WORKFLOW_JENKINS_HOME; do
  [[ -z "${!workflow_variable+x}" ]] || fail "$workflow_variable is caller-controlled and must be unset"
done

if [[ "$SCRIPT_DIR" == */scripts ]]; then
  [[ -d "$SCRIPT_DIR/../aio-workflow" ]] || fail "installed workflow root is unavailable: $SCRIPT_DIR/../aio-workflow"
  WORKFLOW_ROOT="$(cd "$SCRIPT_DIR/../aio-workflow" && pwd)"
  WORKFLOW_SHA256_SCRIPT="$WORKFLOW_ROOT/workflow-sha256.sh"
  WORKFLOW_MODE=installed
  WORKFLOW_MANIFEST="$WORKFLOW_ROOT/aio-workflow-files.txt"
  WORKFLOW_JENKINS_HOME="$SCRIPT_DIR/../var/jenkins_home"
  [[ -x "$WORKFLOW_SHA256_SCRIPT" ]] || fail "installed workflow checksum script not found or not executable: $WORKFLOW_SHA256_SCRIPT"
  [[ -f "$WORKFLOW_MANIFEST" ]] || fail "installed workflow manifest not found: $WORKFLOW_MANIFEST"
  [[ -d "$WORKFLOW_JENKINS_HOME/jobs" ]] || fail "installed Jenkins jobs are unavailable: $WORKFLOW_JENKINS_HOME/jobs"
elif [[ -x "$SCRIPT_DIR/workflow-sha256.sh" ]]; then
  WORKFLOW_ROOT=$SCRIPT_DIR
  WORKFLOW_SHA256_SCRIPT="$WORKFLOW_ROOT/workflow-sha256.sh"
  WORKFLOW_MODE=source
  WORKFLOW_MANIFEST="$WORKFLOW_ROOT/initial-configuration/jenkins/jenkins-docker/aio-workflow-files.txt"
  WORKFLOW_JENKINS_HOME="$WORKFLOW_ROOT/initial-configuration/jenkins/jenkins-docker/jenkins_home"
else
  fail "trusted workflow checksum script is unavailable"
fi

[[ $# -eq 1 && -f "$BUILD_SPEC" ]] || fail "usage: $0 <build-spec.json>"
[[ -f "$CONTRACT_FILE" ]] || fail "rollout contract not found: $CONTRACT_FILE"
[[ -f "$SOURCE_FILE" ]] || fail "rollout source metadata not found: $SOURCE_FILE"
[[ -x "$WORKFLOW_SHA256_SCRIPT" ]] || fail "workflow checksum script not found or not executable: $WORKFLOW_SHA256_SCRIPT"
[[ -f "$SCRIPT_DIR/aio-sha256.sh" ]] || fail "checksum helper not found: $SCRIPT_DIR/aio-sha256.sh"
# shellcheck source=aio-sha256.sh
. "$SCRIPT_DIR/aio-sha256.sh"
command -v jq >/dev/null 2>&1 || fail "jq is required"

contract_commit=$(jq -er '.contractSourceCommit | select(type == "string" and test("^[0-9a-f]{40}$"))' "$SOURCE_FILE") || fail "rollout source metadata is invalid: $SOURCE_FILE"
contract_sha=$(jq -er '.contractSha256 | select(type == "string" and test("^[0-9a-f]{64}$"))' "$SOURCE_FILE") || fail "rollout source metadata is invalid: $SOURCE_FILE"
[[ "$(sha256_file "$CONTRACT_FILE")" == "$contract_sha" ]] || fail "rollout contract checksum does not match $contract_commit"

jq -e --arg commit "$contract_commit" --arg checksum "$contract_sha" '
  .bannerRollout.contractSourceCommit == $commit and
  .bannerRollout.contractSha256 == $checksum and
  .bannerRollout.releaseControlCommitSource == "pipeline_git_commit.txt" and
  .bannerRollout.forwardPhases == [
    "APPLY_AUTHORIZATION_AND_PIC_SURE_MIGRATIONS",
    "RECREATE_PSAMA",
    "VERIFY_OPERATIONS_AND_GATEWAY_HEALTH",
    "PUBLISH_FRONTEND_ACTIVE_V2"
  ] and
  .bannerRollout.rollbackPhases == [
    "FREEZE_BANNER_MANAGEMENT_WRITES",
    "ROLL_BACK_FRONTEND",
    "DISABLE_ACTIVE_AND_SCHEDULED_TARGETED_BANNERS_BEFORE_LEGACY_ACTIVE_FEED_BACKEND",
    "ROLL_BACK_OPERATIONS_AND_GATEWAY",
    "KEEP_BANNER_MANAGEMENT_WRITES_FROZEN_BELOW_TARGETING_CAPABLE_BACKEND",
    "RECREATE_PSAMA"
  ] and
  .bannerRollout.schemaRollback == "KEEP_FORWARD_SCHEMA" and
  .bannerRollout.downMigrationAllowed == false and
  (.bannerRollout.aioWorkflowSha256 | test("^[0-9a-f]{64}$")) and
  ([.application[] | select(.project_job_git_key == "PSA" or .project_job_git_key == "PSF" or .project_job_git_key == "PSM" or .project_job_git_key == "AIO") | .project_job_git_key] | sort) == ["AIO", "PSA", "PSF", "PSM"] and
  ([.application[] | select(.project_job_git_key == "PSA" or .project_job_git_key == "PSF" or .project_job_git_key == "PSM" or .project_job_git_key == "AIO") | .git_hash] | all(test("^[0-9a-f]{40}$")))
' "$BUILD_SPEC" >/dev/null || fail "build spec does not implement the reviewed banner rollout contract"

psa_commit=$(jq -er '[.application[] | select(.project_job_git_key == "PSA") | .git_hash] | if length == 1 then .[0] else error("expected one PSA entry") end' "$BUILD_SPEC")
[[ "$psa_commit" == "$contract_commit" ]] || fail "PSA commit $psa_commit does not match rollout contract source $contract_commit"

expected_aio_commit=$(jq -er '[.application[] | select(.project_job_git_key == "AIO") | .git_hash] | if length == 1 then .[0] else error("expected one AIO entry") end' "$BUILD_SPEC")
expected_workflow_sha=$(jq -er '.bannerRollout.aioWorkflowSha256' "$BUILD_SPEC")
if ! actual_workflow_sha=$(env AIO_WORKFLOW_MODE="$WORKFLOW_MODE" AIO_WORKFLOW_MANIFEST="$WORKFLOW_MANIFEST" AIO_WORKFLOW_REPO_ROOT="$WORKFLOW_ROOT" AIO_WORKFLOW_JENKINS_HOME="$WORKFLOW_JENKINS_HOME" "$WORKFLOW_SHA256_SCRIPT"); then
  fail "could not fingerprint the active AIO workflow"
fi
[[ "$actual_workflow_sha" =~ ^[0-9a-f]{64}$ ]] || fail "installed AIO workflow content fingerprint is unavailable"
if [[ "$actual_workflow_sha" != "$expected_workflow_sha" ]]; then
  fail "installed AIO workflow content $actual_workflow_sha does not match release tuple $expected_workflow_sha. Git installs: run sudo ./update-jenkins.sh --aio-ref $expected_aio_commit. Non-Git installs: reinstall the AIO artifact for that commit"
fi

actual_aio_commit="${AIO_WORKFLOW_COMMIT:-UNAVAILABLE}"
if [[ "$actual_aio_commit" != "UNAVAILABLE" && ! "$actual_aio_commit" =~ ^[0-9a-f]{40}$ ]]; then
  fail "installed AIO commit is malformed: $actual_aio_commit"
fi
if [[ "$actual_aio_commit" != "UNAVAILABLE" && "$actual_aio_commit" != "$expected_aio_commit" ]]; then
  fail "installed AIO commit $actual_aio_commit does not match release tuple $expected_aio_commit. Run sudo ./update-jenkins.sh --aio-ref $expected_aio_commit"
fi
