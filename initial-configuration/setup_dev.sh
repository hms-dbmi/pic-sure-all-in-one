#!/bin/bash
DOCKER_CONFIG_DIR="$1"

mkdir -p "$DOCKER_CONFIG_DIR"
sudo mkdir -p "$DOCKER_CONFIG_DIR"/log/jenkins-docker-logs
sudo mkdir -p "$DOCKER_CONFIG_DIR"/jenkins_home
sudo mkdir -p "$DOCKER_CONFIG_DIR"/jenkins_cert

# Set appropriate permissions for Jenkins directories
sudo chmod 777 "$DOCKER_CONFIG_DIR"/jenkins_home
sudo chmod 777 "$DOCKER_CONFIG_DIR"/log/jenkins-docker-logs
sudo chmod 777 "$DOCKER_CONFIG_DIR"/jenkins_cert

# Set ownership for Jenkins directories
sudo chown -R $(whoami):$(id -gn) "$DOCKER_CONFIG_DIR"/jenkins_home
sudo chown -R $(whoami):$(id -gn) "$DOCKER_CONFIG_DIR"/log/jenkins-docker-logs
sudo chown -R $(whoami):$(id -gn) "$DOCKER_CONFIG_DIR"/jenkins_cert

# Create and set ownership for picsure-db directory
mkdir -p "$DOCKER_CONFIG_DIR"/picsure-db
chown $(whoami):$(id -gn) "$DOCKER_CONFIG_DIR"/picsure-db