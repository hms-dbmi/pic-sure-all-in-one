#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_CONFIG_DIR="${DOCKER_CONFIG_DIR:-/usr/local/docker-config}"
MODE="${AIO_WORKFLOW_MODE:-installed}"
MANIFEST="$SCRIPT_DIR/initial-configuration/jenkins/jenkins-docker/aio-workflow-files.txt"
[[ "$MODE" == "source" || "$MODE" == "installed" ]] || { echo "ERROR: invalid AIO workflow mode: $MODE" >&2; exit 2; }
[[ -f "$SCRIPT_DIR/aio-sha256.sh" ]] || { echo "ERROR: checksum helper is missing: $SCRIPT_DIR/aio-sha256.sh" >&2; exit 2; }
# shellcheck source=aio-sha256.sh
. "$SCRIPT_DIR/aio-sha256.sh"

resolve_path() {
  local entry=$1
  local location=${entry#*:}
  [[ "$location" != "$entry" && "$location" != /* && "$location" != *".."* ]] || return 2
  case "$entry" in
    repo:*)
      printf '%s/%s\n' "$SCRIPT_DIR" "$location"
      ;;
    jenkins-home:*)
      if [[ "$MODE" == "source" ]]; then
        printf '%s/initial-configuration/jenkins/jenkins-docker/%s\n' "$SCRIPT_DIR" "$location"
      else
        printf '%s/jenkins_home/%s\n' "$DOCKER_CONFIG_DIR" "$location"
      fi
      ;;
    *)
      return 2
      ;;
  esac
}

[[ -f "$MANIFEST" ]] || { echo "ERROR: AIO workflow manifest is missing: $MANIFEST" >&2; exit 2; }
material_file=$(mktemp)
trap 'rm -f "$material_file"' EXIT
{
  manifest_sha=$(sha256_file "$MANIFEST") || exit $?
  printf '%s  %s\n' "$manifest_sha" "aio-workflow-files.txt"
  while IFS= read -r entry; do
    [[ -n "$entry" && "$entry" != \#* ]] || continue
    path=$(resolve_path "$entry") || { echo "ERROR: invalid AIO workflow manifest entry: $entry" >&2; exit 2; }
    [[ -f "$path" ]] || { echo "ERROR: installed AIO workflow file is missing: $path" >&2; exit 2; }
    file_sha=$(sha256_file "$path") || exit $?
    printf '%s  %s\n' "$file_sha" "$entry"
  done < "$MANIFEST"
} > "$material_file"
sha256_file "$material_file"
