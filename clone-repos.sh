#!/usr/bin/env bash
# =============================================================================
# PIC-SURE — Clone Sibling Repositories
# =============================================================================
# Clones all required sibling repos into the parent directory of this script.
# Uses `gh` if available, falls back to `git`.
#
# Usage:
#   ./clone-repos.sh            # Clone all repos
#   ./clone-repos.sh --ssh      # Force SSH URLs (git@github.com:...)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_DIR="$SCRIPT_DIR/repos"

REPOS=(
  hms-dbmi/pic-sure
  hms-dbmi/pic-sure-auth-microapp
  hms-dbmi/pic-sure-hpds
  hms-dbmi/picsure-dictionary
  hms-dbmi/picsure-dictionary-etl
  hms-dbmi/PIC-SURE-Frontend
  hms-dbmi/PIC-SURE-Migrations
  hms-dbmi/pic-sure-visualization-resource
  hms-dbmi/PIC-SURE-Logging
  hms-dbmi/PIC-SURE-Logging-Client
)

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[clone]${NC} $*"; }
skip()  { echo -e "${YELLOW}[skip]${NC} $*"; }

# Determine clone method
USE_SSH=false
[[ "${1:-}" == "--ssh" ]] && USE_SSH=true

clone_repo() {
  local full_name="$1"
  local repo_name="${full_name#*/}"
  local target="$REPOS_DIR/$repo_name"

  if [ -d "$target" ]; then
    skip "$repo_name already exists"
    return
  fi

  if command -v gh &>/dev/null; then
    info "Cloning $repo_name (gh)..."
    gh repo clone "$full_name" "$target" 2>&1
  elif $USE_SSH; then
    info "Cloning $repo_name (git+ssh)..."
    git clone "git@github.com:${full_name}.git" "$target" 2>&1
  else
    info "Cloning $repo_name (git+https)..."
    git clone "https://github.com/${full_name}.git" "$target" 2>&1
  fi
}

mkdir -p "$REPOS_DIR"
info "Cloning repos into $REPOS_DIR"
echo ""

for repo in "${REPOS[@]}"; do
  clone_repo "$repo"
done

echo ""
info "Done. All repos are in $REPOS_DIR"
