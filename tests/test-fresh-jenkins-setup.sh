#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
jenkins_dir="$repo_dir/initial-configuration/jenkins/jenkins-docker"
installer="$repo_dir/initial-configuration/install-dependencies-docker.sh"
jenkins_version=$(sed -n 's/^FROM jenkins\/jenkins:\([^-]*\)-.*/\1/p' "$jenkins_dir/Dockerfile")

if [ -z "$jenkins_version" ]; then
  echo "Unable to determine the Jenkins version from the Dockerfile" >&2
  exit 1
fi

for marker in jenkins.install.UpgradeWizard.state jenkins.install.InstallUtil.lastExecVersion; do
  marker_file="$jenkins_dir/$marker"
  if [ ! -f "$marker_file" ]; then
    echo "Missing fresh-install marker: $marker" >&2
    exit 1
  fi
  if [ "$(tr -d '[:space:]' < "$marker_file")" != "$jenkins_version" ]; then
    echo "$marker does not match Jenkins $jenkins_version" >&2
    exit 1
  fi
  if ! grep -Fq "jenkins/jenkins-docker/$marker" "$installer"; then
    echo "Installer does not copy $marker into the new Jenkins home" >&2
    exit 1
  fi
done

echo "Fresh Jenkins installation-state checks passed"
