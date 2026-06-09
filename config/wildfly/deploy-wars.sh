#!/bin/sh
# Copy additional WAR files into Wildfly deployments volume
# This runs as a one-shot init container before Wildfly starts

DEPLOY_DIR="/deployments"
ADDITIONAL_DIR="/additional-wars"

if [ -d "$ADDITIONAL_DIR" ]; then
  for war in "$ADDITIONAL_DIR"/*.war; do
    if [ -f "$war" ]; then
      echo "[deploy] Copying $(basename "$war") to deployments"
      cp "$war" "$DEPLOY_DIR/"
    fi
  done
fi

echo "[deploy] Done."
