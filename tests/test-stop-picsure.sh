#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'find "$test_dir" -depth -delete' EXIT

config_dir="$test_dir/config"
fake_bin="$test_dir/bin"
mkdir -p "$config_dir/hpds" "$config_dir/dictionary/dump" "$config_dir/logging" "$config_dir/visualization" "$config_dir/gateway" "$config_dir/operations" "$config_dir/query" "$fake_bin"

cat > "$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "container" ] && [ "$2" = "inspect" ]; then
  exit 1
fi
exit 1
EOF
chmod +x "$fake_bin/docker"

set +e
PATH="$fake_bin:$PATH" DOCKER_CONFIG_DIR="$config_dir" CURRENT_FS_DOCKER_CONFIG_DIR="$config_dir" "$repo_dir/stop-picsure.sh" >"$test_dir/output.log" 2>&1
status=$?
set -e

if [ "$status" -ne 0 ]; then
  echo "Expected stop-picsure.sh to succeed when configured containers do not exist" >&2
  cat "$test_dir/output.log" >&2
  exit 1
fi

echo "stop-picsure.sh missing-container check passed"
