#!/bin/bash
./stop-jenkins.sh
git pull

echo "Sometimes we have to update not just the Jenkins jobs, but also the docker image itself."
echo "If you want to update that image. Rerun this command with the --rebuild flag added."

DOCKER_CONFIG_DIR="${DOCKER_CONFIG_DIR:-/usr/local/docker-config}"

if [ "$1" = "--rebuild" ]; then
  #  Rebuild the docker image. This matches the initial dep script. The proxy args are generally empty, but you might
  # run into bugs if you have an http proxy, but don't set it somewhere clever like your bash profile
  cd initial-configuration
  echo "Rebuilding the Jenkins container:"
  docker build --build-arg http_proxy=$http_proxy --build-arg https_proxy=$http_proxy --build-arg no_proxy="$no_proxy" \
    --build-arg HTTP_PROXY=$http_proxy --build-arg HTTPS_PROXY=$http_proxy --build-arg NO_PROXY="$no_proxy" \
    -t pic-sure-jenkins:`git log -n 1 | grep commit | cut -d ' ' -f 2 | cut -c 1-7` jenkins/jenkins-docker
  docker tag pic-sure-jenkins:`git log -n 1 | grep commit | cut -d ' ' -f 2 | cut -c 1-7` pic-sure-jenkins:LATEST
  cd ../
fi

mkdir -p /var/jenkins_home_bak
cp -r /var/jenkins_home/* /var/jenkins_home_bak/
rm -rf /var/jenkins_home/*
cp -r initial-configuration/jenkins/jenkins-docker/jobs /var/jenkins_home/jobs
cp -r initial-configuration/jenkins/jenkins-docker/config.xml /var/jenkins_home/
cp -r initial-configuration/jenkins/jenkins-docker/scriptApproval.xml /var/jenkins_home/
cp -r initial-configuration/jenkins/jenkins-docker/hudson.tasks.Maven.xml /var/jenkins_home/hudson.tasks.Maven.xml

if [ ! -f $DOCKER_CONFIG_DIR/wildfly/mysql-connector-java-5.1.49.jar ]; then
	cp initial-configuration/config/wildfly/mysql-connector-java-5.1.49.jar $DOCKER_CONFIG_DIR/wildfly/
	cp initial-configuration/config/wildfly/wildfly_mysql_module.xml $DOCKER_CONFIG_DIR/wildfly/
fi

# Pull through previous PICSURE configurations
sed -i "s|__RELEASE_CONTROL_REPO__|`cat /var/jenkins_home_bak/config.xml | grep -A1 release_control_repo | tail -1 | sed 's/<\/*string>//g' | sed 's/ //g' `|g" /var/jenkins_home/config.xml
sed -i "s|__PROJECT_SPECIFIC_MIGRATION_NAME__|`cat /var/jenkins_home_bak/config.xml | grep -A1 migration_name | tail -1 | sed 's/<\/*string>//g' | sed 's/ //g' `|g" /var/jenkins_home/config.xml
sed -i "s|*/master|`cat /var/jenkins_home_bak/config.xml | grep -A1 release_control_branch | tail -1 | sed 's/<\/*string>//g' | sed 's/ //g' `|g" /var/jenkins_home/config.xml


./start-jenkins.sh
