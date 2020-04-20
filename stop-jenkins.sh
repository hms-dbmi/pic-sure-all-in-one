#!/usr/bin/env bash
docker cp jenkins:/var/jenkins_home/config.xml /var/jenkins_home/config.xml
docker cp jenkins:/var/jenkins_home/scriptApproval.xml /var/jenkins_home/scriptApproval.xml
docker stop jenkins
docker rm jenkins
