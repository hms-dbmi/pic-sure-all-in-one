#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — Publish shared HPDS data
# =============================================================================
# Copies this stack's hpds-data and hpds-genomic volumes into a named, shared
# data set that any stack on this host can mount read-only with
# HPDS_DATA_MODE=shared and HPDS_SHARED_DATA=NAME:
#
#   NAME_hpds-data     phenotype store, encryption key, columnMeta.csv
#   NAME_hpds-genomic  genomic data and its indexes (empty when none loaded)
#
# Load the data first (./load-demo-data.sh or ./etl.sh, which also generates
# columnMeta.csv for the dictionary), and when genomic data is present start
# HPDS once so it writes its genomic indexes; a read-only mount cannot.
#
# Usage:
#   scripts/publish-shared-hpds-data.sh NAME [--force] [--contents TEXT]
#
#   --force          replace NAME's volumes if they already exist (refused
#                    while any container still uses them)
#   --contents TEXT  what the data set holds, recorded as a volume label
#                    (default: the demo dataset load-demo-data.sh recorded in
#                    the volume, else "unknown", plus whether genomic is present)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
PICSURE_ROOT="$SCRIPT_DIR"
export PICSURE_ROOT

LOG_PREFIX="publish"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"
# shellcheck source=scripts/picsure-compose.sh
source "$SCRIPT_DIR/scripts/picsure-compose.sh"

LABEL="org.hms-dbmi.picsure.shared-hpds-data"
GENOMIC_INDEXES=(variantIndex_fbbis.javabin BucketIndexBySample.javabin)
PHENOTYPE_FILES=(encryption_key allObservationsStore.javabin columnMeta.javabin columnMeta.csv)

usage() { sed -n '2,23p' "$0"; }

NAME=""
FORCE=false
CONTENTS=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --contents) CONTENTS="${2:?--contents requires a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) error "Unknown option: $1"; usage >&2; exit 1 ;;
    *)
      if [ -n "$NAME" ]; then
        error "Only one data set name may be given."
        exit 1
      fi
      NAME="$1"; shift
      ;;
  esac
done

if [ -z "$NAME" ]; then
  usage >&2
  exit 1
fi
# Same rule as a Compose project name, so NAME_hpds-data is a valid volume.
if ! [[ "$NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
  error "Data set name must match [a-z0-9][a-z0-9_-]* (got: $NAME)."
  exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
  error ".env not found. Run ./init.sh first."
  exit 1
fi
picsure_load_env "$ENV_FILE"

if picsure_hpds_shared; then
  error "This stack already mounts the shared data set '${HPDS_SHARED_DATA:-}'."
  error "Publish from a stack with HPDS_DATA_MODE=local that loaded its own data."
  exit 1
fi

SRC_DATA="$(picsure_hpds_volume hpds-data)"
SRC_GENOMIC="$(picsure_hpds_volume hpds-genomic)"
DST_DATA="${NAME}_hpds-data"
DST_GENOMIC="${NAME}_hpds-genomic"

for vol in "$SRC_DATA" "$SRC_GENOMIC"; do
  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    error "Source volume $vol does not exist. Load data into this stack first."
    exit 1
  fi
done

# Small read-only probes run in a throwaway alpine container.
probe() {
  local vol="$1"
  shift
  docker run --rm -v "$vol:/v:ro" alpine sh -c "$@"
}

missing=()
for f in "${PHENOTYPE_FILES[@]}"; do
  probe "$SRC_DATA" "test -s /v/$f" || missing+=("$f")
done
if [ "${#missing[@]}" -gt 0 ]; then
  error "$SRC_DATA is missing: ${missing[*]}"
  error "Load phenotype data and hydrate the dictionary first (./load-demo-data.sh)."
  exit 1
fi

genomic_present=false
if [ -n "$(probe "$SRC_GENOMIC" 'ls -A /v')" ]; then
  genomic_present=true
  missing=()
  for f in "${GENOMIC_INDEXES[@]}"; do
    probe "$SRC_GENOMIC" "test -s /v/$f" || missing+=("$f")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    error "$SRC_GENOMIC holds genomic data but not its indexes: ${missing[*]}"
    error "Start HPDS once with this data (it writes them on first start), then publish."
    exit 1
  fi
fi

for vol in "$DST_DATA" "$DST_GENOMIC"; do
  if docker volume inspect "$vol" >/dev/null 2>&1; then
    if [ "$FORCE" != "true" ]; then
      error "$vol already exists. Pass --force to replace it."
      exit 1
    fi
    users="$(docker ps -a --filter "volume=$vol" --format '{{.Names}}')"
    if [ -n "$users" ]; then
      error "$vol is still used by: $(echo "$users" | tr '\n' ' ')"
      error "Switch those stacks off $NAME (or remove the containers) before replacing it."
      exit 1
    fi
  fi
done

if [ -z "$CONTENTS" ]; then
  # load-demo-data.sh records the dataset it loaded; etl.sh loads remove it.
  phenotype="$(probe "$SRC_DATA" 'cat /v/.picsure-dataset 2>/dev/null' || true)"
  CONTENTS="phenotype=${phenotype:-unknown} genomic=$genomic_present"
fi

# The pic-sure commit the HPDS loader was built from, falling back to the
# configured source checkout; the AIO commit records how the data was loaded.
picsure_commit="$(picsure_image_label "hms-dbmi/pic-sure-hpds-etl:${PICSURE_IMAGE_TAG:-LATEST}" \
  org.hms-dbmi.picsure.reactor-src)"
if [ -z "$picsure_commit" ]; then
  picsure_commit="$(picsure_src_commit "${PICSURE_SRC:-$SCRIPT_DIR/repos/pic-sure}")"
fi
aio_commit="$(picsure_src_commit "$SCRIPT_DIR")"
created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ "$FORCE" = "true" ]; then
  for vol in "$DST_DATA" "$DST_GENOMIC"; do
    if docker volume inspect "$vol" >/dev/null 2>&1; then
      docker volume rm "$vol" >/dev/null
      info "Removed existing $vol"
    fi
  done
fi

# Remove half-written volumes if any step below fails.
created_vols=()
cleanup_failed() {
  local vol
  for vol in ${created_vols[@]+"${created_vols[@]}"}; do
    docker volume rm "$vol" >/dev/null 2>&1 || true
  done
}
trap cleanup_failed EXIT

create_volume() {
  local vol="$1" kind="$2"
  docker volume create \
    --label "$LABEL=$NAME" \
    --label "$LABEL.kind=$kind" \
    --label "$LABEL.contents=$CONTENTS" \
    --label "$LABEL.picsure-commit=${picsure_commit:-unknown}" \
    --label "$LABEL.aio-commit=${aio_commit:-unknown}" \
    --label "$LABEL.source-project=${COMPOSE_PROJECT_NAME:-picsure}" \
    --label "$LABEL.created=$created" \
    "$vol" >/dev/null
  created_vols+=("$vol")
}

create_volume "$DST_DATA" hpds-data
create_volume "$DST_GENOMIC" hpds-genomic

info "Copying $SRC_DATA -> $DST_DATA..."
# HPDS mounts the genomic volume at /opt/local/hpds/all, inside the read-only
# data volume, so the mount point has to exist in the copy already.
docker run --rm -v "$SRC_DATA:/src:ro" -v "$DST_DATA:/dst" alpine \
  sh -c 'cp -a /src/. /dst/ && mkdir -p /dst/all'
info "Copying $SRC_GENOMIC -> $DST_GENOMIC..."
docker run --rm -v "$SRC_GENOMIC:/src:ro" -v "$DST_GENOMIC:/dst" alpine \
  sh -c 'cp -a /src/. /dst/'

created_vols=()
trap - EXIT

info "Published shared HPDS data set '$NAME' ($CONTENTS)."
info "Mount it from any stack with, in that stack's .env:"
info "  HPDS_DATA_MODE=shared"
info "  HPDS_SHARED_DATA=$NAME"
info "then recreate HPDS (./scripts/compose.sh up -d hpds) and hydrate the dictionary (./load-demo-data.sh)."
