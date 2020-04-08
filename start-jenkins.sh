#!/usr/bin/env bash
sudo docker run -d \
-v /var/jenkins_home/jobs:/var/jenkins_home/jobs \
-v /var/run/docker.sock:/var/run/docker.sock \
-v /var/run/mysqld/mysqld.sock:/var/run/mysqld/mysqld.sock \
-v /root/.my.cnf:/root/.my.cnf \
-p 8080:8080 --name jenkins --restart always pic-sure-jenkins:LATEST
