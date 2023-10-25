
#!/usr/bin/env bash


CWD=`pwd`
{
mkdir -p /usr/local/docker-config
cp -r config/* /usr/local/docker-config/

echo "Starting update"
yum -y update 
yum -y install net-tools
echo "Update yum to get correct version of MariaDB"
curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash -s -- --mariadb-server-version="mariadb-10.11.4"

echo "Finished update, adding epel, docker-ce, mysql-community-release repositories and installing wget and yum-utils"
yum -y install epel-release wget yum-utils
yum-config-manager  --add-repo https://download.docker.com/linux/centos/docker-ce.repo
yum-config-manager --disable mysql56-community
yum-config-manager --enable mysql57-community-dmr
yum -y update

echo "Added docker-ce repo, starting docker install"
yum -y install docker-ce docker-ce-cli containerd.io

echo "Finished docker install, enabling and starting docker service"
systemctl enable docker
service docker start

echo "Installing MySQL/MariaDB"
yum -y install mariadb-server
echo  "Creating picsure docker network"
export DOCKER_NETWORK_IF=br-`docker network create picsure | cut -c1-12`
sysctl -w net.ipv4.conf.$DOCKER_NETWORK_IF.route_localnet=1
iptables -t nat -I PREROUTING -i $DOCKER_NETWORK_IF -d 172.18.0.1 -p tcp --dport 3306 -j DNAT --to 127.0.0.1:3306
iptables -t filter -I INPUT -i $DOCKER_NETWORK_IF -d 127.0.0.1 -p tcp --dport 3306 -j ACCEPT
echo "[Unit]" > /etc/systemd/system/configure_docker_networks.service
echo "After=docker.service" >> /etc/systemd/system/configure_docker_networks.service
echo "" >> /etc/systemd/system/configure_docker_networks.service
echo "[Service]" >> /etc/systemd/system/configure_docker_networks.service
echo "ExecStart=/root/configure_docker_networking.sh" >> /etc/systemd/system/configure_docker_networks.service
echo "" >> /etc/systemd/system/configure_docker_networks.service
echo "[Install]" >> /etc/systemd/system/configure_docker_networks.service
echo "WantedBy=default.target" >> /etc/systemd/system/configure_docker_networks.service

cp configure_docker_networking.sh /root/configure_docker_networking.sh 
chmod +x /root/configure_docker_networking.sh 
systemctl daemon-reload
systemctl enable configure_docker_networks

echo "Starting mysql server"
echo "[mysqld]" >> /etc/my.cnf
echo "bind-address=127.0.0.1" >> /etc/my.cnf
echo "default-time-zone='-00:00'" >> /etc/my.cnf
systemctl start mariadb.service
systemctl enable mariadb.service
echo "` < /dev/urandom tr -dc @^=+$*%_A-Z-a-z-0-9 | head -c${1:-24}`%4cA" > pass.tmp
mysql -u root --connect-expired-password -e "ALTER USER root@localhost IDENTIFIED BY '`cat pass.tmp`';flush privileges;"
echo "[mysql]" > ~/.my.cnf
echo "user = root" >> ~/.my.cnf
echo "password = `cat pass.tmp`" >> ~/.my.cnf
echo "port = 3306" >> ~/.my.cnf
echo "host = 127.0.0.1" >> ~/.my.cnf

for addr in $(ifconfig | grep netmask | sed 's/  */ /g'| cut -d ' ' -f 3)
do
	mysql -u root -e "grant all privileges on *.* to root@$addr identified by '`cat pass.tmp`';flush privileges;";
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

cd $CWD
if [ -n "$1" ]; then
  echo "Configuring jenkins for https:"
  # Just making a random password. This is just for the cert, not jenkins admin
  # If the user somehow nukes this, they can just regen from the crt and key
  password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13 ; echo '')
  ./convert-cert.sh $1 $2 $password
fi

echo "Installation script complete.  Staring Jenkins."
../start-jenkins.sh
} 2>&1 | tee .initial-installation.log

