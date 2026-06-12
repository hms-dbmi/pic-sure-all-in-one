#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — ETL Operations
# =============================================================================
# CLI replacement for the Jenkins ETL jobs.
#
# Usage:
#   ./etl.sh load-demo [nhanes|synthea|1000genomes]
#   ./etl.sh load-csv --file /path/allConcepts.csv [--heap 4096]
#   ./etl.sh load-multiple --input-dir /path/hpds_input [--heap 8000]
#   ./etl.sh load-rdbms --sql-properties /path/sql.properties --query /path/loadQuery.sql [--heap 20480]
#   ./etl.sh hydrate-dictionary [--include-dataset-facets] [--clear]
#   ./etl.sh load-dictionary-csv --datasets /path/datasets.csv --concepts /path/concepts.zip [--clear]
#   ./etl.sh load-facets --categories /path/facet_categories.csv --facets /path/facets.csv --concepts /path/facet_concepts.csv
#   ./etl.sh run-weights [--weights /path/weights.csv]
#   ./etl.sh load-vcf --partition name --vcf-index /path/vcfIndex.tsv [--vcf-dir /path/vcfs] [--heap 16000]
#   ./etl.sh promote-genomic [--backup-current-data] [--clean]
#   ./etl.sh public-1000genomes [--heap 16000]
#
# Orchestrators (recommended entry points — chain the atomic ops above):
#   ./etl.sh load-phenotype --file /path/allConcepts.csv [--heap 4096] [--dictionary auto|custom] \
#       [--datasets /path/datasets.csv --concepts /path/concepts.zip] \
#       [--facets-categories /path/facet_categories.csv --facets /path/facets.csv --facet-concepts /path/facet_concepts.csv] \
#       [--skip-weights]
#   ./etl.sh load-genomic --partition name --vcf-index /path/vcfIndex.tsv [--vcf-dir /path/vcfs] [--heap 16000] \
#       [--promote] [--enable-profile]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
PICSURE_ROOT="$SCRIPT_DIR"
export PICSURE_ROOT

LOG_PREFIX="etl"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

# shellcheck source=scripts/picsure-compose.sh
source "$SCRIPT_DIR/scripts/picsure-compose.sh"

usage() {
  sed -n '2,26p' "$0"
}

require_file() {
  if [ ! -f "$1" ]; then
    error "Missing file: $1"
    exit 1
  fi
}

require_dir() {
  if [ ! -d "$1" ]; then
    error "Missing directory: $1"
    exit 1
  fi
}

project_name() {
  echo "${COMPOSE_PROJECT_NAME:-picsure}"
}

volume_name() {
  echo "$(project_name)_$1"
}

network_name() {
  echo "$(project_name)_$1"
}

ensure_env() {
  if [ ! -f "$ENV_FILE" ]; then
    error ".env not found. Run ./init.sh first."
    exit 1
  fi
  picsure_load_env "$ENV_FILE"
}

ensure_image() {
  local image="$1"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    error "Required image not found: $image"
    error "Run ./init.sh first, or build the relevant image."
    exit 1
  fi
}

copy_hpds_key() {
  local target_volume="$1"
  local key="$SCRIPT_DIR/config/hpds/encryption_key"

  if [ ! -f "$key" ]; then
    error "HPDS encryption key not found at $key. Run ./init.sh first."
    exit 1
  fi

  docker run --rm \
    -v "$target_volume:/data" \
    -v "$key:/key:ro" \
    alpine sh -c "cp /key /data/encryption_key"
}

stop_hpds() {
  picsure_compose stop hpds >/dev/null 2>&1 || true
}

start_hpds() {
  picsure_compose up -d hpds
}

build_dictionary_etl_image() {
  if docker image inspect hms-dbmi/dictionary-etl:latest >/dev/null 2>&1; then
    return 0
  fi

  local src="${DICT_ETL_SRC:-$SCRIPT_DIR/repos/picsure-dictionary-etl}"
  if [ ! -f "$src/Dockerfile" ]; then
    error "Dictionary ETL Dockerfile not found at $src/Dockerfile"
    exit 1
  fi

  info "Building dictionary ETL image..."
  docker build -t hms-dbmi/dictionary-etl:latest "$src"
}

start_dictionary_etl() {
  build_dictionary_etl_image
  docker rm -f dictionaryetl >/dev/null 2>&1 || true
  local dict_env="$SCRIPT_DIR/config/dictionary/dictionary.env"
  require_file "$dict_env"

  docker run -d \
    --name dictionaryetl \
    --env-file "$dict_env" \
    --network "$(network_name data)" \
    -v "$(volume_name hpds-data):/opt/local/hpds/" \
    hms-dbmi/dictionary-etl:latest >/dev/null

  for _ in $(seq 1 24); do
    if docker logs dictionaryetl 2>&1 | grep -q "Started DictionaryEtlApplication"; then
      return 0
    fi
    sleep 5
  done

  docker logs dictionaryetl >&2 || true
  error "Dictionary ETL did not start."
  exit 1
}

stop_dictionary_etl() {
  docker rm -f dictionaryetl >/dev/null 2>&1 || true
}

curl_data() {
  docker run --rm --network "$(network_name data)" curlimages/curl:latest "$@"
}

load_csv() {
  local file="" heap="4096"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file) file="${2:?--file requires a value}"; shift 2 ;;
      --heap) heap="${2:?--heap requires a value}"; shift 2 ;;
      *) error "Unknown load-csv option: $1"; exit 1 ;;
    esac
  done

  require_file "$file"
  ensure_image "hms-dbmi/pic-sure-hpds-etl:${PICSURE_IMAGE_TAG:-LATEST}"
  warn "Replacing phenotype HPDS data in the hpds-data volume."
  stop_hpds
  copy_hpds_key "$(volume_name hpds-data)"
  docker run --rm \
    --name hpds-etl-loader \
    -v "$(volume_name hpds-data):/opt/local/hpds" \
    -v "$file:/opt/local/hpds/allConcepts.csv:ro" \
    -e HEAPSIZE="$heap" \
    -e LOADER_NAME=CSVLoaderNewSearch \
    "hms-dbmi/pic-sure-hpds-etl:${PICSURE_IMAGE_TAG:-LATEST}"
  start_hpds
}

load_multiple() {
  local input_dir="" heap="8000" temp_volume
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --input-dir) input_dir="${2:?--input-dir requires a value}"; shift 2 ;;
      --heap) heap="${2:?--heap requires a value}"; shift 2 ;;
      *) error "Unknown load-multiple option: $1"; exit 1 ;;
    esac
  done

  require_dir "$input_dir"
  ensure_image "hms-dbmi/pic-sure-hpds-etl:${PICSURE_IMAGE_TAG:-LATEST}"
  temp_volume="$(project_name)_hpds-temp"
  warn "Replacing phenotype HPDS data in the hpds-data volume, matching the old Jenkins multiple-file loader behavior."
  stop_hpds
  docker volume rm "$temp_volume" >/dev/null 2>&1 || true
  docker volume create "$temp_volume" >/dev/null
  copy_hpds_key "$temp_volume"
  docker run --rm \
    --name hpds-data-load-multiple-files \
    -v "$temp_volume:/opt/local/hpds" \
    -v "$input_dir:/opt/local/hpds_input:ro" \
    -e JAVA_OPTS="-Dlogback.log.level=INFO" \
    -e HEAPSIZE="$heap" \
    -e LOADER_NAME=SequentialLoader \
    "hms-dbmi/pic-sure-hpds-etl:${PICSURE_IMAGE_TAG:-LATEST}"
  docker run --rm \
    -v "$(volume_name hpds-data):/hpds" \
    -v "$temp_volume:/newdata:ro" \
    alpine sh -c "find /hpds -mindepth 1 -maxdepth 1 ! -name all -exec rm -rf {} + && cp -a /newdata/. /hpds/"
  start_hpds
}

load_rdbms() {
  local sql_properties="" query="" heap="20480" temp_volume
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --sql-properties) sql_properties="${2:?--sql-properties requires a value}"; shift 2 ;;
      --query) query="${2:?--query requires a value}"; shift 2 ;;
      --heap) heap="${2:?--heap requires a value}"; shift 2 ;;
      *) error "Unknown load-rdbms option: $1"; exit 1 ;;
    esac
  done

  require_file "$sql_properties"
  require_file "$query"
  ensure_image "hms-dbmi/pic-sure-hpds-etl:${PICSURE_IMAGE_TAG:-LATEST}"
  temp_volume="$(project_name)_hpds-rdbms-temp"
  warn "Replacing phenotype HPDS data in the hpds-data volume after RDBMS load."
  stop_hpds
  docker volume rm "$temp_volume" >/dev/null 2>&1 || true
  docker volume create "$temp_volume" >/dev/null
  copy_hpds_key "$temp_volume"
  docker run --rm \
    -v "$temp_volume:/data" \
    -v "$sql_properties:/input/sql.properties:ro" \
    -v "$query:/input/loadQuery.sql:ro" \
    alpine sh -c "cp /input/sql.properties /data/sql.properties && cp /input/loadQuery.sql /data/loadQuery.sql"
  docker run --rm \
    --name hpds-data-load-rdbms \
    -v "$temp_volume:/opt/local/hpds" \
    -e HEAPSIZE="$heap" \
    -e LOADER_NAME=SQLLoader \
    "hms-dbmi/pic-sure-hpds-etl:${PICSURE_IMAGE_TAG:-LATEST}"
  docker run --rm \
    -v "$(volume_name hpds-data):/hpds" \
    -v "$temp_volume:/newdata:ro" \
    alpine sh -c "find /hpds -mindepth 1 -maxdepth 1 ! -name all -exec rm -rf {} + && cp -a /newdata/. /hpds/"
  start_hpds
}

hydrate_dictionary() {
  local include="false" clear="false"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --include-dataset-facets) include="true"; shift ;;
      --clear) clear="true"; shift ;;
      *) error "Unknown hydrate-dictionary option: $1"; exit 1 ;;
    esac
  done

  ensure_image "hms-dbmi/pic-sure-hpds-etl:${PICSURE_IMAGE_TAG:-LATEST}"
  start_dictionary_etl
  trap stop_dictionary_etl EXIT
  docker run --rm \
    --name hpds-generate-columnmeta-csv \
    -v "$(volume_name hpds-data):/opt/local/hpds/" \
    -e JAVA_OPTS="-Dlogback.log.level=INFO" \
    -e HEAPSIZE=4096 \
    -e LOADER_NAME=CreateColumnmetaCSV \
    "hms-dbmi/pic-sure-hpds-etl:${PICSURE_IMAGE_TAG:-LATEST}"
  curl_data -sS --fail -X POST -H "Content-Type: application/json" \
    -d "{\"includeDefaultFacets\":\"$include\",\"clearDatabase\":\"$clear\"}" \
    http://dictionaryetl:8086/load/initialize
  stop_dictionary_etl
  trap - EXIT
  picsure_compose restart dictionary-api >/dev/null 2>&1 || true
}

load_dictionary_csv() {
  local datasets="" concepts="" clear="false" workdir
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --datasets) datasets="${2:?--datasets requires a value}"; shift 2 ;;
      --concepts) concepts="${2:?--concepts requires a value}"; shift 2 ;;
      --clear) clear="true"; shift ;;
      *) error "Unknown load-dictionary-csv option: $1"; exit 1 ;;
    esac
  done

  require_file "$datasets"
  require_file "$concepts"
  workdir="$(mktemp -d)"
  cp "$datasets" "$workdir/datasets.csv"
  unzip -q "$concepts" -d "$workdir/concepts"
  first_concepts="$(find "$workdir/concepts" -type f -name 'concepts_*.csv' | sort | head -n 1)"
  require_file "$first_concepts"
  start_dictionary_etl
  trap 'stop_dictionary_etl; rm -rf "$workdir"' EXIT
  if [ "$clear" = "true" ]; then
    curl_data -sS --fail -X DELETE http://dictionaryetl:8086/clear/all
  fi
  docker run --rm --network "$(network_name data)" \
    -v "$workdir/datasets.csv:/datasets.csv:ro" \
    curlimages/curl:latest \
    -sS --fail -X PUT -T /datasets.csv http://dictionaryetl:8086/api/dataset/csv

  while IFS=, read -r ref _; do
    ref="${ref%\"}"
    ref="${ref#\"}"
    [ "$ref" = "ref" ] && continue
    [ -z "$ref" ] && continue
    local dataset_dir="$workdir/$ref"
    mkdir -p "$dataset_dir"
    head -n 1 "$first_concepts" > "$dataset_dir/concepts.csv"
    grep -h -e "^\"*$ref" "$workdir"/concepts/concepts_*.csv >> "$dataset_dir/concepts.csv" || true
    docker run --rm --network "$(network_name data)" \
      -v "$dataset_dir/concepts.csv:/concepts.csv:ro" \
      curlimages/curl:latest \
      -sS --fail --request PUT --header "Content-Type: text/plain" \
      --data-binary @/concepts.csv \
      "http://dictionaryetl:8086/api/concept/csv?datasetRef=$ref"
  done < "$workdir/datasets.csv"

  picsure_compose exec -T dictionary-db psql dictionary picsure -c 'UPDATE dict.update_info SET last_updated = NOW();' || true
  stop_dictionary_etl
  rm -rf "$workdir"
  trap - EXIT
  picsure_compose restart dictionary-api >/dev/null 2>&1 || true
}

load_facets() {
  local categories="" facets="" concepts=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --categories) categories="${2:?--categories requires a value}"; shift 2 ;;
      --facets) facets="${2:?--facets requires a value}"; shift 2 ;;
      --concepts) concepts="${2:?--concepts requires a value}"; shift 2 ;;
      *) error "Unknown load-facets option: $1"; exit 1 ;;
    esac
  done

  require_file "$categories"
  require_file "$facets"
  require_file "$concepts"
  start_dictionary_etl
  trap stop_dictionary_etl EXIT
  docker run --rm --network "$(network_name data)" --entrypoint sh \
    -v "$categories:/facet_categories.csv:ro" \
    -v "$facets:/facets.csv:ro" \
    -v "$concepts:/facet_concepts.csv:ro" \
    curlimages/curl:latest -c '
      curl -sS --fail --request PUT --header "Content-Type: text/plain" --data-binary @/facet_categories.csv http://dictionaryetl:8086/api/facet/category/csv &&
      curl -sS --fail --request PUT --header "Content-Type: text/plain" --data-binary @/facets.csv http://dictionaryetl:8086/api/facet/csv &&
      curl -sS --fail --request PUT --header "Content-Type: text/plain" --data-binary @/facet_concepts.csv http://dictionaryetl:8086/api/facet/concept/csv
    '
  picsure_compose exec -T dictionary-db psql dictionary picsure -c 'UPDATE dict.update_info SET last_updated = NOW();' || true
  stop_dictionary_etl
  trap - EXIT
  picsure_compose restart dictionary-api >/dev/null 2>&1 || true
}

run_weights() {
  local weights="${DICTIONARY_WEIGHTS:-$SCRIPT_DIR/repos/picsure-dictionary/dictionaryweights/weights.csv}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --weights) weights="${2:?--weights requires a value}"; shift 2 ;;
      *) error "Unknown run-weights option: $1"; exit 1 ;;
    esac
  done

  require_file "$weights"
  local src="${DICTIONARY_SRC:-$SCRIPT_DIR/repos/picsure-dictionary}/dictionaryweights"
  if ! docker image inspect hms-dbmi/dictionary-weights:latest >/dev/null 2>&1; then
    require_file "$src/Dockerfile"
    docker build -f "$src/Dockerfile" -t hms-dbmi/dictionary-weights:latest "$src"
  fi
  local dict_env="$SCRIPT_DIR/config/dictionary/dictionary.env"
  require_file "$dict_env"
  docker run --rm \
    --name dictionary-weights \
    --network "$(network_name data)" \
    --env-file "$dict_env" \
    -v "$weights:/weights.csv:ro" \
    hms-dbmi/dictionary-weights:latest
}

load_vcf() {
  local partition="" vcf_index="" vcf_dir="" heap="16000"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --partition) partition="${2:?--partition requires a value}"; shift 2 ;;
      --vcf-index) vcf_index="${2:?--vcf-index requires a value}"; shift 2 ;;
      --vcf-dir) vcf_dir="${2:?--vcf-dir requires a value}"; shift 2 ;;
      --heap) heap="${2:?--heap requires a value}"; shift 2 ;;
      *) error "Unknown load-vcf option: $1"; exit 1 ;;
    esac
  done

  [ -n "$partition" ] || { error "--partition is required"; exit 1; }
  require_file "$vcf_index"
  [ -z "$vcf_dir" ] || require_dir "$vcf_dir"
  ensure_image "hms-dbmi/pic-sure-hpds-etl:${PICSURE_IMAGE_TAG:-LATEST}"
  local stage_dir="$SCRIPT_DIR/.data/vcf-load"
  mkdir -p "$stage_dir/genomic/$partition" "$stage_dir/genomic-merged/$partition"
  cp "$vcf_index" "$stage_dir/vcfIndex.tsv"
  local vcf_mount=()
  if [ -n "$vcf_dir" ]; then
    vcf_mount=(-v "$vcf_dir:$vcf_dir:ro")
  fi
  docker run --rm --name "hpds-new-vcf-loader-$partition" \
    -v "$stage_dir:/opt/local/hpds" \
    ${vcf_mount[@]+"${vcf_mount[@]}"} \
    -e HEAPSIZE="$heap" -e LOADER_NAME=SplitChromosomeVcfLoader \
    "hms-dbmi/pic-sure-hpds-etl:${PICSURE_IMAGE_TAG:-LATEST}"
  docker run --rm --name "hpds-vcf-metadata-loader-$partition" \
    -v "$stage_dir:/opt/local/hpds" \
    ${vcf_mount[@]+"${vcf_mount[@]}"} \
    -e HEAPSIZE="$heap" -e LOADER_NAME=VariantMetadataLoader \
    "hms-dbmi/pic-sure-hpds-etl:${PICSURE_IMAGE_TAG:-LATEST}"
  docker run --rm --name "genomic-dataset-finalizer-$partition" \
    -v "$stage_dir/genomic/$partition:/opt/local/hpds/all" \
    -e HEAPSIZE="$heap" -e LOADER_NAME=GenomicDatasetFinalizer \
    "hms-dbmi/pic-sure-hpds-etl:${PICSURE_IMAGE_TAG:-LATEST}"
}

promote_genomic() {
  local backup="false" clean="false"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --backup-current-data) backup="true"; shift ;;
      --clean) clean="true"; shift ;;
      *) error "Unknown promote-genomic option: $1"; exit 1 ;;
    esac
  done

  local stage_dir="$SCRIPT_DIR/.data/vcf-load/genomic"
  require_dir "$stage_dir"
  warn "Promoting staged genomic data into hpds-genomic. Large backups are only made when --backup-current-data is set."
  stop_hpds
  docker run --rm \
    -v "$(volume_name hpds-genomic):/hpds-genomic" \
    -v "$stage_dir:/staged:ro" \
    -e BACKUP="$backup" \
    -e CLEAN="$clean" \
    alpine sh -c '
      if [ "$BACKUP" = "true" ]; then
        rm -rf /hpds-genomic/all-bak
        mkdir -p /hpds-genomic/all-bak
        find /hpds-genomic -mindepth 1 -maxdepth 1 ! -name all-bak -exec cp -a {} /hpds-genomic/all-bak/ \; 2>/dev/null || true
      fi
      if [ "$CLEAN" = "true" ]; then
        find /hpds-genomic -mindepth 1 -maxdepth 1 ! -name all-bak -exec rm -rf {} +
      fi
      cp -a /staged/. /hpds-genomic/
    '
  start_hpds
}

public_1000genomes() {
  local heap="16000"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --heap) heap="${2:?--heap requires a value}"; shift 2 ;;
      *) error "Unknown public-1000genomes option: $1"; exit 1 ;;
    esac
  done

  warn "Nothing was downloaded or changed — genomic data requires a manual load:"
  warn "Use: ./etl.sh load-vcf --partition 1000genomes --vcf-index <path> --vcf-dir <path> --heap $heap"
  warn "Then: ./etl.sh promote-genomic [--clean] and set HPDS_PROFILE=bch-dev only after genomic data is present."
}

# orchestrator_info: emit a top-level step marker under a phase-specific
# LOG_PREFIX (e.g. `load-phenotype`) so phase detection can key off it, then
# restore the script's own prefix so the atomic functions' messages keep their
# default `[etl]` prefix. LOG_PREFIX is global in common.sh, so we scope the
# swap to exactly this one line rather than mutating it for the whole run.
# Usage: orchestrator_info PHASE_PREFIX MESSAGE
orchestrator_info() {
  local phase="$1"
  shift
  local saved="$LOG_PREFIX"
  LOG_PREFIX="$phase"
  info "$@"
  LOG_PREFIX="$saved"
}

orchestrator_warn() {
  local phase="$1"
  shift
  local saved="$LOG_PREFIX"
  LOG_PREFIX="$phase"
  warn "$@"
  LOG_PREFIX="$saved"
}

orchestrator_error() {
  local phase="$1"
  shift
  local saved="$LOG_PREFIX"
  LOG_PREFIX="$phase"
  error "$@"
  LOG_PREFIX="$saved"
}

# =============================================================================
# Orchestrators — chain the happy path over the atomic ops above.
# These are the recommended entry points; the atomic subcommands remain for
# advanced/recovery use. ALL inputs are validated up front, before any HPDS
# mutation, so a typo never half-loads the stack.
# =============================================================================

load_phenotype() {
  local phase="load-phenotype"
  local file="" heap="4096" dictionary="auto"
  local datasets="" concepts=""
  local facets_categories="" facets="" facet_concepts=""
  local skip_weights="false"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file) file="${2:?--file requires a value}"; shift 2 ;;
      --heap) heap="${2:?--heap requires a value}"; shift 2 ;;
      --dictionary) dictionary="${2:?--dictionary requires a value}"; shift 2 ;;
      --datasets) datasets="${2:?--datasets requires a value}"; shift 2 ;;
      --concepts) concepts="${2:?--concepts requires a value}"; shift 2 ;;
      --facets-categories) facets_categories="${2:?--facets-categories requires a value}"; shift 2 ;;
      --facets) facets="${2:?--facets requires a value}"; shift 2 ;;
      --facet-concepts) facet_concepts="${2:?--facet-concepts requires a value}"; shift 2 ;;
      --skip-weights) skip_weights="true"; shift ;;
      *) orchestrator_error "$phase" "Unknown load-phenotype option: $1"; exit 1 ;;
    esac
  done

  # --- Validate ALL inputs up front, before any HPDS mutation. -------------
  if [ -z "$file" ]; then
    orchestrator_error "$phase" "--file is required"
    exit 1
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    orchestrator_error "$phase" "--file not found or not readable: $file"
    exit 1
  fi

  case "$dictionary" in
    auto|custom) ;;
    *) orchestrator_error "$phase" "--dictionary must be 'auto' or 'custom' (got: $dictionary)"; exit 1 ;;
  esac

  if [ "$dictionary" = "custom" ]; then
    if [ -z "$datasets" ] || [ -z "$concepts" ]; then
      orchestrator_error "$phase" "--dictionary custom requires --datasets and --concepts"
      exit 1
    fi
    if [ ! -f "$datasets" ] || [ ! -r "$datasets" ]; then
      orchestrator_error "$phase" "--datasets not found or not readable: $datasets"
      exit 1
    fi
    if [ ! -f "$concepts" ] || [ ! -r "$concepts" ]; then
      orchestrator_error "$phase" "--concepts not found or not readable: $concepts"
      exit 1
    fi
  fi

  # Facet trio is all-or-none.
  local facet_count=0
  [ -n "$facets_categories" ] && facet_count=$((facet_count + 1))
  [ -n "$facets" ] && facet_count=$((facet_count + 1))
  [ -n "$facet_concepts" ] && facet_count=$((facet_count + 1))
  local have_facets="false"
  if [ "$facet_count" -ne 0 ]; then
    if [ "$facet_count" -ne 3 ]; then
      orchestrator_error "$phase" "--facets-categories, --facets, and --facet-concepts must be given together (all three or none)"
      exit 1
    fi
    for f in "$facets_categories" "$facets" "$facet_concepts"; do
      if [ ! -f "$f" ] || [ ! -r "$f" ]; then
        orchestrator_error "$phase" "facet file not found or not readable: $f"
        exit 1
      fi
    done
    have_facets="true"
  fi

  case "$heap" in
    ''|*[!0-9]*) orchestrator_error "$phase" "--heap must be numeric (got: $heap)"; exit 1 ;;
  esac

  # --- Run the happy path. --------------------------------------------------
  orchestrator_info "$phase" "Step 1/3: Loading phenotype CSV into HPDS…"
  if ! load_csv --file "$file" --heap "$heap"; then
    orchestrator_error "$phase" "Step 1/3 (load CSV) failed. Re-run just this step with:"
    orchestrator_error "$phase" "  ./etl.sh load-csv --file $file --heap $heap"
    exit 1
  fi

  orchestrator_info "$phase" "Step 2/3: Loading dictionary ($dictionary)…"
  if [ "$dictionary" = "auto" ]; then
    if ! hydrate_dictionary --clear; then
      orchestrator_error "$phase" "Step 2/3 (hydrate dictionary) failed. HPDS is already back up; re-run just this step with:"
      orchestrator_error "$phase" "  ./etl.sh hydrate-dictionary --clear"
      exit 1
    fi
  else
    if ! load_dictionary_csv --datasets "$datasets" --concepts "$concepts" --clear; then
      orchestrator_error "$phase" "Step 2/3 (load dictionary CSV) failed. HPDS is already back up; re-run just this step with:"
      orchestrator_error "$phase" "  ./etl.sh load-dictionary-csv --datasets $datasets --concepts $concepts --clear"
      exit 1
    fi
    if [ "$have_facets" = "true" ]; then
      if ! load_facets --categories "$facets_categories" --facets "$facets" --concepts "$facet_concepts"; then
        orchestrator_error "$phase" "Step 2/3 (load facets) failed. HPDS is already back up; re-run just this step with:"
        orchestrator_error "$phase" "  ./etl.sh load-facets --categories $facets_categories --facets $facets --concepts $facet_concepts"
        exit 1
      fi
    fi
  fi

  if [ "$skip_weights" = "true" ]; then
    orchestrator_info "$phase" "Step 3/3: Skipping dictionary weights (--skip-weights)."
  else
    orchestrator_info "$phase" "Step 3/3: Running dictionary weights…"
    if ! run_weights; then
      orchestrator_error "$phase" "Step 3/3 (run weights) failed. HPDS is already back up; re-run just this step with:"
      orchestrator_error "$phase" "  ./etl.sh run-weights"
      exit 1
    fi
  fi

  orchestrator_info "$phase" "Phenotype load complete."
}

load_genomic() {
  local phase="load-genomic"
  local partition="" vcf_index="" vcf_dir="" heap="16000"
  local promote="false" enable_profile="false"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --partition) partition="${2:?--partition requires a value}"; shift 2 ;;
      --vcf-index) vcf_index="${2:?--vcf-index requires a value}"; shift 2 ;;
      --vcf-dir) vcf_dir="${2:?--vcf-dir requires a value}"; shift 2 ;;
      --heap) heap="${2:?--heap requires a value}"; shift 2 ;;
      --promote) promote="true"; shift ;;
      --enable-profile) enable_profile="true"; shift ;;
      *) orchestrator_error "$phase" "Unknown load-genomic option: $1"; exit 1 ;;
    esac
  done

  # --- Validate ALL inputs up front, before any HPDS mutation. -------------
  if [ -z "$partition" ]; then
    orchestrator_error "$phase" "--partition is required"
    exit 1
  fi
  case "$partition" in
    *[!A-Za-z0-9_-]*|'') orchestrator_error "$phase" "--partition must match ^[A-Za-z0-9_-]+\$ (got: $partition)"; exit 1 ;;
  esac

  if [ -z "$vcf_index" ]; then
    orchestrator_error "$phase" "--vcf-index is required"
    exit 1
  fi
  if [ ! -f "$vcf_index" ] || [ ! -r "$vcf_index" ]; then
    orchestrator_error "$phase" "--vcf-index not found or not readable: $vcf_index"
    exit 1
  fi

  if [ -n "$vcf_dir" ] && [ ! -d "$vcf_dir" ]; then
    orchestrator_error "$phase" "--vcf-dir is not a directory: $vcf_dir"
    exit 1
  fi

  case "$heap" in
    ''|*[!0-9]*) orchestrator_error "$phase" "--heap must be numeric (got: $heap)"; exit 1 ;;
  esac

  if [ "$enable_profile" = "true" ] && [ "$promote" != "true" ]; then
    orchestrator_warn "$phase" "--enable-profile set without --promote: enabling HPDS_PROFILE=bch-dev without promoted genomic data crash-loops HPDS."
  fi

  # --- Run the happy path. --------------------------------------------------
  orchestrator_info "$phase" "Step 1: Loading VCF into the genomic staging area…"
  local vcf_args=(--partition "$partition" --vcf-index "$vcf_index" --heap "$heap")
  if [ -n "$vcf_dir" ]; then
    vcf_args+=(--vcf-dir "$vcf_dir")
  fi
  if ! load_vcf "${vcf_args[@]}"; then
    orchestrator_error "$phase" "Step 1 (load VCF) failed. Re-run just this step with:"
    orchestrator_error "$phase" "  ./etl.sh load-vcf ${vcf_args[*]}"
    exit 1
  fi

  if [ "$promote" = "true" ]; then
    orchestrator_info "$phase" "Step 2: Promoting staged genomic data (with backup)…"
    if ! promote_genomic --backup-current-data; then
      orchestrator_error "$phase" "Step 2 (promote genomic) failed. Re-run just this step with:"
      orchestrator_error "$phase" "  ./etl.sh promote-genomic --backup-current-data"
      exit 1
    fi
  fi

  if [ "$enable_profile" = "true" ]; then
    orchestrator_info "$phase" "Step 3: Enabling HPDS genomic profile (HPDS_PROFILE=bch-dev) and restarting HPDS…"
    if ! "$SCRIPT_DIR/scripts/env-set.sh" HPDS_PROFILE bch-dev; then
      orchestrator_error "$phase" "Step 3 (set HPDS_PROFILE) failed. Re-run just this step with:"
      orchestrator_error "$phase" "  scripts/env-set.sh HPDS_PROFILE bch-dev"
      exit 1
    fi
    if ! "$SCRIPT_DIR/scripts/compose.sh" restart hpds; then
      orchestrator_error "$phase" "Step 3 (restart HPDS) failed. Re-run just this step with:"
      orchestrator_error "$phase" "  scripts/compose.sh restart hpds"
      exit 1
    fi
  fi

  orchestrator_info "$phase" "Genomic load complete."
}

# When sourced (not executed) — e.g. by scripts/test-etl-orchestrators.sh —
# stop here so tests can call the loader functions directly against stubs
# WITHOUT running ensure_env or the dispatch below (no docker, no .env needed).
# Production always executes the script, so this never short-circuits a real
# run. (BASH_SOURCE[0] != $0 only when sourced.)
# INVARIANT: everything ABOVE this guard must stay side-effect-light at the top
# level (only function definitions + assignments) — sourcing must be safe.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

COMMAND="${1:-}"
[ -n "$COMMAND" ] || { usage; exit 1; }
shift

case "$COMMAND" in
  -h|--help|help) usage; exit 0 ;;
esac

ensure_env

case "$COMMAND" in
  load-demo) "$SCRIPT_DIR/load-demo-data.sh" "$@" ;;
  load-csv) load_csv "$@" ;;
  load-multiple) load_multiple "$@" ;;
  load-rdbms) load_rdbms "$@" ;;
  hydrate-dictionary) hydrate_dictionary "$@" ;;
  load-dictionary-csv) load_dictionary_csv "$@" ;;
  load-facets) load_facets "$@" ;;
  run-weights) run_weights "$@" ;;
  load-vcf) load_vcf "$@" ;;
  promote-genomic) promote_genomic "$@" ;;
  public-1000genomes) public_1000genomes "$@" ;;
  load-phenotype) load_phenotype "$@" ;;
  load-genomic) load_genomic "$@" ;;
  *) error "Unknown command: $COMMAND"; usage; exit 1 ;;
esac
