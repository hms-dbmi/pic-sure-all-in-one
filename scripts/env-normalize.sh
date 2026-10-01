#!/usr/bin/env bash
# =============================================================================
# PIC-SURE — Normalize an upgraded .env
# =============================================================================
# Brings a .env written by an older install in line with the current schema:
# drops the component refs release-control no longer resolves, backfills the
# service secrets the monorepo stack requires (compose interpolates them with
# no default, and a blank token fails closed), and flags a DICTIONARY_ETL_REF
# pin that release-control used to overwrite on every run and now leaves
# alone, and checks the HPDS data mode. Safe to re-run; a current .env is left
# untouched.
#
# Usage:
#   scripts/env-normalize.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${PICSURE_ROOT:-$SCRIPT_DIR}"
ENV_FILE="$ROOT/.env"

LOG_PREFIX="env-normalize"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

RETIRED_KEYS=(
  HPDS_REF
  PSAMA_REF
  DICTIONARY_REF
  VISUALIZATION_REF
  LOGGING_REF
  LOGGING_CLIENT_REF
  OPEN_ACCESS_ENABLED
  VITE_RESOURCE_HPDS
  VITE_RESOURCE_OPEN_HPDS
  VITE_RESOURCE_VIZ
  AUTH_HPDS_RESOURCE_UUID
  OPEN_HPDS_RESOURCE_UUID
)

if [ ! -f "$ENV_FILE" ]; then
  exit 0
fi

removed=()
for key in "${RETIRED_KEYS[@]}"; do
  if grep -q "^${key}=" "$ENV_FILE"; then
    picsure_sed_in_place "/^${key}=/d" "$ENV_FILE"
    removed+=("$key")
  fi
done

if [ "${#removed[@]}" -gt 0 ]; then
  info "Removed retired .env keys: ${removed[*]}"
fi

# Same generation init.sh runs on a fresh install (keep the two in sync).
generated=()
backfill_secret() {
  local key="$1" bytes="$2"
  local current
  current="$(grep "^${key}=" "$ENV_FILE" | tail -1 | cut -d'=' -f2- || true)"
  if [ -z "$current" ]; then
    picsure_set_env_var "$ENV_FILE" "$key" "$(openssl rand -hex "$bytes")" true
    generated+=("$key")
  fi
}
backfill_secret QUERY_SERVICE_INTERNAL_TOKEN 32
backfill_secret PICSURE_APPLICATION_TOKEN 32
backfill_secret AGGREGATE_OBFUSCATION_SALT 16

if [ "${#generated[@]}" -gt 0 ]; then
  info "Generated missing service secrets: ${generated[*]}"
fi

# env_value KEY: the last KEY= value in .env, without CR or surrounding quotes.
env_value() {
  local value
  value="$(grep "^$1=" "$ENV_FILE" | tail -1 | cut -d'=' -f2- || true)"
  value="${value%$'\r'}"
  value="${value#\"}"
  printf '%s' "${value%\"}"
}

etl_ref="$(env_value DICTIONARY_ETL_REF)"
if [ -n "$etl_ref" ] && [ "$etl_ref" != "main" ]; then
  warn "DICTIONARY_ETL_REF is pinned to $etl_ref; release-control no longer resolves it."
  warn "Set DICTIONARY_ETL_REF=main in .env unless you pinned it deliberately."
fi

# Shared HPDS data is opt-in; a .env without the keys keeps local volumes.
hpds_mode="$(env_value HPDS_DATA_MODE)"
case "${hpds_mode:-local}" in
  local) ;;
  shared)
    if [ -z "$(env_value HPDS_SHARED_DATA)" ]; then
      warn "HPDS_DATA_MODE=shared but HPDS_SHARED_DATA is empty; set it to a published data set name."
    fi
    ;;
  *) warn "HPDS_DATA_MODE must be local or shared, got '$hpds_mode'." ;;
esac
