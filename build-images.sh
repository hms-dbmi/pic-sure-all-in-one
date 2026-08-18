#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — Build Images
# =============================================================================
# Builds local Docker images from the sibling service repos. This script does
# not generate secrets, run migrations, seed databases, or start services.
#
# Usage:
#   ./build-images.sh
#   ./build-images.sh --force
#   ./build-images.sh --verbose
#   ./build-images.sh --log
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

LOG_PREFIX="build"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

FORCE=false
VERBOSE=false
LOG=false

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    --verbose) VERBOSE=true ;;
    --log) LOG=true ;;
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

if [ -x "$SCRIPT_DIR/clone-repos.sh" ]; then
  "$SCRIPT_DIR/clone-repos.sh"
fi

LOG_FILE="$SCRIPT_DIR/build-images.log"
if [ "$LOG" = "true" ]; then
  info "Logging all output to $LOG_FILE"
  exec > >(tee "$LOG_FILE") 2>&1
fi

run_step() {
  picsure_run_logged "$SCRIPT_DIR/.data/logs/build" "$@"
}

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

IMAGE_TAG="${PICSURE_IMAGE_TAG:-LATEST}"
MAVEN_CACHE="maven_m2_cache"
MAVEN_IMAGE="maven:3-amazoncorretto-25"

PICSURE_SRC="${PICSURE_SRC:-$SCRIPT_DIR/repos/pic-sure}"
case "$PICSURE_SRC" in
  /*) ;;
  *) PICSURE_SRC="$SCRIPT_DIR/$PICSURE_SRC" ;;
esac
FRONTEND_SRC="${FRONTEND_SRC:-$SCRIPT_DIR/repos/PIC-SURE-Frontend}"
FRONTEND_THEME="${PICSURE_THEME:-picsure}"
REACTOR_BUILD_DIR="$SCRIPT_DIR/.build-pic-sure"

# Images built from the monorepo reactor output, as
# "image name|build context|Dockerfile" — the last two relative to the reactor
# build dir. Each Dockerfile copies its module's target/ jar, so the reactor is
# the only Maven run.
MONOREPO_IMAGES=(
  "pic-sure-gateway|services/pic-sure-gateway|services/pic-sure-gateway/Dockerfile"
  "pic-sure-operations-service|services/pic-sure-operations-service|services/pic-sure-operations-service/Dockerfile"
  "pic-sure-hpds-query-service|services/pic-sure-hpds-query-service|services/pic-sure-hpds-query-service/Dockerfile"
  "pic-sure-psama|services/pic-sure-auth-microapp|services/pic-sure-auth-microapp/pic-sure-auth-services/Dockerfile"
  "pic-sure-hpds|services/pic-sure-hpds|services/pic-sure-hpds/docker/pic-sure-hpds/Dockerfile"
  "pic-sure-hpds-etl|services/pic-sure-hpds|services/pic-sure-hpds/docker/pic-sure-hpds-etl/Dockerfile"
  "pic-sure-visualization|services/pic-sure-visualization-service|services/pic-sure-visualization-service/Dockerfile"
  "pic-sure-logging|services/pic-sure-logging|services/pic-sure-logging/Dockerfile"
  "pic-sure-dictionary-api|services/picsure-dictionary|services/picsure-dictionary/Dockerfile"
  "pic-sure-dictionary-dump|services/picsure-dictionary/aggregate|services/picsure-dictionary/aggregate/Dockerfile"
)

info "Checking container images..."
docker volume create "$MAVEN_CACHE" 2>/dev/null || true

REACTOR_NEEDED="$FORCE"
for entry in "${MONOREPO_IMAGES[@]}"; do
  if ! docker image inspect "hms-dbmi/${entry%%|*}:$IMAGE_TAG" &>/dev/null; then
    REACTOR_NEEDED=true
    break
  fi
done

if [ "$REACTOR_NEEDED" = "true" ]; then
  if [ ! -d "$PICSURE_SRC" ]; then
    error "pic-sure monorepo not found at $PICSURE_SRC"
    exit 1
  fi
  if [ ! -d "$PICSURE_SRC/services/pic-sure-gateway" ]; then
    error "pic-sure checkout at $PICSURE_SRC has no services/ layout (pre-monorepo ref?)."
    error "Check PICSURE_REF in .env — the release-control build-spec may pin a pre-monorepo version; use main or a monorepo-era ref."
    exit 1
  fi

  info "Building the pic-sure monorepo (Maven reactor)..."
  rm -rf "$REACTOR_BUILD_DIR"
  mkdir -p "$REACTOR_BUILD_DIR"
  run_step "pic-sure-reactor-maven" docker run --rm \
    -v "$PICSURE_SRC:/src:ro" \
    -v "$MAVEN_CACHE:/root/.m2" \
    -v "$REACTOR_BUILD_DIR:/build" \
    -w /build \
    "$MAVEN_IMAGE" \
    bash -c "cp -r /src/. /build/ && mvn -B clean install -T1C -DskipTests"

  # Rebuild every image from the fresh reactor output: skipping ones that
  # already exist can leave a mixed set of old and new jars.
  for entry in "${MONOREPO_IMAGES[@]}"; do
    IFS='|' read -r image_name image_context image_dockerfile <<< "$entry"
    info "Building $image_name (Docker)..."
    run_step "$image_name-docker" docker build \
      -f "$REACTOR_BUILD_DIR/$image_dockerfile" \
      -t "hms-dbmi/$image_name:$IMAGE_TAG" \
      "$REACTOR_BUILD_DIR/$image_context"
    info "Built hms-dbmi/$image_name:$IMAGE_TAG"
  done

  rm -rf "$REACTOR_BUILD_DIR"
else
  info "All monorepo service images exist. Skipping reactor build."
fi

# The frontend bakes VITE_* (and the theme) into the image at build time, so a
# config change (e.g. AUTH_MODE) only takes effect on a rebuild. Gate the
# rebuild on a hash of those exact build inputs, stamped onto the image as a
# label — so re-running init rebuilds the frontend iff its config changed,
# without a global --force and without any external state to track. The dev
# overlay builds a separate :dev tag, so it never desyncs this label.
FRONTEND_DEFAULTS="$FRONTEND_SRC/.env.example"
FRONTEND_LABEL="org.hms-dbmi.picsure.frontend-config"

# Exact bytes baked into the frontend image (same concatenation as the build).
frontend_vite_env() {
  if [ -f "$FRONTEND_DEFAULTS" ]; then grep '^VITE_' "$FRONTEND_DEFAULTS" || true; fi
  grep '^VITE_' "$ENV_FILE" || true
}

# Portable sha256 over stdin (mirrors cli/install.sh's sha256sum→shasum fallback).
picsure_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

frontend_want_hash="$(printf '%s\nTHEME=%s\n' "$(frontend_vite_env)" "$FRONTEND_THEME" | picsure_sha256)"
frontend_have_hash="$(docker image inspect \
  --format "{{ with .Config.Labels }}{{ index . \"$FRONTEND_LABEL\" }}{{ end }}" \
  "hms-dbmi/pic-sure-httpd:$IMAGE_TAG" 2>/dev/null || true)"

# A mismatch also covers "image missing" (frontend_have_hash is empty then).
if [ "$FORCE" = "true" ] || [ "$frontend_want_hash" != "$frontend_have_hash" ]; then
  if [ ! -d "$FRONTEND_SRC" ]; then
    if [ -n "$frontend_have_hash" ]; then
      info "Frontend source missing at $FRONTEND_SRC; keeping existing image (config may be stale — re-clone to rebuild)."
    else
      error "Frontend source not found at $FRONTEND_SRC"
      exit 1
    fi
  else
    info "Building frontend (theme: $FRONTEND_THEME)..."
    frontend_vite_env > "$FRONTEND_SRC/.env"
    run_step "pic-sure-httpd-docker" docker build -f "$FRONTEND_SRC/Dockerfile" \
      --build-arg THEME="$FRONTEND_THEME" \
      --label "$FRONTEND_LABEL=$frontend_want_hash" \
      -t "hms-dbmi/pic-sure-httpd:$IMAGE_TAG" \
      "$FRONTEND_SRC"
    rm -f "$FRONTEND_SRC/.env"
    info "Built hms-dbmi/pic-sure-httpd:$IMAGE_TAG"
  fi
else
  info "Frontend image is up to date with the current config. Skipping."
fi

info "All images ready."
