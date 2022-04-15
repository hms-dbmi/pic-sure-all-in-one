#!/usr/bin/env bash

CWD=`pwd`

mkdir -p /usr/local/docker-config
cp -r config/* /usr/local/docker-config/

echo "Starting update"
#yum -y update

echo "Finished update, adding epel, docker-ce, mysql-community-release repositories and installing wget and yum-utils"
#yum -y install epel-release wget yum-utils
yum -y install dnf-utils wget openssl java-11-openjdk
#yum-config-manager  --add-repo https://download.docker.com/linux/centos/docker-ce.repo
rpm --import https://repo.mysql.com/RPM-GPG-KEY-mysql-2022
wget http://repo.mysql.com/mysql57-community-release-el7-9.noarch.rpm
#yum localinstall -y mysql57-community-release-el7-9.noarch.rpm --nogpgcheck --allowerasing
#wget mirrors.jenkins.io/war-stable/latest/jenkins.war
rpm -ivh mysql57-community-release-el7-9.noarch.rpm
#yum-config-manager --disable mysql56-community
yum-config-manager --disable mysql80-community
yum-config-manager --enable mysql57-community
yum module disable -y mysql;
yum remove -y  java-1.8*
yum clean -y  packages
#Instaling Maven
#wget https://www.apache.org/dist/maven/maven-3/3.6.3/binaries/apache-maven-3.6.3-bin.tar.gz -P /opt
#tar -xvzf /opt/apache-maven-3.6.3-bin.tar.gz -C /opt
#rm -rf /opt/apache-maven-3.6.3-bin.tar.gz
#/opt/apache-maven-3.6.3/bin/mvn clean install
mkdir -p  /root/.m2
#################echo "Added docker-ce repo, starting docker install"
echo "install container-tools podman podman-docker"

########yum -y install docker-ce docker-ce-cli containerd.io
dnf module install -y container-tools:rhel8
yum install -y podman podman-remote
systemctl enable --now podman.socket
yum install -y podman-docker podman-plugins
#echo "Finished podman install, enabling and starting podman-remote service"
##############systemctl enable docker
##############service docker start
echo "alias docker=podman" >> ~/.bash_profile
source ~/.bash_profile
echo "Installing MySQL"
yum -y install mysql-community-server
echo  "Creating picsure docker network"
podman network create podman
podman network create picsure
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

MYSQL_PASSWORD=`cat pass.tmp`

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
########################### Configuring picsure-specif network and replacing docker specific ip address configurations in standaolne.xml #########################
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
echo "Mysql setup completed"
###############################
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
mkdir -p /var/log/httpd-docker-logs/ssl_mutex

cd $CWD

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
################################## Enabling Podman to use remote socket inside the jenkins container to launch the containers on the host######################
cd $CWD
PODMAN_REMOTE_FLAG=no
echo "if you want to enable podman socket from Host enter yes else enter no"
read -p "enter yes or no :  " PODMAN_REMOTE_FLAG
if [ $PODMAN_REMOTE_FLAG == yes ]
 then
        sed -i '/<string>podman_remote_flag<\/string>/{n;s/<string>.*<\/string>/<string>--remote<\/string>/}' /var/jenkins_home/config.xml
        mkdir -p /var/log/hpds-logs
	mkdir -p /var/log/httpd-docker-logs
	mkdir -p /var/log/wildfly-docker-logs
	mkdir -p /var/log/wildfly-docker-os-logs/
	mkdir -p /usr/local/docker-config/wildfly/passthru
	mkdir -p /usr/local/docker-config/wildfly/aggregate-data-sharing/
	mkdir -p /usr/local/docker-config/wildfly/emailTemplates
fi
if [ $PODMAN_REMOTE_FLAG == no ]
 then
        sed -i '/<string>podman_remote_flag<\/string>/{n;s/<string>.*<\/string>/<string><\/string>/}' /var/jenkins_home/config.xml
fi
###############################################

../start-jenkins.sh
