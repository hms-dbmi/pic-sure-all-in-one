#!/usr/bin/env bash
# =============================================================================
# Build the PIC-SURE frontend image
# =============================================================================
# Extracts only VITE_* variables from .env and passes them to the frontend
# build. No secrets (DB passwords, Auth0 client secret, etc.) are exposed.
#
# Usage:
#   ./build-frontend.sh
#   ./build-frontend.sh --theme picsure
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND_SRC="${FRONTEND_SRC:-$SCRIPT_DIR/../PIC-SURE-Frontend}"
THEME="${1:-picsure}"
ENV_FILE="$SCRIPT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "Error: .env not found. Run ./init.sh first."
  exit 1
fi

if [ ! -d "$FRONTEND_SRC" ]; then
  echo "Error: Frontend source not found at $FRONTEND_SRC"
  echo "Set FRONTEND_SRC to the path of the PIC-SURE-Frontend repo."
  exit 1
fi

# Extract only VITE_* vars — no secrets leak into the build
# The Frontend Dockerfile does `COPY .env ...` so we write a filtered .env
echo "Extracting VITE_* variables for frontend build..."
grep '^VITE_' "$ENV_FILE" > "$FRONTEND_SRC/.env"

echo "Building frontend image with theme: $THEME"
cd "$FRONTEND_SRC"
docker build \
  -f Dockerfile \
  --build-arg THEME="$THEME" \
  -t hms-dbmi/pic-sure-httpd:LATEST \
  .

# Clean up — don't leave secrets (even filtered) in the frontend repo
rm -f "$FRONTEND_SRC/.env"

echo "Frontend image built: hms-dbmi/pic-sure-httpd:LATEST"
