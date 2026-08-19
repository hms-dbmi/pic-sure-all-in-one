#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — env-normalize Tests
# =============================================================================
# Local, non-network tests for scripts/env-normalize.sh, which edits the
# operator's live .env: it must remove exactly the retired keys, backfill the
# required service secrets, and touch nothing else. Each test runs against a
# fixture .env in a temp dir via the PICSURE_ROOT override.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/picsure-env-normalize-test.XXXXXX")"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

pass() { echo "[env-normalize-test] ok - $*"; }
fail() {
  echo "[env-normalize-test] fail - $*" >&2
  exit 1
}

run_normalize() {
  PICSURE_ROOT="$1" "$SCRIPT_DIR/scripts/env-normalize.sh"
}

# ---------------------------------------------------------------------------
# 1. Retired keys removed; look-alike keys and comments preserved
# ---------------------------------------------------------------------------
root="$TEST_ROOT/retired"
mkdir -p "$root"
cat > "$root/.env" << 'EOF'
PICSURE_REF=main
HPDS_REF=v1.2.3
PSAMA_REF=v1.2.3
DICTIONARY_REF=main
VISUALIZATION_REF=main
LOGGING_REF=main
LOGGING_CLIENT_REF=main
OPEN_ACCESS_ENABLED=true
MY_HPDS_REF=keep-me
# HPDS_REF=commented-out
DICTIONARY_ETL_REF=main
EOF
run_normalize "$root" > /dev/null
for key in HPDS_REF PSAMA_REF DICTIONARY_REF VISUALIZATION_REF LOGGING_REF LOGGING_CLIENT_REF OPEN_ACCESS_ENABLED; do
  grep -q "^${key}=" "$root/.env" && fail "retired key $key survived"
done
grep -q "^PICSURE_REF=main$" "$root/.env" || fail "PICSURE_REF was touched"
grep -q "^MY_HPDS_REF=keep-me$" "$root/.env" || fail "MY_HPDS_REF was touched"
grep -q "^# HPDS_REF=commented-out$" "$root/.env" || fail "comment line was touched"
pass "retired keys removed, look-alikes preserved"

# ---------------------------------------------------------------------------
# 2. Missing service secrets backfilled with hex values
# ---------------------------------------------------------------------------
grep -Eq "^QUERY_SERVICE_INTERNAL_TOKEN=[0-9a-f]{64}$" "$root/.env" \
  || fail "QUERY_SERVICE_INTERNAL_TOKEN not backfilled"
grep -Eq "^PICSURE_APPLICATION_TOKEN=[0-9a-f]{64}$" "$root/.env" \
  || fail "PICSURE_APPLICATION_TOKEN not backfilled"
grep -Eq "^AGGREGATE_OBFUSCATION_SALT=[0-9a-f]{32}$" "$root/.env" \
  || fail "AGGREGATE_OBFUSCATION_SALT not backfilled"
pass "missing secrets backfilled"

# ---------------------------------------------------------------------------
# 3. Existing non-empty secrets untouched; blank ones filled
# ---------------------------------------------------------------------------
root="$TEST_ROOT/secrets"
mkdir -p "$root"
cat > "$root/.env" << 'EOF'
QUERY_SERVICE_INTERNAL_TOKEN=preexisting-token
PICSURE_APPLICATION_TOKEN=
EOF
run_normalize "$root" > /dev/null
grep -q "^QUERY_SERVICE_INTERNAL_TOKEN=preexisting-token$" "$root/.env" \
  || fail "existing secret was regenerated"
grep -Eq "^PICSURE_APPLICATION_TOKEN=[0-9a-f]{64}$" "$root/.env" \
  || fail "blank secret not filled in place"
pass "existing secrets kept, blank secrets filled"

# ---------------------------------------------------------------------------
# 4. Idempotent: a second run changes nothing
# ---------------------------------------------------------------------------
before="$(cat "$root/.env")"
run_normalize "$root" > /dev/null
[ "$before" = "$(cat "$root/.env")" ] || fail "second run modified a normalized .env"
pass "idempotent on a normalized .env"

# ---------------------------------------------------------------------------
# 5. Missing .env: silent success
# ---------------------------------------------------------------------------
root="$TEST_ROOT/missing"
mkdir -p "$root"
out="$(run_normalize "$root")" || fail "missing .env caused a non-zero exit"
[ -z "$out" ] || fail "missing .env produced output: $out"
[ ! -e "$root/.env" ] || fail "a .env was created from nothing"
pass "missing .env is a silent no-op"

# ---------------------------------------------------------------------------
# 6. DICTIONARY_ETL_REF warning: fires on a real pin, not on dressed-up main
# ---------------------------------------------------------------------------
root="$TEST_ROOT/etl"
mkdir -p "$root"
printf 'DICTIONARY_ETL_REF="main"\n' > "$root/.env"
out="$(run_normalize "$root" 2>&1)"
echo "$out" | grep -q "pinned" && fail "quoted main triggered the pin warning"
printf 'DICTIONARY_ETL_REF=my-branch\n' > "$root/.env"
out="$(run_normalize "$root" 2>&1)"
echo "$out" | grep -q "pinned to my-branch" || fail "real pin did not warn"
pass "DICTIONARY_ETL_REF warning fires only on real pins"

echo "[env-normalize-test] all tests passed"
