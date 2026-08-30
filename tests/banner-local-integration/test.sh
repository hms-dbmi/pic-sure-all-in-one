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

for variable in \
  BANNER_LOCAL_BACKEND_ROOT \
  BANNER_LOCAL_FRONTEND_ROOT \
  BANNER_LOCAL_MIGRATIONS_ROOT \
  BANNER_LOCAL_RELEASE_CONTROL_ROOT; do
  [[ -n "${!variable:-}" ]] || {
    echo "$variable must point to its exact clean integration root" >&2
    exit 2
  }
done

temp_parent=${TMPDIR:-/tmp}
temp_root=$(mktemp -d "$temp_parent/banner-local-XXXXXXXX")
run_id="proof$PPID$$"

cleanup() {
  local status=$?
  "$test_dir/cleanup-resources.sh" "$run_id" || status=$?
  rm -rf -- "$temp_root"
  exit "$status"
}
trap cleanup EXIT INT TERM

"$test_dir/test-cleanup.sh"
python3 "$test_dir/run.py" "$repo_root" "$temp_root" "$run_id"
"$test_dir/cleanup-resources.sh" "$run_id"
python3 "$test_dir/run.py" --finalize "$repo_root" "$temp_root/observed-result.json"
trap - EXIT INT TERM
rm -rf -- "$temp_root"
