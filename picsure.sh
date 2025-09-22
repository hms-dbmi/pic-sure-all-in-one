#!/usr/bin/env bash

export DOCKER_CONFIG_DIR="${DOCKER_CONFIG_DIR:-/usr/local/docker-config}"
export MYSQL_CONFIG_DIR="${MYSQL_CONFIG_DIR:-$DOCKER_CONFIG_DIR/picsure-db/}"
# Use this for file system checks. Use DOCKER_CONFIG_DIR for docker commands.
# Except for --env_file commands, which refer to the current file system, not the root fs
export CURRENT_FS_DOCKER_CONFIG_DIR="${CURRENT_FS_DOCKER_CONFIG_DIR:-$DOCKER_CONFIG_DIR}"

if [ -f "$CURRENT_FS_DOCKER_CONFIG_DIR/setProxy.sh" ]; then
   . $CURRENT_FS_DOCKER_CONFIG_DIR/setProxy.sh
fi

export COMPOSE_PROFILES="standalone"
export COMPOSE_FILES=""

if [[ "$COMPOSE_PROFILES" == *"debug"* ]];then
   export COMPOSE_FILES="-f compose.yml -f compose.debug.yml"
fi

if [[ "$1" == "start" ]]
   then MODE='up -d'
   else MODE='down'
fi

# pass in a specific service, or leave blank to start
# Example: './picsure.sh start jenkins' (starts jenkins service only)
# Example: './picsure.sh start' (starts everything)
if [[ -n "$2" ]]
  then docker compose $COMPOSE_FILES $MODE $2
  else docker compose $COMPOSE_FILES $MODE $(docker compose config --services)
fi
