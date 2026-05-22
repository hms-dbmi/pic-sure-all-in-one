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
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
RELEASE_DIR="${RELEASE_CONTROL_DIR:-$SCRIPT_DIR/.data/release-control}"
REPOS_DIR="${REPOS_DIR:-$SCRIPT_DIR/repos}"

LOG_PREFIX="release"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

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

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

set_env_var() {
  picsure_set_env_var "$ENV_FILE" "$1" "$2" true
}

repo_url="${RELEASE_CONTROL_REPO:-https://github.com/hms-dbmi/pic-sure-baseline-release-control}"
repo_branch="${RELEASE_CONTROL_BRANCH:-main}"
JQ_IMAGE="${JQ_IMAGE:-ghcr.io/jqlang/jq:1.7.1}"

run_jq() {
  local filter="$1"
  local file="$2"

  if command -v jq >/dev/null 2>&1; then
    jq -r "$filter" "$file"
  else
    if ! command -v docker >/dev/null 2>&1; then
      error "jq or docker is required to parse release-control build-spec.json."
      exit 1
    fi
    docker run --rm -i "$JQ_IMAGE" -r "$filter" < "$file"
  fi
}

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

  local jq_filter
  jq_filter='
    def ref_for($key):
      first(.application[]? | select(.project_job_git_key == $key and .git_hash) | .git_hash);
    [
      ["PICSURE_REF", ref_for("PSA")],
      ["HPDS_REF", ref_for("PSH")],
      ["PSAMA_REF", ref_for("PSAMA")],
      ["FRONTEND_REF", ref_for("PSF")],
      ["MIGRATIONS_REF", ref_for("PSM")],
      ["DICTIONARY_REF", ref_for("DICTIONARY")],
      ["DICTIONARY_ETL_REF", ref_for("DICTIONARY_ETL")],
      ["VISUALIZATION_REF", null],
      ["LOGGING_REF", ref_for("PSL")],
      ["LOGGING_CLIENT_REF", null]
    ][] |
    .[0] as $env_name |
    (.[1] // "main") as $ref |
    (if .[1] == null then "MISSING" else "FOUND" end) as $marker |
    "\($env_name)=\($ref)\t\($marker)"
  '

  local resolved
  if [ -f "$spec" ]; then
    resolved="$(run_jq "$jq_filter" "$spec")"
  else
    resolved=$'PICSURE_REF=main\tMISSING\nHPDS_REF=main\tMISSING\nPSAMA_REF=main\tMISSING\nFRONTEND_REF=main\tMISSING\nMIGRATIONS_REF=main\tMISSING\nDICTIONARY_REF=main\tMISSING\nDICTIONARY_ETL_REF=main\tMISSING\nVISUALIZATION_REF=main\tMISSING\nLOGGING_REF=main\tMISSING\nLOGGING_CLIENT_REF=main\tMISSING'
  fi

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

  checkout_repo_ref "$REPOS_DIR/pic-sure" "PICSURE_REF"
  checkout_repo_ref "$REPOS_DIR/pic-sure-hpds" "HPDS_REF"
  checkout_repo_ref "$REPOS_DIR/pic-sure-auth-microapp" "PSAMA_REF"
  checkout_repo_ref "$REPOS_DIR/PIC-SURE-Frontend" "FRONTEND_REF"
  checkout_repo_ref "$REPOS_DIR/PIC-SURE-Migrations" "MIGRATIONS_REF"
  checkout_repo_ref "$REPOS_DIR/picsure-dictionary" "DICTIONARY_REF"
  checkout_repo_ref "$REPOS_DIR/picsure-dictionary-etl" "DICTIONARY_ETL_REF"
  checkout_repo_ref "$REPOS_DIR/PIC-SURE-Logging" "LOGGING_REF"
  checkout_repo_ref "$REPOS_DIR/PIC-SURE-Logging-Client" "LOGGING_CLIENT_REF"
  checkout_repo_ref "$REPOS_DIR/pic-sure-visualization-resource" "VISUALIZATION_REF"
}

if [ "$RESOLVE" = "true" ]; then
  resolve_refs
fi

if [ "$APPLY" = "true" ]; then
  apply_refs
fi

info "Release refs ready."
