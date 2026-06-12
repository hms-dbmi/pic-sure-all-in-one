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
# Every mutating step is an explicit if-guard so a failure names the repo and
# the operation, then returns 1 for the caller's loop to continue past.
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

  # Best-effort fetch: offline or a removed origin must not abort.
  if ! git -C "$repo_dir" fetch --tags origin --prune 2>/dev/null; then
    warn "$name: could not fetch origin; resetting to the last-fetched origin/$ref, which may be behind the remote."
  fi

  # Resolve the target BEFORE touching the working tree, so an unresolvable
  # ref leaves the repo truly unchanged.
  local mode=""
  if git -C "$repo_dir" rev-parse --verify --quiet "origin/$ref" >/dev/null; then
    mode="branch"
  elif git -C "$repo_dir" rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
    mode="detach"   # tag or local-only ref: no remote branch to track
  elif git -C "$repo_dir" rev-parse --verify --quiet "origin/main" >/dev/null; then
    warn "$name: ref '$ref' not found locally or on origin; falling back to main."
    ref="main"
    mode="branch"
  else
    warn "$name: ref '$ref' not found and no origin/main; leaving working tree unchanged."
    return 0
  fi

  # Discard dirty state FIRST. A conflicting uncommitted edit would make the
  # switch below fail silently, leaving HEAD on the user's branch — and a
  # later hard reset would then move THAT branch's pointer, orphaning local
  # commits (the exact bug scripts/test-repo-reset.sh's conflict case covers).
  if ! git -C "$repo_dir" reset --hard HEAD >/dev/null; then
    warn "$name: discarding uncommitted changes failed (git reset --hard HEAD)."
    return 1
  fi
  if ! git -C "$repo_dir" clean -fd >/dev/null; then
    warn "$name: removing untracked files failed (git clean -fd)."
    return 1
  fi

  if [ "$mode" = "branch" ]; then
    if ! git -C "$repo_dir" switch "$ref" >/dev/null 2>&1 && \
       ! git -C "$repo_dir" switch -c "$ref" "origin/$ref" >/dev/null 2>&1; then
      warn "$name: could not switch to $ref."
      return 1
    fi
    # Guard the branch-pointer move: hard-reset ONLY when HEAD is verifiably
    # on $ref. Never move some other branch's pointer.
    if [ "$(git -C "$repo_dir" branch --show-current)" != "$ref" ]; then
      warn "$name: HEAD is not on $ref after switch; refusing to move the branch pointer."
      return 1
    fi
    if ! git -C "$repo_dir" reset --hard "origin/$ref" >/dev/null; then
      warn "$name: git reset --hard origin/$ref failed."
      return 1
    fi
  else
    if ! git -C "$repo_dir" switch --detach "$ref" >/dev/null 2>&1; then
      warn "$name: could not detach onto $ref."
      return 1
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
    # reset_one_repo returns 1 deliberately (after a warn naming the repo and
    # operation — its body is explicit if-guards, NOT bare errexit, because
    # this || suspends errexit inside the call). The || here only keeps the
    # loop going: one bad repo cannot abort the rest.
    reset_one_repo "$REPOS_DIR/${REPO_DIRS[$i]}" "${REPO_ENVS[$i]}" \
      || warn "${REPO_DIRS[$i]}: repo reset failed; continuing with the rest."
  done
}

# When sourced (not executed) — e.g. by scripts/test-repo-reset.sh — stop here
# so tests can call reset_repos() against a fixture REPOS_DIR WITHOUT running
# the destructive container/volume/config teardown that targets the real
# checkout. Production always executes the script, so this never short-circuits
# a real reset. (BASH_SOURCE[0] != $0 only when sourced.)
# INVARIANT: everything ABOVE this guard must stay side-effect-light (no rm,
# no docker, no git mutations at the top level) — sourcing must be safe.
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
