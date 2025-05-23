#!/usr/bin/env bash

# Optional services
[[ -d "$CURRENT_FS_DOCKER_CONFIG_DIR/hpds" ]] && INCLUDE_HPDS=true || INCLUDE_HPDS=false
echo "INCLUDE_HPDS=$INCLUDE_HPDS"
[[ -d "$CURRENT_FS_DOCKER_CONFIG_DIR/uploader" ]] && INCLUDE_UPLOADER=true || INCLUDE_UPLOADER=false
echo "INCLUDE_UPLOADER=$INCLUDE_UPLOADER"
[[ -d "$CURRENT_FS_DOCKER_CONFIG_DIR/dictionary" ]] && INCLUDE_DICTIONARY=true || INCLUDE_DICTIONARY=false
echo "INCLUDE_DICTIONARY=$INCLUDE_DICTIONARY"
[[ -d "$CURRENT_FS_DOCKER_CONFIG_DIR/dictionary/dump" ]] && INCLUDE_AGG_DICT=true || INCLUDE_AGG_DICT=false
echo "INCLUDE_AGG_DICT=$INCLUDE_AGG_DICT"
[[ -d "$CURRENT_FS_DOCKER_CONFIG_DIR/passthru" ]] && INCLUDE_PASSTHRU=true || INCLUDE_PASSTHRU=false
echo "INCLUDE_PASSTHRU=$INCLUDE_PASSTHRU"

if $INCLUDE_HPDS; then
  docker stop hpds && docker rm hpds
fi
docker stop httpd && docker rm httpd
docker stop wildfly && docker rm wildfly
docker stop psama && docker rm psama

if $INCLUDE_UPLOADER; then
  docker compose --profile production -f $CURRENT_FS_DOCKER_CONFIG_DIR/uploader/docker-compose.yml down
fi
if $INCLUDE_DICTIONARY; then
  docker stop dictionary-api && docker rm dictionary-api
fi
if $INCLUDE_AGG_DICT; then
  docker stop dictionary-dump && docker rm dictionary-dump
fi
if $INCLUDE_PASSTHRU; then
  docker stop passthru && docker rm passthru
fi
