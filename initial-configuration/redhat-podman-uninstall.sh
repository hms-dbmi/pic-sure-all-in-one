#!/usr/bin/env bash

echo "Checking docker status..."
systemctl is-active --quiet docker
if [ $? != "0" ]; then
        echo "Starting docker..."
        systemctl start docker
fi

# Prune docker images
containers=$(docker ps -a -q)
if [ ! -z "$containers" ]; then
        docker stop $(docker ps -a -q)
        docker rm $(docker ps -a -q)
fi
images=$(docker ps -a -q)
if [ ! -z "$images" ]; then
        docker rmi $(docker images -a -q)
fi

networks=$(docker network ls)
if [ ! -z "networks" ]; then
        docker network rm $(docker network ls)
fi
docker network prune  -f
docker volume prune  -f
docker system prune -a -f
docker system prune --volumes -f
systemctl stop podman.socket
systemctl disable podman.socket

CWD=`pwd`

cd /usr/local/docker-config
rm -rf APP_ID_HEX  APP_ID_RAW  flyway  hpds  hpds_csv  httpd  jupyterhub_config.py  RESOURCE_ID_HEX  RESOURCE_ID_RAW  setProxy.sh  wildfly
cd $CWD
yum -y remove podman-remote podman-docker podman-plugins podman
yum module remove container-tools -y
rm -rf /var/lib/docker
rm -rf /var/lib/containers
unlink /var/run/docker.sock
rm -rf /run/podman/podman.sock
rm -rf /run/podman
rm -rf /run/netns

# MySQL
systemctl stop mysqld
systemctl disable mariadb
yum -y remove  mariadb-server mysql-community-server mysql-community-client mysql-community-release
rm -f /etc/my.cnf
rm -f ~/.my.cnf
rm -rf /var/lib/mysql
rm -rf /var/jenkins_home
rm -rf /var/jenkins_home_bak
rm -rf /var/log/httpd-docker-logs
rm -rf /var/log/jenkins-docker-logs
rm -rf /var/log/wildfly-docker-logs
rm -rf /var/log/wildfly-docker-os-logs
rm -rf /var/log/mysqld.log

yum remove -y maven
rm -rf ~/.m2

systemctl stop jenkins
systemctl disable --now jenkins
rm -rf /etc/systemd/system/jenkins.service
rm -rf /etc/jenkinsconf
rm -rf /usr/share/jenkins/jenkins.war*

firewall-cmd --remove-port=8080/tcp
firewall-cmd --runtime-to-permanent
