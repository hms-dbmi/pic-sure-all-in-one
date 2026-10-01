#!/usr/bin/env bash
# Check the selected sources/config before rebuilding. Known incompatibilities
# fail; unclassified upstream changes warn. Never print configuration values.
set -euo pipefail
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PICSURE_ROOT="$SCRIPT_DIR"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
export PICSURE_ROOT
# shellcheck source=scripts/picsure-compose.sh
source "$SCRIPT_DIR/scripts/picsure-compose.sh"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"
# shellcheck source=scripts/lib/config.sh
source "$SCRIPT_DIR/scripts/lib/config.sh"

case "${1:-}" in
  -h|--help) echo 'Usage: scripts/config-drift.sh [--images-only]'; exit 0 ;;
  ''|--images-only) ;;
  *) echo 'Unknown option. Use --help.' >&2; exit 1 ;;
esac
IMAGES_ONLY=false
[ "${1:-}" != --images-only ] || IMAGES_ONLY=true
failures=0
fail() { printf '[drift] FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
note() { printf '[drift] %s\n' "$*"; }
warning() { printf '[drift] WARN: %s\n' "$*" >&2; }
if [ ! -f "$ENV_FILE" ]; then fail 'Missing .env; run init.sh first.'; exit 1; fi
picsure_load_env "$ENV_FILE"
umask 077
scratch="$(mktemp -d "${TMPDIR:-/tmp}/picsure-drift.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

# Check actual Compose output rather than guessing at override/profile semantics.
# Keep the resolved document private: it contains credentials.
if picsure_compose config --format json > "$scratch/compose.json" 2> "$scratch/compose.err"; then
  check_env() {
    local service="$1" key="$2" expected="$3" actual
    # shellcheck disable=SC2016 # jq variables, not shell interpolation.
    actual="$(run_jq --arg svc "$service" --arg key "$key" \
      '.services[$svc].environment[$key] // "" | tostring' "$scratch/compose.json")"
    [ "$actual" = "$expected" ] || fail "$service.$key conflicts with AIO configuration; rerun init.sh."
  }
  anonymous=false; explore=false; discover=false
  case "${AUTH_MODE:-required}" in
    required) ;;
    open) anonymous=true; discover=true ;;
    explore) anonymous=true; explore=true ;;
    *) fail 'AUTH_MODE must be required, open, or explore.' ;;
  esac
  check_env psama OPEN_IDP_PROVIDER_IS_ENABLED "$anonymous"
  check_env psama ENABLE_PUBLIC_ACCESS "$explore"
  check_env gateway GATEWAY_OPEN_ACCESS_ENABLED "$anonymous"
  for service in gateway httpd; do
    check_env "$service" GATEWAY_DOCS_ENABLED "${GATEWAY_DOCS_ENABLED:-true}"
  done
  for service in psama pic-sure-hpds-query-service; do
    check_env "$service" CONSENT_BASED_AUTHORIZATION_ENABLED "${CONSENT_BASED_AUTHORIZATION_ENABLED:-false}"
  done
  if [ "${CONSENT_BASED_AUTHORIZATION_ENABLED:-false}" = true ]; then
    psama_url="$(run_jq '.services["pic-sure-hpds-query-service"].environment.PSAMA_URL // ""' "$scratch/compose.json")"
    [ -n "$psama_url" ] || fail 'Consent authorization requires query-service PSAMA_URL.'
  fi
  for assignment in "VITE_OPEN=$anonymous" "VITE_OPEN_EXPLORER=$explore" "VITE_DISCOVER=$discover" \
    VITE_CONFIG_MODE=override VITE_API_CONFIG_FEATURES=ui:featureFlag \
    VITE_API_CONFIG_SETTINGS=ui:setting VITE_API_CONFIG_BRANDING=ui:branding VITE_ORIGIN=http://localhost; do
    key="${assignment%%=*}"; expected="${assignment#*=}"
    [ "${!key:-}" = "$expected" ] || fail "$key conflicts with AIO configuration; rerun init.sh."
  done
else
  fail 'Compose configuration cannot be resolved; run scripts/compose.sh config to diagnose missing setup files or invalid settings.'
fi
picsure_theme_valid "${PICSURE_THEME:-picsure}" || fail 'PICSURE_THEME is not supported.'
for key in GATEWAY_DOCS_ENABLED CONSENT_BASED_AUTHORIZATION_ENABLED; do
  value="${!key:-}"
  case "$value" in ''|true|false) ;; *) fail "$key must be true or false." ;; esac
done

if [ "$IMAGES_ONLY" = true ]; then
  warning 'Source checks skipped: existing/pulled image contents cannot be inferred from local source checkouts.'
else
  PICSURE_SRC="${PICSURE_SRC:-$SCRIPT_DIR/repos/pic-sure}"
  FRONTEND_SRC="${FRONTEND_SRC:-$SCRIPT_DIR/repos/PIC-SURE-Frontend}"
  for key in PICSURE_SRC FRONTEND_SRC; do
    case "${!key}" in /*) ;; *) printf -v "$key" '%s/%s' "$SCRIPT_DIR" "${!key}" ;; esac
    if [ ! -d "${!key}" ]; then fail "$key checkout missing; clone the selected sources first."; fi
  done
  # A source census is deliberately warn-only: a new placeholder may belong to
  # an inactive profile or have a safe default. Names alone cannot prove a break.
  {
    grep -Eo '[A-Z][A-Z0-9_]{2,}' "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/docker-compose.yml" | sed 's/.*://' || true
    grep -Eo '[A-Z][A-Z0-9_]{2,}' "$ENV_FILE" | sed 's/.*://' || true
  } | sort -u > "$scratch/known-keys"
  if [ -d "$PICSURE_SRC/services" ]; then
    find "$PICSURE_SRC/services" -type f \( -name 'application*.yml' -o -name 'application*.yaml' -o -name 'application*.properties' \) \
      -path '*/src/main/resources/*' -exec grep -hEo '\$\{[A-Z][A-Z0-9_]*(:[^}]*)?\}' {} + \
      | sed -E 's/^\$\{([A-Z][A-Z0-9_]*).*$/\1/' | sort -u > "$scratch/upstream-keys" || true
    while IFS= read -r key; do
      [ -z "$key" ] || warning "Upstream environment key not explicitly covered by AIO: $key (review profile/default before changing it)."
    done < <(comm -23 "$scratch/upstream-keys" "$scratch/known-keys")
    # Inspect only the build contexts used by AIO, recording source revisions and
    # ownership/ignore changes without attempting to emulate Docker's parser.
    while IFS='|' read -r image context dockerfile; do
      [ -n "$image" ] || continue
      path="$PICSURE_SRC/$dockerfile"
      if [ ! -f "$path" ]; then fail "Selected source lacks Dockerfile for $image."; continue; fi
      user="$(awk 'toupper($1)=="USER" {u=$2} END {print u}' "$path")"
      if [ "$image" = pic-sure-hpds-etl ]; then
        note 'ETL image user inspected; loaders explicitly use ETL_RUN_AS (default 0:0).'
      else
        case "$user" in
          ''|root|0|0:0) ;;
          *) warning "$image declares USER $user; review mounted volume ownership." ;;
        esac
      fi
      if [ -f "$PICSURE_SRC/$context/.dockerignore" ]; then
        warning "$image uses a context .dockerignore; review it against this Dockerfile's COPY inputs."
      fi
    done < <(sed -nE 's/^  "([^"|]+\|[^"|]+\|[^"]+)"$/\1/p' "$SCRIPT_DIR/build-images.sh")
    note "Core revision: $(git -C "$PICSURE_SRC" rev-parse HEAD 2>/dev/null || echo unversioned)"
  else
    fail 'Selected core checkout lacks services/ required by the AIO image build.'
  fi
  if [ -f "$FRONTEND_SRC/.env.example" ]; then
    sed -nE 's/^[[:space:]]*#?[[:space:]]*([A-Z][A-Z0-9_]*)=.*/\1/p' "$FRONTEND_SRC/.env.example" | sort -u > "$scratch/frontend-keys"
    while IFS= read -r key; do
      [ -z "$key" ] || warning "Frontend example key not configured by AIO: $key (not inherited into the build)."
    done < <(comm -23 "$scratch/frontend-keys" "$scratch/known-keys")
  fi
  if [ -d "$FRONTEND_SRC" ]; then
    if ! grep -q 'csp:' "$FRONTEND_SRC/svelte.config.js" 2>/dev/null; then
      warning 'Cannot recognize frontend CSP configuration; verify HTML supplies its own policy before using the Apache fallback.'
    fi
    if [ ! -f "$FRONTEND_SRC/.nvmrc" ]; then
      fail 'Selected frontend lacks .nvmrc required by the HMR workflow.'
    fi
    note "Frontend revision: $(git -C "$FRONTEND_SRC" rev-parse HEAD 2>/dev/null || echo unversioned)"
    warning 'HMR imports the selected upstream vite.config.ts; review new proxy/plugin behavior when changing frontend revisions.'
  fi
fi

if [ "$failures" -ne 0 ]; then
  note "$failures verified configuration incompatibility check(s) failed; update stopped before build/migrations/restart."
  exit 1
fi
note 'No known configuration incompatibilities found; warnings still require review.'
