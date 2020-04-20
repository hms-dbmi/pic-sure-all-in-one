#!/bin/bash
./stop-jenkins.sh
mkdir -p /var/jenkins_home_bak
cp -r /var/jenkins_home/* /var/jenkins_home_bak/
rm -rf /var/jenkins_home/jobs/*
cp -r initial-configuration/jenkins/jenkins-docker/config.xml /var/jenkins_home/config.xml
cp -r initial-configuration/jenkins/jenkins-docker/scriptApproval.xml /var/jenkins_home/scriptApproval.xml
cp -r initial-configuration/jenkins/jenkins-docker/jobs/* /var/jenkins_home/jobs/
docker build -t pic-sure-jenkins:`git log -n 1 | grep commit | cut -d ' ' -f 2 | cut -c 1-7` initial-configuration/jenkins/jenkins-docker
docker tag pic-sure-jenkins:`git log -n 1 | grep commit | cut -d ' ' -f 2 | cut -c 1-7` pic-sure-jenkins:LATEST
sed -i "s|`cat /var/jenkins_home_bak/config.xml | grep -A1 project_specific_override_repo | tail -1 | sed 's/<\/*string>//g'`|$env.PROJECT_SPECIFIC_OVERRIDE_REPOSITORY|g" /var/jenkins_home/config.xml
sed -i "s|`cat /var/jenkins_home_bak/config.xml | grep -A1 release_control_repo | tail -1 | sed 's/<\/*string>//g'`|$env.RELEASE_CONTROL_REPOSITORY|g" /var/jenkins_home/config.xml
./start-jenkins.sh
