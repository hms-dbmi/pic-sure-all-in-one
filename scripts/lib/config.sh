#!/usr/bin/env bash
# Shared validation and AUTH_MODE derivation for AIO configuration.

picsure_theme_valid() {
  case "${1:-picsure}" in picsure|bdc|aim-ahead|local) return 0 ;; *) return 1 ;; esac
}

# Configuration completeness only; does not verify JWT signature or expiry.
picsure_introspection_configured() {
  local token="${1-${PICSURE_INTROSPECTION_TOKEN:-}}"
  case "$token" in ''|*PLACEHOLDER*|*placeholder*|__*__) return 1 ;; esac
  [[ "$token" != *[[:space:]]* ]]
}

# The caller supplies set_env_var(key, value, force).
picsure_configure_auth() {
  local anonymous=false explore=false discover=false
  case "${AUTH_MODE:-required}" in
    required) ;;
    open) anonymous=true; discover=true ;;
    explore) anonymous=true; explore=true ;;
    *) echo "AUTH_MODE must be required, open, or explore." >&2; return 1 ;;
  esac
  set_env_var OPEN_IDP_PROVIDER_IS_ENABLED "$anonymous" true
  set_env_var GATEWAY_OPEN_ACCESS_ENABLED "$anonymous" true
  set_env_var ENABLE_PUBLIC_ACCESS "$explore" true
  set_env_var VITE_OPEN "$anonymous" true
  set_env_var VITE_OPEN_EXPLORER "$explore" true
  set_env_var VITE_DISCOVER "$discover" true
  set_env_var VITE_CONFIG_MODE override true
  set_env_var VITE_API_CONFIG_FEATURES ui:featureFlag true
  set_env_var VITE_API_CONFIG_SETTINGS ui:setting true
  set_env_var VITE_API_CONFIG_BRANDING ui:branding true
}
