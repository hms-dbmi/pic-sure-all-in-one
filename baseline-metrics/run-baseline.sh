#!/usr/bin/env bash
# Repeatable latency-baseline suite for the gateway migration (P1-2, ALS-12239).
#
# Runs an identical endpoint suite against the AIO stack through httpd and reports
# p50/p95/p99 per endpoint per run, plus a median-of-runs summary. Run it BEFORE the
# cutover (wildfly-direct) and AFTER (via-gateway); the difference is the gateway hop.
# The run label is auto-detected from the deployed httpd rule (override with LABEL=).
#
# No dependencies beyond curl, awk, and docker (for label detection + the optional
# gateway Prometheus snapshot). Sequential requests (c=1) by design: this measures
# per-hop latency, not capacity, and stays reproducible on a laptop.
#
# Usage:
#   TOKEN=<long-term PSAMA token> [RESOURCE_UUID=<uuid>] ./run-baseline.sh
#
# Env:
#   BASE_URL       default https://localhost   (curl -k is used; self-signed OK)
#   TOKEN          PSAMA long-term token; without it only /system/status is measured
#   RESOURCE_UUID  HPDS resource UUID; enables the query/sync endpoint (with TOKEN)
#   RUNS=3 N=100 WARMUP=20   runs per endpoint / samples per run / warmup requests
#   LABEL          override auto-detected state label (wildfly-direct | via-gateway)
#   OUT_ROOT       default <this dir>/results
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="${BASE_URL:-https://localhost}"
RUNS="${RUNS:-3}"
N="${N:-100}"
WARMUP="${WARMUP:-20}"
TOKEN="${TOKEN:-}"
RESOURCE_UUID="${RESOURCE_UUID:-}"
OUT_ROOT="${OUT_ROOT:-$SCRIPT_DIR/results}"

# ---- label detection (which rule is httpd serving?) -------------------------
detect_label() {
    # NB: no `grep -q` in pipelines here — with pipefail, -q's early exit SIGPIPEs
    # the upstream docker exec and fails the whole condition. Capture instead.
    local conf="/usr/local/apache2/conf/extra/httpd-vhosts.conf" out
    out=$(docker exec httpd grep -F 'http://gateway:8080/$1' "$conf" 2>/dev/null | grep -v '^[[:space:]]*#' || true)
    if [ -n "$out" ]; then echo "via-gateway"; return; fi
    out=$(docker exec httpd grep -F 'http://wildfly:8080/pic-sure-api-2' "$conf" 2>/dev/null | grep -v '^[[:space:]]*#' || true)
    if [ -n "$out" ]; then echo "wildfly-direct"; return; fi
    echo "unknown"
}
LABEL="${LABEL:-$(detect_label)}"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$OUT_ROOT/$STAMP-$LABEL"
mkdir -p "$OUT_DIR"
SUMMARY="$OUT_DIR/summary.md"

echo "== PIC-SURE latency baseline =="
echo "label=$LABEL base_url=$BASE_URL runs=$RUNS n=$N warmup=$WARMUP"
echo "results -> $OUT_DIR"

# ---- endpoint suite ----------------------------------------------------------
# name|method|path|needs_token|body_file
ENDPOINTS=()
ENDPOINTS+=("system-status|GET|/picsure/system/status|no|")
if [ -n "$TOKEN" ]; then
    ENDPOINTS+=("info-resources|GET|/picsure/info/resources|yes|")
    if [ -n "$RESOURCE_UUID" ]; then
        QUERY_FILE="$OUT_DIR/count-query.json"
        sed "s/__RESOURCE_UUID__/$RESOURCE_UUID/" "$SCRIPT_DIR/queries/count-query.json" > "$QUERY_FILE"
        ENDPOINTS+=("query-sync|POST|/picsure/query/sync|yes|$QUERY_FILE")
    else
        echo "NOTE: RESOURCE_UUID not set — skipping query/sync endpoint."
    fi
else
    echo "NOTE: TOKEN not set — measuring only the unauthenticated /system/status endpoint."
fi

curl_once() { # $1 method, $2 url, $3 needs_token, $4 body_file -> "http_code time_total"
    local args=(-ks -o /dev/null -w '%{http_code} %{time_total}' -X "$1")
    [ "$3" = "yes" ] && args+=(-H "Authorization: Bearer $TOKEN")
    if [ -n "$4" ]; then args+=(-H "Content-Type: application/json" --data-binary "@$4"); fi
    curl "${args[@]}" "$2" 2>/dev/null || echo "000 0"
}

percentiles() { # stdin: one time-in-seconds per line -> "count p50 p95 p99 mean min max" (ms)
    sort -n | awk '
        { v[NR] = $1 * 1000 ; sum += $1 * 1000 }
        END {
            if (NR == 0) { print "0 - - - - - -"; exit }
            p50 = v[int(0.50 * (NR - 1)) + 1]
            p95 = v[int(0.95 * (NR - 1)) + 1]
            p99 = v[int(0.99 * (NR - 1)) + 1]
            printf "%d %.1f %.1f %.1f %.1f %.1f %.1f\n", NR, p50, p95, p99, sum / NR, v[1], v[NR]
        }'
}

{
    echo "# Latency baseline — $LABEL"
    echo ""
    echo "- date: $STAMP  |  base_url: $BASE_URL  |  runs: $RUNS × n=$N (warmup $WARMUP, sequential)"
    echo ""
    echo "| endpoint | run | samples | errors | p50 ms | p95 ms | p99 ms | mean ms | min | max |"
    echo "|---|---|---|---|---|---|---|---|---|---|"
} > "$SUMMARY"

for spec in "${ENDPOINTS[@]}"; do
    IFS='|' read -r name method path needs_token body_file <<< "$spec"
    url="$BASE_URL$path"
    echo ""
    echo "-- $name ($method $path)"

    for ((i = 1; i <= WARMUP; i++)); do curl_once "$method" "$url" "$needs_token" "$body_file" >/dev/null; done

    for ((run = 1; run <= RUNS; run++)); do
        raw="$OUT_DIR/$name-run$run.csv"
        errors=0
        : > "$raw"
        for ((i = 1; i <= N; i++)); do
            read -r code t <<< "$(curl_once "$method" "$url" "$needs_token" "$body_file")"
            if [[ "$code" =~ ^2 ]]; then
                echo "$t" >> "$raw"
            else
                errors=$((errors + 1))
            fi
        done
        read -r cnt p50 p95 p99 mean minv maxv <<< "$(percentiles < "$raw")"
        echo "   run $run: n=$cnt errors=$errors p50=${p50}ms p95=${p95}ms p99=${p99}ms"
        echo "| $name | $run | $cnt | $errors | $p50 | $p95 | $p99 | $mean | $minv | $maxv |" >> "$SUMMARY"
        if [ "$errors" -gt $((N / 10)) ]; then
            echo "   WARNING: >10% errors on $name — check TOKEN/endpoint; percentiles exclude errors."
        fi
    done

    # median-of-runs p95/p99 (compare THESE across pre/post, not single runs)
    med=$(awk -F'|' -v ep=" $name " '$2 == ep { print $7, $8 }' "$SUMMARY" \
        | sort -n | awk '{ a[NR] = $1; b[NR] = $2 } END { if (NR) printf "%.1f %.1f", a[int((NR+1)/2)], b[int((NR+1)/2)] }')
    echo "   median-of-runs: p95/p99 = $med ms"
    echo "| $name | **median** |  |  |  | **$(echo "$med" | cut -d' ' -f1)** | **$(echo "$med" | cut -d' ' -f2)** |  |  |  |" >> "$SUMMARY"
done

# ---- gateway-side snapshot (only meaningful post-cutover) ---------------------
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^gateway$'; then
    docker run --rm --network=picsure busybox wget -qO- http://gateway:8080/actuator/prometheus \
        > "$OUT_DIR/gateway-prometheus.txt" 2>/dev/null \
        && echo "" && echo "Saved gateway Prometheus snapshot (http_server_requests percentiles) -> $OUT_DIR/gateway-prometheus.txt"
fi

echo ""
echo "== Done. Summary: $SUMMARY =="
cat "$SUMMARY"
