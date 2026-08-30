#!/usr/bin/env bash
if ! docker container inspect jenkins >/dev/null 2>&1; then
  exit 0
fi
docker stop jenkins && docker rm jenkins
