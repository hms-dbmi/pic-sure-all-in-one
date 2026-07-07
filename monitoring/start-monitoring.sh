#!/usr/bin/env bash
# Sync monitoring assets into $DOCKER_CONFIG_DIR/monitoring and start the stack.
# Opt-in: create $DOCKER_CONFIG_DIR/monitoring/ with a monitoring.env in it
# (see monitoring.env.example). start-picsure.sh calls this when that dir exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_CONFIG_DIR="${DOCKER_CONFIG_DIR:-/usr/local/docker-config}"
CURRENT_FS_DOCKER_CONFIG_DIR="${CURRENT_FS_DOCKER_CONFIG_DIR:-$DOCKER_CONFIG_DIR}"
MON_DIR="$CURRENT_FS_DOCKER_CONFIG_DIR/monitoring"

if [[ ! -f "$MON_DIR/monitoring.env" ]]; then
  echo "ERROR: $MON_DIR/monitoring.env not found. Copy monitoring.env.example there and fill it in." >&2
  exit 1
fi

# Sync repo assets (never the user's env/secrets/data)
mkdir -p "$MON_DIR/prometheus/rules" "$MON_DIR/grafana" "$MON_DIR/secrets"
cp "$SCRIPT_DIR/docker-compose.monitoring.yml" "$MON_DIR/"
cp "$SCRIPT_DIR/prometheus/prometheus-aio.yml" "$MON_DIR/prometheus/"
cp "$SCRIPT_DIR/prometheus/rules/"*.yml "$MON_DIR/prometheus/rules/"
cp -R "$SCRIPT_DIR/grafana/provisioning" "$SCRIPT_DIR/grafana/dashboards" "$MON_DIR/grafana/"

# Token secret file for Prometheus http_headers
# shellcheck disable=SC1091
source "$MON_DIR/monitoring.env"
if [[ -z "${PICSURE_APPLICATION_TOKEN:-}" ]]; then
  echo "WARNING: PICSURE_APPLICATION_TOKEN is empty in monitoring.env; token-gated scrapes will 401." >&2
fi
printf '%s' "${PICSURE_APPLICATION_TOKEN:-}" > "$MON_DIR/secrets/app-token"
chmod 600 "$MON_DIR/secrets/app-token"

docker compose -f "$MON_DIR/docker-compose.monitoring.yml" --project-directory "$MON_DIR" up -d
echo "Monitoring up. Grafana: http://127.0.0.1:3001  Prometheus (inside network): prometheus:9090"
