#!/bin/bash
sed_inplace() {
  if sed --version 2>/dev/null | grep -q "GNU sed"; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}
./stop-jenkins.sh
git pull

echo "Sometimes we have to update not just the Jenkins jobs, but also the docker image itself."
echo "If you want to update that image. Rerun this command with the --rebuild flag added."

export DOCKER_CONFIG_DIR="${DOCKER_CONFIG_DIR:-/usr/local/docker-config}"
export MYSQL_CONFIG_DIR="${MYSQL_CONFIG_DIR:-$DOCKER_CONFIG_DIR/picsure-db/}"
# Use this for file system checks. Use DOCKER_CONFIG_DIR for docker commands.
# Except for --env_file commands, which refer to the current file system, not the root fs
export CURRENT_FS_DOCKER_CONFIG_DIR="${CURRENT_FS_DOCKER_CONFIG_DIR:-$DOCKER_CONFIG_DIR}"

if [ -f "$CURRENT_FS_DOCKER_CONFIG_DIR/setProxy.sh" ]; then
   . $CURRENT_FS_DOCKER_CONFIG_DIR/setProxy.sh
fi

if [ "$1" = "--rebuild" ]; then
  #  Rebuild the docker image. This matches the initial dep script. The proxy args are generally empty, but you might
  # run into bugs if you have an http proxy, but don't set it somewhere clever like your bash profile
  cd initial-configuration
  echo "Rebuilding the Jenkins container:"
  docker build --build-arg http_proxy=$http_proxy --build-arg https_proxy=$http_proxy --build-arg no_proxy="$no_proxy" \
    --build-arg HTTP_PROXY=$http_proxy --build-arg HTTPS_PROXY=$http_proxy --build-arg NO_PROXY="$no_proxy" \
    -t pic-sure-jenkins:`git log -n 1 | grep commit | cut -d ' ' -f 2 | cut -c 1-7` jenkins/jenkins-docker
  docker tag pic-sure-jenkins:`git log -n 1 | grep commit | cut -d ' ' -f 2 | cut -c 1-7` pic-sure-jenkins:LATEST
  cd ../
fi

mkdir -p "$DOCKER_CONFIG_DIR"/jenkins_home_bak
cp -r "$DOCKER_CONFIG_DIR"/jenkins_home/* "$DOCKER_CONFIG_DIR"/jenkins_home_bak/
rm -rf "$DOCKER_CONFIG_DIR"/jenkins_home/*
cp -r initial-configuration/jenkins/jenkins-docker/jobs "$DOCKER_CONFIG_DIR"/jenkins_home/jobs
cp -r initial-configuration/jenkins/jenkins-docker/config.xml "$DOCKER_CONFIG_DIR"/jenkins_home/
cp -r initial-configuration/jenkins/jenkins-docker/scriptApproval.xml "$DOCKER_CONFIG_DIR"/jenkins_home/
cp -r initial-configuration/jenkins/jenkins-docker/hudson.tasks.Maven.xml "$DOCKER_CONFIG_DIR"/jenkins_home/hudson.tasks.Maven.xml

if [ ! -f "$DOCKER_CONFIG_DIR"/wildfly/mysql-connector-java-5.1.49.jar ]; then
	cp initial-configuration/config/wildfly/mysql-connector-java-5.1.49.jar "$DOCKER_CONFIG_DIR"/wildfly/
	cp initial-configuration/config/wildfly/wildfly_mysql_module.xml "$DOCKER_CONFIG_DIR"/wildfly/
fi

# Pull through previous PICSURE configurations
sed_inplace "s|__PROJECT_SPECIFIC_OVERRIDE_REPO__|`cat "$DOCKER_CONFIG_DIR"/jenkins_home_bak/config.xml | grep -A1 project_specific_override_repo | tail -1 | sed 's/<\/*string>//g' | sed 's/ //g' `|g" "$DOCKER_CONFIG_DIR"/jenkins_home/config.xml
sed_inplace "s|__RELEASE_CONTROL_REPO__|`cat "$DOCKER_CONFIG_DIR"/jenkins_home_bak/config.xml | grep -A1 release_control_repo | tail -1 | sed 's/<\/*string>//g' | sed 's/ //g' `|g" "$DOCKER_CONFIG_DIR"/jenkins_home/config.xml
sed_inplace "s|/usr/local/docker-config/|`cat "$DOCKER_CONFIG_DIR"/jenkins_home_bak/config.xml | grep -A1 DOCKER_CONFIG_DIR | tail -1 | sed 's/<\/*string>//g' | sed 's/ //g' `|g" "$DOCKER_CONFIG_DIR"/jenkins_home/config.xml
sed_inplace "s|host|`cat "$DOCKER_CONFIG_DIR"/jenkins_home_bak/config.xml | grep -A1 MYSQL_NETWORK | tail -1 | sed 's/<\/*string>//g' | sed 's/ //g' `|g" "$DOCKER_CONFIG_DIR"/jenkins_home/config.xml
sed_inplace "s|*/master|`cat "$DOCKER_CONFIG_DIR"/jenkins_home_bak/config.xml | grep -A1 release_control_branch | tail -1 | sed 's/<\/*string>//g' | sed 's/ //g' `|g" "$DOCKER_CONFIG_DIR"/jenkins_home/config.xml
sed_inplace "s|__PROJECT_SPECIFIC_MIGRATION_NAME__|`cat "$DOCKER_CONFIG_DIR"/jenkins_home_bak/config.xml | grep -A1 MIGRATION_NAME | tail -1 | sed 's/<\/*string>//g' | sed 's/ //g' `|g" "$DOCKER_CONFIG_DIR"/jenkins_home/config.xml

./start-jenkins.sh
