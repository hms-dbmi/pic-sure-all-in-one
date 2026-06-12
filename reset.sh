#!/usr/bin/env bash
# =============================================================================
# PIC-SURE — Reset Environment
# =============================================================================
# Tears down containers and generated config so you can re-run init.sh cleanly.
# Backs up .env before removing anything. Does NOT touch:
#   - The database volume (picsure-db data persists, unless --all)
#   - Sibling repos under repos/ (unless --repos)
#   - .env.example
#
# With --repos, each sibling repo's WORKING TREE is reset to its release ref
# (uncommitted changes are discarded) but .git is NEVER deleted: local
# branches, commits, and the reflog always survive. To DELETE repos/ outright
# (history and all) use `uninstall.sh --repos` instead.
#
# Usage:
#   ./reset.sh              # Reset config + containers (keep DB)
#   ./reset.sh --all        # Also remove database volume (full wipe)
#   ./reset.sh --repos      # Also git-reset sibling repos to release refs
#   ./reset.sh --yes        # Skip the confirmation prompt
#
# Declining the prompt exits 0 (a deliberate cancel is not an error).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
# REPOS_DIR is overridable so tests can sandbox the repo reset against fixture
# checkouts in a temp dir (mirrors release-control.sh).
REPOS_DIR="${REPOS_DIR:-$SCRIPT_DIR/repos}"
PICSURE_ROOT="$SCRIPT_DIR"
export PICSURE_ROOT

LOG_PREFIX="reset"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

# shellcheck source=scripts/picsure-compose.sh
source "$SCRIPT_DIR/scripts/picsure-compose.sh"

WIPE_DB=false
RESET_REPOS=false
ASSUME_YES=false
for arg in "$@"; do
  case "$arg" in
    --all) WIPE_DB=true ;;
    --repos) RESET_REPOS=true ;;
    --yes) ASSUME_YES=true ;;
    -h|--help)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    *)
      error "Unknown option: $arg"
      exit 1
      ;;
  esac
done

# Read COMPOSE_PROJECT_NAME / PICSURE_IMAGE_TAG from .env so volume and image
# names match what docker compose actually created. Best-effort: reset is the
# recovery tool, so a broken .env must not prevent it from running.
if ! picsure_load_env "$ENV_FILE"; then
  warn "Could not fully load .env; continuing with defaults."
fi
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-picsure}"

# Parallel arrays (bash 3.2: no associative arrays): repo dir under repos/ and
# the .env ref variable that targets it. Kept in sync with status.sh's
# REPO_DIRS/REPO_ENVS and release-control.sh's apply_refs.
REPO_DIRS=(
  pic-sure
  pic-sure-hpds
  pic-sure-auth-microapp
  PIC-SURE-Frontend
  PIC-SURE-Migrations
  picsure-dictionary
  picsure-dictionary-etl
  PIC-SURE-Logging
  PIC-SURE-Logging-Client
  pic-sure-visualization-resource
)
REPO_ENVS=(
  PICSURE_REF
  HPDS_REF
  PSAMA_REF
  FRONTEND_REF
  MIGRATIONS_REF
  DICTIONARY_REF
  DICTIONARY_ETL_REF
  LOGGING_REF
  LOGGING_CLIENT_REF
  VISUALIZATION_REF
)

# reset_one_repo: git-preserving working-tree reset of a single sibling repo.
# Mirrors release-control.sh's checkout_repo_ref ref-resolution + fallbacks,
# but DISCARDS uncommitted changes (that is the reset) instead of skipping a
# dirty tree. .git is NEVER touched: local branches, commits, and reflog
# survive. A repo without origin, a missing ref, or an offline fetch warns and
# continues — one bad repo must not abort the whole reset (set -e discipline).
reset_one_repo() {
  local repo_dir="$1"
  local env_name="$2"
  local ref="${!env_name:-main}"
  local name
  name="$(basename "$repo_dir")"

  if [ ! -d "$repo_dir/.git" ]; then
    warn "$name is missing; skipping repo reset."
    return 0
  fi

  info "Resetting $name -> $ref (discarding uncommitted changes; keeping history)"

  # Best-effort fetch: offline or a removed origin must not abort. We fall
  # back to whatever refs are already local.
  if ! git -C "$repo_dir" fetch --tags origin --prune 2>/dev/null; then
    warn "$name: could not fetch origin (offline or no remote); using local refs."
  fi

  if git -C "$repo_dir" rev-parse --verify --quiet "origin/$ref" >/dev/null; then
    # Branch ref: switch to it (creating a tracking branch if needed), then
    # hard-reset the working tree to the remote tip and clean untracked files.
    git -C "$repo_dir" switch "$ref" 2>/dev/null || \
      git -C "$repo_dir" switch -c "$ref" "origin/$ref" 2>/dev/null || \
      git -C "$repo_dir" checkout "$ref" 2>/dev/null || true
    git -C "$repo_dir" reset --hard "origin/$ref" >/dev/null
    git -C "$repo_dir" clean -fd >/dev/null
  elif git -C "$repo_dir" rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
    # Tag or local-only ref: detach onto it. No remote tracking branch to
    # reset against, so reset --hard to the ref itself, then clean.
    git -C "$repo_dir" switch --detach "$ref" 2>/dev/null || \
      git -C "$repo_dir" checkout --detach "$ref" 2>/dev/null || true
    git -C "$repo_dir" reset --hard "$ref" >/dev/null
    git -C "$repo_dir" clean -fd >/dev/null
  else
    warn "$name: ref '$ref' not found locally or on origin; falling back to main."
    if git -C "$repo_dir" rev-parse --verify --quiet "origin/main" >/dev/null; then
      git -C "$repo_dir" switch main 2>/dev/null || \
        git -C "$repo_dir" switch -c main origin/main 2>/dev/null || \
        git -C "$repo_dir" checkout main 2>/dev/null || true
      git -C "$repo_dir" reset --hard origin/main >/dev/null
      git -C "$repo_dir" clean -fd >/dev/null
    else
      warn "$name: no origin/main either; leaving working tree unchanged."
    fi
  fi
}

reset_repos() {
  if [ ! -d "$REPOS_DIR" ]; then
    warn "No repos/ directory at $REPOS_DIR; nothing to reset."
    return 0
  fi
  info "Resetting sibling repos (git history is preserved)..."
  local i
  for i in "${!REPO_DIRS[@]}"; do
    # Resilience: a single repo whose git op fails (corrupt index, locked
    # ref, etc.) must warn and let the loop continue — one bad repo cannot
    # abort the whole reset under set -e.
    reset_one_repo "$REPOS_DIR/${REPO_DIRS[$i]}" "${REPO_ENVS[$i]}" \
      || warn "${REPO_DIRS[$i]}: repo reset hit an error; continuing with the rest."
  done
}

# When sourced (not executed) — e.g. by scripts/test-repo-reset.sh — stop here
# so tests can call reset_repos() against a fixture REPOS_DIR WITHOUT running
# the destructive container/volume/config teardown that targets the real
# checkout. Production always executes the script, so this never short-circuits
# a real reset. (BASH_SOURCE[0] != $0 only when sourced.)
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

echo ""
if [ "$WIPE_DB" = "true" ]; then
  warn "⚠  FULL RESET — this will delete everything including the database."
else
  info "Resetting environment (database volume will be preserved)."
fi
if [ "$RESET_REPOS" = "true" ]; then
  warn "Sibling repos will be reset to release refs (uncommitted changes discarded;"
  warn "local branches and git history are KEPT)."
fi
echo ""

if [ "$ASSUME_YES" != "true" ]; then
  read -r -p "Are you sure? [y/N] " response
  case "$response" in
    [yY][eE][sS]|[yY]) ;;
    *)
      info "Aborted."
      exit 0
      ;;
  esac
fi
echo ""

# -------------------------------------------------------------------------
# Step 1: Back up .env
# -------------------------------------------------------------------------
BACKUP=""
if [ -f "$ENV_FILE" ]; then
  BACKUP="$ENV_FILE.backup.$(date +%Y%m%d-%H%M%S)"
  cp "$ENV_FILE" "$BACKUP"
  info "Backed up .env → $(basename "$BACKUP")"
fi

# -------------------------------------------------------------------------
# Step 2: Stop and remove containers
# -------------------------------------------------------------------------
info "Stopping containers..."
picsure_compose down 2>/dev/null || true

# -------------------------------------------------------------------------
# Step 3: Remove volumes (except DB unless --all)
# -------------------------------------------------------------------------
DB_VOLUME="${PROJECT_NAME}_picsure-db-data"

# Get all project volumes
VOLUMES=$(docker volume ls --filter "name=${PROJECT_NAME}_" --format '{{.Name}}' 2>/dev/null || true)

for vol in $VOLUMES; do
  if [ "$vol" = "$DB_VOLUME" ] && [ "$WIPE_DB" != "true" ]; then
    warn "Keeping database volume: $vol"
    continue
  fi
  docker volume rm "$vol" 2>/dev/null && info "Removed volume: $vol" || true
done

# -------------------------------------------------------------------------
# Step 4: Remove generated config files
# -------------------------------------------------------------------------
info "Removing generated config..."

# Generated by init.sh
rm -f "$ENV_FILE"
rm -rf "$SCRIPT_DIR/certs"
rm -f "$SCRIPT_DIR/config/dictionary/dictionary.env"
rm -f "$SCRIPT_DIR/config/hpds/encryption_key"
rm -f "$SCRIPT_DIR/config/wildfly/application.truststore"
rm -f "$SCRIPT_DIR/config/psama/application.truststore"
rm -f "$SCRIPT_DIR/config/wildfly/visualization/pic-sure-visualization-resource/resource.properties"
rm -rf "$SCRIPT_DIR/.data"

# WAR files (copied/built)
rm -f "$SCRIPT_DIR/config/wildfly/deployments/"*.war

info "Generated config removed."

# -------------------------------------------------------------------------
# Step 5: Remove images (--all only)
# -------------------------------------------------------------------------
if [ "$WIPE_DB" = "true" ]; then
  info "Removing PIC-SURE images..."
  # Keep in sync with uninstall.sh's images=() list (the two have drifted before).
  for img in pic-sure-hpds pic-sure-psama pic-sure-wildfly pic-sure-httpd \
             pic-sure-dictionary-api pic-sure-dictionary-dump pic-sure-hpds-etl \
             pic-sure-visualization pic-sure-logging; do
    docker rmi "hms-dbmi/$img:${PICSURE_IMAGE_TAG:-LATEST}" 2>/dev/null && \
      info "Removed image: hms-dbmi/$img" || true
  done
  # Remove Maven cache volume (forces full rebuild)
  docker volume rm maven_m2_cache 2>/dev/null && \
    info "Removed Maven cache volume." || true
fi

# -------------------------------------------------------------------------
# Step 6: Git-preserving repo reset (--repos only)
# -------------------------------------------------------------------------
# Runs after config removal. The *_REF values were read into this shell by
# picsure_load_env above (before Step 4 deleted .env), so they are still
# available here even though the file is gone.
if [ "$RESET_REPOS" = "true" ]; then
  reset_repos
fi

# -------------------------------------------------------------------------
# Done
# -------------------------------------------------------------------------
echo ""
info "======================================"
info "  Reset complete!"
info "======================================"
echo ""
if [ -f "$BACKUP" ]; then
  info "Your .env was backed up to: $(basename "$BACKUP")"
  info "To restore: cp $(basename "$BACKUP") .env"
fi
echo ""
info "To start fresh:"
info "  1. cp .env.example .env    # or restore your backup"
info "  2. Edit .env with your Auth0 credentials"
info "  3. ./init.sh"
if [ "$WIPE_DB" = "true" ]; then
  info "  4. ./load-demo-data.sh"
fi
echo ""
