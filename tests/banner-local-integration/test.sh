#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_dir="$repo_root/tests/banner-local-integration"
mode=${1:-all}
export PYTHONDONTWRITEBYTECODE=1

case "$mode" in
  contract|all) ;;
  *) echo "usage: $0 [contract|all]" >&2; exit 2 ;;
esac

python3 -m unittest discover -v -s "$test_dir" -p 'test_*.py'
PYTHONOPTIMIZE=1 python3 -m unittest discover -v -s "$test_dir" -p 'test_*.py'
[[ "$mode" == contract ]] && exit 0
"$test_dir/test-failure-diagnostics.sh"

for variable in \
  BANNER_LOCAL_BACKEND_ROOT \
  BANNER_LOCAL_FRONTEND_ROOT \
  BANNER_LOCAL_MIGRATIONS_ROOT \
  BANNER_LOCAL_RELEASE_CONTROL_ROOT \
  BANNER_LOCAL_BDC_ROOT \
  BANNER_LOCAL_LEGACY_PSAMA_ROOT; do
  [[ -n "${!variable:-}" ]] || {
    echo "$variable must point to its exact clean integration root" >&2
    exit 2
  }
done

temp_parent=${TMPDIR:-/tmp}
temp_root=$(mktemp -d "$temp_parent/banner-local-XXXXXXXX")
run_id="proof$PPID$$"
diagnostics_root=${BANNER_LOCAL_DIAGNOSTICS_ROOT:-$temp_parent/banner-local-integration-diagnostics}

cleanup() {
  local original_status=$?
  local final_status=$original_status
  local cleanup_status=0
  trap - EXIT INT TERM
  if [[ $original_status -ne 0 && -d "$temp_root" ]]; then
    "$test_dir/preserve-diagnostics.sh" "$temp_root" "$diagnostics_root/$run_id" || {
      echo "Ticket 22A diagnostics preservation failed" >&2
    }
  fi
  "$test_dir/cleanup-resources.sh" "$run_id" || cleanup_status=$?
  if [[ $final_status -eq 0 && $cleanup_status -ne 0 ]]; then
    final_status=$cleanup_status
  fi
  case "$temp_root" in
    "$temp_parent"/banner-local-*) find "$temp_root" -depth -delete ;;
    *) echo "Refusing to remove unexpected runtime directory: $temp_root" >&2; final_status=2 ;;
  esac
  exit "$final_status"
}
trap cleanup EXIT INT TERM

"$test_dir/test-cleanup.sh"
python3 "$test_dir/run.py" "$repo_root" "$temp_root" "$run_id"
"$test_dir/cleanup-resources.sh" "$run_id"
python3 "$test_dir/run.py" --finalize "$repo_root" "$temp_root/observed-result.json"
trap - EXIT INT TERM
find "$temp_root" -depth -delete
