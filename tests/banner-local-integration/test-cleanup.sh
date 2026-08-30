#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
run_id="cleanup$PPID$$"
label="org.pic-sure.banner-local-integration=$run_id"
network="banner-local-$run_id"
trap '"$test_dir/cleanup-resources.sh" "$run_id" >/dev/null 2>&1 || true' EXIT

docker network create --label "$label" "$network" >/dev/null
docker run --detach --name "banner-local-$run_id-fixture" --label "$label" --network "$network" \
  busybox@sha256:dc2d74b28e4cf8984fa52af1f39bc7c3d9c73760b41a74d629f5d11b1ab28616 sleep 300 >/dev/null
"$test_dir/cleanup-resources.sh" "$run_id"
trap - EXIT
echo "PASS: forced cleanup removed every Ticket 22A resource"
