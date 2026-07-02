#!/usr/bin/env bash
# Adapter-driven route health + latency suite — the broad-coverage companion to
# run-baseline.sh (which stays the tight hop-cost instrument).
#
# Two stages, both driven by the pic-sure-python-adapter-hpds repo:
#   1. HEALTH GATE  — the adapter's live integration tests (connect, search,
#      query, export, genomic) against the target env. Any failure stops the
#      suite: the environment is not fit to baseline or promote.
#   2. METRICS      — scripts/collect_env_metrics.py: every route the adapter
#      exercises, N samples each, per-route p50/p95/p99 (errors excluded and
#      counted). Results land next to the curl suite's under results/.
#
# Run it once per environment/state; the label auto-detects wildfly-direct vs
# via-gateway on a local AIO (override with LABEL= for remote envs).
#
# Usage:
#   TOKEN=<PSAMA token> [CONCEPT_PATH='\...\'] ./run-adapter-suite.sh
#
# Env:
#   ADAPTER_DIR    adapter repo checkout (default ../../adapters/... — see below)
#   BASE_URL       default https://localhost
#   TOKEN          required — PSAMA long-term token for the target env
#   CONCEPT_PATH   enables the query actions (must exist on the target dataset)
#   SEARCH_TERM    default age
#   GENE           enables the genomic action (authorized+genomic envs only)
#   RESOURCE_UUID  needed when the env exposes more than one resource
#   N / WARMUP     samples per action (default 30 / 3)
#   LABEL          override auto-detection (wildfly-direct | via-gateway | ...)
#   OUT_ROOT       default <this dir>/results
#   SKIP_HEALTH=1  metrics only;  HEALTH_ONLY=1  gate only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_DIR="${ADAPTER_DIR:-$HOME/code_workspaces/adapters/pic-sure-python-adapter-hpds}"
BASE_URL="${BASE_URL:-https://localhost}"
TOKEN="${TOKEN:-}"
CONCEPT_PATH="${CONCEPT_PATH:-}"
SEARCH_TERM="${SEARCH_TERM:-age}"
GENE="${GENE:-}"
RESOURCE_UUID="${RESOURCE_UUID:-}"
N="${N:-30}"
WARMUP="${WARMUP:-3}"
OUT_ROOT="${OUT_ROOT:-$SCRIPT_DIR/results}"

[ -n "$TOKEN" ] || { echo "ERROR: TOKEN is required (PSAMA long-term token)"; exit 2; }
[ -d "$ADAPTER_DIR" ] || { echo "ERROR: adapter repo not found at $ADAPTER_DIR (set ADAPTER_DIR)"; exit 2; }
command -v uv >/dev/null 2>&1 || { echo "ERROR: uv not found — needed to run the adapter"; exit 2; }

# Local https uses the mkcert cert; Python's httpx trusts certifi, not the
# macOS keychain, so point it at the mkcert CA unless the caller already did.
if [ -z "${SSL_CERT_FILE:-}" ] && command -v mkcert >/dev/null 2>&1; then
    export SSL_CERT_FILE="$(mkcert -CAROOT)/rootCA.pem"
fi

# ---- label detection (same rule-sniffing as run-baseline.sh) -----------------
detect_label() {
    local conf="/usr/local/apache2/conf/extra/httpd-vhosts.conf" out
    out=$(docker exec httpd grep -F 'http://gateway:8080/$1' "$conf" 2>/dev/null | grep -v '^[[:space:]]*#' || true)
    if [ -n "$out" ]; then echo "via-gateway"; return; fi
    out=$(docker exec httpd grep -F 'http://wildfly:8080/pic-sure-api-2' "$conf" 2>/dev/null | grep -v '^[[:space:]]*#' || true)
    if [ -n "$out" ]; then echo "wildfly-direct"; return; fi
    echo "env"
}
LABEL="${LABEL:-$(detect_label)}"

echo "== PIC-SURE adapter suite == label=$LABEL base_url=$BASE_URL adapter=$ADAPTER_DIR"

# The adapter's integration tests and metrics script read this env family.
export PICSURE_INTEGRATION=1
export PICSURE_TEST_PLATFORM="$BASE_URL"
export PICSURE_TEST_TOKEN="$TOKEN"
export PICSURE_TEST_CONCEPT_PATH="$CONCEPT_PATH"
export PICSURE_TEST_SEARCH_TERM="$SEARCH_TERM"
export PICSURE_TEST_GENE="$GENE"
export PICSURE_TEST_RESOURCE_UUID="$RESOURCE_UUID"
export METRICS_N="$N" METRICS_WARMUP="$WARMUP"

if [ "${SKIP_HEALTH:-0}" != "1" ]; then
    echo ""
    echo "-- stage 1/2: health gate (adapter live integration tests)"
    if ! (cd "$ADAPTER_DIR" && uv run pytest tests/integration -q); then
        echo ""
        echo "HEALTH GATE FAILED: $BASE_URL is not healthy — fix before baselining/promoting."
        echo "(SKIP_HEALTH=1 forces metrics collection anyway.)"
        exit 1
    fi
    echo "-- health gate passed"
fi

if [ "${HEALTH_ONLY:-0}" = "1" ]; then
    echo "HEALTH_ONLY=1 — skipping metrics."
    exit 0
fi

echo ""
echo "-- stage 2/2: per-route latency metrics"
(cd "$ADAPTER_DIR" && uv run python scripts/collect_env_metrics.py \
    --label "adapter-$LABEL" --out "$OUT_ROOT")
