#!/bin/bash

CWD=`pwd`
export JENKINS_HOME=/var/jenkins_home
export JENKINS_WAR=jenkins.war
export JAVA_HOME=/usr/bin/java
export JENKINS_UC=https://updates.jenkins.io
export COPY_REFERENCE_FILE_LOG=/var/jenkins_home/copy_reference_file.log
export JENKINS_UC_EXPERIMENTAL=https://updates.jenkins.io/experimental
export JENKINS_INCREMENTALS_REPO_MIRROR=https://repo.jenkins-ci.org/incrementals

mkdir -p /var/log/jenkins

cd $CWD/jenkins/jenkins-docker

cp plugins.txt /usr/share/jenkins/ref/plugins.txt

cd /var/jenkins_home/jobs
sed -i 's:docker run:docker run --privileged:g' */config.xml
sed -i 's:--network=picsure -v:--privileged --network=picsure -v:g' */config.xml
cd $CWD
echo "Downloading jenins Plugins"
wget https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/2.12.3/jenkins-plugin-manager-2.12.3.jar
#/usr/local/bin/install-plugins.sh < /usr/share/jenkins/ref/plugins.txt || echo "Some errors occurred during plugin installation."
java -jar $CWD/jenkins-plugin-manager-*.jar --war $CWD/jenkins.war -d /var/jenkins_home/plugins  --plugin-file $CWD/jenkins/jenkins-docker/plugins.txt --verbose
echo "Starting Jenkins Locally"
nohup java -Duser.home="$JENKINS_HOME" -Djenkins.model.Jenkins.slaveAgentPort=50000 -jar ${JENKINS_WAR} --logfile=/var/log/jenkins/jenkins.log &
echo "Jenkins Startup completed checkikng jeknins process"
ps -aef|grep jenkins
echo "all done"
