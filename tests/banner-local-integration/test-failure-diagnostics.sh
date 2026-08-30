#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
temp_parent=${TMPDIR:-/tmp}
temp_parent=${temp_parent%/}
runtime_root=$(mktemp -d "$temp_parent/banner-local-diagnostics-runtime-XXXXXXXX")
diagnostics_parent=$(mktemp -d "$temp_parent/banner-local-diagnostics-output-XXXXXXXX")
diagnostics_root="$diagnostics_parent/proof-forced"

cleanup() {
  case "$runtime_root" in
    "$temp_parent"/banner-local-diagnostics-runtime-*)
      [[ ! -d "$runtime_root" ]] || find "$runtime_root" -depth -delete
      ;;
    *) echo "Refusing to remove unexpected diagnostics test runtime: $runtime_root" >&2 ;;
  esac
  case "$diagnostics_parent" in
    "$temp_parent"/banner-local-diagnostics-output-*)
      [[ ! -d "$diagnostics_parent" ]] || find "$diagnostics_parent" -depth -delete
      ;;
    *) echo "Refusing to remove unexpected diagnostics test output: $diagnostics_parent" >&2 ;;
  esac
}
trap cleanup EXIT

mkdir -p "$runtime_root/logs"
printf '{"status":"FAIL","forced":true}\n' > "$runtime_root/failed-result.json"
printf 'synthetic forced-failure log\n' > "$runtime_root/logs/operations.log"

"$test_dir/preserve-diagnostics.sh" "$runtime_root" "$diagnostics_root"
find "$runtime_root" -depth -delete

[[ ! -e "$runtime_root" ]] || { echo "forced-failure runtime was not cleaned" >&2; exit 1; }
[[ -f "$diagnostics_root/failed-result.json" ]] || { echo "partial result was not retained" >&2; exit 1; }
[[ -f "$diagnostics_root/logs/operations.log" ]] || { echo "service log was not retained" >&2; exit 1; }
grep -q '"forced":true' "$diagnostics_root/failed-result.json"
grep -q 'synthetic forced-failure log' "$diagnostics_root/logs/operations.log"

echo "Ticket 22A forced-failure diagnostics and runtime cleanup PASS"
