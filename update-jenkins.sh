#!/bin/bash
./stop-jenkins.sh
mkdir -p /var/jenkins_home/jobs_bak
cp -r /var/jenkins_home/jobs/* /var/jenkins_home/jobs_bak/
rm -rf /var/jenkins_home/jobs/*
cp -r initial-configuration/jenkins/jenkins-docker/jobs/* /var/jenkins_home/jobs/
docker build -t pic-sure-jenkins:`git log -n 1 | grep commit | cut -d ' ' -f 2 | cut -c 1-7` initial-configuration/jenkins/jenkins-docker
docker tag pic-sure-jenkins:`git log -n 1 | grep commit | cut -d ' ' -f 2 | cut -c 1-7` pic-sure-jenkins:LATEST
./start-jenkins.sh
