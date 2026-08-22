#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — Initialization Script
# =============================================================================
# Run once to generate secrets, self-signed certs, and prepare the environment.
#
# Usage:
#   cp .env.example .env   # Edit with your Auth0 creds, admin email
#   ./init.sh              # Generates secrets, builds images, starts services, seeds DB
#
# That's it. One command from clone to running.
#
# Flags:
#   --force     Regenerate all secrets (passwords, certs, etc.)
#   --verbose   Show full build output (Maven, Docker, etc.)
#   --log       Pipe all output to init.log in the current directory
#   --release-control-branch BRANCH
#               Use a non-default release-control branch for this init
#
# Re-running init.sh is safe — it will NOT overwrite existing passwords
# unless you pass --force.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
CERTS_DIR="$SCRIPT_DIR/certs"
PICSURE_ROOT="$SCRIPT_DIR"
export PICSURE_ROOT

LOG_PREFIX="init"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

# shellcheck source=scripts/picsure-compose.sh
source "$SCRIPT_DIR/scripts/picsure-compose.sh"

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
    error "uuidgen is required on systems without /proc/sys/kernel/random/uuid."
    exit 1
  fi
}

set_env_var() {
  # Set a variable in .env only if it's currently empty/unset
  picsure_set_env_var "$ENV_FILE" "$1" "$2" "${3:-false}"
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

FORCE=false
VERBOSE=false
LOG=false
INIT_RELEASE_CONTROL_BRANCH=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=true ;;
    --verbose) VERBOSE=true ;;
    --log) LOG=true ;;
    --release-control-branch)
      shift
      if [ -z "${1:-}" ]; then
        error "--release-control-branch requires a branch name."
        exit 1
      fi
      INIT_RELEASE_CONTROL_BRANCH="$1"
      ;;
    --release-control-branch=*)
      INIT_RELEASE_CONTROL_BRANCH="${1#*=}"
      if [ -z "$INIT_RELEASE_CONTROL_BRANCH" ]; then
        error "--release-control-branch requires a branch name."
        exit 1
      fi
      ;;
    -h|--help)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    *) warn "Unknown flag: $1" ;;
  esac
  shift
done

if [ ! -f "$ENV_FILE" ]; then
  error ".env file not found. Run: cp .env.example .env"
  error "Then edit .env with your Auth0 credentials and admin email."
  exit 1
fi

# ---------------------------------------------------------------------------
# Clone sibling repos if missing
# ---------------------------------------------------------------------------
if [ -x "$SCRIPT_DIR/clone-repos.sh" ]; then
  "$SCRIPT_DIR/clone-repos.sh"
fi

# --- Output redirection ---
# By default, noisy build output (Maven, Docker) is suppressed.
# --verbose shows everything; --log pipes all output to init.log.
LOG_FILE="$SCRIPT_DIR/init.log"

if [ "$LOG" = "true" ]; then
  info "Logging all output to $LOG_FILE"
  exec > >(tee "$LOG_FILE") 2>&1
fi

# Noisy build/db output is redirected to this path.
# --verbose → /dev/stdout (show everything)
# --log     → /dev/stdout so it reaches the tee above (and thus init.log);
#             like build-images.sh's --log, this also surfaces on the terminal
# default   → /dev/null (quiet, just show [init] status lines)
#
# A per-command redirect to /dev/null would otherwise override the exec'd tee
# fds, so without this the steps below (bootstrap-remote-db.sh, db-wait.sh,
# the final compose up) never reach init.log even with --log set.
if [ "$VERBOSE" = "true" ] || [ "$LOG" = "true" ]; then
  BUILD_OUT="/dev/stdout"
else
  BUILD_OUT="/dev/null"
fi

if [ "$FORCE" = "true" ]; then
  warn "Force mode — will regenerate all secrets"
fi

# Source current .env to check what's already set
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [ -n "$INIT_RELEASE_CONTROL_BRANCH" ]; then
  info "Using release-control branch: $INIT_RELEASE_CONTROL_BRANCH"
  set_env_var "RELEASE_CONTROL_BRANCH" "$INIT_RELEASE_CONTROL_BRANCH" "true"
  export RELEASE_CONTROL_BRANCH="$INIT_RELEASE_CONTROL_BRANCH"
fi

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
AUTH_RESOURCE_ID="$RESOURCE_ID"
if [ -n "${PICSURE_RESOURCE_ID:-}" ] && [ "$FORCE" != "true" ]; then
  AUTH_RESOURCE_ID="$PICSURE_RESOURCE_ID"
fi
set_env_var "PICSURE_RESOURCE_ID"    "$RESOURCE_ID" "$FORCE"
set_env_var "AUTH_HPDS_RESOURCE_UUID" "$AUTH_RESOURCE_ID" "$FORCE"
set_env_var "VITE_RESOURCE_HPDS"     "$AUTH_RESOURCE_ID" "$FORCE"

# Re-source .env so later auth-mode logic sees generated/backfilled UUIDs.
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

info "Generating logging API key..."
set_env_var "LOGGING_API_KEY" "$(openssl rand -hex 32)" "$FORCE"

info "Generating shared service secrets..."
set_env_var "QUERY_SERVICE_INTERNAL_TOKEN" "$(openssl rand -hex 32)" "$FORCE"
set_env_var "PICSURE_APPLICATION_TOKEN"    "$(openssl rand -hex 32)" "$FORCE"
set_env_var "AGGREGATE_OBFUSCATION_SALT"   "$(openssl rand -hex 16)" "$FORCE"

info "Generating introspection token..."
# Re-source .env to pick up the APPLICATION_ID we may have just generated
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
if [ -n "${AUTH0_CLIENT_SECRET:-}" ] && [ -n "${PICSURE_APPLICATION_ID:-}" ]; then
  INTRO_TOKEN=$("$SCRIPT_DIR/config/scripts/generate-introspection-token.sh" \
    "$AUTH0_CLIENT_SECRET" "$PICSURE_APPLICATION_ID" 365)
  set_env_var "PICSURE_INTROSPECTION_TOKEN" "$INTRO_TOKEN" "$FORCE"
  info "Introspection token generated (365-day expiry)."
  # Also update the DB if picsure-db is running. The token must match in .env
  # (which feeds the gateway's TOKEN_INTROSPECTION_TOKEN) AND in the auth DB
  # row PSAMA checks at /auth/token/inspect.
  # The HOST shell expands the password into docker's environment via the
  # env-prefix assignment (never into argv); the BARE `-e MYSQL_PWD` makes
  # docker forward it from its own environment into the container. The SQL —
  # which embeds the secret token — is fed on stdin. So neither the password
  # nor the token ever reaches the host `docker` process listing (ps).
  if [ "${DB_MODE:-local}" = "remote" ]; then
    if MYSQL_PWD="${DB_ROOT_PASSWORD:-}" docker run --rm -i \
      -e MYSQL_PWD \
      mysql:8.0 \
      mysql -h "${DB_HOST}" -P "${DB_PORT:-3306}" -u "${DB_ROOT_USER:-root}" \
      2>/dev/null <<SQL; then
UPDATE auth.application SET token='$INTRO_TOKEN' WHERE name='PICSURE';
SQL
      info "Introspection token updated in remote database."
    else
      warn "Could not update token in remote DB (application table may not exist yet)."
    fi
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q picsure-db; then
    db_pass=$(grep "^DB_ROOT_PASSWORD=" "$ENV_FILE" | cut -d= -f2-)
    if MYSQL_PWD="$db_pass" docker exec -i -e MYSQL_PWD picsure-db mysql -uroot \
      2>/dev/null <<SQL; then
UPDATE auth.application SET token='$INTRO_TOKEN' WHERE name='PICSURE';
SQL
      info "Introspection token updated in database."
    else
      warn "Could not update token in DB (application table may not exist yet)."
    fi
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
# Anonymous access spans three services and must move as one set: psama
# (OPEN_IDP_PROVIDER_IS_ENABLED), the gateway (GATEWAY_OPEN_ACCESS_ENABLED) and
# the frontend (VITE_OPEN). VITE_OPEN_EXPLORER/VITE_DISCOVER then pick which
# anonymous surface is shown.
# See https://pic-sure.gitbook.io/pic-sure-developer-guide/configuring-pic-sure/explore-without-login
case "${AUTH_MODE:-required}" in
  open)
    # Open PIC-SURE: Discover page without login, no export/API
    set_env_var "OPEN_IDP_PROVIDER_IS_ENABLED" "true" "true"
    set_env_var "GATEWAY_OPEN_ACCESS_ENABLED" "true" "true"
    set_env_var "VITE_OPEN" "true" "true"
    set_env_var "VITE_OPEN_EXPLORER" "false" "true"
    set_env_var "VITE_DISCOVER" "true" "true"
    # Open HPDS resource must match the main HPDS resource for unauthenticated queries
    set_env_var "OPEN_HPDS_RESOURCE_UUID" "${PICSURE_RESOURCE_ID}" "true"
    set_env_var "VITE_RESOURCE_OPEN_HPDS" "${PICSURE_RESOURCE_ID}" "true"
    ;;
  explore)
    # Explore Without Login: full query builder without login, export prompts login
    set_env_var "OPEN_IDP_PROVIDER_IS_ENABLED" "true" "true"
    set_env_var "GATEWAY_OPEN_ACCESS_ENABLED" "true" "true"
    set_env_var "VITE_OPEN" "true" "true"
    set_env_var "VITE_OPEN_EXPLORER" "true" "true"
    # Explore-Without-Login uses the query builder, NOT the Discover page.
    set_env_var "VITE_DISCOVER" "false" "true"
    # Open HPDS resource must match the main HPDS resource for unauthenticated queries
    set_env_var "OPEN_HPDS_RESOURCE_UUID" "${PICSURE_RESOURCE_ID}" "true"
    set_env_var "VITE_RESOURCE_OPEN_HPDS" "${PICSURE_RESOURCE_ID}" "true"
    ;;
  required|*)
    # Login Required: no access without authentication
    set_env_var "OPEN_IDP_PROVIDER_IS_ENABLED" "false" "true"
    set_env_var "GATEWAY_OPEN_ACCESS_ENABLED" "false" "true"
    set_env_var "VITE_OPEN" "false" "true"
    set_env_var "VITE_OPEN_EXPLORER" "false" "true"
    set_env_var "VITE_DISCOVER" "false" "true"
    ;;
esac

if [ "${TOS_ENABLED:-false}" = "true" ]; then
  set_env_var "VITE_ENABLE_TOS" "true" "true"
  set_env_var "VITE_ENFORCE_TOS_ACCEPT" "true" "true"
else
  set_env_var "VITE_ENABLE_TOS" "false" "true"
  set_env_var "VITE_ENFORCE_TOS_ACCEPT" "false" "true"
fi

# ---------------------------------------------------------------------------
# Set frontend auth provider vars (VITE_*)
# ---------------------------------------------------------------------------

info "Configuring frontend auth provider..."
# Re-source to get current AUTH0 values
set -a
# shellcheck disable=SC1090
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

if [ ! -f "$SCRIPT_DIR/config/psama/application.truststore" ] || [ "$FORCE" = "true" ]; then
  info "Generating Java truststore with Let's Encrypt root certs..."
  mkdir -p "$SCRIPT_DIR/config/psama"
  rm -f "$SCRIPT_DIR/config/psama/application.truststore"
  docker run --rm \
    -v "$SCRIPT_DIR/config/scripts:/scripts:ro" \
    -v "$SCRIPT_DIR/config/psama:/output" \
    amazoncorretto:24-alpine \
    sh -c "apk add --no-cache curl >/dev/null 2>&1 && sh /scripts/create-truststore.sh /output" 2>/dev/null
  info "Truststore created for PSAMA."
else
  info "Truststore already exists. Skipping. (Use --force to regenerate)"
fi

CUSTOM_TRUST_CERTS_DIR="${CUSTOM_TRUST_CERTS_DIR:-certs/trust}"
if [ -d "$SCRIPT_DIR/$CUSTOM_TRUST_CERTS_DIR" ]; then
  info "Importing custom trust certificates from $CUSTOM_TRUST_CERTS_DIR..."
  docker run --rm \
    -v "$SCRIPT_DIR/$CUSTOM_TRUST_CERTS_DIR:/certs:ro" \
    -v "$SCRIPT_DIR/config/psama:/psama" \
    amazoncorretto:24-alpine \
    sh -c '
      set -e
      i=0
      for cert in /certs/*.crt /certs/*.cer /certs/*.pem; do
        [ -f "$cert" ] || continue
        i=$((i + 1))
        alias="custom-$i-$(basename "$cert" | tr -cd "A-Za-z0-9._-")"
        keytool -delete -keystore /psama/application.truststore -storepass password -alias "$alias" >/dev/null 2>&1 || true
        keytool -importcert -noprompt -trustcacerts -keystore /psama/application.truststore -storepass password -alias "$alias" -file "$cert" >/dev/null
      done
    ' 2>/dev/null
fi

# ---------------------------------------------------------------------------
# Ensure required directories exist
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Generate visualization resource UUID
# ---------------------------------------------------------------------------

info "Configuring visualization resource..."
set_env_var "PICSURE_VIZ_RESOURCE_ID" "$(generate_uuid)" "$FORCE"
set_env_var "VITE_RESOURCE_VIZ" "" "$FORCE"

# Re-source to get all current values
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# Update VIZ to match
set_env_var "VITE_RESOURCE_VIZ" "${PICSURE_VIZ_RESOURCE_ID}" "true"

# The frontend's SSR config cache (src/lib/server/configCache.ts) fetches
# ui:setting and ui:branding from ${VITE_ORIGIN}/picsure/configuration and is
# baked in at build time. Without this key, build-images.sh's frontend_vite_env
# falls through to the frontend repo's own .env.example, which ships the
# placeholder https://picsure.example.com/ -- the fetches then fail ENOTFOUND
# and the UI silently renders built-in defaults instead of the configuration
# rows in the database.
#
# This is an IN-CONTAINER origin, not the browser one: the fetch runs in the
# SvelteKit node process beside httpd, so it must not carry HTTPS_PORT (that
# maps to 443 inside) or the public hostname. http://localhost is what the
# port-80 vhost in config/httpd/httpd-vhosts.conf exists to serve -- it proxies
# /picsure/* to the gateway for Host localhost|127.0.0.1 only, and redirects
# everything else to HTTPS. Plain HTTP also sidesteps the self-signed cert,
# which node's fetch would otherwise reject.
set_env_var "VITE_ORIGIN" "http://localhost" "true"

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
# Resolve and apply release-control refs
# ---------------------------------------------------------------------------

if [ -x "$SCRIPT_DIR/release-control.sh" ]; then
  info "Resolving release-control refs..."
  "$SCRIPT_DIR/release-control.sh"
fi

# ---------------------------------------------------------------------------
# Build container images from source
# ---------------------------------------------------------------------------

info "Building container images..."
build_args=""
if [ "$FORCE" = "true" ]; then
  build_args="$build_args --force"
fi
if [ "$VERBOSE" = "true" ]; then
  build_args="$build_args --verbose"
fi
if [ "$LOG" = "true" ]; then
  build_args="$build_args --log"
fi
# shellcheck disable=SC2086
"$SCRIPT_DIR/build-images.sh" $build_args

# ---------------------------------------------------------------------------
# Start database
# ---------------------------------------------------------------------------

info "Starting database..."
cd "$SCRIPT_DIR"
if [ "${DB_MODE:-local}" = "remote" ]; then
  "$SCRIPT_DIR/bootstrap-remote-db.sh" &> "$BUILD_OUT"
else
  "$SCRIPT_DIR/scripts/db-wait.sh" &> "$BUILD_OUT"
fi

# ---------------------------------------------------------------------------
# Verify the datadir credentials before migrating
# ---------------------------------------------------------------------------
# A picsure-db volume left over from an earlier install still carries the OLD
# root password: MySQL only honours MYSQL_ROOT_PASSWORD when it initialises an
# empty datadir. The container reports healthy anyway — `mysqladmin ping`, the
# Compose healthcheck, answers "alive" on access-denied — so db-wait.sh passes
# and the mismatch only surfaces as flyway-init retry-looping on its
# connection. Probe with a real authenticated query so it is named here.
# Remote mode has no local volume to go stale; bootstrap-remote-db.sh above
# already authenticates against the remote server.
if [ "${DB_MODE:-local}" = "local" ]; then
  info "Verifying database credentials..."
  if ! picsure_db_exec_mysql -e "SELECT 1;" >/dev/null 2>&1; then
    error "picsure-db rejected the DB_ROOT_PASSWORD in .env."
    error "The ${COMPOSE_PROJECT_NAME:-picsure}_picsure-db-data volume was initialised with a"
    error "different password — MySQL only reads MYSQL_ROOT_PASSWORD when it creates"
    error "the datadir, so a new .env cannot change an existing volume."
    error "Fix it either way:"
    error "  - restore the matching DB_ROOT_PASSWORD (see the .env.backup.* files here), or"
    error "  - discard the stale database:  ./reset.sh --all && cp .env.example .env && ./init.sh"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Run database migrations
# ---------------------------------------------------------------------------

info "Running database migrations..."
"$SCRIPT_DIR/run-migrations.sh" --no-restart

# ---------------------------------------------------------------------------
# Seed database extras
# ---------------------------------------------------------------------------

info "Seeding database..."
"$SCRIPT_DIR/seed-db.sh"

# ---------------------------------------------------------------------------
# Start services
# ---------------------------------------------------------------------------

info "Starting services..."
# gateway, pic-sure-operations-service and pic-sure-hpds-query-service are
# omitted deliberately: httpd depends_on gateway, which depends_on the other
# two (and the query service on hpds), so naming httpd starts them. The
# services below either sit on that chain too (psama, hpds — named for
# clarity) or are pulled in by nothing else
# (visualization, the dictionary trio, pic-sure-logging) and must be named
# to start at all.
picsure_compose up -d \
  psama \
  hpds \
  visualization \
  dictionary-db \
  dictionary-api \
  dictionary-dump \
  pic-sure-logging \
  httpd &> "$BUILD_OUT"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
info "======================================"
info "  PIC-SURE is running!"
info "======================================"
echo ""
info "  Browse to: $(picsure_browse_url)"
echo ""

if [ -z "${AUTH0_CLIENT_ID:-}" ]; then
  warn "⚠  AUTH0_CLIENT_ID is not set — login will not work until configured."
fi
if [ -z "${ADMIN_EMAIL:-}" ]; then
  warn "⚠  ADMIN_EMAIL is not set — no admin user will be created."
fi

echo ""
info "Optional next steps:"
info "  - Load demo data:  ./load-demo-data.sh"
info "  - For production: replace self-signed certs in certs/ with real SSL certificates"
echo ""
