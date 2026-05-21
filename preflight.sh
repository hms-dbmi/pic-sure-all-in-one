#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — Preflight Checks
# =============================================================================
# Non-mutating host/config validation for init.sh and update.sh.
#
# Usage:
#   ./preflight.sh
#   ./preflight.sh --network
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

NETWORK=false
FAILED=false

ok() { echo -e "${GREEN}[ok]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
fail() { echo -e "${RED}[fail]${NC} $*" >&2; FAILED=true; }

for arg in "$@"; do
  case "$arg" in
    --network) NETWORK=true ;;
    -h|--help)
      sed -n '2,9p' "$0"
      exit 0
      ;;
    *)
      fail "Unknown option: $arg"
      ;;
  esac
done

check_command() {
  local cmd="$1"
  local label="${2:-$1}"

  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$label found: $(command -v "$cmd")"
  else
    fail "$label not found."
  fi
}

check_required_env() {
  local key="$1"
  local value="${!key:-}"

  if [ -n "$value" ]; then
    ok "$key is set."
  else
    warn "$key is not set."
  fi
}

cd "$SCRIPT_DIR"

echo "[preflight] Host tools"
check_command git Git
check_command docker Docker

if command -v uuidgen >/dev/null 2>&1; then
  ok "UUID generation available through uuidgen."
elif [ -f /proc/sys/kernel/random/uuid ]; then
  ok "UUID generation available through /proc/sys/kernel/random/uuid."
else
  fail "UUID generation unavailable. Install uuidgen."
fi

if command -v jq >/dev/null 2>&1; then
  ok "jq found: $(command -v jq)"
else
  warn "jq not found; release-control.sh will use Docker image ${JQ_IMAGE:-ghcr.io/jqlang/jq:1.7.1}."
fi

if docker compose version >/dev/null 2>&1; then
  ok "Docker Compose available: $(docker compose version --short 2>/dev/null || docker compose version)"
else
  fail "Docker Compose V2 is not available through 'docker compose'."
fi

if docker info >/dev/null 2>&1; then
  ok "Docker daemon is reachable."
else
  fail "Docker daemon is not reachable."
fi

echo "[preflight] Files"
for path in docker-compose.yml init.sh update.sh build-images.sh release-control.sh run-migrations.sh seed-db.sh config/scripts/generate-introspection-token.sh; do
  if [ -f "$path" ]; then
    ok "$path exists."
  else
    fail "$path is missing."
  fi
done

for path in init.sh update.sh build-images.sh release-control.sh run-migrations.sh seed-db.sh config/scripts/generate-introspection-token.sh; do
  if [ -x "$path" ]; then
    ok "$path is executable."
  else
    fail "$path is not executable."
  fi
done

echo "[preflight] Shell syntax"
for path in init.sh update.sh build-images.sh release-control.sh bootstrap-remote-db.sh run-migrations.sh seed-db.sh load-demo-data.sh etl.sh scripts/picsure-compose.sh scripts/db-wait.sh config/scripts/generate-introspection-token.sh; do
  if [ -f "$path" ]; then
    if bash -n "$path"; then
      ok "$path syntax is valid."
    else
      fail "$path has a shell syntax error."
    fi
  fi
done

echo "[preflight] Environment"
if [ -f "$ENV_FILE" ]; then
  ok ".env exists."
  picsure_load_env "$ENV_FILE"
  check_required_env AUTH0_CLIENT_ID
  check_required_env AUTH0_CLIENT_SECRET
  check_required_env AUTH0_TENANT
  check_required_env ADMIN_EMAIL

  case "${DB_MODE:-local}" in
    local|remote) ok "DB_MODE=${DB_MODE:-local}" ;;
    *) fail "DB_MODE must be local or remote, got '${DB_MODE}'." ;;
  esac

  if [ "${DB_MODE:-local}" = "remote" ]; then
    check_required_env DB_HOST
    check_required_env DB_ROOT_USER
    check_required_env DB_ROOT_PASSWORD
  fi

  case "${AUTH_MODE:-required}" in
    required|open|explore) ok "AUTH_MODE=${AUTH_MODE:-required}" ;;
    *) fail "AUTH_MODE must be required, open, or explore, got '${AUTH_MODE}'." ;;
  esac
else
  warn ".env is missing. Run: cp .env.example .env"
fi

echo "[preflight] Compose"
if picsure_compose config --quiet; then
  ok "Compose config is valid."
else
  fail "Compose config is invalid."
fi

echo "[preflight] Release control"
release_repo="${RELEASE_CONTROL_REPO:-https://github.com/hms-dbmi/pic-sure-baseline-release-control}"
release_branch="${RELEASE_CONTROL_BRANCH:-main}"
ok "RELEASE_CONTROL_REPO=$release_repo"
ok "RELEASE_CONTROL_BRANCH=$release_branch"

if [ -d "$SCRIPT_DIR/.data/release-control/.git" ]; then
  ok "Release-control cache exists at .data/release-control."
else
  warn "Release-control cache is missing; init/update will clone it."
fi

echo "[preflight] JWT creator"
jwt_repo="${JWT_CREATOR_REPO:-https://github.com/hms-dbmi/jwt-creator.git}"
jwt_ref="${JWT_CREATOR_REF:-v1.0.0}"
jwt_dir="${JWT_CREATOR_DIR:-$SCRIPT_DIR/.data/jwt-creator}"
ok "JWT_CREATOR_REPO=$jwt_repo"
if [ "$jwt_ref" = "v1.0.0" ]; then
  ok "JWT_CREATOR_REF=$jwt_ref"
else
  warn "JWT_CREATOR_REF=$jwt_ref (default is v1.0.0)."
fi

if [ -f "$jwt_dir/target/generateJwt.jar" ]; then
  ok "jwt-creator jar is cached."
else
  warn "jwt-creator jar is not cached; first token generation will clone/build it with Docker."
fi

if [ "$NETWORK" = "true" ]; then
  echo "[preflight] Network"
  if git ls-remote --heads "$release_repo" "$release_branch" >/dev/null 2>&1 || git ls-remote --tags "$release_repo" "$release_branch" >/dev/null 2>&1; then
    ok "Release-control ref is reachable."
  else
    fail "Release-control branch/tag '$release_branch' is not reachable at $release_repo."
  fi

  if git ls-remote --tags "$jwt_repo" "$jwt_ref" >/dev/null 2>&1 || git ls-remote --heads "$jwt_repo" "$jwt_ref" >/dev/null 2>&1; then
    ok "jwt-creator ref is reachable."
  else
    fail "jwt-creator ref '$jwt_ref' is not reachable at $jwt_repo."
  fi
else
  warn "Skipping network checks. Use --network to verify remote release-control and jwt-creator refs."
fi

if [ "$FAILED" = "true" ]; then
  echo "[preflight] Failed." >&2
  exit 1
fi

echo "[preflight] Passed."
