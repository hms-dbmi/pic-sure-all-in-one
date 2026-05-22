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
