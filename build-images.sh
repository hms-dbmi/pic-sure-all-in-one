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

if [ "$VERBOSE" = "true" ]; then
  BUILD_OUT="/dev/stdout"
else
  BUILD_OUT="/dev/null"
fi

LAST_BUILD_LOG=""

run_step() {
  local label="$1"
  shift

  if [ "$VERBOSE" = "true" ]; then
    "$@"
    return
  fi

  local log_file="$SCRIPT_DIR/.data/logs/build/${label}.log"
  mkdir -p "$(dirname "$log_file")"
  if "$@" >"$log_file" 2>&1; then
    LAST_BUILD_LOG="$log_file"
    return
  fi

  error "$label failed. See $log_file"
  tail -40 "$log_file" >&2 || true
  exit 1
}

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

IMAGE_TAG="${PICSURE_IMAGE_TAG:-LATEST}"
MAVEN_CACHE="maven_m2_cache"

HPDS_SRC="${HPDS_SRC:-$SCRIPT_DIR/repos/pic-sure-hpds}"
PSAMA_SRC="${PSAMA_SRC:-$SCRIPT_DIR/repos/pic-sure-auth-microapp}"
WILDFLY_SRC="${WILDFLY_SRC:-$SCRIPT_DIR/repos/pic-sure}"
DICTIONARY_SRC="${DICTIONARY_SRC:-$SCRIPT_DIR/repos/picsure-dictionary}"
VISUALIZATION_SRC="${VISUALIZATION_SRC:-$SCRIPT_DIR/repos/pic-sure-visualization-resource}"
FRONTEND_SRC="${FRONTEND_SRC:-$SCRIPT_DIR/repos/PIC-SURE-Frontend}"
FRONTEND_THEME="${PICSURE_THEME:-picsure}"

maven_build() {
  local name="$1" src="$2" dockerfile="$3" mvn_flags="${4:-}" maven_image="${5:-maven:3.9.9-amazoncorretto-24}"
  local build_dir="$SCRIPT_DIR/.build-$name"

  if docker image inspect "hms-dbmi/$name:$IMAGE_TAG" &>/dev/null && [ "$FORCE" != "true" ]; then
    info "Image hms-dbmi/$name:$IMAGE_TAG exists. Skipping."
    return
  fi

  info "Building $name (Maven + Docker)..."
  rm -rf "$build_dir"
  mkdir -p "$build_dir"
  docker volume create "$MAVEN_CACHE" 2>/dev/null || true

  run_step "$name-maven" docker run --rm \
    -v "$src:/src:ro" \
    -v "$MAVEN_CACHE:/root/.m2" \
    -v "$build_dir:/build" \
    -w /build \
    "$maven_image" \
    bash -c "cp -r /src/. /build/ && mvn -B clean install -DskipTests $mvn_flags"

  run_step "$name-docker" docker build -f "$dockerfile" -t "hms-dbmi/$name:$IMAGE_TAG" "$build_dir"
  rm -rf "$build_dir"
  info "Built hms-dbmi/$name:$IMAGE_TAG"
}

docker_build_with_m2_context() {
  local name="$1" context="$2" dockerfile="$3"
  local m2_context="$SCRIPT_DIR/.build-$name-m2-cache"

  if docker image inspect "hms-dbmi/$name:$IMAGE_TAG" &>/dev/null && [ "$FORCE" != "true" ]; then
    info "Image hms-dbmi/$name:$IMAGE_TAG exists. Skipping."
    return
  fi

  info "Building $name (Dockerfile + Maven cache context)..."
  rm -rf "$m2_context"
  mkdir -p "$m2_context"
  run_step "$name-m2-cache" docker run --rm \
    -v "$MAVEN_CACHE:/m2:ro" \
    -v "$m2_context:/cache" \
    alpine:latest \
    sh -c "if [ -d /m2/repository ]; then cp -a /m2/repository/. /cache/; fi"

  run_step "$name-docker" docker buildx build --load \
    --build-context "m2_cache=$m2_context" \
    -f "$dockerfile" \
    -t "hms-dbmi/$name:$IMAGE_TAG" \
    "$context"
  rm -rf "$m2_context"
  info "Built hms-dbmi/$name:$IMAGE_TAG"
}

info "Checking container images..."
docker volume create "$MAVEN_CACHE" 2>/dev/null || true

LOG_CLIENT_SRC="${LOG_CLIENT_SRC:-$SCRIPT_DIR/repos/PIC-SURE-Logging-Client}"
if [ -d "$LOG_CLIENT_SRC" ]; then
  info "Installing PIC-SURE Logging Client to Maven cache..."
  docker run --rm \
    -v "$LOG_CLIENT_SRC:/src:ro" \
    -v "$MAVEN_CACHE:/root/.m2" \
    "maven:3.9-eclipse-temurin-11" \
    bash -c "cp -r /src /build && cd /build && mvn -B clean install -DskipTests" \
    &> "$BUILD_OUT"
  info "Logging client installed."
else
  warn "PIC-SURE-Logging-Client not found at $LOG_CLIENT_SRC — skipping."
  warn "Java services may fail to build if they depend on the logging client."
fi

LOG_SRC="${LOG_SRC:-$SCRIPT_DIR/repos/PIC-SURE-Logging}"
maven_build "pic-sure-logging" "$LOG_SRC" "$LOG_SRC/Dockerfile" "" "maven:3.9-eclipse-temurin-21"

maven_build "pic-sure-wildfly" "$WILDFLY_SRC" "$WILDFLY_SRC/docker/all-in-one/all-in-one.Dockerfile" "" "maven:3.9-eclipse-temurin-11"

HPDS_NEED_BUILD=false
if ! docker image inspect "hms-dbmi/pic-sure-hpds:$IMAGE_TAG" &>/dev/null || \
   ! docker image inspect "hms-dbmi/pic-sure-hpds-etl:$IMAGE_TAG" &>/dev/null || \
   [ "$FORCE" = "true" ]; then
  HPDS_NEED_BUILD=true
fi

if [ "$HPDS_NEED_BUILD" = "true" ]; then
  HPDS_BUILD_DIR="$SCRIPT_DIR/.build-pic-sure-hpds"
  info "Building HPDS (Maven + Docker)..."
  rm -rf "$HPDS_BUILD_DIR"
  mkdir -p "$HPDS_BUILD_DIR"
  docker run --rm \
    -v "$HPDS_SRC:/src:ro" \
    -v "$MAVEN_CACHE:/root/.m2" \
    -v "$HPDS_BUILD_DIR:/build" \
    -w /build \
    maven:3.9.9-amazoncorretto-24 \
    bash -c "which git >/dev/null 2>&1 || yum install -y git >/dev/null 2>&1; cp -r /src/. /build/ && mvn -B clean install -DskipTests -nsu" \
    &> "$BUILD_OUT"

  docker build -f "$HPDS_SRC/docker/pic-sure-hpds/Dockerfile" \
    -t "hms-dbmi/pic-sure-hpds:$IMAGE_TAG" "$HPDS_BUILD_DIR" \
    &> "$BUILD_OUT"
  info "Built hms-dbmi/pic-sure-hpds:$IMAGE_TAG"

  docker build -f "$HPDS_BUILD_DIR/docker/pic-sure-hpds-etl/Dockerfile" \
    -t "hms-dbmi/pic-sure-hpds-etl:$IMAGE_TAG" "$HPDS_BUILD_DIR" \
    &> "$BUILD_OUT"
  info "Built hms-dbmi/pic-sure-hpds-etl:$IMAGE_TAG"

  rm -rf "$HPDS_BUILD_DIR"
else
  info "Images hms-dbmi/pic-sure-hpds and pic-sure-hpds-etl exist. Skipping."
fi

if [ -f "$VISUALIZATION_SRC/Dockerfile" ]; then
  maven_build "pic-sure-visualization" "$VISUALIZATION_SRC" "$VISUALIZATION_SRC/Dockerfile" "" "maven:3.9-amazoncorretto-25"
else
  current_ref="$(git -C "$VISUALIZATION_SRC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  if [ "$current_ref" = "HEAD" ]; then
    current_ref="$(git -C "$VISUALIZATION_SRC" rev-parse --short HEAD 2>/dev/null || echo detached)"
  fi
  error "Visualization Dockerfile not found at $VISUALIZATION_SRC/Dockerfile"
  error "Current visualization checkout is '$current_ref'; normal builds require a ref with Dockerfile, such as rewrite."
  error "Check VISUALIZATION_REF in .env and ensure release-control build-spec.json contains project_job_git_key PSV."
  exit 1
fi
maven_build "pic-sure-psama" "$PSAMA_SRC" "$PSAMA_SRC/pic-sure-auth-services/Dockerfile" "" "maven:3.9.9-amazoncorretto-24"

maven_build "pic-sure-dictionary-api" "$DICTIONARY_SRC" "$DICTIONARY_SRC/Dockerfile" "" "maven:3.9-eclipse-temurin-21"
maven_build "pic-sure-dictionary-dump" "$DICTIONARY_SRC/aggregate" "$DICTIONARY_SRC/aggregate/Dockerfile" "" "maven:3.9.9-amazoncorretto-24"

if ! docker image inspect "hms-dbmi/pic-sure-httpd:$IMAGE_TAG" &>/dev/null || [ "$FORCE" = "true" ]; then
  if [ ! -d "$FRONTEND_SRC" ]; then
    error "Frontend source not found at $FRONTEND_SRC"
    exit 1
  fi
  info "Building frontend (theme: $FRONTEND_THEME)..."
  FRONTEND_DEFAULTS="$FRONTEND_SRC/.env.example"
  {
    if [ -f "$FRONTEND_DEFAULTS" ]; then grep '^VITE_' "$FRONTEND_DEFAULTS" || true; fi
    grep '^VITE_' "$ENV_FILE" || true
  } > "$FRONTEND_SRC/.env"
  docker build -f "$FRONTEND_SRC/Dockerfile" \
    --build-arg THEME="$FRONTEND_THEME" \
    -t "hms-dbmi/pic-sure-httpd:$IMAGE_TAG" \
    "$FRONTEND_SRC" &> "$BUILD_OUT"
  rm -f "$FRONTEND_SRC/.env"
  info "Built hms-dbmi/pic-sure-httpd:$IMAGE_TAG"
else
  info "Image hms-dbmi/pic-sure-httpd:$IMAGE_TAG exists. Skipping."
fi

info "All images ready."
