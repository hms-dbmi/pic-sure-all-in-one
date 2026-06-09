#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — Safe Update
# =============================================================================
# Refreshes service sources/images, runs migrations, syncs the introspection
# token, and restarts services without deleting data volumes.
#
# Usage:
#   ./update.sh
#   ./update.sh --dry-run
#   ./update.sh --dry-run --offline
#   ./update.sh --no-rebuild
#   ./update.sh --pull-images
#   ./update.sh --verbose
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
PICSURE_ROOT="$SCRIPT_DIR"
export PICSURE_ROOT

LOG_PREFIX="update"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

# shellcheck source=scripts/picsure-compose.sh
source "$SCRIPT_DIR/scripts/picsure-compose.sh"

REBUILD_IMAGES=true
PULL_IMAGES=false
VERBOSE=false
DRY_RUN=false
OFFLINE=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --offline) OFFLINE=true ;;
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
  picsure_set_env_var "$ENV_FILE" "$1" "$2" true
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

repo_status_line() {
  local repo_dir="$1"
  local env_name="$2"
  local ref="${!env_name:-main}"
  local name
  name="$(basename "$repo_dir")"

  if [ ! -d "$repo_dir/.git" ]; then
    printf '  %-34s missing; would skip %s -> %s\n' "$name" "$env_name" "$ref"
    return 0
  fi

  local current
  current="$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  if [ "$current" = "HEAD" ]; then
    current="$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null || echo detached)"
  fi

  local state="clean"
  if ! git -C "$repo_dir" diff --quiet || ! git -C "$repo_dir" diff --cached --quiet; then
    state="dirty; checkout skipped"
  fi

  printf '  %-34s current=%-18s target=%-18s %s\n' "$name" "$current" "$ref" "$state"
}

dry_run_update() {
  info "Dry run only; no real repos, images, migrations, tokens, or services will be changed."

  local dry_env="$ENV_FILE"
  local dry_release_dir="$SCRIPT_DIR/.data/release-control"
  local dry_tmp=""

  if [ "$OFFLINE" = "true" ]; then
    warn "Offline dry run; using refs currently stored in .env."
  else
    dry_tmp="$(mktemp -d "${TMPDIR:-/tmp}/picsure-update-dry-run.XXXXXX")"
    dry_env="$dry_tmp/.env"
    dry_release_dir="$dry_tmp/release-control"
    cp "$ENV_FILE" "$dry_env"

    info "Resolving release-control refs into temporary dry-run state..."
    if ENV_FILE="$dry_env" RELEASE_CONTROL_DIR="$dry_release_dir" "$SCRIPT_DIR/release-control.sh" --resolve-only; then
      set -a
      # shellcheck disable=SC1090
      source "$dry_env"
      set +a
    else
      rm -rf "$dry_tmp"
      error "Dry-run release-control resolution failed. Use --dry-run --offline to inspect current .env refs only."
      exit 1
    fi
  fi

  echo ""
  echo "Release control:"
  echo "  repo:   ${RELEASE_CONTROL_REPO:-https://github.com/hms-dbmi/pic-sure-baseline-release-control}"
  echo "  branch: ${RELEASE_CONTROL_BRANCH:-main}"
  if [ -n "${RELEASE_CONTROL_COMMIT:-}" ]; then
    echo "  commit: ${RELEASE_CONTROL_COMMIT}"
  elif [ -d "$dry_release_dir/.git" ]; then
    echo "  commit: $(git -C "$dry_release_dir" rev-parse HEAD 2>/dev/null || echo unknown)"
  else
    echo "  commit: unknown; release-control cache has not been resolved yet"
  fi
  if [ -n "$dry_tmp" ]; then
    echo "  state:  resolved in temporary dry-run directory"
  else
    echo "  state:  offline; using current .env"
  fi

  echo ""
  echo "Component refs from .env:"
  for key in \
    PICSURE_REF \
    HPDS_REF \
    PSAMA_REF \
    FRONTEND_REF \
    MIGRATIONS_REF \
    DICTIONARY_REF \
    DICTIONARY_ETL_REF \
    VISUALIZATION_REF \
    LOGGING_REF \
    LOGGING_CLIENT_REF; do
    printf '  %-24s %s\n' "$key" "${!key:-main}"
  done

  echo ""
  echo "Repo checkout plan:"
  repo_status_line "$SCRIPT_DIR/repos/pic-sure" "PICSURE_REF"
  repo_status_line "$SCRIPT_DIR/repos/pic-sure-hpds" "HPDS_REF"
  repo_status_line "$SCRIPT_DIR/repos/pic-sure-auth-microapp" "PSAMA_REF"
  repo_status_line "$SCRIPT_DIR/repos/PIC-SURE-Frontend" "FRONTEND_REF"
  repo_status_line "$SCRIPT_DIR/repos/PIC-SURE-Migrations" "MIGRATIONS_REF"
  repo_status_line "$SCRIPT_DIR/repos/picsure-dictionary" "DICTIONARY_REF"
  repo_status_line "$SCRIPT_DIR/repos/picsure-dictionary-etl" "DICTIONARY_ETL_REF"
  repo_status_line "$SCRIPT_DIR/repos/PIC-SURE-Logging" "LOGGING_REF"
  repo_status_line "$SCRIPT_DIR/repos/PIC-SURE-Logging-Client" "LOGGING_CLIENT_REF"
  repo_status_line "$SCRIPT_DIR/repos/pic-sure-visualization-resource" "VISUALIZATION_REF"

  echo ""
  echo "Image action:"
  if [ "$PULL_IMAGES" = "true" ]; then
    echo "  would run: docker compose pull"
  elif [ "$REBUILD_IMAGES" = "true" ]; then
    echo "  would run: ./build-images.sh --force"
  else
    echo "  would skip image rebuild"
  fi

  echo ""
  echo "Database action:"
  echo "  DB_MODE=${DB_MODE:-local}"
  echo "  would run: ./run-migrations.sh --check"
  echo "  would run: ./run-migrations.sh"

  echo ""
  echo "Token/service action:"
  if [ -n "${AUTH0_CLIENT_SECRET:-}" ] && [ -n "${PICSURE_APPLICATION_ID:-}" ]; then
    echo "  would rotate and sync PIC-SURE introspection token"
  else
    echo "  would skip token rotation; AUTH0_CLIENT_SECRET or PICSURE_APPLICATION_ID is missing"
  fi
  echo "  would run: docker compose up -d"
  echo "  would restart: wildfly psama httpd"

  if [ -n "$dry_tmp" ]; then
    rm -rf "$dry_tmp"
  fi
}

cd "$SCRIPT_DIR"

if [ "$DRY_RUN" = "true" ]; then
  dry_run_update
  exit 0
fi

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
