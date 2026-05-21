#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — Safe Update
# =============================================================================
# Refreshes service sources/images, runs migrations, syncs the introspection
# token, and restarts services without deleting data volumes.
#
# Usage:
#   ./update.sh
#   ./update.sh --no-rebuild
#   ./update.sh --pull-images
#   ./update.sh --verbose
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
PICSURE_ROOT="$SCRIPT_DIR"
export PICSURE_ROOT

# shellcheck source=scripts/picsure-compose.sh
source "$SCRIPT_DIR/scripts/picsure-compose.sh"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[update]${NC} $*"; }
warn()  { echo -e "${YELLOW}[update]${NC} $*"; }
error() { echo -e "${RED}[update]${NC} $*" >&2; }

REBUILD_IMAGES=true
PULL_IMAGES=false
VERBOSE=false

for arg in "$@"; do
  case "$arg" in
    --no-rebuild) REBUILD_IMAGES=false ;;
    --pull-images) PULL_IMAGES=true ;;
    --verbose) VERBOSE=true ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      error "Unknown option: $arg"
      exit 1
      ;;
  esac
done

if [ ! -f "$ENV_FILE" ]; then
  error ".env not found. Run: cp .env.example .env && ./init.sh"
  exit 1
fi

picsure_load_env "$ENV_FILE"

set_env_var() {
  local key="$1"
  local value="$2"

  if grep -q "^${key}=" "$ENV_FILE"; then
    if [[ "$OSTYPE" =~ ^darwin ]]; then
      sed -i '' "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    else
      sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    fi
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

rotate_introspection_token() {
  if [ -z "${AUTH0_CLIENT_SECRET:-}" ] || [ -z "${PICSURE_APPLICATION_ID:-}" ]; then
    warn "AUTH0_CLIENT_SECRET or PICSURE_APPLICATION_ID missing; skipping introspection token rotation."
    return 0
  fi

  info "Rotating PIC-SURE introspection token..."
  local token
  token="$("$SCRIPT_DIR/config/scripts/generate-introspection-token.sh" \
    "$AUTH0_CLIENT_SECRET" "$PICSURE_APPLICATION_ID" 365)"
  set_env_var "PICSURE_INTROSPECTION_TOKEN" "$token"
  picsure_load_env "$ENV_FILE"

  if [ "${DB_MODE:-local}" = "remote" ]; then
    docker run --rm \
      -e MYSQL_PWD="${DB_ROOT_PASSWORD}" \
      mysql:8.0 \
      mysql -h "${DB_HOST}" -P "${DB_PORT:-3306}" -u "${DB_ROOT_USER:-root}" \
      -e "UPDATE auth.application SET token='$token' WHERE name='PICSURE';"
  else
    docker exec picsure-db mysql -uroot -p"${DB_ROOT_PASSWORD}" \
      -e "UPDATE auth.application SET token='$token' WHERE name='PICSURE';"
  fi
}

cd "$SCRIPT_DIR"

if [ -x "$SCRIPT_DIR/clone-repos.sh" ]; then
  "$SCRIPT_DIR/clone-repos.sh"
fi

if [ -x "$SCRIPT_DIR/release-control.sh" ]; then
  info "Resolving release-control refs..."
  "$SCRIPT_DIR/release-control.sh"
fi

if [ "$PULL_IMAGES" = "true" ]; then
  info "Pulling published images for PICSURE_IMAGE_TAG=${PICSURE_IMAGE_TAG:-LATEST}..."
  picsure_compose pull
elif [ "$REBUILD_IMAGES" = "true" ]; then
  build_args=(--force)
  if [ "$VERBOSE" = "true" ]; then
    build_args+=(--verbose)
  fi
  "$SCRIPT_DIR/build-images.sh" "${build_args[@]}"
else
  info "Skipping image rebuild."
fi

"$SCRIPT_DIR/run-migrations.sh" --check
"$SCRIPT_DIR/run-migrations.sh"
rotate_introspection_token
picsure_compose up -d
picsure_compose restart wildfly psama httpd

info "Update complete."
