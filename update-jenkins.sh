#!/bin/bash
# shellcheck disable=SC2154
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 2

REBUILD=false
JOBS_ONLY=false
AIO_REF=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild)
      REBUILD=true
      ;;
    --jobs-only)
      JOBS_ONLY=true
      ;;
    --aio-ref)
      shift
      AIO_REF=${1:-}
      [[ "$AIO_REF" =~ ^[0-9a-f]{40}$ ]] || { echo "--aio-ref requires an exact 40-character commit" >&2; exit 2; }
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

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

PIN_BRANCH=picsure-aio-release-pin
UPDATE_BRANCH_CONFIG=picsure.updateBranch
if [[ -n "$AIO_REF" ]]; then
  current_branch=$(git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" symbolic-ref --short HEAD) || {
    echo "Cannot install an exact AIO ref from an unmanaged detached checkout." >&2
    exit 2
  }
  if [[ "$current_branch" != "$PIN_BRANCH" ]]; then
    git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" config "$UPDATE_BRANCH_CONFIG" "$current_branch"
  elif ! git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" config --get "$UPDATE_BRANCH_CONFIG" >/dev/null; then
    echo "The saved AIO update branch is unavailable." >&2
    exit 2
  fi
  if ! git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" cat-file -e "$AIO_REF^{commit}"; then
    git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" fetch origin "$AIO_REF"
  fi
  git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" checkout -B "$PIN_BRANCH" "$AIO_REF"
  installed_ref=$(git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" rev-parse HEAD)
  [[ "$installed_ref" == "$AIO_REF" ]] || { echo "Exact AIO ref checkout resolved to $installed_ref, expected $AIO_REF." >&2; exit 2; }
else
  current_branch=$(git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" symbolic-ref --short HEAD) || {
    echo "Cannot update an unmanaged detached checkout. Run this script with --aio-ref or check out the configured branch." >&2
    exit 2
  }
  if [[ "$current_branch" == "$PIN_BRANCH" ]]; then
    update_branch=$(git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" config --get "$UPDATE_BRANCH_CONFIG") || {
      echo "The saved AIO update branch is unavailable." >&2
      exit 2
    }
    git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" checkout "$update_branch"
  fi
  git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" pull --ff-only
fi
./stop-jenkins.sh

echo "Sometimes we have to update not just the Jenkins jobs, but also the docker image itself."
echo "If you want to update that image. Rerun this command with the --rebuild flag added."

DOCKER_CONFIG_DIR="${DOCKER_CONFIG_DIR:-/usr/local/docker-config}"

if $REBUILD; then
  #  Rebuild the docker image. This matches the initial dep script. The proxy args are generally empty, but you might
  # run into bugs if you have an http proxy, but don't set it somewhere clever like your bash profile
  cd initial-configuration || exit 2
  echo "Rebuilding the Jenkins container:"
  jenkins_tag=$(git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" rev-parse --short=7 HEAD)
  docker build --build-arg http_proxy="$http_proxy" --build-arg https_proxy="$http_proxy" --build-arg no_proxy="$no_proxy" \
    --build-arg HTTP_PROXY="$http_proxy" --build-arg HTTPS_PROXY="$http_proxy" --build-arg NO_PROXY="$no_proxy" \
    -t "pic-sure-jenkins:$jenkins_tag" jenkins/jenkins-docker
  docker tag "pic-sure-jenkins:$jenkins_tag" pic-sure-jenkins:LATEST
  cd ../
fi

if $JOBS_ONLY; then
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
