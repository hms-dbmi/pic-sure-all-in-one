#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — load-csv decompression / archive-csvs tests
# =============================================================================
# Local, hermetic tests for etl.sh's compressed/archived phenotype input
# handling. The HOST-SIDE decompression logic (detection, gunzip, tar extract,
# --entry selection, temp-dir cleanup) runs FOR REAL against tiny fixtures
# built in a temp dir; only `docker` and the HPDS stop/start helpers are stubbed
# so the loader image never actually runs.
#
# Mechanism: each case runs in a SUBSHELL that SOURCES etl.sh (which returns at
# its BASH_SOURCE guard before ensure_env / dispatch), then overrides docker
# (recording the resolved -v mount), ensure_image, copy_hpds_key, and the
# stop/start_hpds helpers. resolve_phenotype_csv + load_csv run unmodified.
#
# Asserted contract (LD-7a):
#   - raw .csv            → mounted path IS the file itself; no temp dir.
#   - single-CSV .tgz     → extracted to a temp dir, mounted; temp gone after.
#   - multi-CSV .tgz      → without --entry: exit 1, lists entries, NO docker.
#                           with --entry b.csv: extracts b.csv, mounts it.
#                           with bogus --entry: exit 1.
#   - plain .csv.gz       → gunzip to temp, mounted.
#   - cleanup verified on BOTH success and a forced mid-run docker failure
#     (and start_hpds is skipped when the loader fails).
#   - archive-csvs: lists CSVs of a tgz (sorted); nothing for raw .csv / .gz
#     (exit 0); non-zero on a missing file.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ETL="$SCRIPT_DIR/etl.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/picsure-etl-loadcsv-test.XXXXXX")"

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

pass() { echo "[etl-loadcsv-test] ok - $*"; }
fail() { echo "[etl-loadcsv-test] fail - $*" >&2; exit 1; }

# --- Build tiny real fixtures ------------------------------------------------
FIX="$TEST_ROOT/fix"
mkdir -p "$FIX" "$FIX/single" "$FIX/multi"
printf 'PATIENT_NUM,CONCEPT_PATH,NVAL_NUM,TVAL_CHAR\n1,\\demo\\,1,,\n' > "$FIX/allConcepts.csv"

# single-CSV gzipped tar
cp "$FIX/allConcepts.csv" "$FIX/single/allConcepts.csv"
tar -czf "$FIX/single.tgz" -C "$FIX/single" allConcepts.csv

# multi-CSV gzipped tar (a.csv + b.csv, plus a non-CSV to prove filtering)
printf 'a-data\n' > "$FIX/multi/a.csv"
printf 'b-data\n' > "$FIX/multi/b.csv"
printf 'note\n'   > "$FIX/multi/readme.txt"
tar -czf "$FIX/multi.tgz" -C "$FIX/multi" a.csv b.csv readme.txt

# plain gzip of a CSV (NOT a tar)
gzip -c "$FIX/allConcepts.csv" > "$FIX/allConcepts.csv.gz"

# --- Harness: run the REAL load_csv with docker + hpds helpers stubbed -------
# A small generated driver SOURCES etl.sh (which returns at its BASH_SOURCE
# guard before ensure_env / dispatch), overrides docker (recording the resolved
# allConcepts.csv -v mount) plus ensure_image / copy_hpds_key / stop_hpds /
# start_hpds / volume_name, then runs the REAL load_csv. resolve_phenotype_csv +
# load_csv are NOT stubbed — the host-side decompression runs for real.
#
# The driver prints one pipe-delimited line on its OWN stdout:
#   <exit-code>|<captured-mount-host-path>|<tmpdir-or-empty>|<start_ran 0|1>
# Set FORCE_DOCKER_RC to make the stubbed loader "fail".
DRIVER="$TEST_ROOT/driver.sh"
cat > "$DRIVER" <<DRIVER_EOF
#!/usr/bin/env bash
set -euo pipefail
ETL="$ETL"
FIX="$FIX"
DRIVER_EOF
cat >> "$DRIVER" <<'DRIVER_EOF'
# shellcheck disable=SC1090
source "$ETL"

CAPTURED_MOUNT=""
START_RAN=0
# shellcheck disable=SC2329  # invoked indirectly by load_csv (overrides etl.sh)
docker() {
  local a
  for a in "$@"; do
    case "$a" in
      *:/opt/local/hpds/allConcepts.csv:ro) CAPTURED_MOUNT="$a" ;;
    esac
  done
  return "${FORCE_DOCKER_RC:-0}"
}
# shellcheck disable=SC2329
ensure_image() { :; }
# shellcheck disable=SC2329
warn() { :; }
# shellcheck disable=SC2329
stop_hpds() { :; }
# shellcheck disable=SC2329
copy_hpds_key() { :; }
# shellcheck disable=SC2329
start_hpds() { START_RAN=1; }
# shellcheck disable=SC2329
volume_name() { echo "picsure_$1"; }

rc=0
load_csv "$@" >/dev/null 2>"${LOADCSV_ERRLOG:-/dev/null}" || rc=$?

host_path="${CAPTURED_MOUNT%:/opt/local/hpds/allConcepts.csv:ro}"
tmpdir=""
case "$host_path" in
  */*) tmpdir="$(dirname "$host_path")" ;;
esac
# A raw-CSV mount's dirname is the fixture dir, NOT a temp dir — never report it
# (so the cleanup assertions don't try to rm the fixtures).
case "$tmpdir" in
  "$FIX"|"$FIX"/*) tmpdir="" ;;
esac
printf '%s|%s|%s|%s\n' "$rc" "$host_path" "$tmpdir" "$START_RAN"
DRIVER_EOF
chmod +x "$DRIVER"

run_load_csv() {
  /usr/bin/env bash "$DRIVER" "$@"
}

field() { echo "$1" | cut -d'|' -f"$2"; }

# --- Cases -------------------------------------------------------------------

test_raw_csv() {
  local r rc mount tmpdir
  r="$(run_load_csv --file "$FIX/allConcepts.csv")"
  rc="$(field "$r" 1)"; mount="$(field "$r" 2)"; tmpdir="$(field "$r" 3)"
  [ "$rc" = "0" ] || fail "raw-csv: expected exit 0, got $rc"
  [ "$mount" = "$FIX/allConcepts.csv" ] || fail "raw-csv: mounted '$mount', expected the file itself"
  [ -z "$tmpdir" ] || fail "raw-csv: a temp dir was created ($tmpdir); raw CSV must be used verbatim"
  pass "raw .csv mounted verbatim, no temp dir"
}

test_single_tgz() {
  local r rc mount tmpdir
  r="$(run_load_csv --file "$FIX/single.tgz")"
  rc="$(field "$r" 1)"; mount="$(field "$r" 2)"; tmpdir="$(field "$r" 3)"
  [ "$rc" = "0" ] || fail "single-tgz: expected exit 0, got $rc"
  case "$mount" in
    /*/allConcepts.csv) ;;
    *) fail "single-tgz: unexpected mount '$mount'" ;;
  esac
  [ "$mount" != "$FIX/allConcepts.csv" ] || fail "single-tgz: mounted the fixture, not an extracted temp copy"
  [ -n "$tmpdir" ] || fail "single-tgz: expected a temp dir"
  [ ! -e "$tmpdir" ] || fail "single-tgz: temp dir $tmpdir leaked after run"
  pass "single-CSV .tgz extracted to temp, mounted, temp cleaned after success"
}

test_multi_no_entry() {
  # Capture load_csv's stderr (via LOADCSV_ERRLOG) to assert it lists both
  # entries; assert exit 1 and that NO docker mount was captured (no loader ran).
  local errlog="$TEST_ROOT/multi-no-entry.err" r rc mount
  r="$(LOADCSV_ERRLOG="$errlog" run_load_csv --file "$FIX/multi.tgz")"
  rc="$(field "$r" 1)"; mount="$(field "$r" 2)"
  [ "$rc" = "1" ] || fail "multi-no-entry: expected exit 1, got $rc"
  [ -z "$mount" ] || fail "multi-no-entry: a loader mount was captured ('$mount'); docker should not have run"
  grep -q "multiple CSVs in archive" "$errlog" || fail "multi-no-entry: missing 'multiple CSVs' message"
  grep -q "a.csv" "$errlog" || fail "multi-no-entry: did not list a.csv"
  grep -q "b.csv" "$errlog" || fail "multi-no-entry: did not list b.csv"
  pass "multi-CSV .tgz without --entry: exit 1, lists both entries, no docker"
}

test_multi_with_entry() {
  local r rc mount tmpdir
  r="$(run_load_csv --file "$FIX/multi.tgz" --entry b.csv)"
  rc="$(field "$r" 1)"; mount="$(field "$r" 2)"; tmpdir="$(field "$r" 3)"
  [ "$rc" = "0" ] || fail "multi-entry: expected exit 0, got $rc"
  case "$mount" in
    */b.csv) ;;
    *) fail "multi-entry: expected b.csv to be mounted, got '$mount'" ;;
  esac
  [ -n "$tmpdir" ] && [ ! -e "$tmpdir" ] || fail "multi-entry: temp dir not cleaned ($tmpdir)"
  pass "multi-CSV .tgz with --entry b.csv: extracts and mounts b.csv"
}

test_multi_bogus_entry() {
  local r rc
  r="$(run_load_csv --file "$FIX/multi.tgz" --entry bogus.csv)"
  rc="$(field "$r" 1)"
  [ "$rc" = "1" ] || fail "multi-bogus-entry: expected exit 1, got $rc"
  pass "multi-CSV .tgz with bogus --entry: exit 1"
}

test_plain_gz() {
  local r rc mount tmpdir
  r="$(run_load_csv --file "$FIX/allConcepts.csv.gz")"
  rc="$(field "$r" 1)"; mount="$(field "$r" 2)"; tmpdir="$(field "$r" 3)"
  [ "$rc" = "0" ] || fail "plain-gz: expected exit 0, got $rc"
  case "$mount" in
    */allConcepts.csv) ;;
    *) fail "plain-gz: unexpected mount '$mount'" ;;
  esac
  [ "$mount" != "$FIX/allConcepts.csv" ] || fail "plain-gz: mounted the fixture, not a gunzipped temp copy"
  [ -n "$tmpdir" ] && [ ! -e "$tmpdir" ] || fail "plain-gz: temp dir not cleaned ($tmpdir)"
  pass "plain .csv.gz gunzipped to temp, mounted, temp cleaned"
}

test_cleanup_on_docker_failure() {
  local r rc tmpdir start_ran
  r="$(FORCE_DOCKER_RC=17 run_load_csv --file "$FIX/single.tgz")"
  rc="$(field "$r" 1)"; tmpdir="$(field "$r" 3)"; start_ran="$(field "$r" 4)"
  [ "$rc" = "17" ] || fail "docker-failure: expected loader exit 17 to propagate, got $rc"
  [ -n "$tmpdir" ] && [ ! -e "$tmpdir" ] || fail "docker-failure: temp dir leaked on failure ($tmpdir)"
  [ "$start_ran" = "0" ] || fail "docker-failure: start_hpds ran after a failed loader"
  pass "forced mid-run docker failure: rc propagated, temp cleaned, start_hpds skipped"
}

# copy_hpds_key hard-`exit 1`s (not `return`) when the encryption key is missing.
# With a compressed --file the temp dir already exists by then, so this asserts
# load_csv's EXIT trap still cleans it up rather than leaking it past the abort.
# The run_load_csv driver can't report back across a process exit, so use a
# dedicated driver and detect a leak by diffing the temp root before/after.
test_cleanup_on_copy_key_exit() {
  local kdriver="$TEST_ROOT/copykey-driver.sh"
  cat > "$kdriver" <<KEY_EOF
#!/usr/bin/env bash
set -euo pipefail
ETL="$ETL"
KEY_EOF
  cat >> "$kdriver" <<'KEY_EOF'
# shellcheck disable=SC1090
source "$ETL"
# shellcheck disable=SC2329  # invoked indirectly by load_csv
docker() { return 0; }
# shellcheck disable=SC2329
ensure_image() { :; }
# shellcheck disable=SC2329
warn() { :; }
# shellcheck disable=SC2329
stop_hpds() { :; }
# shellcheck disable=SC2329
start_hpds() { :; }
# shellcheck disable=SC2329
volume_name() { echo "picsure_$1"; }
# Mirror the real copy_hpds_key's missing-key behavior: ERROR then `exit 1`,
# which bypasses any rc-capture in load_csv (the bug this guards against).
# shellcheck disable=SC2329
copy_hpds_key() { echo "[stub] encryption key missing -> exit 1" >&2; exit 1; }
load_csv "$@"
KEY_EOF
  chmod +x "$kdriver"

  local tmproot="${TMPDIR:-/tmp}" before after leaked rc=0
  # mktemp -d names dirs tmp.XXXX directly under the temp root.
  before="$(find "$tmproot" -maxdepth 1 -type d -name 'tmp.*' 2>/dev/null | LC_ALL=C sort)"
  /usr/bin/env bash "$kdriver" --file "$FIX/single.tgz" >/dev/null 2>&1 || rc=$?
  after="$(find "$tmproot" -maxdepth 1 -type d -name 'tmp.*' 2>/dev/null | LC_ALL=C sort)"

  [ "$rc" != "0" ] || fail "copy-key-exit: expected nonzero exit, got 0"
  leaked="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
  [ -z "$leaked" ] || fail "copy-key-exit: temp dir(s) leaked past copy_hpds_key exit: $leaked"
  pass "copy_hpds_key exit on compressed --file: process exits nonzero, no temp leak"
}

# --- archive-csvs (dispatch-level, no .env / docker) -------------------------

test_archive_csvs_multi() {
  local out rc=0
  out="$(/usr/bin/env bash "$ETL" archive-csvs "$FIX/multi.tgz")" || rc=$?
  [ "$rc" = "0" ] || fail "archive-csvs/multi: expected exit 0, got $rc"
  local want
  want="$(printf 'a.csv\nb.csv')"
  [ "$out" = "$want" ] || fail "archive-csvs/multi: expected 'a.csv\\nb.csv', got '$out'"
  pass "archive-csvs on multi .tgz prints a.csv then b.csv (sorted)"
}

test_archive_csvs_raw() {
  local out rc=0
  out="$(/usr/bin/env bash "$ETL" archive-csvs "$FIX/allConcepts.csv")" || rc=$?
  [ "$rc" = "0" ] || fail "archive-csvs/raw: expected exit 0, got $rc"
  [ -z "$out" ] || fail "archive-csvs/raw: expected NO output, got '$out'"
  pass "archive-csvs on raw .csv prints nothing, exit 0"
}

test_archive_csvs_plain_gz() {
  local out rc=0
  out="$(/usr/bin/env bash "$ETL" archive-csvs "$FIX/allConcepts.csv.gz")" || rc=$?
  [ "$rc" = "0" ] || fail "archive-csvs/plain-gz: expected exit 0, got $rc"
  [ -z "$out" ] || fail "archive-csvs/plain-gz: expected NO output, got '$out'"
  pass "archive-csvs on plain .csv.gz prints nothing, exit 0"
}

test_archive_csvs_missing() {
  local rc=0
  /usr/bin/env bash "$ETL" archive-csvs "$FIX/does-not-exist.tgz" >/dev/null 2>&1 || rc=$?
  [ "$rc" != "0" ] || fail "archive-csvs/missing: expected non-zero exit, got 0"
  pass "archive-csvs on a missing file exits non-zero"
}

test_raw_csv
test_single_tgz
test_multi_no_entry
test_multi_with_entry
test_multi_bogus_entry
test_plain_gz
test_cleanup_on_docker_failure
test_cleanup_on_copy_key_exit
test_archive_csvs_multi
test_archive_csvs_raw
test_archive_csvs_plain_gz
test_archive_csvs_missing

echo "[etl-loadcsv-test] complete"
