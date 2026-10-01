#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — Shared HPDS data mode tests
# =============================================================================
# Hermetic checks for HPDS_DATA_MODE=shared: the overlay is selected only in
# shared mode, every script-side volume name goes through picsure_hpds_volume,
# HPDS writes are refused, and the merged Compose config mounts the published
# volumes external and read-only. Needs only the docker CLI (`compose config`
# does not talk to the daemon); no containers or volumes are created.
# =============================================================================

set -euo pipefail
exec </dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/picsure-shared-hpds-test.XXXXXX")"
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

pass() { echo "[shared-hpds-test] ok - $*"; }
fail() { echo "[shared-hpds-test] fail - $*" >&2; exit 1; }

# with_helpers SNIPPET [VAR=value...]: run SNIPPET with the helpers loaded and
# only the given variables set.
with_helpers() {
  local snippet="$1"
  shift
  # shellcheck disable=SC2016  # expanded by the inner shell, not this one
  env -i PATH="$PATH" HOME="${HOME:-/tmp}" "$@" bash -c '
    set -euo pipefail
    source "$0/scripts/picsure-compose.sh"
    eval "$1"
  ' "$SCRIPT_DIR" "$snippet"
}

# --- overlay selection --------------------------------------------------------
files="$(with_helpers 'picsure_compose_files /root' COMPOSE_PROJECT_NAME=p)"
case "$files" in *shared-hpds*) fail "local mode selected the shared overlay" ;; esac
files="$(with_helpers 'picsure_compose_files /root' HPDS_DATA_MODE=shared HPDS_SHARED_DATA=d)"
case "$files" in *"/root/docker-compose.shared-hpds.yml"*) ;; *) fail "shared mode did not select the overlay: $files" ;; esac
pass "overlay selected only when HPDS_DATA_MODE=shared"

# --- volume names -------------------------------------------------------------
got="$(with_helpers 'picsure_hpds_volume hpds-data' COMPOSE_PROJECT_NAME=proj)"
[ "$got" = "proj_hpds-data" ] || fail "local volume name: $got"
got="$(with_helpers 'picsure_hpds_volume hpds-genomic' COMPOSE_PROJECT_NAME=proj \
  HPDS_DATA_MODE=shared HPDS_SHARED_DATA=picsure-demo-v1)"
[ "$got" = "picsure-demo-v1_hpds-genomic" ] || fail "shared volume name: $got"
if with_helpers 'picsure_hpds_volume hpds-data' HPDS_DATA_MODE=shared >/dev/null 2>&1; then
  fail "shared mode without HPDS_SHARED_DATA produced a volume name"
fi
pass "picsure_hpds_volume follows the mode and requires HPDS_SHARED_DATA"

# --- write refusal ------------------------------------------------------------
with_helpers 'picsure_require_hpds_writable test' COMPOSE_PROJECT_NAME=proj \
  || fail "local mode refused an HPDS write"
if out="$(with_helpers 'picsure_require_hpds_writable "./etl.sh load-csv"' \
  HPDS_DATA_MODE=shared HPDS_SHARED_DATA=picsure-demo-v1 2>&1)"; then
  fail "shared mode allowed an HPDS write"
fi
case "$out" in *"picsure-demo-v1"*) ;; *) fail "refusal does not name the data set: $out" ;; esac
pass "HPDS writes are refused in shared mode"

# --- HPDS profile from the data set's label -------------------------------------
# A fake docker answers the label lookup and reports the HPDS_PROFILE that
# reached `docker compose`.
mkdir -p "$TEST_ROOT/bin"
cat > "$TEST_ROOT/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
case "$1" in
  volume) [ "${FAKE_VOLUME:-missing}" = present ] && echo "${FAKE_LABEL:-}" || exit 1 ;;
  compose) echo "profile=[${HPDS_PROFILE:-}]" ;;
  *) exit 99 ;;
esac
DOCKER
chmod +x "$TEST_ROOT/bin/docker"
fake() { with_helpers 'picsure_compose ps' PATH="$TEST_ROOT/bin:$PATH" PICSURE_ROOT=/root "$@"; }
[ "$(fake HPDS_DATA_MODE=shared HPDS_SHARED_DATA=d FAKE_VOLUME=present FAKE_LABEL=bch-dev)" = "profile=[bch-dev]" ] \
  || fail "shared mode did not apply the data set's recorded profile"
[ "$(fake HPDS_DATA_MODE=shared HPDS_SHARED_DATA=d FAKE_VOLUME=present FAKE_LABEL=bch-dev HPDS_PROFILE=custom)" = "profile=[custom]" ] \
  || fail "an explicit HPDS_PROFILE was overridden"
[ "$(fake HPDS_DATA_MODE=shared HPDS_SHARED_DATA=d FAKE_VOLUME=present FAKE_LABEL=)" = "profile=[]" ] \
  || fail "a phenotype-only data set set a profile"
[ "$(fake HPDS_DATA_MODE=shared HPDS_SHARED_DATA=d)" = "profile=[]" ] \
  || fail "a missing data set volume set a profile"
[ "$(fake FAKE_VOLUME=present FAKE_LABEL=bch-dev)" = "profile=[]" ] \
  || fail "local mode read a shared data set label"
pass "shared mode applies the recorded HPDS profile unless .env sets one"

# --- merged Compose config ----------------------------------------------------
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "[shared-hpds-test] skip - docker compose unavailable; config merge not checked"
  echo "[shared-hpds-test] Complete"
  exit 0
fi
# Compose resolves env_file paths even for `config`; give it empty stand-ins.
cp "$SCRIPT_DIR/docker-compose.yml" "$SCRIPT_DIR/docker-compose.shared-hpds.yml" "$TEST_ROOT/"
mkdir -p "$TEST_ROOT/config/dictionary"
: > "$TEST_ROOT/config/dictionary/dictionary.env"
config="$TEST_ROOT/config.json"
(cd "$TEST_ROOT" && HPDS_SHARED_DATA=picsure-demo-v1 docker compose -p proj \
  -f docker-compose.yml -f docker-compose.shared-hpds.yml config --format json 2>/dev/null) > "$config" \
  || fail "compose config failed with the shared overlay"

check() {
  local filter="$1" want="$2" got
  got="$(jq -r "$filter" "$config")"
  [ "$got" = "$want" ] || fail "$filter = $got, want $want"
}
check '.volumes["hpds-data"].name' picsure-demo-v1_hpds-data
check '.volumes["hpds-data"].external' true
check '.volumes["hpds-genomic-shared"].name' picsure-demo-v1_hpds-genomic
check '.volumes["hpds-genomic-shared"].external' true
check '[.services.hpds.volumes[] | select(.target == "/opt/local/hpds")][0].source' hpds-data
check '[.services.hpds.volumes[] | select(.target == "/opt/local/hpds")][0].read_only' true
# HPDS reads genomic data from this project's seeded copy, never the shared
# volume, and the project's own hpds-genomic is no longer mounted.
check '[.services.hpds.volumes[] | select(.target == "/opt/local/hpds/all")][0].source' hpds-genomic-shared-copy
check '.volumes["hpds-genomic-shared-copy"].name' proj_hpds-genomic-shared-copy
check '[.services.hpds.volumes[] | select(.source == "hpds-genomic")] | length' 0
check '.services.hpds.depends_on["hpds-genomic-seed"].condition' service_completed_successfully
check '[.services["hpds-genomic-seed"].volumes[] | select(.source == "hpds-genomic-shared")][0].read_only' true
# No service mounts a shared volume writable; per-stack volumes are unchanged.
check '[.services[] | .volumes // [] | .[] | select((.source == "hpds-data" or .source == "hpds-genomic-shared") and (.read_only != true))] | length' 0
check '.volumes["hpds-query-results"].name' proj_hpds-query-results
pass "overlay mounts the shared volumes external and read-only, genomic via a per-stack copy"

if (cd "$TEST_ROOT" && docker compose -p proj -f docker-compose.yml -f docker-compose.shared-hpds.yml \
  config --quiet >/dev/null 2>&1); then
  fail "compose accepted the shared overlay without HPDS_SHARED_DATA"
fi
pass "compose refuses the overlay without HPDS_SHARED_DATA"

echo "[shared-hpds-test] Complete"
