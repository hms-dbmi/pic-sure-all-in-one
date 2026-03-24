#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — Initialization Script
# =============================================================================
# Run once to generate secrets, self-signed certs, and prepare the environment.
#
# Usage:
#   cp .env.example .env   # Edit with your Auth0 creds, admin email
#   ./init.sh              # Generates passwords, certs, DB setup
#   docker compose up -d   # Start everything
#
# Re-running init.sh is safe — it will NOT overwrite existing passwords
# unless you pass --force.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
CERTS_DIR="$SCRIPT_DIR/certs"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[init]${NC} $*"; }
warn()  { echo -e "${YELLOW}[init]${NC} $*"; }
error() { echo -e "${RED}[init]${NC} $*" >&2; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

generate_password() {
  # Generate a secure random password (24 chars, alphanumeric)
  # The || true prevents SIGPIPE from tr causing a non-zero exit under pipefail
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true
}

generate_uuid() {
  # Generate a UUID, works on both Linux and macOS
  if command -v uuidgen &>/dev/null; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [ -f /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    # Fallback: python
    python3 -c "import uuid; print(uuid.uuid4())"
  fi
}

set_env_var() {
  # Set a variable in .env only if it's currently empty/unset
  local key="$1"
  local value="$2"
  local force="${3:-false}"

  if grep -q "^${key}=" "$ENV_FILE"; then
    local current
    current=$(grep "^${key}=" "$ENV_FILE" | cut -d'=' -f2-)
    if [ -n "$current" ] && [ "$force" != "true" ]; then
      return 0  # Already set, don't overwrite
    fi
    # Replace existing empty value
    if [[ "$OSTYPE" =~ ^darwin ]]; then
      sed -i '' "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    else
      sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    fi
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Clone sibling repos if missing
# ---------------------------------------------------------------------------
if [ -x "$SCRIPT_DIR/clone-repos.sh" ]; then
  "$SCRIPT_DIR/clone-repos.sh"
fi

if [ ! -f "$ENV_FILE" ]; then
  error ".env file not found. Run: cp .env.example .env"
  error "Then edit .env with your Auth0 credentials and admin email."
  exit 1
fi

FORCE=false
if [ "${1:-}" = "--force" ]; then
  FORCE=true
  warn "Force mode — will regenerate all secrets"
fi

# Source current .env to check what's already set
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# Validate required fields
if [ -z "${AUTH0_CLIENT_ID:-}" ]; then
  warn "AUTH0_CLIENT_ID is not set in .env"
  warn "You can set it later, but the app won't work without it."
fi

if [ -z "${ADMIN_EMAIL:-}" ]; then
  warn "ADMIN_EMAIL is not set in .env"
  warn "You'll need this to create the first admin user."
fi

# ---------------------------------------------------------------------------
# Generate secrets
# ---------------------------------------------------------------------------

info "Generating database passwords..."
set_env_var "DB_ROOT_PASSWORD"    "$(generate_password)" "$FORCE"
set_env_var "DB_PICSURE_PASSWORD" "$(generate_password)" "$FORCE"
set_env_var "DB_AUTH_PASSWORD"    "$(generate_password)" "$FORCE"
set_env_var "DB_AIRFLOW_PASSWORD" "$(generate_password)" "$FORCE"

info "Generating application UUIDs..."
set_env_var "PICSURE_APPLICATION_ID" "$(generate_uuid)" "$FORCE"
RESOURCE_ID=$(generate_uuid)
set_env_var "PICSURE_RESOURCE_ID"    "$RESOURCE_ID" "$FORCE"
set_env_var "VITE_RESOURCE_HPDS"     "$RESOURCE_ID" "$FORCE"

info "Generating introspection token..."
# Re-source .env to pick up the APPLICATION_ID we may have just generated
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
if [ -n "${AUTH0_CLIENT_SECRET:-}" ] && [ -n "${PICSURE_APPLICATION_ID:-}" ]; then
  INTRO_TOKEN=$(python3 "$SCRIPT_DIR/config/scripts/generate-introspection-token.py" \
    "$AUTH0_CLIENT_SECRET" "$PICSURE_APPLICATION_ID" 365)
  set_env_var "PICSURE_INTROSPECTION_TOKEN" "$INTRO_TOKEN" "$FORCE"
  info "Introspection token generated (365-day expiry)."
  # Also update the DB if picsure-db is running (token must match in .env, standalone.xml, AND the DB)
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q picsure-db; then
    db_pass=$(grep "^DB_ROOT_PASSWORD=" "$ENV_FILE" | cut -d= -f2)
    docker exec picsure-db mysql -uroot -p"$db_pass" -e \
      "UPDATE auth.application SET token='$INTRO_TOKEN' WHERE name='PICSURE';" 2>/dev/null && \
      info "Introspection token updated in database." || \
      warn "Could not update token in DB (application table may not exist yet)."
  fi
else
  warn "Cannot generate introspection token — AUTH0_CLIENT_SECRET or PICSURE_APPLICATION_ID not set."
  warn "Token will be generated when these values are configured and init.sh is re-run."
  set_env_var "PICSURE_INTROSPECTION_TOKEN" "PLACEHOLDER_RUN_INIT_AGAIN" "$FORCE"
fi

# ---------------------------------------------------------------------------
# Generate self-signed SSL certificate
# ---------------------------------------------------------------------------

if [ ! -f "$CERTS_DIR/server.crt" ] || [ "$FORCE" = "true" ]; then
  info "Generating self-signed SSL certificate..."
  mkdir -p "$CERTS_DIR"

  openssl req -x509 -nodes -days 365 \
    -newkey rsa:2048 \
    -keyout "$CERTS_DIR/server.key" \
    -out "$CERTS_DIR/server.crt" \
    -subj "/C=US/ST=Massachusetts/L=Boston/O=PIC-SURE/CN=localhost" \
    2>/dev/null

  # Create a self-signed chain (just the cert itself for self-signed)
  cp "$CERTS_DIR/server.crt" "$CERTS_DIR/server.chain"

  info "Certificate generated in $CERTS_DIR/"
  warn "This is a self-signed certificate for development/evaluation only."
  warn "Replace with real certificates for production use."
else
  info "SSL certificates already exist. Skipping. (Use --force to regenerate)"
fi

# ---------------------------------------------------------------------------
# Generate dictionary .env if not exists
# ---------------------------------------------------------------------------

DICT_ENV="$SCRIPT_DIR/config/dictionary/dictionary.env"
if [ ! -f "$DICT_ENV" ] || [ "$FORCE" = "true" ]; then
  info "Generating dictionary database credentials..."
  DICT_PASS=$(generate_password)
  mkdir -p "$(dirname "$DICT_ENV")"
  cat > "$DICT_ENV" <<EOF
POSTGRES_PASSWORD=$DICT_PASS
POSTGRES_USER=picsure
POSTGRES_DB=dictionary
POSTGRES_HOST=dictionary-db
EOF
  info "Dictionary config written to $DICT_ENV"
else
  info "Dictionary config already exists. Skipping."
fi

# ---------------------------------------------------------------------------
# Generate HPDS encryption key
# ---------------------------------------------------------------------------

HPDS_KEY_DIR="$SCRIPT_DIR/config/hpds"
if [ ! -f "$HPDS_KEY_DIR/encryption_key" ] || [ "$FORCE" = "true" ]; then
  info "Generating HPDS encryption key..."
  mkdir -p "$HPDS_KEY_DIR"
  openssl enc -aes-128-cbc -k "$(generate_password)" -P 2>/dev/null | grep key | cut -d'=' -f2 > "$HPDS_KEY_DIR/encryption_key"
  info "HPDS encryption key written to $HPDS_KEY_DIR/encryption_key"
else
  info "HPDS encryption key already exists. Skipping."
fi

# ---------------------------------------------------------------------------
# Resolve AUTH_MODE → env vars
# ---------------------------------------------------------------------------

info "Configuring auth mode: ${AUTH_MODE:-required}..."
# See GLOSSARY.md for auth mode definitions.
# See https://pic-sure.gitbook.io/pic-sure-developer-guide/configuring-pic-sure/explore-without-login
case "${AUTH_MODE:-required}" in
  open)
    # Open PIC-SURE: Discover page without login, no export/API
    # PSAMA allows unauthenticated requests
    set_env_var "OPEN_IDP_PROVIDER_IS_ENABLED" "true" "true"
    # Frontend shows open access UI
    set_env_var "VITE_OPEN" "true" "true"
    set_env_var "VITE_OPEN_EXPLORER" "false" "true"
    set_env_var "VITE_DISCOVER" "true" "true"
    # Wildfly openAccessEnabled is set via standalone.xml ${env.OPEN_ACCESS_ENABLED}
    set_env_var "OPEN_ACCESS_ENABLED" "true" "true"
    # Open HPDS resource must match the main HPDS resource for unauthenticated queries
    set_env_var "VITE_RESOURCE_OPEN_HPDS" "${PICSURE_RESOURCE_ID}" "true"
    ;;
  explore)
    # Explore Without Login: full query builder without login, export prompts login
    # PSAMA allows unauthenticated requests
    set_env_var "OPEN_IDP_PROVIDER_IS_ENABLED" "true" "true"
    # Frontend enables open explorer
    set_env_var "VITE_OPEN" "true" "true"
    set_env_var "VITE_OPEN_EXPLORER" "true" "true"
    set_env_var "VITE_DISCOVER" "true" "true"
    set_env_var "OPEN_ACCESS_ENABLED" "true" "true"
    # Open HPDS resource must match the main HPDS resource for unauthenticated queries
    set_env_var "VITE_RESOURCE_OPEN_HPDS" "${PICSURE_RESOURCE_ID}" "true"
    ;;
  required|*)
    # Login Required: no access without authentication
    set_env_var "OPEN_IDP_PROVIDER_IS_ENABLED" "false" "true"
    set_env_var "VITE_OPEN" "false" "true"
    set_env_var "VITE_OPEN_EXPLORER" "false" "true"
    set_env_var "VITE_DISCOVER" "false" "true"
    set_env_var "OPEN_ACCESS_ENABLED" "false" "true"
    ;;
esac

# ---------------------------------------------------------------------------
# Set frontend auth provider vars (VITE_*)
# ---------------------------------------------------------------------------

info "Configuring frontend auth provider..."
# Re-source to get current AUTH0 values
set -a
source "$ENV_FILE"
set +a
set_env_var "VITE_AUTH0_TENANT" "${AUTH0_TENANT:-avillachlab}" "true"
if [ -n "${AUTH0_CLIENT_ID:-}" ]; then
  set_env_var "VITE_AUTH_PROVIDER_MODULE_GOOGLE" "true" "$FORCE"
  set_env_var "VITE_AUTH_PROVIDER_MODULE_GOOGLE_TYPE" "AUTH0" "$FORCE"
  set_env_var "VITE_AUTH_PROVIDER_MODULE_GOOGLE_CLIENTID" "$AUTH0_CLIENT_ID" "true"
  set_env_var "VITE_AUTH_PROVIDER_MODULE_GOOGLE_CONNECTION" "google-oauth2" "$FORCE"
  set_env_var "VITE_AUTH_PROVIDER_MODULE_GOOGLE_DESCRIPTION" "Login" "$FORCE"
fi

# ---------------------------------------------------------------------------
# Generate Java truststore (Let's Encrypt root certs)
# ---------------------------------------------------------------------------

if [ ! -f "$SCRIPT_DIR/config/wildfly/application.truststore" ] || [ "$FORCE" = "true" ]; then
  info "Generating Java truststore with Let's Encrypt root certs..."
  mkdir -p "$SCRIPT_DIR/config/wildfly" "$SCRIPT_DIR/config/psama"
  docker run --rm \
    -v "$SCRIPT_DIR/config/scripts:/scripts:ro" \
    -v "$SCRIPT_DIR/config/wildfly:/output" \
    amazoncorretto:24-alpine \
    sh -c "apk add --no-cache curl >/dev/null 2>&1 && sh /scripts/create-truststore.sh /output" 2>/dev/null
  cp "$SCRIPT_DIR/config/wildfly/application.truststore" "$SCRIPT_DIR/config/psama/application.truststore"
  info "Truststores created for Wildfly and PSAMA."
else
  info "Truststores already exist. Skipping. (Use --force to regenerate)"
fi

# ---------------------------------------------------------------------------
# Ensure required directories exist
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Generate visualization resource UUID + properties
# ---------------------------------------------------------------------------

info "Configuring visualization resource..."
set_env_var "PICSURE_VIZ_RESOURCE_ID" "$(generate_uuid)" "$FORCE"
set_env_var "VITE_RESOURCE_VIZ" "" "$FORCE"

# Re-source to get all current values
set -a
source "$ENV_FILE"
set +a

# Update VIZ to match
set_env_var "VITE_RESOURCE_VIZ" "${PICSURE_VIZ_RESOURCE_ID}" "true"

# Write visualization properties file
VIZ_PROPS_DIR="$SCRIPT_DIR/config/wildfly/visualization/pic-sure-visualization-resource"
mkdir -p "$VIZ_PROPS_DIR"
cat > "$VIZ_PROPS_DIR/resource.properties" <<EOF
target.origin.id=http://localhost:8080/pic-sure-api-2/PICSURE/
visualization.resource.id=${PICSURE_VIZ_RESOURCE_ID}
auth.hpds.resource.id=${PICSURE_RESOURCE_ID}
open.hpds.resource.id=${PICSURE_RESOURCE_ID}
EOF

# ---------------------------------------------------------------------------
# Ensure required directories exist
# ---------------------------------------------------------------------------

info "Creating required directories..."
mkdir -p "$SCRIPT_DIR/config/flyway/auth/sql"
mkdir -p "$SCRIPT_DIR/config/flyway/picsure/sql"
mkdir -p "$SCRIPT_DIR/config/hpds"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
# ---------------------------------------------------------------------------
# Authenticate to GitHub Container Registry
# ---------------------------------------------------------------------------
# Container images are hosted on ghcr.io and require authentication to pull.
# We use `gh auth token` if available, otherwise check for an existing login.
#
# To build images from source instead, use docker-compose.dev.yml:
#   docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build
# See README-compose.md for details.
# ---------------------------------------------------------------------------

info "Checking GitHub Container Registry access..."

GHCR_LOGGED_IN=false
# Check if already logged into ghcr.io
if grep -q "ghcr.io" ~/.docker/config.json 2>/dev/null; then
  GHCR_LOGGED_IN=true
  info "Already authenticated to ghcr.io."
elif command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
  info "Logging into ghcr.io via GitHub CLI..."
  if gh auth token | docker login ghcr.io -u token --password-stdin 2>/dev/null; then
    GHCR_LOGGED_IN=true
    info "Authenticated to ghcr.io."
  fi
fi

if [ "$GHCR_LOGGED_IN" != "true" ]; then
  echo ""
  error "Cannot authenticate to GitHub Container Registry (ghcr.io)."
  error ""
  error "PIC-SURE images are hosted on ghcr.io and require a GitHub token to pull."
  error "Options:"
  error "  1. Install GitHub CLI and authenticate:"
  error "       gh auth login"
  error "       ./init.sh"
  error ""
  error "  2. Log in to ghcr.io manually with a Personal Access Token (read:packages scope):"
  error "       echo YOUR_TOKEN | docker login ghcr.io -u YOUR_USERNAME --password-stdin"
  error "       ./init.sh"
  error ""
  error "  3. Build from source instead (no registry auth needed):"
  error "       docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build"
  exit 1
fi

# Build the frontend image (merges feature flags from frontend repo + auth config from .env)
info "Building frontend image..."
"$SCRIPT_DIR/build-frontend.sh"

# ---------------------------------------------------------------------------

info "======================================"
info "  Initialization complete!"
info "======================================"
echo ""
info "Next steps:"
info "  1. Review .env and fill in any missing values (AUTH0_CLIENT_ID, etc.)"
info "  2. Start services:  docker compose up -d"
info "  3. Seed database:   ./seed-db.sh"
info "  4. Restart:          docker compose restart wildfly psama"
info "  5. Load demo data:  ./load-demo-data.sh  (optional)"
info "  6. Browse to: https://localhost"
echo ""

if [ -z "${AUTH0_CLIENT_ID:-}" ]; then
  warn "⚠  AUTH0_CLIENT_ID is not set — login will not work until configured."
fi
if [ -z "${ADMIN_EMAIL:-}" ]; then
  warn "⚠  ADMIN_EMAIL is not set — no admin user will be created."
fi

echo ""
info "For production deployments:"
info "  - Replace self-signed certs in certs/ with real SSL certificates"
info "  - Set strong Auth0 credentials"
info "  - Consider DB_MODE=remote for external database"
echo ""
