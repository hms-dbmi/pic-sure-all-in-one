#!/usr/bin/env bash
# Hermetic drift/update tests: actual policy scripts, synthetic sources and Docker.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v jq >/dev/null || { echo 'jq is required for config-drift tests.' >&2; exit 1; }
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/picsure-drift-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/scripts/lib" "$TEST_ROOT/bin" "$TEST_ROOT/repos/core/services/example/src/main/resources" "$TEST_ROOT/repos/frontend"
cp "$ROOT/scripts/config-drift.sh" "$TEST_ROOT/scripts/"
cp "$ROOT/scripts/picsure-compose.sh" "$TEST_ROOT/scripts/"
cp "$ROOT/scripts/lib/"{common,config}.sh "$TEST_ROOT/scripts/lib/"
cp "$ROOT/update.sh" "$ROOT/docker-compose.yml" "$ROOT/.env.example" "$TEST_ROOT/"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"
cat > "$TEST_ROOT/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *' config '*)
    echo config >> "$TEST_ROOT/events"
    [ ! -f "$TEST_ROOT/compose-fails" ] || exit 1
    cat "$TEST_ROOT/compose.json"
    ;;
  *) printf 'docker %s\n' "$*" >> "$TEST_ROOT/events" ;;
esac
STUB
chmod +x "$TEST_ROOT/bin/docker"
for script in clone-repos.sh release-control.sh run-migrations.sh build-images.sh scripts/env-normalize.sh; do
  cat > "$TEST_ROOT/$script" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "$TEST_ROOT/events"
STUB
  chmod +x "$TEST_ROOT/$script"
done
cat >> "$TEST_ROOT/build-images.sh" <<'STUB'
# Build matrix syntax read by the drift checker; unused by this recording stub.
: <<'MATRIX'
  "pic-sure-hpds-etl|services/example|services/example/Dockerfile"
MATRIX
STUB
printf 'FROM scratch\nUSER 1000\n' > "$TEST_ROOT/repos/core/services/example/Dockerfile"
printf 'export default { kit: { csp: {} } };\n' > "$TEST_ROOT/repos/frontend/svelte.config.js"
printf '24\n' > "$TEST_ROOT/repos/frontend/.nvmrc"
printf 'VITE_NEW_UPSTREAM_OPTION=true\n' > "$TEST_ROOT/repos/frontend/.env.example"
# Keep the Spring placeholder literal in the synthetic source.
# shellcheck disable=SC2016
printf 'new: ${UNKNOWN_UPSTREAM_OPTION:default}\n' > "$TEST_ROOT/repos/core/services/example/src/main/resources/application.yml"

fail() { echo "[drift-test] FAIL: $*" >&2; cat "$TEST_ROOT/output" >&2; exit 1; }
run() { env -i PATH="$TEST_ROOT/bin:$PATH" TEST_ROOT="$TEST_ROOT" bash "$@" > "$TEST_ROOT/output" 2>&1; }
set_env_var() { picsure_set_env_var "$TEST_ROOT/.env" "$1" "$2" "$3"; }
configure() {
  local mode="$1" anonymous=false explore=false
  [ "$mode" = required ] || anonymous=true
  [ "$mode" != explore ] || explore=true
  cat > "$TEST_ROOT/.env" <<ENV
AUTH_MODE=$mode
PICSURE_SRC=./repos/core
FRONTEND_SRC=./repos/frontend
VITE_ORIGIN=http://localhost
PICSURE_THEME=picsure
ENV
  AUTH_MODE="$mode" picsure_configure_auth
  jq -n --arg anon "$anonymous" --arg explore "$explore" '{services:{
    psama:{environment:{OPEN_IDP_PROVIDER_IS_ENABLED:$anon, ENABLE_PUBLIC_ACCESS:$explore, CONSENT_BASED_AUTHORIZATION_ENABLED:"false"}},
    gateway:{environment:{GATEWAY_OPEN_ACCESS_ENABLED:$anon,GATEWAY_DOCS_ENABLED:"true"}},
    httpd:{environment:{GATEWAY_DOCS_ENABLED:"true"}},
    "pic-sure-hpds-query-service":{environment:{CONSENT_BASED_AUTHORIZATION_ENABLED:"false",PSAMA_URL:"http://psama:8090"}}
  }}' > "$TEST_ROOT/compose.json"
  : > "$TEST_ROOT/events"
}
patch_compose() {
  jq "$1" "$TEST_ROOT/compose.json" > "$TEST_ROOT/next.json"
  mv "$TEST_ROOT/next.json" "$TEST_ROOT/compose.json"
}
expect_failure() {
  if run "$TEST_ROOT/scripts/config-drift.sh" "$@"; then fail 'Expected drift failure'; fi
  grep -q 'FAIL:' "$TEST_ROOT/output" || fail 'Missing diagnostic'
}
for mode in required open explore; do
  configure "$mode"
  run "$TEST_ROOT/scripts/config-drift.sh" || fail "Valid $mode configuration rejected"
  grep -q 'WARN:.*UNKNOWN_UPSTREAM_OPTION' "$TEST_ROOT/output" || fail 'Missing uncertain source-key warning'
  grep -q 'WARN:.*VITE_NEW_UPSTREAM_OPTION' "$TEST_ROOT/output" || fail 'Missing frontend-key warning'
  patch_compose '.services.psama.environment.ENABLE_PUBLIC_ACCESS |= if . == "true" then "false" else "true" end'
  expect_failure
  grep -q 'psama.ENABLE_PUBLIC_ACCESS' "$TEST_ROOT/output" || fail 'Auth mismatch not identified'
done
for patch in \
  '.services.gateway.environment.GATEWAY_OPEN_ACCESS_ENABLED="true"' \
  '.services.httpd.environment.GATEWAY_DOCS_ENABLED="false"' \
  '.services.psama.environment.CONSENT_BASED_AUTHORIZATION_ENABLED="true"'; do
  configure required; patch_compose "$patch"; expect_failure --images-only
done
configure required
set_env_var GATEWAY_DOCS_ENABLED false true
patch_compose '.services.gateway.environment.GATEWAY_DOCS_ENABLED="false" | .services.httpd.environment.GATEWAY_DOCS_ENABLED="false"'
run "$TEST_ROOT/scripts/config-drift.sh" --images-only || fail 'Consistent docs-off configuration rejected'
configure required
set_env_var CONSENT_BASED_AUTHORIZATION_ENABLED true true
patch_compose '.services.psama.environment.CONSENT_BASED_AUTHORIZATION_ENABLED="true" | .services["pic-sure-hpds-query-service"].environment.CONSENT_BASED_AUTHORIZATION_ENABLED="true"'
run "$TEST_ROOT/scripts/config-drift.sh" --images-only || fail 'Configured consent workflow rejected'
patch_compose 'del(.services["pic-sure-hpds-query-service"].environment.PSAMA_URL)'
expect_failure --images-only
grep -q 'requires query-service PSAMA_URL' "$TEST_ROOT/output" || fail 'Incomplete consent workflow not identified'
configure required
set_env_var VITE_CONFIG_MODE seed true
expect_failure --images-only
configure required
set_env_var PICSURE_THEME invalid true
expect_failure --images-only
configure required
touch "$TEST_ROOT/compose-fails"
expect_failure --images-only
rm "$TEST_ROOT/compose-fails"
configure required
mv "$TEST_ROOT/repos" "$TEST_ROOT/saved-repos"
expect_failure
run "$TEST_ROOT/scripts/config-drift.sh" --images-only || fail 'Image-only validation incorrectly needs sources'
grep -q 'Source checks skipped' "$TEST_ROOT/output" || fail 'Image-only uncertainty missing'
mv "$TEST_ROOT/saved-repos" "$TEST_ROOT/repos"
configure required
rm "$TEST_ROOT/repos/core/services/example/Dockerfile"
expect_failure
grep -q 'lacks Dockerfile' "$TEST_ROOT/output" || fail 'Missing build context not diagnosed'
printf 'FROM scratch\n' > "$TEST_ROOT/repos/core/services/example/Dockerfile"

# Run the actual update entrypoint. A verified mismatch must precede every
# image, migration and restart operation, including image-only updates.
for option in '' --no-rebuild --pull-images; do
  configure explore
  patch_compose '.services.psama.environment.ENABLE_PUBLIC_ACCESS="false"'
  if [ -n "$option" ]; then
    if run "$TEST_ROOT/update.sh" "$option"; then fail "Update continued with mismatch: $option"; fi
  else
    if run "$TEST_ROOT/update.sh"; then fail 'Default update continued with mismatch'; fi
  fi
  grep -q '^config$' "$TEST_ROOT/events" || fail 'Update did not check effective Compose config'
  if grep -Eq '^(build-images|run-migrations)|^docker ' "$TEST_ROOT/events"; then fail 'Update mutated images/database/services before rejecting mismatch'; fi
done
configure required
run "$TEST_ROOT/update.sh" || fail 'Warn-only drift prevented normal update'
config_line="$(grep -n '^config$' "$TEST_ROOT/events" | cut -d: -f1)"
build_line="$(grep -n '^build-images.sh ' "$TEST_ROOT/events" | cut -d: -f1)"
[ "$config_line" -lt "$build_line" ] || fail 'Build ran before drift checks'
grep -q '^run-migrations.sh --check$' "$TEST_ROOT/events" || fail 'Normal update missed migration validation'
grep -q ' restart psama httpd$' "$TEST_ROOT/events" || fail 'Normal update missed restart'
echo '[drift-test] modes, known failures, warn-only drift, source/image checks, and update ordering passed'
