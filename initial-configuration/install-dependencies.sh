#!/usr/bin/env bash
echo "Starting update"
yum -y update 

echo "Finished update, adding epel, docker-ce, mysql-community-release repositories and installing wget and yum-utils"
yum -y install epel-release wget yum-utils
yum-config-manager  --add-repo https://download.docker.com/linux/centos/docker-ce.repo
wget http://repo.mysql.com/mysql-community-release-el7-5.noarch.rpm
sudo rpm -ivh mysql-community-release-el7-5.noarch.rpm

echo "Added docker-ce repo, starting docker install"
yum -y install docker-ce docker-ce-cli containerd.io

echo "Finished docker install, enabling and starting docker service"
systemctl enable docker
service docker start

echo "Installing MySQL"
yum -y install mysql-server
systemctl start mysqld

echo "Building and installing Jenkins"
docker build -t jenkins:`git log -n 1 | grep commit | cut -d ' ' -f 2 | cut -c 1-7` jenkins/jenkins-docker

echo "Creating Jenkins Log Path"
sudo mkdir -p /var/log/jenkins-docker-logs
