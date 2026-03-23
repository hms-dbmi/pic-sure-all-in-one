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
#
# Prerequisites:
#   - docker compose up -d must have been run (databases healthy)
#   - init.sh must have been run (.env exists)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATASET="${1:-nhanes}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[data]${NC} $*"; }
warn()  { echo -e "${YELLOW}[data]${NC} $*"; }
error() { echo -e "${RED}[data]${NC} $*" >&2; }

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

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

if ! docker compose -f "$SCRIPT_DIR/docker-compose.yml" ps picsure-db 2>/dev/null | grep -q healthy; then
  error "picsure-db is not healthy. Run 'docker compose up -d' first."
  exit 1
fi

# ---------------------------------------------------------------------------
# Ensure HPDS ETL image exists
# ---------------------------------------------------------------------------

if ! docker image inspect hms-dbmi/pic-sure-hpds-etl:LATEST >/dev/null 2>&1; then
  info "Building HPDS ETL image..."
  HPDS_SRC="${HPDS_SRC:-$SCRIPT_DIR/../pic-sure-hpds}"
  if [ ! -d "$HPDS_SRC/docker/pic-sure-hpds-etl" ]; then
    error "HPDS source not found at $HPDS_SRC. Clone pic-sure-hpds as a sibling repo."
    exit 1
  fi
  docker build -f "$HPDS_SRC/docker/pic-sure-hpds-etl/Dockerfile" \
    -t hms-dbmi/pic-sure-hpds-etl:LATEST "$HPDS_SRC" || exit 1
fi

# ---------------------------------------------------------------------------
# Ensure Dictionary ETL image exists
# ---------------------------------------------------------------------------

if ! docker image inspect hms-dbmi/pic-sure-dictionary-etl:LATEST >/dev/null 2>&1; then
  info "Building Dictionary ETL image..."
  DICT_SRC="${DICTIONARY_SRC:-$SCRIPT_DIR/../picsure-dictionary}"
  if [ -f "$DICT_SRC/dictionaryweights/Dockerfile" ]; then
    docker build -f "$DICT_SRC/dictionaryweights/Dockerfile" \
      -t hms-dbmi/pic-sure-dictionary-etl:LATEST "$DICT_SRC/dictionaryweights" || \
      warn "Dictionary ETL image build failed. Dictionary hydration will be skipped."
  else
    warn "Dictionary ETL source not found. Dictionary hydration will be skipped."
  fi
fi

# ---------------------------------------------------------------------------
# Download / extract dataset
# ---------------------------------------------------------------------------

DATA_DIR="$SCRIPT_DIR/.data"
mkdir -p "$DATA_DIR"
DATASETS_REPO="https://github.com/hms-dbmi/pic-sure-public-datasets.git"

case "$DATASET" in
  nhanes)
    info "Preparing NHANES demo dataset..."
    if [ ! -f "$DATA_DIR/allConcepts.csv" ]; then
      if [ -f "$SCRIPT_DIR/initial-configuration/allConcepts.csv.tgz" ]; then
        info "Extracting bundled NHANES data..."
        tar -xzf "$SCRIPT_DIR/initial-configuration/allConcepts.csv.tgz" -C "$DATA_DIR/"
      else
        info "Downloading NHANES data from GitHub..."
        CLONE_DIR="$DATA_DIR/datasets"
        rm -rf "$CLONE_DIR"
        git clone --depth 1 --filter=blob:none --sparse "$DATASETS_REPO" "$CLONE_DIR" 2>/dev/null
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
      git clone --depth 1 --filter=blob:none --sparse "$DATASETS_REPO" "$CLONE_DIR" 2>/dev/null
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
      git clone --depth 1 --filter=blob:none --sparse "$DATASETS_REPO" "$CLONE_DIR" 2>/dev/null
      cd "$CLONE_DIR" && git sparse-checkout set "open_access-1000Genomes_allConcepts_new_search_with_data_analyzer.csv"
      cp "open_access-1000Genomes_allConcepts_new_search_with_data_analyzer.csv" "$DATA_DIR/allConcepts.csv"
      cd "$SCRIPT_DIR"
    fi
    ;;
  *)
    error "Unknown dataset: $DATASET"
    error "Available: nhanes, synthea, 1000genomes"
    exit 1
    ;;
esac

info "Dataset ready: $(wc -l < "$DATA_DIR/allConcepts.csv") rows"

# ---------------------------------------------------------------------------
# Ensure encryption key exists
# ---------------------------------------------------------------------------

HPDS_KEY="$SCRIPT_DIR/config/hpds/encryption_key"
if [ ! -f "$HPDS_KEY" ]; then
  info "Generating HPDS encryption key..."
  mkdir -p "$(dirname "$HPDS_KEY")"
  openssl enc -aes-128-cbc -k "$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)" -P 2>/dev/null \
    | grep key | cut -d'=' -f2 > "$HPDS_KEY"
fi

# ---------------------------------------------------------------------------
# Step 1: Load data into HPDS (CSV → javabin)
# ---------------------------------------------------------------------------

info "Step 1/4: Loading data into HPDS (CSV → javabin)..."
info "This may take 1-5 minutes depending on dataset size."

# Stop HPDS while loading
docker compose -f "$SCRIPT_DIR/docker-compose.yml" stop hpds 2>/dev/null || true

# Copy encryption key into the data volume FIRST (bind mount overlay doesn't persist)
docker run --rm \
  -v picsure_hpds-data:/data \
  -v "$HPDS_KEY:/key:ro" \
  alpine sh -c "cp /key /data/encryption_key"

docker run --rm \
  --name hpds-etl-loader \
  -v picsure_hpds-data:/opt/local/hpds \
  -v "$DATA_DIR/allConcepts.csv:/opt/local/hpds/allConcepts.csv:ro" \
  -e HEAPSIZE=4096 \
  -e LOADER_NAME=CSVLoaderNewSearch \
  hms-dbmi/pic-sure-hpds-etl:LATEST

info "HPDS data loaded."

# ---------------------------------------------------------------------------
# Step 2: Restart HPDS
# ---------------------------------------------------------------------------

info "Step 2/4: Starting HPDS..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d hpds

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
DICT_ETL_SRC="${DICT_ETL_SRC:-$SCRIPT_DIR/../picsure-dictionary-etl}"
if ! docker image inspect hms-dbmi/dictionary-etl:latest >/dev/null 2>&1; then
  if [ -f "$DICT_ETL_SRC/Dockerfile" ]; then
    info "Building dictionary ETL image..."
    docker build -t hms-dbmi/dictionary-etl:latest "$DICT_ETL_SRC" 2>&1 | tail -3
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
  docker run --rm \
    --name hpds-columnmeta \
    -v picsure_hpds-data:/opt/local/hpds/ \
    -e HEAPSIZE=4096 \
    -e LOADER_NAME=CreateColumnmetaCSV \
    hms-dbmi/pic-sure-hpds-etl:LATEST 2>/dev/null

  # Step 3b: Start dictionary ETL service
  info "Starting dictionary ETL service..."
  docker rm -f dictionaryetl 2>/dev/null || true
  docker run -d \
    --name dictionaryetl \
    --network picsure_data \
    -v picsure_hpds-data:/opt/local/hpds/ \
    -e POSTGRES_HOST=dictionary-db \
    -e POSTGRES_DB=dictionary \
    -e POSTGRES_USER=picsure \
    -e POSTGRES_PASSWORD="$DICT_PASS" \
    hms-dbmi/dictionary-etl:latest 2>/dev/null

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
  docker run --rm --network picsure_data curlimages/curl:latest \
    -s -X POST -H "Content-Type: application/json" \
    -d '{"includeDefaultFacets": "true", "clearDatabase": "true"}' \
    http://dictionaryetl:8086/load/initialize 2>&1

  # Step 3c.1: Load facet configuration
  FACET_CONFIG="$SCRIPT_DIR/initial-configuration/config/dictionary/facet_loader_configuration.json"
  if [ -f "$FACET_CONFIG" ]; then
    info "Loading facet configuration..."
    docker run --rm --network picsure_data \
      -v "$FACET_CONFIG:/facet_config.json:ro" \
      curlimages/curl:latest \
      -s -X POST -H "Content-Type: application/json" \
      -d @/facet_config.json \
      http://dictionaryetl:8086/api/facet/loader/load 2>&1
    info "Facets loaded."
  else
    warn "Facet config not found at $FACET_CONFIG — skipping facet loading."
  fi

  # Clean up ETL container
  docker stop dictionaryetl 2>/dev/null && docker rm dictionaryetl 2>/dev/null

  # Step 3d: Run dictionary weights (required for search to work)
  info "Running dictionary weights..."
  DICT_WEIGHTS_SRC="${DICTIONARY_SRC:-$SCRIPT_DIR/../picsure-dictionary}/dictionaryweights"
  if ! docker image inspect hms-dbmi/dictionary-weights:latest >/dev/null 2>&1; then
    if [ -f "$DICT_WEIGHTS_SRC/Dockerfile" ]; then
      docker build -f "$DICT_WEIGHTS_SRC/Dockerfile" "$DICT_WEIGHTS_SRC" \
        -t hms-dbmi/dictionary-weights:latest 2>/dev/null
    fi
  fi

  if docker image inspect hms-dbmi/dictionary-weights:latest >/dev/null 2>&1; then
    docker run --rm \
      --name dictionary-weights \
      --network picsure_data \
      -v "$SCRIPT_DIR/../picsure-dictionary/dictionaryweights/weights.csv:/weights.csv:ro" \
      -e POSTGRES_HOST=dictionary-db \
      -e POSTGRES_DB=dictionary \
      -e POSTGRES_USER=picsure \
      -e POSTGRES_PASSWORD="$DICT_PASS" \
      hms-dbmi/dictionary-weights:latest 2>&1 | tail -3
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
docker compose -f "$SCRIPT_DIR/docker-compose.yml" restart dictionary-api 2>/dev/null || true

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
