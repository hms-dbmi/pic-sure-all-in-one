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
docker system prune -a --volumes -f
docker volume prune -a -f

systemctl stop docker

rm -rf $DOCKER_CONFIG_DIR

yum -y remove docker-ce docker-ce-cli containerd.io

rm -rf /var/lib/docker

systemctl disable configure_docker_networks
rm -f /etc/systemd/system/configure_docker_networks.service
rm -f /root/configure_docker_networking.sh 

# MySQL
systemctl stop mariadb
yum -y remove mariadb-server mariadb-client mariadb
rm -f /etc/my.cnf
rm -f ~/.my.cnf
rm -rf /var/lib/mysql

rm -rf "$DOCKER_CONFIG_DIR"/jenkins_home
rm -rf "$DOCKER_CONFIG_DIR"/jenkins_home_bak
rm -rf "$DOCKER_CONFIG_DIR"/log/httpd-docker-logs
rm -rf "$DOCKER_CONFIG_DIR"/log/jenkins-docker-logs
rm -rf "$DOCKER_CONFIG_DIR"/log/wildfly-docker-logs
rm -rf "$DOCKER_CONFIG_DIR"/log/wildfly-docker-os-logs
rm -rf "$DOCKER_CONFIG_DIR"/log/mysqld.log
