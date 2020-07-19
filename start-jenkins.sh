#!/usr/bin/env bash

if [ -f "~/setProxy.sh" ]; then
   . ~/setProxy.sh
fi

docker run -d \
-e http_proxy=$http_proxy
-e https_proxy=$https_proxy
-e no_proxy=$no_proxy
-v /var/jenkins_home:/var/jenkins_home \
-v /usr/local/docker-config:/usr/local/docker-config \
-v /var/run/docker.sock:/var/run/docker.sock \
-v /root/.my.cnf:/root/.my.cnf \
-v /root/.m2:/root/.m2 \
-p 8080:8080 --name jenkins pic-sure-jenkins:LATEST
docker restart jenkins
