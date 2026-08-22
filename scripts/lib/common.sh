#!/usr/bin/env bash

set -euo pipefail

PICSURE_GREEN='\033[0;32m'
PICSURE_YELLOW='\033[1;33m'
PICSURE_RED='\033[0;31m'
PICSURE_NC='\033[0m'

LOG_PREFIX="${LOG_PREFIX:-script}"

info()  { echo -e "${PICSURE_GREEN}[${LOG_PREFIX}]${PICSURE_NC} $*"; }
warn()  { echo -e "${PICSURE_YELLOW}[${LOG_PREFIX}]${PICSURE_NC} $*"; }
error() { echo -e "${PICSURE_RED}[${LOG_PREFIX}]${PICSURE_NC} $*" >&2; }

picsure_require_env_var() {
  local name="$1"
  local message="${2:-$name is required.}"

  if [ -z "${!name:-}" ]; then
    error "$message"
    return 1
  fi
}

# Run a jq filter over a file, preferring host jq and falling back to a
# dockerized jq (override the image with JQ_IMAGE). Parsing only — JSON
# emission helpers live in scripts/lib/json.sh. Note: the fallback may pull
# the jq image on first use.
#
# Usage: run_jq [jq-flags...] FILTER FILE
run_jq() {
  local flags=()
  while [ "$#" -gt 2 ]; do
    flags+=("$1")
    shift
  done
  local filter="$1"
  local file="$2"

  if command -v jq >/dev/null 2>&1; then
    jq -r ${flags[@]+"${flags[@]}"} "$filter" "$file"
  else
    if ! command -v docker >/dev/null 2>&1; then
      error "jq or docker is required to parse JSON."
      return 1
    fi
    docker run --rm -i "${JQ_IMAGE:-ghcr.io/jqlang/jq:1.7.1}" -r ${flags[@]+"${flags[@]}"} "$filter" < "$file"
  fi
}

# Run a noisy step: stream output when VERBOSE=true, otherwise capture it to
# LOG_DIR/LABEL.log and show the tail on failure (then exit 1).
# Usage: picsure_run_logged LOG_DIR LABEL CMD [ARGS...]
picsure_run_logged() {
  local log_dir="$1"
  local label="$2"
  shift 2

  if [ "${VERBOSE:-false}" = "true" ]; then
    "$@"
    return
  fi

  local log_file="$log_dir/$label.log"
  mkdir -p "$log_dir"
  if "$@" >"$log_file" 2>&1; then
    return
  fi

  error "$label failed. See $log_file"
  tail -40 "$log_file" >&2 || true
  exit 1
}

picsure_sed_in_place() {
  if [[ "$OSTYPE" =~ ^darwin ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

picsure_set_env_var() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  local force="${4:-true}"

  if grep -q "^${key}=" "$env_file"; then
    local current
    current="$(grep "^${key}=" "$env_file" | cut -d'=' -f2-)"
    if [ -n "$current" ] && [ "$force" != "true" ]; then
      return 0
    fi

    local escaped_value
    escaped_value="${value//\\/\\\\}"
    escaped_value="${escaped_value//&/\\&}"
    escaped_value="${escaped_value//|/\\|}"
    picsure_sed_in_place "s|^${key}=.*|${key}=${escaped_value}|" "$env_file"
  else
    echo "${key}=${value}" >> "$env_file"
  fi
}

# picsure_browse_url: the URL a human should open for this stack.
# The port is omitted only when it is the HTTPS default, so an install that
# had to move off 443 (another stack, or a host process such as Tailscale
# holding the port) prints a URL that actually works. Requires .env to have
# been loaded by the caller; falls back to the compose default.
picsure_browse_url() {
  local port="${HTTPS_PORT:-443}"

  if [ "$port" = "443" ]; then
    printf 'https://localhost'
  else
    printf 'https://localhost:%s' "$port"
  fi
}

# picsure_src_commit: HEAD of a source checkout, or empty when it is not a git
# working tree (release tarball, vendored copy). Callers must treat empty as
# "cannot tell" and fall back to their existing behaviour rather than
# rebuilding on every run.
picsure_src_commit() {
  git -C "$1" rev-parse HEAD 2>/dev/null || true
}

# picsure_image_label: read one label off a local image, empty if the image or
# the label is absent. Pairs with picsure_src_commit to answer "was this image
# built from the source that is checked out right now?" — an image-exists test
# alone cannot, so bumping a *_REF silently keeps the stale image.
picsure_image_label() {
  docker image inspect --format "{{ with .Config.Labels }}{{ index . \"$2\" }}{{ end }}" \
    "$1" 2>/dev/null || true
}
