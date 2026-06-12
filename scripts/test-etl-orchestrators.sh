#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — ETL Orchestrator Tests
# =============================================================================
# Local, hermetic tests for etl.sh's load-phenotype / load-genomic
# orchestrators. NOTHING real runs: no docker, no compose, no .env mutation.
#
# Mechanism (modelled on scripts/test-repo-reset.sh): each test runs in a
# SUBSHELL that SOURCES etl.sh — which stops before ensure_env and the command
# dispatch when sourced (BASH_SOURCE guard) — and then OVERRIDES every atomic
# loader function (load_csv, hydrate_dictionary, …) with a recorder that
# appends its name + argv to a log. The orchestrator under test therefore
# exercises its REAL validation + sequencing logic while the atomic steps are
# inert recorders. As belt-and-suspenders, docker / scripts/env-set.sh /
# scripts/compose.sh are also shimmed on PATH so even an un-stubbed call cannot
# touch the real stack.
#
# The contract under test:
#   - ALL inputs validate up front: a failure exits 1 BEFORE any loader fires.
#   - The happy path fires the right atomic ops, IN ORDER, with the right args.
#   - Optional flags (--skip-weights, --promote, --enable-profile, custom
#     dictionary, facets) select the right branch.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/picsure-etl-orch-test.XXXXXX")"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

pass() { echo "[etl-orch-test] ok - $*"; }

# LAST_LOG holds the recorder log for the current case so a failing assertion
# can dump what the orchestrator actually invoked before the temp dir is wiped.
LAST_LOG=""
fail() {
  echo "[etl-orch-test] fail - $*" >&2
  if [ -n "$LAST_LOG" ] && [ -f "$LAST_LOG" ]; then
    echo "[etl-orch-test] --- recorded invocations ($(basename "$LAST_LOG")) ---" >&2
    cat "$LAST_LOG" >&2
    echo "[etl-orch-test] --- end ---" >&2
  fi
  exit 1
}

# --- PATH shims: belt-and-suspenders so nothing real runs -------------------
# These stand in for anything the (overridden) atomic functions would shell out
# to. They record their argv so an accidental real call is visible, and they
# never touch docker/compose/.env. The orchestrators also invoke env-set.sh /
# compose.sh BY ABSOLUTE PATH (via $SCRIPT_DIR), so those are overridden as
# functions inside the subshell rather than via PATH (see run_orchestrator).
mkdir -p "$TEST_ROOT/bin"
for tool in docker unzip; do
  cat > "$TEST_ROOT/bin/$tool" <<SHIM
#!/usr/bin/env bash
printf '$tool %s\n' "\$*" >> "${TEST_ROOT}/path-shim.log"
exit 0
SHIM
  chmod +x "$TEST_ROOT/bin/$tool"
done
PATH="$TEST_ROOT/bin:$PATH"
export PATH

# Tiny readable fixtures the validators accept (exist + readable).
FIX="$TEST_ROOT/fix"
mkdir -p "$FIX" "$FIX/vcfdir"
printf 'header\n' > "$FIX/allConcepts.csv"
printf 'header\n' > "$FIX/datasets.csv"
printf 'zip\n'    > "$FIX/concepts.zip"
printf 'cat\n'    > "$FIX/facet_categories.csv"
printf 'fac\n'    > "$FIX/facets.csv"
printf 'fcon\n'   > "$FIX/facet_concepts.csv"
printf 'idx\n'    > "$FIX/vcfIndex.tsv"

# run_orchestrator: source etl.sh in a SUBSHELL, replace every atomic loader
# (and the env-set/compose helper scripts) with recorders that append
# "<name> <argv>" to $log, then invoke the orchestrator under test. Stdout and
# stderr go to $log.out / $log.err. Echoes the orchestrator's exit code.
#
# Recording lives in a subshell so each case starts from a clean slate and the
# overrides never leak between tests.
run_orchestrator() {
  local log="$1"; shift
  LAST_LOG="$log"
  : > "$log"
  local rc=0
  # `|| rc=$?` keeps the failing subshell from aborting this function under
  # set -e, so a validation exit 1 is captured rather than killing the test.
  if (
    # etl.sh returns at its BASH_SOURCE guard when sourced, before reading any
    # positional, so our orchestrator args in "$@" pass through untouched.
    # shellcheck disable=SC1091  # resolved at runtime from SCRIPT_DIR
    source "$SCRIPT_DIR/etl.sh"

    # SCRIPT_DIR inside etl.sh points at the real repo; repoint the helper
    # script paths the genomic orchestrator calls by overriding the helpers
    # directly. (load_genomic invokes "$SCRIPT_DIR/scripts/env-set.sh" and
    # "$SCRIPT_DIR/scripts/compose.sh"; override SCRIPT_DIR so those resolve to
    # recorders.)
    SCRIPT_DIR="$TEST_ROOT/repo"
    mkdir -p "$SCRIPT_DIR/scripts"
    cat > "$SCRIPT_DIR/scripts/env-set.sh" <<EOF
#!/usr/bin/env bash
printf 'env-set %s\n' "\$*" >> "$log"
exit 0
EOF
    cat > "$SCRIPT_DIR/scripts/compose.sh" <<EOF
#!/usr/bin/env bash
printf 'compose %s\n' "\$*" >> "$log"
exit 0
EOF
    chmod +x "$SCRIPT_DIR/scripts/env-set.sh" "$SCRIPT_DIR/scripts/compose.sh"

    # Recorder factory: define a function NAME that logs "NAME <argv>".
    record_as() {
      local fn="$1"
      eval "$fn() { printf '$fn %s\\n' \"\$*\" >> '$log'; }"
    }
    record_as load_csv
    record_as hydrate_dictionary
    record_as load_dictionary_csv
    record_as load_facets
    record_as run_weights
    record_as load_vcf
    record_as promote_genomic

    "$@"
  ) >"$log.out" 2>"$log.err"; then
    rc=0
  else
    rc=$?
  fi
  echo "$rc"
}

# assert_no_invocations: the recorder log must be empty (validation rejected
# the call before any atomic op fired).
assert_no_invocations() {
  local log="$1" label="$2"
  if [ -s "$log" ]; then
    fail "$label: expected NO atomic invocations, but some fired"
  fi
  pass "$label: no atomic op fired (validation rejected up front)"
}

assert_exit() {
  local got="$1" want="$2" label="$3"
  [ "$got" = "$want" ] || fail "$label: expected exit $want, got $got"
  pass "$label: exit $want"
}

# assert_order: the recorder log lines (in order) must match the given prefixes
# exactly, one per argument. Each prefix is matched against the start of the
# corresponding logged line.
assert_order() {
  local log="$1" label="$2"; shift 2
  local expected=("$@")
  local -a actual=()
  while IFS= read -r line; do
    actual+=("$line")
  done < "$log"
  if [ "${#actual[@]}" -ne "${#expected[@]}" ]; then
    fail "$label: expected ${#expected[@]} invocations, got ${#actual[@]}"
  fi
  local i
  for i in "${!expected[@]}"; do
    case "${actual[$i]}" in
      "${expected[$i]}"*) ;;
      *) fail "$label: invocation $i: expected '${expected[$i]}…', got '${actual[$i]}'" ;;
    esac
  done
  pass "$label: invocations match in order"
}

# ===========================================================================
# load-phenotype
# ===========================================================================

# (a) missing --file -> exit 1, no load_csv.
test_phenotype_missing_file() {
  local log="$TEST_ROOT/a.log" rc
  rc="$(run_orchestrator "$log" load_phenotype --heap 4096)"
  assert_exit "$rc" 1 "phenotype/missing-file"
  assert_no_invocations "$log" "phenotype/missing-file"
}

# (b) --dictionary custom without --datasets -> exit 1, no load_csv.
test_phenotype_custom_missing_datasets() {
  local log="$TEST_ROOT/b.log" rc
  rc="$(run_orchestrator "$log" load_phenotype \
    --file "$FIX/allConcepts.csv" --dictionary custom --concepts "$FIX/concepts.zip")"
  assert_exit "$rc" 1 "phenotype/custom-missing-datasets"
  assert_no_invocations "$log" "phenotype/custom-missing-datasets"
}

# (c) facets partial (2 of 3) -> exit 1, no load_csv.
test_phenotype_facets_partial() {
  local log="$TEST_ROOT/c.log" rc
  rc="$(run_orchestrator "$log" load_phenotype \
    --file "$FIX/allConcepts.csv" \
    --facets-categories "$FIX/facet_categories.csv" --facets "$FIX/facets.csv")"
  assert_exit "$rc" 1 "phenotype/facets-partial"
  assert_no_invocations "$log" "phenotype/facets-partial"
}

# (d) happy auto path -> load_csv, hydrate_dictionary --clear, run_weights, in order.
test_phenotype_auto_happy() {
  local log="$TEST_ROOT/d.log" rc
  rc="$(run_orchestrator "$log" load_phenotype --file "$FIX/allConcepts.csv" --heap 8192)"
  assert_exit "$rc" 0 "phenotype/auto-happy"
  assert_order "$log" "phenotype/auto-happy" \
    "load_csv --file $FIX/allConcepts.csv --heap 8192" \
    "hydrate_dictionary --clear" \
    "run_weights"
}

# (e) custom path -> load_dictionary_csv + load_facets instead of hydrate.
test_phenotype_custom_happy() {
  local log="$TEST_ROOT/e.log" rc
  rc="$(run_orchestrator "$log" load_phenotype \
    --file "$FIX/allConcepts.csv" \
    --dictionary custom \
    --datasets "$FIX/datasets.csv" --concepts "$FIX/concepts.zip" \
    --facets-categories "$FIX/facet_categories.csv" \
    --facets "$FIX/facets.csv" \
    --facet-concepts "$FIX/facet_concepts.csv")"
  assert_exit "$rc" 0 "phenotype/custom-happy"
  assert_order "$log" "phenotype/custom-happy" \
    "load_csv --file $FIX/allConcepts.csv --heap 4096" \
    "load_dictionary_csv --datasets $FIX/datasets.csv --concepts $FIX/concepts.zip --clear" \
    "load_facets --categories $FIX/facet_categories.csv --facets $FIX/facets.csv --concepts $FIX/facet_concepts.csv" \
    "run_weights"
}

# (f) --skip-weights omits run_weights.
test_phenotype_skip_weights() {
  local log="$TEST_ROOT/f.log" rc
  rc="$(run_orchestrator "$log" load_phenotype \
    --file "$FIX/allConcepts.csv" --skip-weights)"
  assert_exit "$rc" 0 "phenotype/skip-weights"
  assert_order "$log" "phenotype/skip-weights" \
    "load_csv --file $FIX/allConcepts.csv --heap 4096" \
    "hydrate_dictionary --clear"
}

# ===========================================================================
# load-genomic
# ===========================================================================

# (g) bad partition -> exit 1, no load_vcf.
test_genomic_bad_partition() {
  local log="$TEST_ROOT/g.log" rc
  rc="$(run_orchestrator "$log" load_genomic \
    --partition 'bad partition!' --vcf-index "$FIX/vcfIndex.tsv")"
  assert_exit "$rc" 1 "genomic/bad-partition"
  assert_no_invocations "$log" "genomic/bad-partition"
}

# (h) happy + --promote + --enable-profile -> load_vcf, promote_genomic
#     --backup-current-data, env-set HPDS_PROFILE bch-dev, compose restart hpds.
test_genomic_full_happy() {
  local log="$TEST_ROOT/h.log" rc
  rc="$(run_orchestrator "$log" load_genomic \
    --partition chr1 --vcf-index "$FIX/vcfIndex.tsv" --vcf-dir "$FIX/vcfdir" \
    --promote --enable-profile)"
  assert_exit "$rc" 0 "genomic/full-happy"
  assert_order "$log" "genomic/full-happy" \
    "load_vcf --partition chr1 --vcf-index $FIX/vcfIndex.tsv --heap 16000 --vcf-dir $FIX/vcfdir" \
    "promote_genomic --backup-current-data" \
    "env-set HPDS_PROFILE bch-dev" \
    "compose restart hpds"
}

# (i) --promote omitted -> no promote_genomic. (also: --enable-profile alone
#     warns about the crash-loop risk; assert the warning surfaced.)
test_genomic_no_promote() {
  local log="$TEST_ROOT/i.log" rc
  rc="$(run_orchestrator "$log" load_genomic \
    --partition chr1 --vcf-index "$FIX/vcfIndex.tsv" --enable-profile)"
  assert_exit "$rc" 0 "genomic/no-promote"
  if grep -q "promote_genomic" "$log"; then
    fail "genomic/no-promote: promote_genomic fired without --promote"
  fi
  pass "genomic/no-promote: promote_genomic did not fire"
  assert_order "$log" "genomic/no-promote" \
    "load_vcf --partition chr1 --vcf-index $FIX/vcfIndex.tsv --heap 16000" \
    "env-set HPDS_PROFILE bch-dev" \
    "compose restart hpds"
  # warn() writes to stdout (only error() goes to stderr in common.sh).
  grep -q "crash-loop" "$log.out" \
    || fail "genomic/no-promote: expected a crash-loop warning for --enable-profile without --promote"
  pass "genomic/no-promote: crash-loop warning surfaced"
}

# Belt-and-suspenders: across every case above, the PATH shims must never have
# recorded a real docker/unzip call (the atomic ops were all overridden).
test_no_real_tool_calls() {
  if [ -s "$TEST_ROOT/path-shim.log" ]; then
    echo "[etl-orch-test] --- path-shim.log ---" >&2
    cat "$TEST_ROOT/path-shim.log" >&2
    fail "global: a real docker/unzip call escaped the overrides"
  fi
  pass "global: no real docker/unzip call escaped the overrides"
}

test_phenotype_missing_file
test_phenotype_custom_missing_datasets
test_phenotype_facets_partial
test_phenotype_auto_happy
test_phenotype_custom_happy
test_phenotype_skip_weights
test_genomic_bad_partition
test_genomic_full_happy
test_genomic_no_promote
test_no_real_tool_calls

echo "[etl-orch-test] complete"
