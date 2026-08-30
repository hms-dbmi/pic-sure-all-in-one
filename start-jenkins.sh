#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_CONFIG_DIR="${DOCKER_CONFIG_DIR:-/usr/local/docker-config}"
MYSQL_CONFIG_DIR="${MYSQL_CONFIG_DIR:-$DOCKER_CONFIG_DIR/picsure-db/}"
AIO_WORKFLOW_COMMIT=UNAVAILABLE
if git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  AIO_WORKFLOW_COMMIT=$(git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" rev-parse HEAD) || exit 2
  if [[ ! "$AIO_WORKFLOW_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: could not resolve the installed AIO workflow commit." >&2
    exit 2
  fi
fi
AIO_WORKFLOW_SHA256=$(DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" AIO_WORKFLOW_MODE=installed "$SCRIPT_DIR/workflow-sha256.sh") || exit 2

if [ -f "$DOCKER_CONFIG_DIR/setProxy.sh" ]; then
   . "$DOCKER_CONFIG_DIR/setProxy.sh"
fi

echo "DOCKER_CONFIG_DIR: $DOCKER_CONFIG_DIR"
docker stop jenkins && docker rm jenkins
docker run -d \
  -e http_proxy="$http_proxy" \
  -e https_proxy="$https_proxy" \
  -e no_proxy="$no_proxy" \
  -e DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" \
  -e AIO_WORKFLOW_COMMIT="$AIO_WORKFLOW_COMMIT" \
  -e AIO_WORKFLOW_SHA256="$AIO_WORKFLOW_SHA256" \
  -v "$DOCKER_CONFIG_DIR"/jenkins_cert:/var/jenkins_cert \
  -v "$DOCKER_CONFIG_DIR"/hpds_csv/:/usr/local/docker-config/hpds_csv/ \
  -v "$DOCKER_CONFIG_DIR"/jenkins_home:/var/jenkins_home \
  -v "$DOCKER_CONFIG_DIR":/usr/local/docker-config \
  -v "$SCRIPT_DIR/start-picsure.sh:/scripts/start-picsure.sh" \
  -v "$SCRIPT_DIR/rollback-picsure.sh:/scripts/rollback-picsure.sh" \
  -v "$SCRIPT_DIR/aio-sha256.sh:/scripts/aio-sha256.sh:ro" \
  -v "$SCRIPT_DIR/validate-build-spec.sh:/scripts/validate-build-spec.sh:ro" \
  -v "$SCRIPT_DIR/initial-configuration/jenkins/jenkins-docker/banner-rollout-contract.json:/scripts/banner-rollout-contract.json:ro" \
  -v "$SCRIPT_DIR/initial-configuration/jenkins/jenkins-docker/banner-rollout-source.json:/scripts/banner-rollout-source.json:ro" \
  -v "$SCRIPT_DIR/stop-picsure.sh:/scripts/stop-picsure.sh" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$MYSQL_CONFIG_DIR"/.my.cnf:/root/.my.cnf \
  -v "$HOME"/.m2:/root/.m2 \
  -v /etc/hosts:/etc/hosts \
  -v /usr/local/pic-sure-services:/pic-sure-services \
  --network picsure \
  --network dictionary \
  -p 8080:8080 --name jenkins pic-sure-jenkins:LATEST
