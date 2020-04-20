#!/usr/bin/env bash
sudo docker run -d \
-v /var/jenkins_home/jobs:/var/jenkins_home/jobs \
-v /var/jenkins_home/config.xml:/var/jenkins_home/config.xml \
-v /var/jenkins_home/scriptApproval.xml:/var/jenkins_home/scriptApproval.xml \
-v /usr/local/docker-config:/usr/local/docker-config \
-v /var/run/docker.sock:/var/run/docker.sock \
-v /root/.my.cnf:/root/.my.cnf \
-p 8080:8080 --name jenkins --restart always pic-sure-jenkins:LATEST
