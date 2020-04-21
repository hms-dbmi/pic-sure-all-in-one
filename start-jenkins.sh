#!/usr/bin/env bash
docker run -d \
-v /var/jenkins_home:/var/jenkins_home \
-v /usr/local/docker-config:/usr/local/docker-config \
-v /var/run/docker.sock:/var/run/docker.sock \
-v /root/.my.cnf:/root/.my.cnf \
-p 8080:8080 --name jenkins pic-sure-jenkins:LATEST
docker restart jenkins
