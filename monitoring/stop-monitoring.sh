#!/usr/bin/env bash
set -euo pipefail
DOCKER_CONFIG_DIR="${DOCKER_CONFIG_DIR:-/usr/local/docker-config}"
CURRENT_FS_DOCKER_CONFIG_DIR="${CURRENT_FS_DOCKER_CONFIG_DIR:-$DOCKER_CONFIG_DIR}"
MON_DIR="$CURRENT_FS_DOCKER_CONFIG_DIR/monitoring"
[[ -f "$MON_DIR/docker-compose.monitoring.yml" ]] || { echo "monitoring not installed; nothing to stop"; exit 0; }
docker compose -f "$MON_DIR/docker-compose.monitoring.yml" --project-directory "$MON_DIR" down
