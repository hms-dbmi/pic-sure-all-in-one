#!/usr/bin/env bash

if [ -f /usr/local/docker-config/setProxy.sh ]; then
   . /usr/local/docker-config/setProxy.sh
fi

if ! docker network inspect selenium > /dev/null 2>&1; then
  docker network create selenium
fi

docker run -d \
  -e http_proxy=$http_proxy \
  -e https_proxy=$https_proxy \
  -e no_proxy=$no_proxy \
  -v /var/jenkins_cert:/var/jenkins_cert \
  -v /var/jenkins_home:/var/jenkins_home \
  -v /usr/local/docker-config:/usr/local/docker-config \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /root/.my.cnf:/root/.my.cnf \
  -v /root/.m2:/root/.m2 \
  -v /etc/hosts:/etc/hosts \
  -v /usr/local/pic-sure-services:/pic-sure-services \
  -e JENKINS_OPTS="$JENKINS_OPTS_STR" \
  --network selenium \
  -p 8080:8080 --name jenkins pic-sure-jenkins:LATEST

# These would normally be volume mounts, but mounting volumes in volumes is bad vibes
# and it was breaking the backup logic in update-jenkins
docker exec jenkins mkdir -p /var/jenkins_home/workspace/Start\ PIC-SURE
docker exec jenkins mkdir -p /var/jenkins_home/workspace/Stop\ PIC-SURE
# Docker cp doesn't add parent dirs. Not even an option. Thanks, I guess?
docker cp start-picsure.sh jenkins:/var/jenkins_home/workspace/Start\ PIC-SURE/start-picsure.sh
docker cp stop-picsure.sh jenkins:/var/jenkins_home/workspace/Stop\ PIC-SURE/stop-picsure.sh

docker restart jenkins
