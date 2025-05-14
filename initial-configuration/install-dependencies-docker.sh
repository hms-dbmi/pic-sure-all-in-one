################################################################################
#                           1) HELPER FUNCTIONS                                #
################################################################################

# Detect a default rc file that we can safely edit and source.
detect_default_rc_file() {
  if [ -n "$ZSH_VERSION" ] && [ -f "$HOME/.zshrc" ]; then
    echo "$HOME/.zshrc"
  elif [ -f "$HOME/.bashrc" ]; then
    echo "$HOME/.bashrc"
  else
    echo "$HOME/.bashrc"
  fi
}

# sed_inplace: unify sed usage across macOS (BSD sed) and Linux (GNU sed).
sed_inplace() {
  if sed --version 2>/dev/null | grep -q "GNU sed"; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

# For things like tr on macOS
export LC_CTYPE=C
export LC_ALL=C

################################################################################
#                           2) CONFIG FUNCTIONS                                #
################################################################################

# Sets DOCKER_CONFIG_DIR in the rc file and aliases the mysql command.
# Usage: set_docker_config_dir <docker_config_dir> [rc_file]
#        If <docker_config_dir> is empty, defaults to /var/local/docker-config
#        If [rc_file] is empty, auto-detect using detect_default_rc_file()
set_docker_config_dir() {
  local docker_config_dir="$1"
  local rc_file="$2"

  if [ -z "$docker_config_dir" ]; then
    docker_config_dir="/var/local/docker-config"
  fi
  if [ -z "$rc_file" ]; then
    rc_file="$(detect_default_rc_file)"
  fi

  # Check if docker_config_dir is a directory
  if [ ! -d "$docker_config_dir" ]; then
    echo "Creating dir $docker_config_dir and setting DOCKER_CONFIG_DIR in $rc_file"
    mkdir -p "$docker_config_dir"
  else
    echo "dir $docker_config_dir already exists, removing old DOCKER_CONFIG_DIR lines in $rc_file"
    # If the config dir exists, we still want to clean up old settings
    grep 'DOCKER_CONFIG_DIR' "$rc_file" && sed_inplace '/DOCKER_CONFIG_DIR/d' "$rc_file"
  fi

  # Export and append to the rc file
  export DOCKER_CONFIG_DIR="$docker_config_dir"
  echo "export DOCKER_CONFIG_DIR=$docker_config_dir" >> "$rc_file"

  # Also add mysql alias
  echo "Aliasing mysql command (picsure-db) in $rc_file"
  echo 'alias picsure-db="docker exec -ti picsure-db bash -c '\''mysql -uroot -p\$MYSQL_ROOT_PASSWORD'\''"' >> "$rc_file"

  # shellcheck disable=SC1090
  source "$rc_file"
}

# Sets MYSQL_CONFIG_DIR in the rc file.
# Usage: set_mysql_config_dir <mysql_config_dir> [rc_file]
set_mysql_config_dir() {
  local mysql_config_dir="$1"
  local rc_file="$2"

  if [ -z "$mysql_config_dir" ]; then
    mysql_config_dir="$DOCKER_CONFIG_DIR/picsure-db"
  fi
  if [ -z "$rc_file" ]; then
    rc_file="$(detect_default_rc_file)"
  fi

  if [ ! -d "$mysql_config_dir" ]; then
    echo "Creating dir $mysql_config_dir and setting MYSQL_CONFIG_DIR in $rc_file"
    mkdir -p "$mysql_config_dir"
  else
    echo "dir $mysql_config_dir exists, removing old MYSQL_CONFIG_DIR lines in $rc_file"
    grep 'MYSQL_CONFIG_DIR' "$rc_file" && sed_inplace '/MYSQL_CONFIG_DIR/d' "$rc_file"
  fi

  export MYSQL_CONFIG_DIR="$mysql_config_dir"
  echo "export MYSQL_CONFIG_DIR=$mysql_config_dir" >> "$rc_file"

  # shellcheck disable=SC1090
  source "$rc_file"
}

################################################################################
#                           3) MAIN SCRIPT START                                #
################################################################################

# Remember current working directory
CWD=$(pwd)

# Set Docker and MySQL config directories (may or may not be passed in)
#  - $1 => Docker config directory
#  - $2 => MySQL config directory
set_docker_config_dir "$1"
set_mysql_config_dir "$2"

#-------------------------------------------------------------------------------------------------#
#                                          Docker Install                                         #
#    This section checks for docker, and if it cant find it, tries to install it via yum / apt.   #
#-------------------------------------------------------------------------------------------------#

echo "Starting update"
echo "Installing docker"
if [ -n "$(command -v yum)" ] && [ -z "$(command -v docker)" ]; then
  echo "Yum detected. Assuming RHEL. Install commands will use yum"
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
if [ -z "$(docker network ls --format '{{.Name}}' | grep ^dictionary$)" ]; then
  docker network create dictionary
else
  echo "dictionary network already exists. Leaving it alone."
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
mkdir -p "$DOCKER_CONFIG_DIR"/log/jenkins-docker-logs
mkdir -p "$DOCKER_CONFIG_DIR"/jenkins_home
cp -r jenkins/jenkins-docker/jobs "$DOCKER_CONFIG_DIR"/jenkins_home/
cp -r jenkins/jenkins-docker/config.xml "$DOCKER_CONFIG_DIR"/jenkins_home/config.xml
cp -r jenkins/jenkins-docker/hudson.tasks.Maven.xml "$DOCKER_CONFIG_DIR"/jenkins_home/hudson.tasks.Maven.xml
cp -r jenkins/jenkins-docker/scriptApproval.xml "$DOCKER_CONFIG_DIR"/jenkins_home/scriptApproval.xml
mkdir -p "$DOCKER_CONFIG_DIR"/log/httpd-docker-logs/ssl_mutex

export APP_ID=`uuidgen | tr '[:upper:]' '[:lower:]'`
export APP_ID_HEX=`echo $APP_ID | awk '{ print toupper($0) }'|sed 's/-//g'`
sed_inplace "s/__STACK_SPECIFIC_APPLICATION_ID__/$APP_ID/g" $DOCKER_CONFIG_DIR/httpd/picsureui_settings.json
sed_inplace "s/__STACK_SPECIFIC_APPLICATION_ID__/$APP_ID/g" $DOCKER_CONFIG_DIR/wildfly/standalone.xml
sed_inplace "s/__STACK_SPECIFIC_APPLICATION_ID__/$APP_ID/g" $DOCKER_CONFIG_DIR/psama/psama.env

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

echo Deleting pass.tmp
rm pass.tmp

echo "Installation script complete.  Staring Jenkins."
cd ..
./start-jenkins.sh



