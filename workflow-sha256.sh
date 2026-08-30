#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_CONFIG_DIR="${DOCKER_CONFIG_DIR:-/usr/local/docker-config}"
MODE="${AIO_WORKFLOW_MODE:-installed}"
MANIFEST="$SCRIPT_DIR/initial-configuration/jenkins/jenkins-docker/aio-workflow-files.txt"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

sha256_stream() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

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
      elif [[ "$MODE" == "installed" ]]; then
        printf '%s/jenkins_home/%s\n' "$DOCKER_CONFIG_DIR" "$location"
      else
        return 2
      fi
      ;;
    *)
      return 2
      ;;
  esac
}

[[ -f "$MANIFEST" ]] || { echo "ERROR: AIO workflow manifest is missing: $MANIFEST" >&2; exit 2; }
{
  printf '%s  %s\n' "$(sha256_file "$MANIFEST")" "aio-workflow-files.txt"
  while IFS= read -r entry; do
    [[ -n "$entry" && "$entry" != \#* ]] || continue
    path=$(resolve_path "$entry") || { echo "ERROR: invalid AIO workflow manifest entry: $entry" >&2; exit 2; }
    [[ -f "$path" ]] || { echo "ERROR: installed AIO workflow file is missing: $path" >&2; exit 2; }
    printf '%s  %s\n' "$(sha256_file "$path")" "$entry"
  done < "$MANIFEST"
} | sha256_stream
