#!/usr/bin/env bash
DOCKER_CONFIG_DIR="${DOCKER_CONFIG_DIR:-/usr/local/docker-config}"

if [ -f $DOCKER_CONFIG_DIR/setProxy.sh ]; then
   . $DOCKER_CONFIG_DIR/setProxy.sh
fi

docker run -d \
  -e http_proxy="$http_proxy" \
  -e https_proxy="$https_proxy" \
  -e no_proxy="$no_proxy" \
  -e DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" \
  -v /var/jenkins_cert:/var/jenkins_cert \
  -v "$DOCKER_CONFIG_DIR"/hpds_csv/:/usr/local/docker-config/hpds_csv/ \
  -v /var/jenkins_home:/var/jenkins_home \
  -v "$DOCKER_CONFIG_DIR":/usr/local/docker-config \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$HOME"/.my.cnf:/root/.my.cnf \
  -v "$HOME"/.m2:/root/.m2 \
  -v /etc/hosts:/etc/hosts \
  -v /usr/local/pic-sure-services:/pic-sure-services \
  --env-file initial-configuration/mysql-docker/.env \
  -p 8080:8080 --name jenkins pic-sure-jenkins:LATEST

# These would normally be volume mounts, but mounting volumes in volumes is bad vibes
# and it was breaking the backup logic in update-jenkins
docker exec jenkins mkdir -p /var/jenkins_home/workspace/Start\ PIC-SURE
docker exec jenkins mkdir -p /var/jenkins_home/workspace/Stop\ PIC-SURE
# Docker cp doesn't add parent dirs. Not even an option. Thanks, I guess?
docker cp start-picsure.sh jenkins:/var/jenkins_home/workspace/Start\ PIC-SURE/start-picsure.sh
docker cp stop-picsure.sh jenkins:/var/jenkins_home/workspace/Stop\ PIC-SURE/stop-picsure.sh

docker restart jenkins
