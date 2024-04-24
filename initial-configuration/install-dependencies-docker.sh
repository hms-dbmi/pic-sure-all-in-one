
#!/usr/bin/env bash

sed_inplace() {
  if [ "$(uname)" = "Darwin" ]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}
export -f sed_inplace

CWD=$(pwd)
# this makes tr work on OSX
export LC_CTYPE=C
export LC_ALL=C

# $1 is the path to the docker-config dir $2 is the path to the rc rc_file
function set_docker_config_dir {
  local docker_config_dir=$1
  local rc_file=$2
  if [ -z "$docker_config_dir" ]; then
   docker_config_dir="/var/local/docker-config"
  fi
  if [ -z "$rc_file" ]; then
   rc_file="$HOME/.bashrc"
  fi
  #Check if docker_config_dir is a dir and exists
  if [ ! -d "$docker_config_dir" ]; then
    echo "Creating dir $docker_config_dir and setting DOCKER_CONFIG_DIR in $rc_file"
    mkdir -p $docker_config_dir
    export DOCKER_CONFIG_DIR=$docker_config_dir
    echo "export DOCKER_CONFIG_DIR=$docker_config_dir" >> "$rc_file"
  else
    echo "dir $docker_config_dir exists, just setting DOCKER_CONFIG_DIR in $rc_file"
    # If the config dir exists, we still want to clean up old settings for it
    export DOCKER_CONFIG_DIR=$1
    # delete any old config lines in bash config file
    grep 'DOCKER_CONFIG_DIR' "$rc_file" && sed_inplace '/DOCKER_CONFIG_DIR/d' "$rc_file"
    echo "export DOCKER_CONFIG_DIR=$docker_config_dir" >> "$rc_file"
  fi
}

set_docker_config_dir "$1"

#-------------------------------------------------------------------------------------------------#
#                                          Docker Install                                         #
#    This section checks for docker, and if it cant find it, tries to install it via yum / apt.   #
#-------------------------------------------------------------------------------------------------#

echo "Starting update"
echo "Installing docker"
if [ -n "$(command -v yum)" ] && [ -z "$(command -v docker)" ]; then
  echo "Yum detected. Assuming RHEL. Install commands will use yum"
  set_docker_config_dir $1  "$HOME/.zshrc"
  yum -y update
  # This repo can be removed after we move away from centos 7 I think
  yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  yum install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker compose-plugin
  sudo systemctl start docker
  mkdir -p ../docker-config
  cp -r config/* $DOCKER_CONFIG_DIR/
fi

if [ -n "$(command -v apt-get)" ] && [ -z "$(command -v docker)" ]; then
  echo "Apt detected. Assuming Debian. Install commands will use apt"
  set_docker_config_dir $1  "$HOME/.zshrc"
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
  apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker compose-plugin
  mkdir -p ../docker-config
  cp -r config/* $DOCKER_CONFIG_DIR
fi

if [[ "$OSTYPE" =~ ^darwin ]]; then
    echo "Darwin detected. Assuming macOS. Install commands will use brew." 
    #check for brew
    if [ -z "$(command -v brew)" ]; then
      echo "Brew not detected. Please install brew and rerun this script."
      exit
    fi
    echo $1
    #check for $1 arg
    if [ -z "$1" ]; then
      echo "No arguments supplied. Please provide the path to the docker-config dir."
      echo "MacOS doesn't like the default docker-config dir Please supply a dir as an arguments."
      exit
    else
      set_docker_config_dir $1  "$HOME/.zshrc"
      echo "Copying config to $1"
      cp -r config/* $1
    fi
fi

if [ -n "$(command -v apk)" ]; then
  echo "apk detected. Assuming alpine. Install commands will use apk"
  apk update && apk add --no-cache wget
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
./mysql-docker/setup.sh

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
cp -r jenkins/jenkins-docker/jobs /var/jenkins_home/
cp -r jenkins/jenkins-docker/config.xml /var/jenkins_home/config.xml
cp -r jenkins/jenkins-docker/hudson.tasks.Maven.xml /var/jenkins_home/hudson.tasks.Maven.xml
cp -r jenkins/jenkins-docker/scriptApproval.xml /var/jenkins_home/scriptApproval.xml
mkdir -p /var/log/httpd-docker-logs/ssl_mutex

export APP_ID=`uuidgen | tr '[:upper:]' '[:lower:]'`
export APP_ID_HEX=`echo $APP_ID | awk '{ print toupper($0) }'|sed 's/-//g'`
sed_inplace "s/__STACK_SPECIFIC_APPLICATION_ID__/$APP_ID/g" $DOCKER_CONFIG_DIR/httpd/picsureui_settings.json
sed_inplace "s/__STACK_SPECIFIC_APPLICATION_ID__/$APP_ID/g" $DOCKER_CONFIG_DIR/wildfly/standalone.xml

export RESOURCE_ID=`uuidgen | tr '[:upper:]' '[:lower:]'`
export RESOURCE_ID_HEX=`echo $RESOURCE_ID | awk '{ print toupper($0) }'|sed 's/-//g'`
sed_inplace "s/__STACK_SPECIFIC_RESOURCE_UUID__/$RESOURCE_ID/g" $DOCKER_CONFIG_DIR/httpd/picsureui_settings.json

echo $APP_ID > $DOCKER_CONFIG_DIR/APP_ID_RAW
echo $APP_ID_HEX > $DOCKER_CONFIG_DIR/APP_ID_HEX
echo $RESOURCE_ID > $DOCKER_CONFIG_DIR/RESOURCE_ID_RAW
echo $RESOURCE_ID_HEX > $DOCKER_CONFIG_DIR/RESOURCE_ID_HEX

mkdir -p $DOCKER_CONFIG_DIR/hpds_csv
mkdir -p $DOCKER_CONFIG_DIR/hpds/all
cp allConcepts.csv.tgz $DOCKER_CONFIG_DIR/hpds_csv/
cd $DOCKER_CONFIG_DIR/hpds_csv/
tar -xvzf allConcepts.csv.tgz

cd $CWD
if [ -n "$2" ]; then
  echo "Configuring jenkins for https:"
  # Just making a random password. This is just for the cert, not jenkins admin
  # If the user somehow nukes this, they can just regen from the crt and key
  password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13 ; echo '')
  ./convert-cert.sh $2 $3 $password
fi

echo "Installation script complete.  Staring Jenkins."
cd ..
./start-jenkins.sh



