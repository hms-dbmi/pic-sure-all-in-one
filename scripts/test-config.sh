#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
ENV_FILE="$TEST_DIR/.env"
touch "$ENV_FILE"
set_env_var() { picsure_set_env_var "$ENV_FILE" "$1" "$2" "$3"; }
for mode in explore required open explore; do
  AUTH_MODE="$mode" picsure_configure_auth
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  case "$mode" in
    explore) expected='true true true true true false' ;;
    required) expected='false false false false false false' ;;
    open) expected='true true false true false true' ;;
  esac
  actual="$OPEN_IDP_PROVIDER_IS_ENABLED $GATEWAY_OPEN_ACCESS_ENABLED $ENABLE_PUBLIC_ACCESS $VITE_OPEN $VITE_OPEN_EXPLORER $VITE_DISCOVER"
  [ "$actual" = "$expected" ] || { echo "Bad auth values for $mode: $actual" >&2; exit 1; }
  [ "$VITE_CONFIG_MODE" = override ]
  [ "$VITE_API_CONFIG_FEATURES $VITE_API_CONFIG_SETTINGS $VITE_API_CONFIG_BRANDING" = 'ui:featureFlag ui:setting ui:branding' ]
done
cp "$ENV_FILE" "$TEST_DIR/before"
if AUTH_MODE=invalid picsure_configure_auth 2>/dev/null; then exit 1; fi
cmp "$ENV_FILE" "$TEST_DIR/before"
for theme in picsure bdc aim-ahead local; do picsure_theme_valid "$theme"; done
if picsure_theme_valid unknown; then exit 1; fi
for token in '' PLACEHOLDER_RUN_INIT_AGAIN 'token with spaces' __PLACEHOLDER_TOKEN_THAT_IS_LONG_ENOUGH__; do
  if picsure_introspection_configured "$token"; then echo 'Accepted invalid token' >&2; exit 1; fi
done
picsure_introspection_configured '0123456789abcdef0123456789abcdef'
# Retirement must preserve application UUIDs still needed by Flyway.
printf '%s\n' VITE_RESOURCE_HPDS=old VITE_RESOURCE_OPEN_HPDS=old VITE_RESOURCE_VIZ=old AUTH_HPDS_RESOURCE_UUID=old OPEN_HPDS_RESOURCE_UUID=old PICSURE_RESOURCE_ID=keep PICSURE_VIZ_RESOURCE_ID=keep > "$ENV_FILE"
PICSURE_ROOT="$TEST_DIR" bash "$ROOT/scripts/env-normalize.sh" >/dev/null
if grep -Eq '^(VITE_RESOURCE_|AUTH_HPDS_RESOURCE_UUID=|OPEN_HPDS_RESOURCE_UUID=)' "$ENV_FILE"; then exit 1; fi
grep -q '^PICSURE_RESOURCE_ID=keep$' "$ENV_FILE"
grep -q '^PICSURE_VIZ_RESOURCE_ID=keep$' "$ENV_FILE"
echo '[config-test] auth transitions, config precedence, theme/token validation, and retirement passed'
