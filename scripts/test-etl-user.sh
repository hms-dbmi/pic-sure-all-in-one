#!/usr/bin/env bash
# Exercise all nine real ETL invocation paths with synthetic inputs and Docker
# replaced at the process boundary. Other images must retain their own user.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/picsure-etl-user.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/repo/scripts/lib" "$TEST_ROOT/repo/config/hpds" \
  "$TEST_ROOT/repo/config/dictionary" "$TEST_ROOT/repo/.data" "$TEST_ROOT/input"
cp "$ROOT/load-demo-data.sh" "$TEST_ROOT/repo/"
cp "$ROOT/scripts/picsure-compose.sh" "$TEST_ROOT/repo/scripts/"
cp "$ROOT/scripts/lib/common.sh" "$ROOT/scripts/lib/etl.sh" "$TEST_ROOT/repo/scripts/lib/"
printf 'synthetic-key\n' > "$TEST_ROOT/repo/config/hpds/encryption_key"
printf 'POSTGRES_PASSWORD=synthetic\n' > "$TEST_ROOT/repo/config/dictionary/dictionary.env"
printf 'PATIENT_NUM,CONCEPT_PATH,NVAL_NUM,TVAL_CHAR\n1,\\demo\\,1,,\n' > "$TEST_ROOT/repo/.data/allConcepts.csv"
printf 'nhanes\n' > "$TEST_ROOT/repo/.data/allConcepts.dataset"
printf 'synthetic\n' > "$TEST_ROOT/input/data"
ETL_CAPTURE="$TEST_ROOT/docker.log"
export ETL_CAPTURE
cat > "$TEST_ROOT/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
etl=false; user=''; loader=''
for arg in "$@"; do
  case "$arg" in hms-dbmi/pic-sure-hpds-etl:*) etl=true ;; LOADER_NAME=*) loader="${arg#*=}" ;; esac
done
prev=''
for arg in "$@"; do
  [ "$prev" != --user ] || user="$arg"
  prev="$arg"
done
if [ "${1:-}" = run ]; then
  if [ "$etl" = true ]; then
    [ "$user" = "$EXPECTED_ETL_USER" ] || { echo "ETL user mismatch" >&2; exit 91; }
    printf '%s:%s\n' "$loader" "$user" >> "$ETL_CAPTURE"
    [ "${FAIL_ETL:-false}" != true ] || exit 17
  else
    [ -z "$user" ] || { echo "Non-ETL user was changed" >&2; exit 92; }
  fi
fi
case "${1:-}" in
  inspect|compose) echo healthy ;;
  logs) echo 'Started DictionaryEtlApplication' ;;
esac
SH
chmod +x "$TEST_ROOT/bin/docker"
PATH="$TEST_ROOT/bin:$PATH"
export PATH

for expected in 0:0 1234:5678; do
  : > "$ETL_CAPTURE"
  EXPECTED_ETL_USER="$expected"
  export EXPECTED_ETL_USER
  (
    # shellcheck source=etl.sh
    source "$ROOT/etl.sh"
    SCRIPT_DIR="$TEST_ROOT/repo"
    if [ "$expected" = 0:0 ]; then unset ETL_RUN_AS; else ETL_RUN_AS="$expected"; fi
    # shellcheck disable=SC2329
    ensure_image() { :; }
    # shellcheck disable=SC2329
    stop_hpds() { :; }
    # shellcheck disable=SC2329
    start_hpds() { :; }
    # shellcheck disable=SC2329
    copy_hpds_key() { :; }
    # shellcheck disable=SC2329
    start_dictionary_etl() { :; }
    # shellcheck disable=SC2329
    stop_dictionary_etl() { :; }
    # shellcheck disable=SC2329
    curl_data() { :; }
    load_csv --file "$TEST_ROOT/input/data"
    load_multiple --input-dir "$TEST_ROOT/input"
    load_rdbms --sql-properties "$TEST_ROOT/input/data" --query "$TEST_ROOT/input/data"
    hydrate_dictionary
    load_vcf --partition demo --vcf-index "$TEST_ROOT/input/data"
  ) > "$TEST_ROOT/etl.out" 2>&1 || { cat "$TEST_ROOT/etl.out"; exit 1; }
  [ "$(wc -l < "$ETL_CAPTURE" | tr -d ' ')" = 7 ]
  if [ "$expected" = 0:0 ]; then
    printf 'DB_MODE=local\n' > "$TEST_ROOT/repo/.env"
  else
    printf 'DB_MODE=local\nETL_RUN_AS=%s\n' "$expected" > "$TEST_ROOT/repo/.env"
  fi
  bash "$TEST_ROOT/repo/load-demo-data.sh" nhanes > "$TEST_ROOT/demo.out" 2>&1 \
    || { cat "$TEST_ROOT/demo.out"; exit 1; }
  [ "$(wc -l < "$ETL_CAPTURE" | tr -d ' ')" = 9 ]
  echo "[etl-user] all nine loaders use $expected; helper images unchanged"
done

EXPECTED_ETL_USER=1234:5678 FAIL_ETL=true bash "$TEST_ROOT/repo/load-demo-data.sh" nhanes \
  > "$TEST_ROOT/failure.out" 2>&1 && { echo 'failed loader unexpectedly succeeded' >&2; exit 1; }
grep -q 'hpds-etl-loader failed' "$TEST_ROOT/failure.out"
echo '[etl-user] demo load propagates loader failure'
