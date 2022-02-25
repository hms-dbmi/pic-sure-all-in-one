#!/usr/bin/env bash

CWD=`pwd`

mkdir -p /usr/local/docker-config
cp -r config/* /usr/local/docker-config/

echo "Starting update"
#yum -y update

echo "Finished update, adding epel, docker-ce, mysql-community-release repositories and installing wget and yum-utils"
#yum -y install epel-release wget yum-utils
yum -y install dnf-utils wget
#yum-config-manager  --add-repo https://download.docker.com/linux/centos/docker-ce.repo
rpm --import https://repo.mysql.com/RPM-GPG-KEY-mysql-2022
wget http://repo.mysql.com/mysql57-community-release-el7-9.noarch.rpm
#yum localinstall -y mysql57-community-release-el7-9.noarch.rpm --nogpgcheck --allowerasing
rpm -ivh mysql57-community-release-el7-9.noarch.rpm
#yum-config-manager --disable mysql56-community
yum-config-manager --disable mysql80-community
yum-config-manager --enable mysql57-community
yum module disable mysql;
yum clean packages
#################echo "Added docker-ce repo, starting docker install"
echo "install container-tools podman podman-docker"

########yum -y install docker-ce docker-ce-cli containerd.io
dnf module install -y container-tools:rhel8
yum install -y podman podman-remote
systemctl enable --now podman.socket
yum install -y podman-docker
#echo "Finished podman install, enabling and starting podman-remote service"
##############systemctl enable docker
##############service docker start
echo "alias docker=podman" >> ~/.bash_profile
source ~/.bash_profile
echo "Installing MySQL"
yum -y install mysql-community-server
echo  "Creating picsure docker network"
podman network create podman
podman network create --subnet 172.18.0.0/16 --gateway 172.18.0.1 picsure
#export DOCKER_NETWORK_IF=br-`docker network create picsure | cut -c1-12`
docker run -it --rm hello-world
docker run -it --rm  --name test1 --network=picsure hello-world
firewall-cmd --add-port={80/tcp,443/tcp,8080/tcp,3306/tcp}
firewall-cmd --runtime-to-permanent
podman network reload --all
firewall-cmd --reload
systemctl daemon-reload
echo "Configuring mysql cnf file"
echo "bind-address=0.0.0.0" >> /etc/my.cnf
echo "default-time-zone='-00:00'" >> /etc/my.cnf
systemctl start mysqld
#systemctl status mysqld
echo "[mysql]" > ~/.my.cnf
echo "user = root" >> ~/.my.cnf
echo "password = `grep "temporary password" /var/log/mysqld.log | cut -d ' ' -f 11`" >> ~/.my.cnf
echo "port = 3306" >> ~/.my.cnf
echo "host = 0.0.0.0" >> ~/.my.cnf
echo "` < /dev/urandom tr -dc @^=+$*%_A-Z-a-z-0-9 | head -c${1:-24}`%4cA" > pass.tmp
mysql -u root --connect-expired-password -e "alter user 'root'@'localhost' identified by '`cat pass.tmp`';flush privileges;"
sed -i "s/password = .*/password = \"`cat pass.tmp`\"/g" ~/.my.cnf

for addr in $(ifconfig | grep netmask | sed 's/  */ /g'| cut -d ' ' -f 3);
do
 mysql -u root -e "grant all privileges on *.* to 'root'@'$addr' identified by '`cat pass.tmp`';flush privileges;";
done

rm -f pass.tmp

mysql -u root -e "create database picsure"
mysql -u root -e "create database auth"

echo "` < /dev/urandom tr -dc @^=+$*%_A-Z-a-z-0-9 | head -c${1:-24}`%4cA" > airflow.tmp
mysql -u root -e "grant all privileges on auth.* to 'airflow'@'%' identified by '`cat airflow.tmp`';flush privileges;";
mysql -u root -e "grant all privileges on picsure.* to 'airflow'@'%' identified by '`cat airflow.tmp`';flush privileges;";
sed -i s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g /usr/local/docker-config/flyway/auth/flyway-auth.conf
sed -i s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g /usr/local/docker-config/flyway/auth/sql.properties
sed -i s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g /usr/local/docker-config/flyway/picsure/flyway-picsure.conf
sed -i s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g /usr/local/docker-config/flyway/picsure/sql.properties
rm -f airflow.tmp

echo "` < /dev/urandom tr -dc @^=+$*%_A-Z-a-z-0-9 | head -c${1:-24}`%4cA" > picsure.tmp
mysql -u root -e "grant all privileges on picsure.* to 'picsure'@'%' identified by '`cat picsure.tmp`';flush privileges;";
sed -i s/__PIC_SURE_MYSQL_PASSWORD__/`cat picsure.tmp`/g /usr/local/docker-config/wildfly/standalone.xml
rm -f picsure.tmp

echo "` < /dev/urandom tr -dc @^=+$*%_A-Z-a-z-0-9 | head -c${1:-24}`%4cA" > auth.tmp
mysql -u root -e "grant all privileges on auth.* to 'auth'@'%' identified by '`cat auth.tmp`';flush privileges;";
sed -i s/__AUTH_MYSQL_PASSWORD__/`cat auth.tmp`/g /usr/local/docker-config/wildfly/standalone.xml
rm -f auth.tmp
echo "Mysql setup completed"
echo "Building and installing Jenkins"
docker build --build-arg http_proxy=$http_proxy --build-arg https_proxy=$http_proxy --build-arg no_proxy="$no_proxy" \
  --build-arg HTTP_PROXY=$http_proxy --build-arg HTTPS_PROXY=$http_proxy --build-arg NO_PROXY="$no_proxy" \
  -t pic-sure-jenkins:`git log -n 1 | grep commit | cut -d ' ' -f 2 | cut -c 1-7` jenkins/jenkins-docker
docker tag pic-sure-jenkins:`git log -n 1 | grep commit | cut -d ' ' -f 2 | cut -c 1-7` pic-sure-jenkins:LATEST

echo "Creating Jenkins Log Path"
mkdir -p /var/log/jenkins-docker-logs
mkdir -p /var/jenkins_home
cp -r jenkins/jenkins-docker/jobs /var/jenkins_home/jobs
cp -r jenkins/jenkins-docker/config.xml /var/jenkins_home/config.xml
cp -r jenkins/jenkins-docker/hudson.tasks.Maven.xml /var/jenkins_home/hudson.tasks.Maven.xml
cp -r jenkins/jenkins-docker/scriptApproval.xml /var/jenkins_home/scriptApproval.xml
mkdir  /var/log/httpd-docker-logs/ssl_mutex

export APP_ID=`uuidgen -r`
export APP_ID_HEX=`echo $APP_ID | awk '{ print toupper($0) }'|sed 's/-//g'`
sed -i "s/__STACK_SPECIFIC_APPLICATION_ID__/$APP_ID/g" /usr/local/docker-config/httpd/picsureui_settings.json
sed -i "s/__STACK_SPECIFIC_APPLICATION_ID__/$APP_ID/g" /usr/local/docker-config/wildfly/standalone.xml

export RESOURCE_ID=`uuidgen -r`
export RESOURCE_ID_HEX=`echo $RESOURCE_ID | awk '{ print toupper($0) }'|sed 's/-//g'`
sed -i "s/__STACK_SPECIFIC_RESOURCE_UUID__/$RESOURCE_ID/g" /usr/local/docker-config/httpd/picsureui_settings.json

echo $APP_ID > /usr/local/docker-config/APP_ID_RAW
echo $APP_ID_HEX > /usr/local/docker-config/APP_ID_HEX
echo $RESOURCE_ID > /usr/local/docker-config/RESOURCE_ID_RAW
echo $RESOURCE_ID_HEX > /usr/local/docker-config/RESOURCE_ID_HEX

mkdir -p /usr/local/docker-config/hpds_csv
mkdir -p /usr/local/docker-config/hpds/all
cp allConcepts.csv.tgz /usr/local/docker-config/hpds_csv/
cd /usr/local/docker-config/hpds_csv/
tar -xvzf allConcepts.csv.tgz

echo "Installation script complete.  Staring Jenkins."
cd $CWD
../start-jenkins.sh