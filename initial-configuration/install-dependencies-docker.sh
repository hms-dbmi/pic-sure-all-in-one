
#!/usr/bin/env bash

CWD=`pwd`

#-------------------------------------------------------------------------------------------------#
#                                          Docker Install                                         #
#    This section checks for docker, and if it cant find it, tries to install it via yum / apt.   #
#-------------------------------------------------------------------------------------------------#
mkdir -p /usr/local/docker-config
cp -r config/* /usr/local/docker-config/

echo "Starting update"
echo "Installing docker"
if [ -n "$(command -v yum)" ] && [ -z "$(command -v docker)" ]; then
  echo "Yum detected. Assuming RHEL. Install commands will use yum"
  yum -y update
  # This repo can be removed after we move away from centos 7 I think
  yum-config-manager  --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  yum install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl start docker
fi

if [ -n "$(command -v apt-get)" ] && [ -z "$(command -v docker)" ]; then
  echo "Apt detected. Assuming Debian. Install commands will use apt"
  # Add Docker's official GPG key:
  apt-get update
  apt-get install ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  # Add the repository to Apt sources:
  echo \
    "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update

  # Install docker
  apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

if [ -z "$(command -v docker)" ]; then
  echo "You dont have docker installed and we cant detect a supported package manager."
  echo "Install docker and then rerun this script"
  exit
else
  echo "Looks like docker is installed! Attempting a simple docker command: "
fi

if ! docker run hello-world > /dev/null 2>&1; then
  echo "Docker hello-world failed. Exiting"
  exit
else
  echo "Docker daemon seems happy!"
fi

echo "Creating docker networks for PIC-SURE and HPDS"
if [ -z "$(docker network ls --format '{{.Name}}' | grep ^picsure$)" ]; then
  docker network create picsure
else
  echo "picsure network already exists. Leaving it alone."
fi
if [ -z "$(docker network ls --format '{{.Name}}' | grep ^hpdsNet$)" ]; then
  docker network create hpdsNet
else
  echo "hpdsNet network already exists. Leaving it alone."
fi


#-------------------------------------------------------------------------------------------------#
#                                           MySQL Start                                           #
#                     Install Jenkins and configure jobs and DB connection                        #
#-------------------------------------------------------------------------------------------------#
if [ -z "$(docker ps --format '{{.Names}}' | grep picsure-db)" ]; then
  echo "Starting mysql server"
  echo "` < /dev/urandom tr -dc @^=+$*%_A-Z-a-z-0-9 | head -c${1:-24}`%4cA" > pass.tmp
  echo "PICSURE_DB_ROOT_PASS=`cat pass.tmp`" >> mysql-docker/.env
  echo "PICSURE_DB_PASS=`cat pass.tmp`" >> mysql-docker/.env
  echo "PICSURE_DB_DATABASE=ignore" >> mysql-docker/.env
  echo "PICSURE_DB_USER=ignore" >> mysql-docker/.env
  cd mysql-docker
  docker-compose up -d

  echo "Waiting for MySQL to become healthy..."
  SECONDS=0
  TIMEOUT=180
  while [ $SECONDS -lt $TIMEOUT ]; do
      HEALTH=$(docker inspect --format='{{.State.Health.Status}}' picsure-db)
      if [ "$HEALTH" = "healthy" ]; then
          echo "MySQL is up and healthy."
          break
      fi
      echo "Waiting for MySQL to become healthy..."
      sleep 10
  done

  if [ "$HEALTH" != "healthy" ]; then
      echo "MySQL did not become healthy within $TIMEOUT seconds."
      exit
  fi


  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "CREATE DATABASE picsure;"
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "CREATE DATABASE auth;"

  echo "` < /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-24}`%4cA" > airflow.tmp
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "CREATE USER 'airflow'@'%' IDENTIFIED BY '`cat airflow.tmp`';";
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "GRANT ALL PRIVILEGES ON auth.* TO 'airflow'@'%';FLUSH PRIVILEGES;";
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "GRANT ALL PRIVILEGES ON picsure.* TO 'airflow'@'%';FLUSH PRIVILEGES;";
  sed -i s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g /usr/local/docker-config/flyway/auth/flyway-auth.conf
  sed -i s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g /usr/local/docker-config/flyway/auth/sql.properties
  sed -i s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g /usr/local/docker-config/flyway/picsure/flyway-picsure.conf
  sed -i s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g /usr/local/docker-config/flyway/picsure/sql.properties
  rm -f airflow.tmp

  echo "` < /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-24}`%4cA" > picsure.tmp
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "CREATE USER 'picsure'@'%' IDENTIFIED BY '`cat picsure.tmp`';";
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "GRANT ALL PRIVILEGES ON picsure.* to 'picsure'@'%';FLUSH PRIVILEGES";
  sed -i s/__PIC_SURE_MYSQL_PASSWORD__/`cat picsure.tmp`/g /usr/local/docker-config/wildfly/standalone.xml
  rm -f picsure.tmp

  echo "` < /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-24}`%4cA" > auth.tmp
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "CREATE USER 'auth'@'%' IDENTIFIED BY '`cat auth.tmp`';";
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "GRANT ALL PRIVILEGES ON auth.* to 'auth'@'%';FLUSH PRIVILEGES;";
  sed -i s/__AUTH_MYSQL_PASSWORD__/`cat auth.tmp`/g /usr/local/docker-config/wildfly/standalone.xml
  rm -f auth.tmp

  cd $CWD
  rm -f pass.tmp
else
  echo "You are already running a docker container named picsure-db. If you want to remove it, do so manually"
  echo "Don't forget to rm the /usr/local/docker-config/picsure-db volume too"
fi

#-------------------------------------------------------------------------------------------------#
#                                         Jenkins Install                                         #
#                     Install Jenkins and configure jobs and DB connection                        #
#-------------------------------------------------------------------------------------------------#

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
cd ..
./start-jenkins.sh



