#!/usr/bin/env bash

CWD=`pwd`

mkdir -p /usr/local/docker-config
cp -r config/* /usr/local/docker-config/

echo "Starting update"
yum -y update

echo "Update yum to get correct version of MariaDB"
curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash -s -- --mariadb-server-version="mariadb-10.11.4"

yum -y install dnf-utils wget openssl tzdata-java java-11-openjdk-devel net-tools zip
rpm --import https://repo.mysql.com/RPM-GPG-KEY-mysql-2022
wget http://repo.mysql.com/mysql57-community-release-el7-9.noarch.rpm
rpm -ivh mysql57-community-release-el7-9.noarch.rpm
yum-config-manager --disable mysql80-community
yum-config-manager --enable mysql57-community
yum module disable -y mysql;
yum remove -y  java-1.8*
yum clean -y  packages

## Installing and starting Firewalld service 

yum install firewalld -y
systemctl enable --now firewalld
systemctl start firewalld

##Instaling Maven

echo "installaing maven"
wget https://downloads.apache.org/maven/maven-3/3.9.3/binaries/apache-maven-3.9.3-bin.tar.gz -P /opt
tar -xvzf /opt/apache-maven-3.9.3-bin.tar.gz -C /opt
ln -s /opt/apache-maven-3.9.3 /opt/apache-maven
rm -rf /opt/apache-maven-3.9.3-bin.tar.gz

## Emulating Docker CLI using podman.

# Installing continer tools, podman services to build and run containers.
echo "install container-tools podman podman-docker podman-plugins"
dnf module reset -y container-tools
dnf module install -y container-tools:4.0
yum install -y podman-docker podman-plugins
yum install -y podman-compose-0.1.7
echo "Finished podman install, enabling and starting podman required service"

# Symlink docker to podman so we can emultate system wide.
# Sometimes, ~/.bash_profile nor ~/.bashrc aliases were getting sourced in jenkins shell processes.
ln -s "$(which podman)" /bin/docker

# Create /etc/containers/nodocker to quiet msg.
mkdir -p /etc/containers/nodocker

## Creating Podman networks 

echo  "Creating picsure, hpdsNet podman network"
docker network inspect podman --format "{{.Name}}: {{.Id}}" 2>&1  ||  docker network create podman
docker network inspect picsure --format "{{.Name}}: {{.Id}}" 2>&1  ||  docker network create picsure
docker network inspect hpdsNet --format "{{.Name}}: {{.Id}}" 2>&1  ||  docker network create hpdsNet

# Run docker using networks to ensure their network interface is up and can be added to the mysql database by interface ip
docker run -it --rm  --name test1 --network=podman hello-world
docker run -it --rm  --name test2 --network=picsure hello-world
docker run -it --rm  --name test3 --network=hpdsNet hello-world

setenforce 0
firewall-cmd --add-port=8080/tcp
firewall-cmd --runtime-to-permanent
podman network reload --all
firewall-cmd --reload
systemctl daemon-reload
setenforce 1

##Installing Configuring MariaDB/Mysql configuration

echo "Installing MySQL/MariaDB"
yum -y install mariadb-server

echo "Support MySQL command references"
echo "alias mysql=mariadb" >> ~/.bash_profile
source ~/.bash_profile

echo "Configuring mysql cnf file"
echo "[mysqld]" >> /etc/my.cnf
echo "bind-address=0.0.0.0" >> /etc/my.cnf
echo "default-time-zone='-00:00'" >> /etc/my.cnf

systemctl enable --now mariadb.service
systemctl start mariadb.service

echo "` < /dev/urandom tr -dc @^=+$*%_A-Z-a-z-0-9 | head -c${1:-24}`%4cA" > pass.tmp
mariadb -u root --connect-expired-password -e "ALTER USER root@localhost IDENTIFIED BY '`cat pass.tmp`';flush privileges;"

echo "[mysql]" > ~/.my.cnf
echo "user = root" >> ~/.my.cnf
echo "password = `cat pass.tmp`" >> ~/.my.cnf
echo "port = 3306" >> ~/.my.cnf
echo "host = 0.0.0.0" >> ~/.my.cnf

for addr in $(ifconfig | grep netmask | sed 's/  */ /g' | cut -d ' ' -f 3); do
  newaddr=$(awk -F"." '{print $1"."$2"."$3".%"}' <<< $addr)
  mariadb -u root -e "grant all privileges on *.* to 'root'@'$newaddr' identified by '`cat pass.tmp`'  WITH GRANT OPTION;flush privileges;";
done

MYSQL_PASSWORD=`cat pass.tmp`

rm -f pass.tmp

mariadb -u root -e "create database picsure"
mariadb -u root -e "create database auth"

echo "` < /dev/urandom tr -dc @^=+$*%_A-Z-a-z-0-9 | head -c${1:-24}`%4cA" > airflow.tmp
mariadb -u root -e "grant all privileges on auth.* to 'airflow'@'%' identified by '`cat airflow.tmp`';flush privileges;";
mariadb -u root -e "grant all privileges on picsure.* to 'airflow'@'%' identified by '`cat airflow.tmp`';flush privileges;";
sed -i s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g /usr/local/docker-config/flyway/auth/flyway-auth.conf
sed -i s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g /usr/local/docker-config/flyway/auth/sql.properties
sed -i s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g /usr/local/docker-config/flyway/picsure/flyway-picsure.conf
sed -i s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g /usr/local/docker-config/flyway/picsure/sql.properties
rm -f airflow.tmp

echo "` < /dev/urandom tr -dc @^=+$*%_A-Z-a-z-0-9 | head -c${1:-24}`%4cA" > picsure.tmp
mariadb -u root -e "grant all privileges on picsure.* to 'picsure'@'%' identified by '`cat picsure.tmp`';flush privileges;";
sed -i s/__PIC_SURE_MYSQL_PASSWORD__/`cat picsure.tmp`/g /usr/local/docker-config/wildfly/standalone.xml
rm -f picsure.tmp

echo "` < /dev/urandom tr -dc @^=+$*%_A-Z-a-z-0-9 | head -c${1:-24}`%4cA" > auth.tmp
mariadb -u root -e "grant all privileges on auth.* to 'auth'@'%' identified by '`cat auth.tmp`';flush privileges;";
sed -i s/__AUTH_MYSQL_PASSWORD__/`cat auth.tmp`/g /usr/local/docker-config/wildfly/standalone.xml
rm -f auth.tmp
## Configuring picsure-specif network and replacing docker specific ip address configurations in standaolne.xml #########################
echo "update MySql Instance configuration related to podman network"
FILE="/root/.my.cnf"
MYSQL_USER_NAME=root
MYSQL_HOST_NAME=10.89.0.1
MYSQL_PORT=3306
cat <<EOM >$FILE
[mysql]
user=$MYSQL_USER_NAME
password="$MYSQL_PASSWORD"
host=$MYSQL_HOST_NAME
port=$MYSQL_PORT
EOM
echo ""


flyway_auth_url=jdbc:mysql://$MYSQL_HOST_NAME:$MYSQL_PORT/auth?serverTimezone=UTC
flyway_picsure_url=jdbc:mysql://$MYSQL_HOST_NAME:$MYSQL_PORT/picsure?serverTimezone=UTC


cd /usr/local/docker-config/flyway/auth
sed -i '/flyway.url/d' ./flyway-auth.conf
sed -i "1iflyway.url=$flyway_auth_url" ./flyway-auth.conf
sed -i '/host/d' ./sql.properties
sed -i "1ihost=$MYSQL_HOST_NAME" ./sql.properties
sed -i '/port/d' ./sql.properties
sed -i "2iport=$MYSQL_PORT" ./sql.properties

cd /usr/local/docker-config/flyway/picsure
sed -i '/flyway.url/d' ./flyway-picsure.conf
sed -i "1iflyway.url=$flyway_picsure_url" ./flyway-picsure.conf
sed -i '/host/d' ./sql.properties
sed -i "1ihost=$MYSQL_HOST_NAME" ./sql.properties
sed -i '/port/d' ./sql.properties
sed -i "2iport=$MYSQL_PORT" ./sql.properties


cd /usr/local/docker-config/wildfly
sed -i 's/jdbc:mysql*.*auth/jdbc:mysql:\/\/'$MYSQL_HOST_NAME':'$MYSQL_PORT'\/auth/g' /usr/local/docker-config/wildfly/standalone.xml
sed -i 's/jdbc:mysql*.*picsure/jdbc:mysql:\/\/'$MYSQL_HOST_NAME':'$MYSQL_PORT'\/picsure/g' /usr/local/docker-config/wildfly/standalone.xml
cd $CWD
echo "Mysql/MariaDB setup completed"

###############################
echo "Building and installing Jenkins"
#docker build --build-arg http_proxy=$http_proxy --build-arg https_proxy=$http_proxy --build-arg no_proxy="$no_proxy" \
#  --build-arg HTTP_PROXY=$http_proxy --build-arg HTTPS_PROXY=$http_proxy --build-arg NO_PROXY="$no_proxy" \
#  -t pic-sure-jenkins:`git log -n 1 | grep commit | cut -d ' ' -f 2 | cut -c 1-7` -f jenkins/jenkins-docker/ubDockerfile
#docker tag pic-sure-jenkins:`git log -n 1 | grep commit | cut -d ' ' -f 2 | cut -c 1-7` pic-sure-jenkins:LATEST

##Configuring Jenkins on local host downloading,Jenkins war and creating necessary directories 
wget https://get.jenkins.io/war-stable/2.387.1/jenkins.war
echo "Creating Jenkins Log Path"
mkdir -p /usr/share/jenkins
mkdir -p /var/log/jenkins-docker-logs
mkdir -p /var/jenkins_home
mkdir -p /var/log/jenkins

mv jenkins.war /usr/share/jenkins/jenkins.war

cp jenkinsconf /etc/jenkinsconf
cp jenkins.service /etc/systemd/system/jenkins.service
systemctl daemon-reload
systemctl enable -now jenkins
systemctl start jenkins

cp -r jenkins/jenkins-docker/jobs /var/jenkins_home/jobs
cp -r jenkins/jenkins-docker/config.xml /var/jenkins_home/config.xml
cp -r jenkins/jenkins-docker/hudson.tasks.Maven.xml /var/jenkins_home/hudson.tasks.Maven.xml
cp -r jenkins/jenkins-docker/scriptApproval.xml /var/jenkins_home/scriptApproval.xml
mkdir -p /var/log/httpd-docker-logs/ssl_mutex

export JENKINS_HOME=/var/jenkins_home
export JENKINS_WAR=jenkins.war
export JENKINS_UCi_URL=https://updates.jenkins.io
export COPY_REFERENCE_FILE_LOG=/var/jenkins_home/copy_reference_file.log
export JENKINS_UC_EXPERIMENTAL=https://updates.jenkins.io/experimental
export JENKINS_INCREMENTALS_REPO_MIRROR=https://repo.jenkins-ci.org/incrementals

mkdir -p /var/log/jenkins

cd $CWD/jenkins/jenkins-docker

cp plugins.txt /usr/share/jenkins/ref/plugins.txt
cd $CWD
echo "Downloading jenkins Plugins"
#wget https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/2.12.6/jenkins-plugin-manager-2.12.6.jar
java -jar $CWD/jenkins-plugin-manager-2.12.6.jar \
  --war /usr/share/jenkins/jenkins.war \
  -d /var/jenkins_home/plugins  \
  --plugin-file $CWD/jenkins/jenkins-docker/plugins.txt \
  --verbose
echo "Starting Jenkins Locally"

systemctl stop jenkins
systemctl start jenkins
echo "Jenkins Startup completed checking jenkins process"
ps -aef | grep jenkins

##########################################################

cd $CWD

export APP_ID=`uuidgen -r`
export APP_ID_HEX=`echo $APP_ID | awk '{ print toupper($0) }' | sed 's/-//g'`
sed -i "s/__STACK_SPECIFIC_APPLICATION_ID__/$APP_ID/g" /usr/local/docker-config/httpd/picsureui_settings.json
sed -i "s/__STACK_SPECIFIC_APPLICATION_ID__/$APP_ID/g" /usr/local/docker-config/wildfly/standalone.xml

export RESOURCE_ID=`uuidgen -r`
export RESOURCE_ID_HEX=`echo $RESOURCE_ID | awk '{ print toupper($0) }' | sed 's/-//g'`
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

echo "Installation script complete.  Started Jenkins."
