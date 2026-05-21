#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — Release Control
# =============================================================================
# Reads a release-control build-spec.json, writes component refs to .env, and
# optionally checks out local repos to those refs.
#
# Usage:
#   ./release-control.sh
#   ./release-control.sh --resolve-only
#   ./release-control.sh --apply-only
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
RELEASE_DIR="$SCRIPT_DIR/.data/release-control"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[release]${NC} $*"; }
warn()  { echo -e "${YELLOW}[release]${NC} $*"; }
error() { echo -e "${RED}[release]${NC} $*" >&2; }

RESOLVE=true
APPLY=true

for arg in "$@"; do
  case "$arg" in
    --resolve-only) APPLY=false ;;
    --apply-only) RESOLVE=false ;;
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
  error ".env not found. Run: cp .env.example .env"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  error "python3 is required to parse release-control build-spec.json."
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

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

repo_url="${RELEASE_CONTROL_REPO:-https://github.com/hms-dbmi/pic-sure-baseline-release-control}"
repo_branch="${RELEASE_CONTROL_BRANCH:-main}"

resolve_refs() {
  mkdir -p "$(dirname "$RELEASE_DIR")"

  if [ ! -d "$RELEASE_DIR/.git" ]; then
    info "Cloning release control repo: $repo_url"
    git clone "$repo_url" "$RELEASE_DIR"
  else
    info "Updating release control repo: $repo_url"
    git -C "$RELEASE_DIR" remote set-url origin "$repo_url"
    git -C "$RELEASE_DIR" fetch origin --prune
  fi

  if ! git -C "$RELEASE_DIR" checkout "$repo_branch"; then
    warn "Release-control branch '$repo_branch' was not found; falling back to main."
    repo_branch="main"
    git -C "$RELEASE_DIR" checkout "$repo_branch"
  fi
  git -C "$RELEASE_DIR" pull --ff-only origin "$repo_branch"

  local spec="$RELEASE_DIR/build-spec.json"
  if [ ! -f "$spec" ]; then
    warn "No build-spec.json found in release control repo; using main for all component refs."
  fi

  local release_commit
  release_commit="$(git -C "$RELEASE_DIR" rev-parse HEAD)"

  local resolved
  resolved="$(python3 - "$spec" <<'PY'
import json
import sys
from pathlib import Path

spec_path = Path(sys.argv[1])
key_to_env = {
    "PSA": "PICSURE_REF",
    "PSH": "HPDS_REF",
    "PSAMA": "PSAMA_REF",
    "PSF": "FRONTEND_REF",
    "PSM": "MIGRATIONS_REF",
    "DICTIONARY": "DICTIONARY_REF",
    "DICTIONARY_ETL": "DICTIONARY_ETL_REF",
    "PSL": "LOGGING_REF",
}
defaults = {
    "PICSURE_REF": "main",
    "HPDS_REF": "main",
    "PSAMA_REF": "main",
    "FRONTEND_REF": "main",
    "MIGRATIONS_REF": "main",
    "DICTIONARY_REF": "main",
    "DICTIONARY_ETL_REF": "main",
    "VISUALIZATION_REF": "main",
    "LOGGING_REF": "main",
    "LOGGING_CLIENT_REF": "main",
}
refs = dict(defaults)
found = set()
if spec_path.exists():
    data = json.loads(spec_path.read_text())
    for item in data.get("application", []):
        env_name = key_to_env.get(item.get("project_job_git_key"))
        git_hash = item.get("git_hash")
        if env_name and git_hash:
            refs[env_name] = git_hash
            found.add(env_name)
for env_name in defaults:
    marker = "FOUND" if env_name in found else "MISSING"
    print(f"{env_name}={refs[env_name]}\t{marker}")
PY
)"

  set_env_var "RELEASE_CONTROL_REPO" "$repo_url"
  set_env_var "RELEASE_CONTROL_BRANCH" "$repo_branch"
  set_env_var "RELEASE_CONTROL_COMMIT" "$release_commit"

  while IFS=$'\t' read -r assignment marker; do
    [ -n "$assignment" ] || continue
    local key="${assignment%%=*}"
    local value="${assignment#*=}"
    set_env_var "$key" "$value"
    if [ "$marker" = "MISSING" ]; then
      warn "$key missing from build-spec.json; falling back to $value."
    else
      info "$key=$value"
    fi
  done <<< "$resolved"
}

checkout_repo_ref() {
  local repo_dir="$1"
  local env_name="$2"
  local ref="${!env_name:-main}"
  local name
  name="$(basename "$repo_dir")"

  if [ ! -d "$repo_dir/.git" ]; then
    warn "$name is missing; skipping $env_name checkout."
    return 0
  fi

  if ! git -C "$repo_dir" diff --quiet || ! git -C "$repo_dir" diff --cached --quiet; then
    warn "$name has local changes; skipping checkout to $ref."
    return 0
  fi

  info "Checking out $name -> $ref"
  git -C "$repo_dir" fetch --tags origin --prune
  if git -C "$repo_dir" rev-parse --verify --quiet "origin/$ref" >/dev/null; then
    git -C "$repo_dir" switch "$ref" 2>/dev/null || git -C "$repo_dir" switch -c "$ref" "origin/$ref"
    git -C "$repo_dir" pull --ff-only origin "$ref"
  elif git -C "$repo_dir" switch --detach "$ref"; then
    return 0
  else
    warn "$name could not check out $ref; falling back to main."
    if git -C "$repo_dir" rev-parse --verify --quiet "origin/main" >/dev/null; then
      git -C "$repo_dir" switch main 2>/dev/null || git -C "$repo_dir" switch -c main origin/main
      git -C "$repo_dir" pull --ff-only origin main
    else
      warn "$name has no origin/main; leaving current checkout unchanged."
    fi
  fi
}

apply_refs() {
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  checkout_repo_ref "$SCRIPT_DIR/repos/pic-sure" "PICSURE_REF"
  checkout_repo_ref "$SCRIPT_DIR/repos/pic-sure-hpds" "HPDS_REF"
  checkout_repo_ref "$SCRIPT_DIR/repos/pic-sure-auth-microapp" "PSAMA_REF"
  checkout_repo_ref "$SCRIPT_DIR/repos/PIC-SURE-Frontend" "FRONTEND_REF"
  checkout_repo_ref "$SCRIPT_DIR/repos/PIC-SURE-Migrations" "MIGRATIONS_REF"
  checkout_repo_ref "$SCRIPT_DIR/repos/picsure-dictionary" "DICTIONARY_REF"
  checkout_repo_ref "$SCRIPT_DIR/repos/picsure-dictionary-etl" "DICTIONARY_ETL_REF"
  checkout_repo_ref "$SCRIPT_DIR/repos/PIC-SURE-Logging" "LOGGING_REF"
  checkout_repo_ref "$SCRIPT_DIR/repos/PIC-SURE-Logging-Client" "LOGGING_CLIENT_REF"
  checkout_repo_ref "$SCRIPT_DIR/repos/pic-sure-visualization-resource" "VISUALIZATION_REF"
}

if [ "$RESOLVE" = "true" ]; then
  resolve_refs
fi

if [ "$APPLY" = "true" ]; then
  apply_refs
fi

info "Release refs ready."
