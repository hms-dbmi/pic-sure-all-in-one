#!/usr/bin/env bash
DOCKER_CONFIG_DIR="${DOCKER_CONFIG_DIR:-/usr/local/docker-config}"
MY_SQL_DIR="${MY_SQL_DIR:-/root/}"

if [ -f $DOCKER_CONFIG_DIR/setProxy.sh ]; then
   . $DOCKER_CONFIG_DIR/setProxy.sh
fi

docker stop jenkins && docker rm jenkins
docker run -d \
  -e http_proxy="$http_proxy" \
  -e https_proxy="$https_proxy" \
  -e no_proxy="$no_proxy" \
  -e DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" \
  -v /var/jenkins_cert:/var/jenkins_cert \
  -v "$DOCKER_CONFIG_DIR"/hpds_csv/:/usr/local/docker-config/hpds_csv/ \
  -v /var/jenkins_home:/var/jenkins_home \
  -v ./start-picsure.sh:/scripts/start-picsure.sh \
  -v ./stop-picsure.sh:/scripts/stop-picsure.sh \
  -v "$DOCKER_CONFIG_DIR":/usr/local/docker-config \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$MYSQL_CONFIG_DIR"/.my.cnf:/root/.my.cnf \
  -v "$HOME"/.m2:/root/.m2 \
  -v /etc/hosts:/etc/hosts \
  -v /usr/local/pic-sure-services:/pic-sure-services \
  -p 8080:8080 --name jenkins pic-sure-jenkins:LATEST
