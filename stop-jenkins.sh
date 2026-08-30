#!/usr/bin/env bash
inspect_output=$(docker container inspect jenkins 2>&1)
inspect_status=$?
if (( inspect_status != 0 )); then
  if [[ "$inspect_output" == *"No such container: jenkins"* ]]; then
    exit 0
  fi
  printf '%s\n' "$inspect_output" >&2
  exit "$inspect_status"
fi
docker stop jenkins && docker rm jenkins
