#!/usr/bin/env bash
docker stop hpds && docker rm hpds
docker stop httpd && docker rm httpd
docker stop wildfly && docker rm wildfly
docker stop psama && docker rm psama

if [ -d $DOCKER_CONFIG_DIR/dictionary ]; then
  docker compose -f $DOCKER_CONFIG_DIR/dictionary/docker-compose.yml --env-file $DOCKER_CONFIG_DIR/dictionary/dictionary.env down
fi