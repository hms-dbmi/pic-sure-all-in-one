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

# Remember whether prometheus was already running *before* we sync new config,
# so we know afterwards whether it needs restarting to pick up the changes.
PROMETHEUS_WAS_RUNNING=false
if [[ "$(docker inspect -f '{{.State.Running}}' prometheus 2>/dev/null)" == "true" ]]; then
  PROMETHEUS_WAS_RUNNING=true
fi

# Sync repo assets (never the user's env/secrets/data)
mkdir -p "$MON_DIR/prometheus/rules" "$MON_DIR/grafana" "$MON_DIR/secrets" "$MON_DIR/blackbox"
cp "$SCRIPT_DIR/docker-compose.monitoring.yml" "$MON_DIR/"
cp "$SCRIPT_DIR/prometheus/prometheus-aio.yml" "$MON_DIR/prometheus/"
cp "$SCRIPT_DIR/prometheus/rules/"*.yml "$MON_DIR/prometheus/rules/"
cp -R "$SCRIPT_DIR/grafana/provisioning" "$SCRIPT_DIR/grafana/dashboards" "$MON_DIR/grafana/"
cp "$SCRIPT_DIR/blackbox/blackbox.yml" "$MON_DIR/blackbox/"

# Token secret file for Prometheus http_headers.
# Extract just the one key we need instead of sourcing the whole env file, so a
# stray value in monitoring.env can't execute shell code.
PICSURE_APPLICATION_TOKEN="$(grep -E '^PICSURE_APPLICATION_TOKEN=' "$MON_DIR/monitoring.env" | head -1 | cut -d= -f2-)"
if [[ -z "${PICSURE_APPLICATION_TOKEN:-}" ]]; then
  echo "WARNING: PICSURE_APPLICATION_TOKEN is empty in monitoring.env; token-gated scrapes will 401." >&2
fi
printf '%s' "${PICSURE_APPLICATION_TOKEN:-}" > "$MON_DIR/secrets/app-token"
chmod 600 "$MON_DIR/secrets/app-token"

# Opt-in DB exporter credentials (db-exporters profile). Same grep-extraction
# pattern as the app token above: pull only the keys we need out of
# monitoring.env rather than sourcing it. Absent/empty keys mean "don't start
# that exporter" — checked after `up -d` below. These four keys are new
# (M5) and optional, so — unlike PICSURE_APPLICATION_TOKEN, which every
# monitoring.env is required to have — grep may legitimately find no match
# on an older monitoring.env; `|| true` keeps that from tripping `pipefail`.
MONITORING_MYSQL_USER="$(grep -E '^MONITORING_MYSQL_USER=' "$MON_DIR/monitoring.env" | head -1 | cut -d= -f2- || true)"
MONITORING_MYSQL_PASSWORD="$(grep -E '^MONITORING_MYSQL_PASSWORD=' "$MON_DIR/monitoring.env" | head -1 | cut -d= -f2- || true)"
MONITORING_PG_USER="$(grep -E '^MONITORING_PG_USER=' "$MON_DIR/monitoring.env" | head -1 | cut -d= -f2- || true)"
MONITORING_PG_PASSWORD="$(grep -E '^MONITORING_PG_PASSWORD=' "$MON_DIR/monitoring.env" | head -1 | cut -d= -f2- || true)"
# mysqld-exporter's compose `command:` interpolates ${MONITORING_MYSQL_USER:-monitoring}
# at `docker compose` invocation time (not from env_file, which only sets the
# container's runtime environment) — export so that substitution sees it.
export MONITORING_MYSQL_USER
{
  echo "DATA_SOURCE_NAME=postgresql://${MONITORING_PG_USER}:${MONITORING_PG_PASSWORD}@dictionary-db:5432/dictionary?sslmode=disable"
  echo "MYSQLD_EXPORTER_PASSWORD=${MONITORING_MYSQL_PASSWORD}"
  echo "MONITORING_MYSQL_USER=${MONITORING_MYSQL_USER}"
} > "$MON_DIR/secrets/db-exporters.env"
chmod 600 "$MON_DIR/secrets/db-exporters.env"

# Bring up the core services strictly. node-exporter's `/:/host:ro,rslave`
# mount fails at container-create on macOS Docker Desktop (VirtioFS
# mount-propagation limits) — tolerate only that one service failing so the
# rest of the platform start doesn't get killed by `set -euo pipefail`
# (see README Known issues).
docker compose -f "$MON_DIR/docker-compose.monitoring.yml" --project-directory "$MON_DIR" up -d prometheus grafana cadvisor apache-exporter blackbox-exporter
docker compose -f "$MON_DIR/docker-compose.monitoring.yml" --project-directory "$MON_DIR" up -d node-exporter \
  || echo "WARNING: node-exporter failed to start (expected on macOS Docker Desktop — see README Known issues); continuing without host metrics"

# Opt-in DB exporters (profile db-exporters, so a plain `up -d` above never
# starts them). Each one only comes up if both of its credential keys are
# present in monitoring.env — see README "DB exporters" for how to create the
# read-only monitoring users.
if [[ -n "$MONITORING_MYSQL_USER" && -n "$MONITORING_MYSQL_PASSWORD" ]]; then
  docker compose -f "$MON_DIR/docker-compose.monitoring.yml" --project-directory "$MON_DIR" --profile db-exporters up -d mysqld-exporter \
    || echo "WARNING: mysqld-exporter failed to start"
else
  echo "skipping mysqld-exporter (no MONITORING_MYSQL_* credentials in monitoring.env)"
fi
if [[ -n "$MONITORING_PG_USER" && -n "$MONITORING_PG_PASSWORD" ]]; then
  docker compose -f "$MON_DIR/docker-compose.monitoring.yml" --project-directory "$MON_DIR" --profile db-exporters up -d postgres-exporter \
    || echo "WARNING: postgres-exporter failed to start"
else
  echo "skipping postgres-exporter (no MONITORING_PG_* credentials in monitoring.env)"
fi

# `docker compose up -d` won't recreate a container just because a bind-mounted
# file's content changed, and this Prometheus has no reload endpoint enabled.
# If it was already running, restart it now so the freshly-synced
# prometheus.yml / rules take effect; a fresh create already picks them up.
if [[ "$PROMETHEUS_WAS_RUNNING" == true ]]; then
  docker restart prometheus >/dev/null
fi

echo "Monitoring up. Grafana: http://127.0.0.1:3001  Prometheus (inside network): prometheus:9090"
