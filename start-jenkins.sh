#!/usr/bin/env bash
sudo docker run -d -rm \
-v /var/jenkins_home/jobs:/var/jenkins_home/jobs \
-v /var/run/docker.sock:/var/run/docker.sock \
-p 8080:8080 --name jenkins --restart always pic-sure-jenkins:LATEST
