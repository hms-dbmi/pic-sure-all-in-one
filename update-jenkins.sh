#!/bin/bash
sed_inplace() {
  if sed --version 2>/dev/null | grep -q "GNU sed"; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

read_jenkins_env_value() {
  local key=$1
  local config_file=$2

  awk -v needle="<string>$key</string>" '
    index($0, needle) {
      if (getline) {
        sub(/^[[:space:]]*<string>/, "")
        sub(/<\/string>[[:space:]]*$/, "")
        print
        exit
      }
    }
  ' "$config_file"
}

restore_jenkins_env_value() {
  local key=$1
  local backup_config=$2
  local target_config=$3
  local value
  local escaped_value

  value=$(read_jenkins_env_value "$key" "$backup_config")
  if [ -z "$value" ]; then
    echo "Unable to restore Jenkins environment value: $key" >&2
    return 1
  fi

  escaped_value=$(printf '%s' "$value" | sed 's/[\\&|]/\\&/g')
  sed_inplace "/<string>$key<\\/string>/{n;s|<string>.*</string>|<string>$escaped_value</string>|;}" "$target_config"
}

./stop-jenkins.sh
git pull

echo "Sometimes we have to update not just the Jenkins jobs, but also the docker image itself."
echo "If you want to update that image. Rerun this command with the --rebuild flag added."

DOCKER_CONFIG_DIR="${DOCKER_CONFIG_DIR:-/usr/local/docker-config}"

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

if [ "$1" = "--jobs-only" ] || [ "$2" = "--jobs-only" ]; then
  echo "Updating jobs only (preserving Jenkins state)"
  rm -rf "$DOCKER_CONFIG_DIR"/jenkins_home/jobs
  cp -r initial-configuration/jenkins/jenkins-docker/jobs "$DOCKER_CONFIG_DIR"/jenkins_home/jobs
else
  mkdir -p "$DOCKER_CONFIG_DIR"/jenkins_home_bak
  cp -r "$DOCKER_CONFIG_DIR"/jenkins_home/* "$DOCKER_CONFIG_DIR"/jenkins_home_bak/
  rm -rf "$DOCKER_CONFIG_DIR"/jenkins_home/*
  cp -r initial-configuration/jenkins/jenkins-docker/jobs "$DOCKER_CONFIG_DIR"/jenkins_home/jobs
  cp -r initial-configuration/jenkins/jenkins-docker/config.xml "$DOCKER_CONFIG_DIR"/jenkins_home/
  cp -r initial-configuration/jenkins/jenkins-docker/scriptApproval.xml "$DOCKER_CONFIG_DIR"/jenkins_home/
  cp -r initial-configuration/jenkins/jenkins-docker/hudson.tasks.Maven.xml "$DOCKER_CONFIG_DIR"/jenkins_home/hudson.tasks.Maven.xml

  # Keep Jenkins from treating an existing installation as a new one after
  # the full reset. These files contain only installation/upgrade state.
  for install_state_file in \
    jenkins.install.UpgradeWizard.state \
    jenkins.install.InstallUtil.lastExecVersion; do
    if [ -f "$DOCKER_CONFIG_DIR/jenkins_home_bak/$install_state_file" ]; then
      cp -p "$DOCKER_CONFIG_DIR/jenkins_home_bak/$install_state_file" "$DOCKER_CONFIG_DIR/jenkins_home/"
    fi
  done

  # Restore configurable values by key so paths embedded in other values are
  # not accidentally rewritten.
  backup_config="$DOCKER_CONFIG_DIR/jenkins_home_bak/config.xml"
  target_config="$DOCKER_CONFIG_DIR/jenkins_home/config.xml"
  for env_key in \
    release_control_branch \
    release_control_repo \
    DOCKER_CONFIG_DIR \
    MYSQL_NETWORK \
    MYSQL_CONFIG_DIR \
    MIGRATION_REPO \
    MIGRATION_NAME; do
    # Jenkins is stopped and jenkins_home is already repopulated by this point, so a
    # key the backup lacks must not abort the update - that leaves Jenkins down.
    if ! restore_jenkins_env_value "$env_key" "$backup_config" "$target_config"; then
      echo "Keeping the shipped default for $env_key" >&2
    fi
  done
fi

./start-jenkins.sh
