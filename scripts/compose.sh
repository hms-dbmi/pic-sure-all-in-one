#!/usr/bin/env bash
# =============================================================================
# PIC-SURE — Compose Wrapper
# =============================================================================
# Day-2 docker compose operations using this project's compose-file selection
# and project-name conventions (scripts/picsure-compose.sh). The pic-sure CLI
# and TUI invoke compose exclusively through this wrapper so those conventions
# live in exactly one place.
#
# Usage:
#   scripts/compose.sh up [SERVICE...]        # start (detached)
#   scripts/compose.sh down [ARGS...]         # stop and remove containers
#   scripts/compose.sh restart [SERVICE...]   # restart services
#   scripts/compose.sh ps [ARGS...]           # read-only: service status
#   scripts/compose.sh logs [ARGS...]         # read-only: service logs
#   scripts/compose.sh config [ARGS...]       # read-only: resolved config
#
#   scripts/compose.sh dev list               # available dev overlays
#   scripts/compose.sh dev up OVERLAY         # run the overlay's service from
#                                             # local source (base + overlay,
#                                             # up -d --no-deps --build)
#   scripts/compose.sh dev off NAME           # recreate a service from the
#                                             # release image (NAME is a
#                                             # service or an overlay name)
#
# Dev overlays are one-shot: a later plain `up` or update recreates the
# service from the base compose files (release images).
# Extra arguments pass through to docker compose verbatim.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
PICSURE_ROOT="$SCRIPT_DIR"
export PICSURE_ROOT

LOG_PREFIX="compose"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

# shellcheck source=scripts/picsure-compose.sh
source "$SCRIPT_DIR/scripts/picsure-compose.sh"

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}"
}

VERB="${1:-}"
if [ -z "$VERB" ]; then
  usage >&2
  exit 1
fi
shift

# picsure_compose_files selects the remote-db overlay from DB_MODE, which is
# only set after loading .env — nothing loads it implicitly.
picsure_load_env "$ENV_FILE"

# --- dev overlay helpers ----------------------------------------------------

# dev_overlays prints the available overlay names (docker-compose.dev-X.yml -> X).
dev_overlays() {
  local f name
  for f in "$SCRIPT_DIR"/docker-compose.dev-*.yml; do
    [ -e "$f" ] || continue
    name="${f##*/docker-compose.dev-}"
    printf '%s\n' "${name%.yml}"
  done
}

# dev_overlay_service prints the (single) service an overlay file defines.
dev_overlay_service() {
  awk '/^services:/{insvc=1; next} insvc && /^  [A-Za-z0-9_-]+:/{name=$1; sub(/:.*/, "", name); print name; exit}' "$1"
}

# picsure_compose_dev runs docker compose with the project's base file
# selection plus one dev overlay appended.
picsure_compose_dev() {
  local overlay_file="$1"
  shift
  local files=()
  while IFS= read -r item; do
    files+=("$item")
  done <<EOF
$(picsure_compose_files "$PICSURE_ROOT")
EOF
  docker compose "${files[@]}" -f "$overlay_file" "$@"
}

case "$VERB" in
  up)
    picsure_compose up -d "$@"
    ;;
  dev)
    SUB="${1:-}"
    case "$SUB" in
      list)
        dev_overlays
        ;;
      up)
        OVERLAY="${2:-}"
        if [ -z "$OVERLAY" ]; then
          error "Usage: scripts/compose.sh dev up OVERLAY"
          error "Available: $(dev_overlays | tr '\n' ' ')"
          exit 1
        fi
        OVERLAY_FILE="$SCRIPT_DIR/docker-compose.dev-$OVERLAY.yml"
        if [ ! -f "$OVERLAY_FILE" ]; then
          error "Unknown dev overlay: $OVERLAY"
          error "Available: $(dev_overlays | tr '\n' ' ')"
          exit 1
        fi
        SVC="$(dev_overlay_service "$OVERLAY_FILE")"
        if [ -z "$SVC" ]; then
          error "Could not determine the service defined by $OVERLAY_FILE"
          exit 1
        fi
        info "Starting $SVC from local source (overlay: $OVERLAY). One-shot: a plain 'up' or update reverts it."
        picsure_compose_dev "$OVERLAY_FILE" up -d --no-deps --build "$SVC"
        ;;
      off)
        NAME="${2:-}"
        if [ -z "$NAME" ]; then
          error "Usage: scripts/compose.sh dev off SERVICE_OR_OVERLAY"
          exit 1
        fi
        # Accept an overlay name and resolve it to its service, so the
        # overlay->service mapping lives only here.
        SVC="$NAME"
        if [ -f "$SCRIPT_DIR/docker-compose.dev-$NAME.yml" ]; then
          SVC="$(dev_overlay_service "$SCRIPT_DIR/docker-compose.dev-$NAME.yml")"
        fi
        info "Recreating $SVC from the release image (base compose files only)."
        picsure_compose up -d --no-deps "$SVC"
        ;;
      *)
        error "Unknown dev subcommand: ${SUB:-<missing>} (expected: list, up, off)"
        usage >&2
        exit 1
        ;;
    esac
    ;;
  down|restart|ps|logs|config)
    picsure_compose "$VERB" "$@"
    ;;
  -h|--help)
    usage
    ;;
  *)
    error "Unknown command: $VERB"
    usage >&2
    exit 1
    ;;
esac
