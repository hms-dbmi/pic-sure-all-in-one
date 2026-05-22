#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — Uninstall
# =============================================================================
# Removes this checkout's Compose stack and generated runtime state. The source
# checkout itself is not removed.
#
# Usage:
#   ./uninstall.sh                 # Show removal plan
#   ./uninstall.sh --yes           # Remove containers, networks, volumes, generated files
#   ./uninstall.sh --yes --keep-env # Keep .env while removing generated files
#   ./uninstall.sh --yes --images  # Also remove local PIC-SURE images
#   ./uninstall.sh --yes --repos   # Also remove cloned service repos
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
PICSURE_ROOT="$SCRIPT_DIR"
export PICSURE_ROOT

LOG_PREFIX="uninstall"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

# shellcheck source=scripts/picsure-compose.sh
source "$SCRIPT_DIR/scripts/picsure-compose.sh"

YES=false
REMOVE_IMAGES=false
REMOVE_REPOS=false
KEEP_ENV=false

for arg in "$@"; do
  case "$arg" in
    --yes) YES=true ;;
    --images) REMOVE_IMAGES=true ;;
    --repos) REMOVE_REPOS=true ;;
    --keep-env) KEEP_ENV=true ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *)
      error "Unknown option: $arg"
      exit 1
      ;;
  esac
done

if [ -f "$ENV_FILE" ]; then
  picsure_load_env "$ENV_FILE"
fi

PROJECT_NAME="${COMPOSE_PROJECT_NAME:-picsure}"
IMAGE_TAG="${PICSURE_IMAGE_TAG:-LATEST}"

generated_paths=(
  "$SCRIPT_DIR/certs"
  "$SCRIPT_DIR/.data"
  "$SCRIPT_DIR/init.log"
  "$SCRIPT_DIR/config/dictionary/dictionary.env"
  "$SCRIPT_DIR/config/hpds/encryption_key"
  "$SCRIPT_DIR/config/wildfly/application.truststore"
  "$SCRIPT_DIR/config/psama/application.truststore"
  "$SCRIPT_DIR/config/wildfly/visualization/pic-sure-visualization-resource/resource.properties"
)

images=(
  "hms-dbmi/pic-sure-hpds:$IMAGE_TAG"
  "hms-dbmi/pic-sure-hpds-etl:$IMAGE_TAG"
  "hms-dbmi/pic-sure-psama:$IMAGE_TAG"
  "hms-dbmi/pic-sure-wildfly:$IMAGE_TAG"
  "hms-dbmi/pic-sure-httpd:$IMAGE_TAG"
  "hms-dbmi/pic-sure-dictionary-api:$IMAGE_TAG"
  "hms-dbmi/pic-sure-dictionary-dump:$IMAGE_TAG"
  "hms-dbmi/pic-sure-visualization:$IMAGE_TAG"
  "hms-dbmi/pic-sure-logging:$IMAGE_TAG"
)

print_plan() {
  echo "PIC-SURE uninstall plan"
  echo ""
  echo "Compose project: $PROJECT_NAME"
  echo "Image tag:       $IMAGE_TAG"
  echo ""
  echo "Will remove:"
  echo "  - Compose containers, networks, and named volumes for this project"
  echo "  - Generated runtime files under certs/, .data/, and config/"
  if [ "$KEEP_ENV" = "true" ]; then
    echo "  - .env will be kept"
  else
    echo "  - .env will be backed up, then removed"
  fi
  if [ "$REMOVE_IMAGES" = "true" ]; then
    echo "  - Local PIC-SURE images tagged $IMAGE_TAG"
  else
    echo "  - Local PIC-SURE images will be kept"
  fi
  if [ "$REMOVE_REPOS" = "true" ]; then
    echo "  - Cloned service repos under repos/"
  else
    echo "  - Cloned service repos under repos/ will be kept"
  fi
  echo ""
  echo "The repository checkout itself will not be removed."
}

remove_path() {
  local path="$1"
  local label="${path#$SCRIPT_DIR/}"

  if [ -e "$path" ]; then
    rm -rf "$path"
    info "Removed $label"
  fi
}

print_plan

if [ "$YES" != "true" ]; then
  echo ""
  warn "No changes made. Re-run with --yes to uninstall."
  exit 0
fi

echo ""
warn "Removing local Compose resources and generated state for '$PROJECT_NAME'."

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  info "Stopping and removing Compose resources..."
  picsure_compose down --volumes --remove-orphans 2>/dev/null || true
else
  warn "Docker daemon is not reachable; skipping Compose cleanup."
fi

if [ "$KEEP_ENV" != "true" ] && [ -f "$ENV_FILE" ]; then
  backup="$ENV_FILE.backup.$(date +%Y%m%d-%H%M%S)"
  cp "$ENV_FILE" "$backup"
  rm -f "$ENV_FILE"
  info "Backed up .env to $(basename "$backup") and removed .env"
fi

info "Removing generated files..."
for path in "${generated_paths[@]}"; do
  remove_path "$path"
done
rm -f "$SCRIPT_DIR/config/wildfly/deployments/"*.war 2>/dev/null || true

if [ "$REMOVE_REPOS" = "true" ]; then
  remove_path "$SCRIPT_DIR/repos"
fi

if [ "$REMOVE_IMAGES" = "true" ]; then
  info "Removing local PIC-SURE images..."
  for image in "${images[@]}"; do
    docker rmi "$image" 2>/dev/null && info "Removed image $image" || true
  done
  docker volume rm maven_m2_cache 2>/dev/null && info "Removed Maven cache volume" || true
fi

info "Uninstall complete."
