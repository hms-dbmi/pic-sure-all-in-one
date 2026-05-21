#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — Smoke Matrix
# =============================================================================
# Non-destructive checks by default. Pass --include-etl to run the tiny custom
# ETL fixture against the current stack.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PICSURE_ROOT="$SCRIPT_DIR"
export PICSURE_ROOT

# shellcheck source=scripts/picsure-compose.sh
source "$SCRIPT_DIR/scripts/picsure-compose.sh"

INCLUDE_ETL=false
for arg in "$@"; do
  case "$arg" in
    --include-etl) INCLUDE_ETL=true ;;
    -h|--help)
      sed -n '2,7p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

cd "$SCRIPT_DIR"

echo "[smoke] Shell syntax"
bash -n init.sh
bash -n build-images.sh
bash -n release-control.sh
bash -n bootstrap-remote-db.sh
bash -n run-migrations.sh
bash -n seed-db.sh
bash -n load-demo-data.sh
bash -n update.sh
bash -n etl.sh
bash -n scripts/picsure-compose.sh
bash -n scripts/db-wait.sh
bash -n scripts/smoke-matrix.sh
bash -n scripts/smoke-remote-db.sh

echo "[smoke] Compose config"
if [ -f .env ]; then
  picsure_load_env .env
fi
picsure_compose config --quiet

echo "[smoke] Migration input check"
if [ -f .env ]; then
  ./run-migrations.sh --check
else
  echo "[smoke] Skipping migration check because .env is missing."
fi

if [ "$INCLUDE_ETL" = "true" ]; then
  if [ ! -f .env ]; then
    echo "[smoke] --include-etl requires .env and a running stack." >&2
    exit 1
  fi

  echo "[smoke] Custom ETL fixture"
  tmpdir="$(mktemp -d)"
  cp fixtures/etl/custom/concepts_0.csv "$tmpdir/"
  (cd "$tmpdir" && zip -q concepts.zip concepts_0.csv)
  ./etl.sh load-csv --file fixtures/etl/custom/allConcepts.csv
  ./etl.sh hydrate-dictionary --include-dataset-facets --clear
  ./etl.sh load-dictionary-csv --datasets fixtures/etl/custom/datasets.csv --concepts "$tmpdir/concepts.zip" --clear
  ./etl.sh load-facets \
    --categories fixtures/etl/custom/facet_categories.csv \
    --facets fixtures/etl/custom/facets.csv \
    --concepts fixtures/etl/custom/facet_concepts.csv
  ./etl.sh run-weights
  rm -rf "$tmpdir"
else
  echo "[smoke] Skipping destructive/custom ETL fixture. Use --include-etl to run it."
fi

echo "[smoke] Complete"
