#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — ETL Operations
# =============================================================================
# CLI replacement for the Jenkins ETL jobs.
#
# Usage:
#   ./etl.sh load-demo [nhanes|synthea|1000genomes]
#   ./etl.sh load-csv --file /path/allConcepts.csv [--heap 4096] [--entry name.csv]
#       (--file accepts a raw .csv, a .gz/.csv.gz, or a .tgz/.tar.gz; for a tar
#        with multiple CSVs, pass --entry to pick one — see `archive-csvs`.)
#   ./etl.sh archive-csvs /path/archive.tgz   (list .csv entries; read-only)
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
#   ./etl.sh load-phenotype --file /path/allConcepts.csv [--heap 4096] [--entry name.csv] [--dictionary auto|custom] \
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
  # Print the header comment block (from line 2) up to but not including the
  # first non-comment line, then trim the trailing `# ===` divider that closes
  # the block. Sentinel-based so adding header lines never truncates the help.
  awk 'NR == 1 { next }
       /^#/ { buf[n++] = $0; next }
       { exit }
       END { end = n; if (n > 0 && buf[n-1] ~ /^# =+$/) end = n - 1;
             for (i = 0; i < end; i++) print buf[i] }' "$0"
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

# archive_csv_entries: print the *.csv entries of a gzipped tar, one per line,
# sorted. For a plain .csv or plain (non-tar) .gz, print NOTHING. Pure
# read-only (tar -tzf only); no docker, no mutation. Detection is by content,
# not extension. Returns non-zero only if $1 is missing/unreadable.
#
# This is the shared core for the `archive-csvs` lister AND for load_csv's tar
# branch, so both agree on exactly which entries count as CSVs.
archive_csv_entries() {
  local file="$1"
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    return 1
  fi
  # Only gzipped tars have enumerable CSV entries; everything else → nothing.
  if tar -tzf "$file" >/dev/null 2>&1; then
    # `|| true`: grep exits 1 with no match (pipefail would otherwise abort).
    tar -tzf "$file" 2>/dev/null | grep -i '\.csv$' | LC_ALL=C sort || true
  fi
}

# archive_csvs: the `archive-csvs <file>` subcommand — a read-only lister for the
# TUI. Prints the *.csv entries of a gzipped tar (one per line, sorted); prints
# NOTHING for a plain .csv or a plain (non-tar) .gz (exit 0). Exits non-zero on a
# missing/unreadable file. No docker, no mutation. The wizard (LD-7b) uses the
# line count to decide whether to prompt for --entry (0–1 → auto; ≥2 → picker).
archive_csvs() {
  local file="${1:-}"
  if [ -z "$file" ]; then
    error "archive-csvs requires a file argument"
    exit 1
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    error "Missing or unreadable file: $file"
    exit 1
  fi
  archive_csv_entries "$file"
}

# resolve_phenotype_csv: turn --file (raw CSV | plain gzip | gzipped tar) into a
# host path to mount as allConcepts.csv. Detection is by CONTENT, not extension.
#
# Contract:
#   $1 = input file (already existence-checked by the caller)
#   $2 = name of a caller-owned variable to receive the resolved host path.
#   $3 = name of a caller-owned variable to receive a created temp dir, set to
#        "" for raw CSV (no temp dir is created — the file is used verbatim).
#   $4 = optional --entry (which CSV inside a multi-CSV tar)
#
# Called WITHOUT command substitution (so the by-name var assignments land in
# the caller's scope). We create the temp dir with mktemp -d (NOT under .data/)
# only when decompression is needed and write its path into the caller's var so
# the caller can trap-clean it. On any error we clean up our own temp dir and
# return non-zero, so a failure here never leaks a temp dir.
# NOTE: internal locals are `_rpc_`-prefixed so they can't collide (under bash's
# dynamic scoping) with the out-param NAMES the caller passes in $2/$3 — a plain
# `local tmpdir` here would shadow a caller var also named `tmpdir`, and the
# by-name `eval` would write the callee's local instead of the caller's.
resolve_phenotype_csv() {
  local _rpc_file="$1" _rpc_resolvedvar="$2" _rpc_tmpvar="$3" _rpc_entry="${4:-}"
  local _rpc_tmpdir=""
  eval "$_rpc_tmpvar=''"

  if tar -tzf "$_rpc_file" >/dev/null 2>&1; then
    # --- gzipped tar ---------------------------------------------------------
    local _rpc_entries _rpc_count _rpc_line
    _rpc_entries="$(archive_csv_entries "$_rpc_file")"
    _rpc_count=0
    while IFS= read -r _rpc_line; do
      [ -n "$_rpc_line" ] && _rpc_count=$((_rpc_count + 1))
    done <<EOF
$_rpc_entries
EOF

    if [ "$_rpc_count" -eq 0 ]; then
      error "archive contains no .csv: $_rpc_file"
      return 1
    fi

    if [ "$_rpc_count" -eq 1 ]; then
      _rpc_entry="$_rpc_entries"
    elif [ -z "$_rpc_entry" ]; then
      error "multiple CSVs in archive; pass --entry <one of>:"
      while IFS= read -r _rpc_line; do
        [ -n "$_rpc_line" ] && error "  $_rpc_line"
      done <<EOF
$_rpc_entries
EOF
      return 1
    else
      local _rpc_matched="false"
      while IFS= read -r _rpc_line; do
        [ "$_rpc_line" = "$_rpc_entry" ] && _rpc_matched="true"
      done <<EOF
$_rpc_entries
EOF
      if [ "$_rpc_matched" != "true" ]; then
        error "--entry not found in archive: $_rpc_entry"
        error "available .csv entries:"
        while IFS= read -r _rpc_line; do
          [ -n "$_rpc_line" ] && error "  $_rpc_line"
        done <<EOF
$_rpc_entries
EOF
        return 1
      fi
    fi

    _rpc_tmpdir="$(mktemp -d)"
    # tar entries may include subdir paths, so the extracted file lands at
    # "$_rpc_tmpdir/$_rpc_entry" — mount exactly that.
    if ! tar -xzf "$_rpc_file" -C "$_rpc_tmpdir" "$_rpc_entry"; then
      error "failed to extract '$_rpc_entry' from archive: $_rpc_file"
      rm -rf "$_rpc_tmpdir"
      return 1
    fi
    if [ ! -s "$_rpc_tmpdir/$_rpc_entry" ]; then
      error "extracted CSV is empty or missing: $_rpc_entry"
      rm -rf "$_rpc_tmpdir"
      return 1
    fi
    eval "$_rpc_tmpvar=\$_rpc_tmpdir"
    eval "$_rpc_resolvedvar=\"\$_rpc_tmpdir/\$_rpc_entry\""
    return 0
  fi

  if gzip -t "$_rpc_file" >/dev/null 2>&1; then
    # --- plain gzip (a single .gz / .csv.gz, not a tar) ----------------------
    [ -n "$_rpc_entry" ] && warn "--entry ignored for a plain gzip (only tars have entries): $_rpc_entry"
    _rpc_tmpdir="$(mktemp -d)"
    if ! gunzip -c "$_rpc_file" > "$_rpc_tmpdir/allConcepts.csv"; then
      error "failed to gunzip: $_rpc_file"
      rm -rf "$_rpc_tmpdir"
      return 1
    fi
    if [ ! -s "$_rpc_tmpdir/allConcepts.csv" ]; then
      error "decompressed CSV is empty: $_rpc_file"
      rm -rf "$_rpc_tmpdir"
      return 1
    fi
    eval "$_rpc_tmpvar=\$_rpc_tmpdir"
    eval "$_rpc_resolvedvar=\"\$_rpc_tmpdir/allConcepts.csv\""
    return 0
  fi

  # --- raw CSV / plain text: used verbatim, no temp dir --------------------
  case "$_rpc_file" in
    *.csv) ;;
    *)
      # Accept anything that looks like text (the loader validates schema); a
      # non-empty binary that is neither a tar nor gzip is almost certainly a
      # mistake.
      if [ -s "$_rpc_file" ] && ! LC_ALL=C grep -Iq . "$_rpc_file" 2>/dev/null; then
        error "unrecognized --file: not a .csv, gzip, or gzipped tar: $_rpc_file"
        return 1
      fi
      ;;
  esac
  [ -n "$_rpc_entry" ] && warn "--entry ignored for a raw CSV (only tars have entries): $_rpc_entry"
  eval "$_rpc_resolvedvar=\$_rpc_file"
  return 0
}

load_csv() {
  local file="" heap="4096" entry=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file) file="${2:?--file requires a value}"; shift 2 ;;
      --heap) heap="${2:?--heap requires a value}"; shift 2 ;;
      --entry) entry="${2:?--entry requires a value}"; shift 2 ;;
      *) error "Unknown load-csv option: $1"; exit 1 ;;
    esac
  done

  require_file "$file"
  ensure_image "hms-dbmi/pic-sure-hpds-etl:${PICSURE_IMAGE_TAG:-LATEST}"

  # Resolve the input (raw CSV verbatim | gunzip | extract-from-tar) into a host
  # path to mount. A temp dir is created ONLY when decompression is needed and
  # is named back into $tmpdir so we can clean it up afterwards.
  #
  # Cleanup-under-set-e note: we deliberately do NOT use a `trap … RETURN` here.
  # In bash 3.2 a RETURN trap set inside a function is NOT auto-scoped — it leaks
  # and fires again when the CALLER returns (where $tmpdir is out of scope → a
  # set -u abort). We also can't wrap the mutating block in `{ … } || rc=$?`,
  # because set -e is SUPPRESSED on the LHS of ||, so a failed `docker run`
  # would no longer short-circuit `start_hpds`. Instead we capture the loader's
  # exit directly with `|| rc=$?` on the docker run, gate start_hpds on success
  # (preserving today's "loader failed → HPDS stays stopped" behavior), and
  # `rm -rf "$tmpdir"` on BOTH paths before returning rc. resolve_phenotype_csv
  # already cleans up its own temp dir on its error paths.
  local tmpdir="" resolved=""
  if ! resolve_phenotype_csv "$file" resolved tmpdir "$entry"; then
    rm -rf "$tmpdir"
    return 1
  fi

  warn "Replacing phenotype HPDS data in the hpds-data volume."
  stop_hpds
  local rc=0
  copy_hpds_key "$(volume_name hpds-data)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    docker run --rm \
      --name hpds-etl-loader \
      -v "$(volume_name hpds-data):/opt/local/hpds" \
      -v "$resolved:/opt/local/hpds/allConcepts.csv:ro" \
      -e HEAPSIZE="$heap" \
      -e LOADER_NAME=CSVLoaderNewSearch \
      "hms-dbmi/pic-sure-hpds-etl:${PICSURE_IMAGE_TAG:-LATEST}" || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    start_hpds || rc=$?
  fi
  rm -rf "$tmpdir"
  return "$rc"
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
  local file="" heap="4096" dictionary="auto" entry=""
  local datasets="" concepts=""
  local facets_categories="" facets="" facet_concepts=""
  local skip_weights="false"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file) file="${2:?--file requires a value}"; shift 2 ;;
      --heap) heap="${2:?--heap requires a value}"; shift 2 ;;
      --entry) entry="${2:?--entry requires a value}"; shift 2 ;;
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
  # --entry only makes sense alongside --file; the archive-content validation
  # (is it a tar? is the entry inside it?) lives in load_csv.
  if [ -n "$entry" ] && [ -z "$file" ]; then
    orchestrator_error "$phase" "--entry requires --file"
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
  # Pass --entry through only when set, so the (common) no-entry call keeps the
  # same argv as before.
  local csv_args=(--file "$file" --heap "$heap")
  [ -n "$entry" ] && csv_args+=(--entry "$entry")
  if ! load_csv "${csv_args[@]}"; then
    orchestrator_error "$phase" "Step 1/3 (load CSV) failed. Re-run just this step with:"
    orchestrator_error "$phase" "  ./etl.sh load-csv ${csv_args[*]}"
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
  # Pure read-only lister; needs no .env / docker, so dispatch before ensure_env
  # (the TUI may call it before a stack exists).
  archive-csvs) archive_csvs "$@"; exit 0 ;;
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
