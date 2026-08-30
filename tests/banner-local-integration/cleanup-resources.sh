#!/usr/bin/env bash
set -euo pipefail

run_id=${1:-}
[[ "$run_id" =~ ^[A-Za-z0-9]+$ ]] || { echo "cleanup run ID must be alphanumeric" >&2; exit 2; }
label="org.pic-sure.banner-local-integration=$run_id"
network="banner-local-$run_id"

for container in $(docker container ls --all --quiet --filter "label=$label"); do
  docker container rm --force "$container" >/dev/null
done
docker network rm "$network" >/dev/null 2>&1 || true
for image in $(docker image ls --quiet --filter "label=$label" | sort -u); do
  docker image rm --force "$image" >/dev/null 2>&1 || true
done

remaining=$(docker container ls --all --quiet --filter "label=$label")
networks=$(docker network ls --quiet --filter "name=^${network}$")
images=$(docker image ls --quiet --filter "label=$label")
[[ -z "$remaining$networks$images" ]] || {
  echo "cleanup left resources: containers=$remaining networks=$networks images=$images" >&2
  exit 1
}
