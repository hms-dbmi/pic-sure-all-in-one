#!/usr/bin/env bash
# =============================================================================
# PIC-SURE — Load Demo Data
# =============================================================================
# Loads a demo dataset into HPDS and hydrates the dictionary.
#
# Usage:
#   ./load-demo-data.sh                # Load NHANES (default)
#   ./load-demo-data.sh synthea        # Load Synthea 10k
#   ./load-demo-data.sh 1000genomes    # Load 1000 Genomes
#   ./load-demo-data.sh --all          # Load NHANES, Synthea 10k, and 1000 Genomes
#   ./load-demo-data.sh --verbose      # Show full ETL/Docker output
#
# Prerequisites:
#   - docker compose up -d must have been run (databases healthy)
#   - init.sh must have been run (.env exists)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PICSURE_ROOT="$SCRIPT_DIR"
export PICSURE_ROOT

LOG_PREFIX="data"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

# shellcheck source=scripts/picsure-compose.sh
source "$SCRIPT_DIR/scripts/picsure-compose.sh"

# Parse flags
VERBOSE=false
DATASET="nhanes"
for arg in "$@"; do
  case "$arg" in
    --verbose) VERBOSE=true ;;
    --all) DATASET="all" ;;
    -*) error "Unknown flag: $arg"; exit 1 ;;
    *) DATASET="$arg" ;;
  esac
done

# Run a noisy step: stream in verbose mode, otherwise capture to a log file
# and show its tail on failure (shared helper in scripts/lib/common.sh).
run_logged() {
  picsure_run_logged "$SCRIPT_DIR/.data/logs/etl" "$@"
}

# Source .env
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
else
  error ".env not found. Run ./init.sh first."
  exit 1
fi

# Volume/network names and image tags must match the Compose project settings.
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-picsure}"
HPDS_DATA_VOLUME="${PROJECT_NAME}_hpds-data"
DATA_NETWORK="${PROJECT_NAME}_data"
HPDS_ETL_IMAGE="hms-dbmi/pic-sure-hpds-etl:${PICSURE_IMAGE_TAG:-LATEST}"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

if [ "${DB_MODE:-local}" = "remote" ]; then
  # Env-prefix + bare -e: the host shell puts the password in docker's
  # environment (not argv); docker forwards it by name into the container.
  if ! MYSQL_PWD="${DB_ROOT_PASSWORD}" docker run --rm -e MYSQL_PWD mysql:8.0 \
    mysql -h "${DB_HOST}" -P "${DB_PORT:-3306}" -u "${DB_ROOT_USER:-root}" -e "SELECT 1;" >/dev/null 2>&1; then
    error "Remote MySQL is not reachable at ${DB_HOST:-unset}:${DB_PORT:-3306}."
    exit 1
  fi
else
  if ! picsure_compose ps picsure-db 2>/dev/null | grep -q healthy; then
    error "picsure-db is not healthy. Run 'docker compose up -d' first."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Ensure HPDS ETL image exists
# ---------------------------------------------------------------------------

if ! docker image inspect "$HPDS_ETL_IMAGE" >/dev/null 2>&1; then
  error "HPDS ETL image not found: $HPDS_ETL_IMAGE. Run ./init.sh first (it builds all images)."
  exit 1
fi

# ---------------------------------------------------------------------------
# Download / extract dataset
# ---------------------------------------------------------------------------

DATA_DIR="$SCRIPT_DIR/.data"
mkdir -p "$DATA_DIR"
DATASETS_REPO="https://github.com/hms-dbmi/pic-sure-public-datasets.git"

# The three single datasets share $DATA_DIR/allConcepts.csv, and each case
# below skips regeneration when the file exists — so without provenance,
# switching datasets would silently load the previous one. A marker records
# which dataset produced the file; a mismatch (or a pre-marker file of
# unknown origin) forces regeneration.
DATASET_MARKER="$DATA_DIR/allConcepts.dataset"
if [ "$DATASET" != "all" ] && [ -f "$DATA_DIR/allConcepts.csv" ]; then
  if [ ! -f "$DATASET_MARKER" ] || [ "$(cat "$DATASET_MARKER")" != "$DATASET" ]; then
    info "Existing allConcepts.csv is not from the '$DATASET' dataset; regenerating."
    rm -f "$DATA_DIR/allConcepts.csv"
  fi
fi

case "$DATASET" in
  nhanes)
    info "Preparing NHANES demo dataset..."
    if [ ! -f "$DATA_DIR/allConcepts.csv" ]; then
      if [ -f "$SCRIPT_DIR/demo-data/allConcepts.csv.tgz" ]; then
        info "Extracting bundled NHANES data..."
        tar -xzf "$SCRIPT_DIR/demo-data/allConcepts.csv.tgz" -C "$DATA_DIR/"
      else
        info "Downloading NHANES data from GitHub..."
        CLONE_DIR="$DATA_DIR/datasets"
        rm -rf "$CLONE_DIR"
        git clone --depth 1 --filter=blob:none --sparse "$DATASETS_REPO" "$CLONE_DIR" 2>/dev/null \
          || { error "Failed to clone $DATASETS_REPO (network?)."; exit 1; }
        cd "$CLONE_DIR" && git sparse-checkout set "NHANES abbreviated allConcepts.csv.tgz"
        tar -xzf "NHANES abbreviated allConcepts.csv.tgz" -C "$DATA_DIR/"
        cd "$SCRIPT_DIR"
      fi
    else
      info "NHANES data already extracted."
    fi
    ;;
  synthea)
    info "Preparing Synthea 10k dataset..."
    if [ ! -f "$DATA_DIR/allConcepts.csv" ]; then
      CLONE_DIR="$DATA_DIR/datasets"
      rm -rf "$CLONE_DIR"
      git clone --depth 1 --filter=blob:none --sparse "$DATASETS_REPO" "$CLONE_DIR" 2>/dev/null \
        || { error "Failed to clone $DATASETS_REPO (network?)."; exit 1; }
      cd "$CLONE_DIR" && git sparse-checkout set "synthea_10k_picsure_format.csv.zip"
      unzip -o "synthea_10k_picsure_format.csv.zip" -d "$DATA_DIR/"
      mv "$DATA_DIR/synthea_10k_picsure_format.csv" "$DATA_DIR/allConcepts.csv"
      cd "$SCRIPT_DIR"
    fi
    ;;
  1000genomes)
    info "Preparing 1000 Genomes dataset..."
    if [ ! -f "$DATA_DIR/allConcepts.csv" ]; then
      CLONE_DIR="$DATA_DIR/datasets"
      rm -rf "$CLONE_DIR"
      git clone --depth 1 --filter=blob:none --sparse "$DATASETS_REPO" "$CLONE_DIR" 2>/dev/null \
        || { error "Failed to clone $DATASETS_REPO (network?)."; exit 1; }
      cd "$CLONE_DIR" && git sparse-checkout set "open_access-1000Genomes_allConcepts_new_search_with_data_analyzer.csv"
      cp "open_access-1000Genomes_allConcepts_new_search_with_data_analyzer.csv" "$DATA_DIR/allConcepts.csv"
      cd "$SCRIPT_DIR"
    fi
    ;;
  all)
    info "Preparing all public demo datasets..."
    ALL_INPUT_DIR="$DATA_DIR/all-public-studies"
    mkdir -p "$ALL_INPUT_DIR"
    if [ ! -f "$ALL_INPUT_DIR/nhanes.csv" ] || \
       [ ! -f "$ALL_INPUT_DIR/synthea.csv" ] || \
       [ ! -f "$ALL_INPUT_DIR/1000_genomes.csv" ]; then
      CLONE_DIR="$DATA_DIR/datasets-all"
      rm -rf "$CLONE_DIR"
      git clone --depth 1 --filter=blob:none --sparse "$DATASETS_REPO" "$CLONE_DIR" 2>/dev/null \
        || { error "Failed to clone $DATASETS_REPO (network?)."; exit 1; }
      cd "$CLONE_DIR" && git sparse-checkout set --no-cone \
        "NHANES abbreviated allConcepts.csv.tgz" \
        "synthea_10k_picsure_format.csv.zip" \
        "open_access-1000Genomes_allConcepts_new_search_with_data_analyzer.csv"

      rm -f "$ALL_INPUT_DIR/nhanes.csv" "$ALL_INPUT_DIR/synthea.csv" "$ALL_INPUT_DIR/1000_genomes.csv"
      tar -xzf "$CLONE_DIR/NHANES abbreviated allConcepts.csv.tgz" -C "$ALL_INPUT_DIR/"
      mv "$ALL_INPUT_DIR/allConcepts.csv" "$ALL_INPUT_DIR/nhanes.csv"
      unzip -o "$CLONE_DIR/synthea_10k_picsure_format.csv.zip" -d "$ALL_INPUT_DIR/" >/dev/null
      mv "$ALL_INPUT_DIR/synthea_10k_picsure_format.csv" "$ALL_INPUT_DIR/synthea.csv"
      cp "$CLONE_DIR/open_access-1000Genomes_allConcepts_new_search_with_data_analyzer.csv" "$ALL_INPUT_DIR/1000_genomes.csv"
      cd "$SCRIPT_DIR"
    else
      info "All public demo datasets already prepared."
    fi

    ALL_CONCEPTS_CSV="$DATA_DIR/allConcepts-all.csv"
    info "Combining all public demo datasets into one CSV..."
    head -n 1 "$ALL_INPUT_DIR/nhanes.csv" > "$ALL_CONCEPTS_CSV"
    tail -n +2 "$ALL_INPUT_DIR/nhanes.csv" >> "$ALL_CONCEPTS_CSV"
    tail -n +2 "$ALL_INPUT_DIR/synthea.csv" >> "$ALL_CONCEPTS_CSV"
    tail -n +2 "$ALL_INPUT_DIR/1000_genomes.csv" >> "$ALL_CONCEPTS_CSV"
    ;;
  *)
    error "Unknown dataset: $DATASET"
    error "Available: nhanes, synthea, 1000genomes, --all"
    exit 1
    ;;
esac

if [ "$DATASET" = "all" ]; then
  info "Datasets ready: $(wc -l < "$ALL_CONCEPTS_CSV") rows"
else
  printf '%s\n' "$DATASET" > "$DATASET_MARKER"
  info "Dataset ready: $(wc -l < "$DATA_DIR/allConcepts.csv") rows"
fi

# ---------------------------------------------------------------------------
# Ensure encryption key exists
# ---------------------------------------------------------------------------

HPDS_KEY="$SCRIPT_DIR/config/hpds/encryption_key"
if [ ! -f "$HPDS_KEY" ]; then
  info "Generating HPDS encryption key..."
  mkdir -p "$(dirname "$HPDS_KEY")"
  openssl enc -aes-128-cbc -k "$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)" -P 2>/dev/null \
    | grep key | cut -d'=' -f2 > "$HPDS_KEY"
fi

# ---------------------------------------------------------------------------
# Step 1: Load data into HPDS (CSV → javabin)
# ---------------------------------------------------------------------------

info "Step 1/4: Loading data into HPDS (CSV → javabin)..."
info "This may take 1-5 minutes depending on dataset size."

# Stop HPDS while loading
picsure_compose stop hpds 2>/dev/null || true

# Clear prior generated HPDS files, then copy encryption key into the data volume
# FIRST (bind mount overlay doesn't persist). Keeping stale javabin/temp files can
# consume large amounts of Docker disk after failed loads.
docker run --rm \
  -v "$HPDS_DATA_VOLUME:/data" \
  -v "$HPDS_KEY:/key:ro" \
  alpine sh -c "rm -f /data/allObservationsStore.javabin /data/allObservationsTemp.javabin /data/columnMeta.javabin /data/columnMeta.csv /data/columnMetaErrors.csv && cp /key /data/encryption_key"

if [ "$DATASET" = "all" ]; then
  LOAD_CSV="$ALL_CONCEPTS_CSV"
else
  LOAD_CSV="$DATA_DIR/allConcepts.csv"
fi

run_logged "hpds-etl-loader" docker run --rm \
  --name hpds-etl-loader \
  -v "$HPDS_DATA_VOLUME:/opt/local/hpds" \
  -v "$LOAD_CSV:/opt/local/hpds/allConcepts.csv:ro" \
  -e HEAPSIZE=4096 \
  -e LOADER_NAME=CSVLoaderNewSearch \
  -e LOADER_ARGS=ROLLUP \
  "$HPDS_ETL_IMAGE"

info "HPDS data loaded."

# ---------------------------------------------------------------------------
# Step 2: Restart HPDS
# ---------------------------------------------------------------------------

info "Step 2/4: Starting HPDS..."
picsure_compose up -d hpds

# Wait for healthy
info "Waiting for HPDS to become healthy..."
for i in $(seq 1 30); do
  if docker inspect --format='{{.State.Health.Status}}' hpds 2>/dev/null | grep -q healthy; then
    info "HPDS is healthy."
    break
  fi
  if [ "$i" -eq 30 ]; then
    warn "HPDS did not become healthy within 150 seconds. Check logs: docker compose logs hpds"
  fi
  sleep 5
done

# ---------------------------------------------------------------------------
# Step 3: Hydrate dictionary database
# ---------------------------------------------------------------------------

info "Step 3/4: Hydrating dictionary database..."

# Build dictionary-etl image if not present
DICT_ETL_SRC="${DICT_ETL_SRC:-$SCRIPT_DIR/repos/picsure-dictionary-etl}"
if ! docker image inspect hms-dbmi/dictionary-etl:latest >/dev/null 2>&1; then
  if [ -f "$DICT_ETL_SRC/Dockerfile" ]; then
    info "Building dictionary ETL image..."
    run_logged "dictionary-etl-build" docker build -t hms-dbmi/dictionary-etl:latest "$DICT_ETL_SRC"
  else
    warn "Dictionary ETL source not found at $DICT_ETL_SRC"
    warn "Clone it: git clone https://github.com/hms-dbmi/picsure-dictionary-etl.git"
    warn "Skipping dictionary hydration."
    SKIP_DICT=true
  fi
fi

if [ "${SKIP_DICT:-}" != "true" ]; then
  DICT_PASS=$(grep "^POSTGRES_PASSWORD=" "$SCRIPT_DIR/config/dictionary/dictionary.env" | cut -d= -f2)

  # Step 3a: Generate columnMeta.csv from HPDS data
  info "Generating columnMeta.csv from HPDS data..."
  run_logged "hpds-columnmeta" docker run --rm \
    --name hpds-columnmeta \
    -v "$HPDS_DATA_VOLUME:/opt/local/hpds/" \
    -e HEAPSIZE=4096 \
    -e LOADER_NAME=CreateColumnmetaCSV \
    "$HPDS_ETL_IMAGE"

  # Step 3b: Start dictionary ETL service
  info "Starting dictionary ETL service..."
  docker rm -f dictionaryetl 2>/dev/null || true
  run_logged "dictionary-etl-start" docker run -d \
    --name dictionaryetl \
    --network "$DATA_NETWORK" \
    -v "$HPDS_DATA_VOLUME:/opt/local/hpds/" \
    -e POSTGRES_HOST=dictionary-db \
    -e POSTGRES_DB=dictionary \
    -e POSTGRES_USER=picsure \
    -e POSTGRES_PASSWORD="$DICT_PASS" \
    hms-dbmi/dictionary-etl:latest

  # Wait for ETL to start
  for i in $(seq 1 12); do
    if docker logs dictionaryetl 2>&1 | grep -q "Started DictionaryEtlApplication"; then
      break
    fi
    sleep 5
  done

  # Step 3c: Trigger hydration via API
  info "Hydrating dictionary (this may take a moment)..."
  # Need to reach the ETL container — use a curl container on the same network
  run_logged "dictionary-hydrate" docker run --rm --network "$DATA_NETWORK" curlimages/curl:latest \
    -sS --fail -X POST -H "Content-Type: application/json" \
    -d '{"includeDefaultFacets": "true", "clearDatabase": "true"}' \
    http://dictionaryetl:8086/load/initialize

  # Step 3c.1: Load facet configuration
  FACET_CONFIG="$SCRIPT_DIR/demo-data/facet_loader_configuration.json"
  if [ -f "$FACET_CONFIG" ]; then
    info "Loading facet configuration..."
    run_logged "facet-load" docker run --rm --network "$DATA_NETWORK" \
      -v "$FACET_CONFIG:/facet_config.json:ro" \
      curlimages/curl:latest \
      -sS --fail -X POST -H "Content-Type: application/json" \
      -d @/facet_config.json \
      http://dictionaryetl:8086/api/facet/loader/load
    info "Facets loaded."
  else
    warn "Facet config not found at $FACET_CONFIG — skipping facet loading."
  fi

  # Clean up ETL container
  docker rm -f dictionaryetl >/dev/null 2>&1 || true

  # Step 3d: Run dictionary weights (required for search to work)
  info "Running dictionary weights..."
  DICT_WEIGHTS_SRC="${DICTIONARY_SRC:-$SCRIPT_DIR/repos/picsure-dictionary}/dictionaryweights"
  if ! docker image inspect hms-dbmi/dictionary-weights:latest >/dev/null 2>&1; then
    if [ -f "$DICT_WEIGHTS_SRC/Dockerfile" ]; then
      run_logged "dictionary-weights-build" docker build -f "$DICT_WEIGHTS_SRC/Dockerfile" "$DICT_WEIGHTS_SRC" \
        -t hms-dbmi/dictionary-weights:latest
    fi
  fi

  if docker image inspect hms-dbmi/dictionary-weights:latest >/dev/null 2>&1; then
    run_logged "dictionary-weights" docker run --rm \
      --name dictionary-weights \
      --network "$DATA_NETWORK" \
      -v "$SCRIPT_DIR/repos/picsure-dictionary/dictionaryweights/weights.csv:/weights.csv:ro" \
      -e POSTGRES_HOST=dictionary-db \
      -e POSTGRES_DB=dictionary \
      -e POSTGRES_USER=picsure \
      -e POSTGRES_PASSWORD="$DICT_PASS" \
      hms-dbmi/dictionary-weights:latest
    info "Dictionary weights applied."
  else
    warn "Dictionary weights image not available. Search may not return results."
  fi

  info "Dictionary hydrated."
fi

# ---------------------------------------------------------------------------
# Step 4: Restart dictionary-api
# ---------------------------------------------------------------------------

info "Step 4/4: Restarting dictionary service..."
picsure_compose restart dictionary-api 2>/dev/null || true

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
info "======================================"
info "  Demo data loaded successfully!"
info "======================================"
info "  Dataset: $DATASET"
info "  HPDS: loaded and healthy"
if [ "${SKIP_DICT:-}" != "true" ]; then
  info "  Dictionary: hydrated"
else
  info "  Dictionary: skipped (ETL not available)"
fi
info ""
info "  Browse to https://localhost to explore."
echo ""
