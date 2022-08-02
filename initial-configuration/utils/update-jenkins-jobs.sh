#!/bin/bash

echo "Copying latest Jenkins job configurations"
cp -r /usr/local/docker-config/pic-sure-all-in-one/initial-configuration/jenkins/jenkins-docker/jobs/* /var/jenkins_home/jobs/


