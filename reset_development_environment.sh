#!/bin/bash

# Check if DOCKER_CONFIG_DIR is set, if not, use default
if [ -z "$DOCKER_CONFIG_DIR" ]; then
  echo "DOCKER_CONFIG_DIR is not set. Defaulting to /var/local/docker-config."
  DOCKER_CONFIG_DIR="/var/local/docker-config"
else
  echo "DOCKER_CONFIG_DIR is set to $DOCKER_CONFIG_DIR"
fi

# Ensure DOCKER_CONFIG_DIR is not set to root "/"
if [ "$DOCKER_CONFIG_DIR" = "/" ]; then
  echo "Error: DOCKER_CONFIG_DIR is set to root '/'. Aborting to prevent system damage."
  exit 1
fi

#$MYSQL_CONFIG_DIR
if [ -z "$MYSQL_CONFIG_DIR" ]; then
  echo "MYSQL_CONFIG_DIR is not set. Defaulting to $DOCKER_CONFIG_DIR."
  MYSQL_CONFIG_DIR="$DOCKER_CONFIG_DIR"
else
  echo "MYSQL_CONFIG_DIR is set to $MYSQL_CONFIG_DIR"
fi

# Ensure DOCKER_CONFIG_DIR is not set to root "/"
if [ "$DOCKER_CONFIG_DIR" = "/" ]; then
  echo "Error: DOCKER_CONFIG_DIR is set to root '/'. Aborting to prevent system damage."
  exit 1
fi

# Step 1: Run stop-picsure.sh
echo "Stopping PIC-SURE..."
./stop-picsure.sh

# Step 2: Run stop-jenkin.sh
echo "Stopping Jenkins..."
./stop-jenkin.sh

# Step 3: Stop and remove the picsure-db container
echo "Stopping and removing PIC-SURE database container..."
docker stop picsure-db
docker rm picsure-db

# Step 4: Run docker system prune -a
echo "Pruning Docker system and removing all images..."
docker system prune -a -f

# Step 5: Clear the MYSQL_CONFIG_DIR
echo "Clearing the MySQL configuration directory..."
rm -rf "$MYSQL_CONFIG_DIR/*"

# Step 6: Clear the DOCKER_CONFIG_DIR
echo "Clearing the Docker configuration directory..."
rm -rf "$DOCKER_CONFIG_DIR/*"

# Step 7: Remove the jenkins_home directory and recreate necessary directories
echo "Removing and recreating Jenkins and log directories..."
sudo rm -rf /var/jenkins_home
sudo rm -rf /var/log/jenkins-docker-logs
sudo rm -rf /var/jenkins_home_bak

sudo mkdir -p /var/log/jenkins-docker-logs
sudo mkdir -p /var/jenkins_home
sudo mkdir -p /var/jenkins_home_bak
sudo mkdir -p /var/log/httpd-docker-logs/ssl_mutex

# Step 8: Set permissions for the directories
echo "Setting permissions for Jenkins and log directories..."
sudo chmod -R 777 /var/jenkins_home
sudo chmod -R 777 /var/jenkins_home_bak
sudo chmod -R 777 /var/log/httpd-docker-logs

echo "All steps completed successfully."