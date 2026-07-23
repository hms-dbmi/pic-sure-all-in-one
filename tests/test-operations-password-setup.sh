#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'find "$TEST_DIR" -depth -delete' EXIT

FAKE_BIN="$TEST_DIR/bin"
TEST_DOCKER_LOG="$TEST_DIR/docker.log"
DOCKER_CONFIG_DIR="$TEST_DIR/docker-config"
MYSQL_CONFIG_DIR="$DOCKER_CONFIG_DIR/picsure-db"
mkdir -p "$FAKE_BIN" "$DOCKER_CONFIG_DIR"
touch "$DOCKER_CONFIG_DIR/preexisting-config"

printf '%s\n' '#!/usr/bin/env bash' > "$FAKE_BIN/docker"
printf '%s\n' 'set -euo pipefail' >> "$FAKE_BIN/docker"
printf '%s\n' 'printf "%s\n" "$*" >> "$TEST_DOCKER_LOG"' >> "$FAKE_BIN/docker"
printf '%s\n' 'if [ "$1" = "ps" ]; then exit 0; fi' >> "$FAKE_BIN/docker"
printf '%s\n' 'if [ "$1" = "compose" ]; then mkdir -p "$MYSQL_CONFIG_DIR"; exit 0; fi' >> "$FAKE_BIN/docker"
printf '%s\n' 'if [ "$1" = "inspect" ]; then echo healthy; exit 0; fi' >> "$FAKE_BIN/docker"
printf '%s\n' 'exit 0' >> "$FAKE_BIN/docker"
chmod +x "$FAKE_BIN/docker"

export TEST_DOCKER_LOG DOCKER_CONFIG_DIR MYSQL_CONFIG_DIR
(
  cd "$ROOT_DIR/initial-configuration"
  LC_ALL=C PATH="$FAKE_BIN:$PATH" bash mysql-docker/setup.sh >/dev/null
)

OPS_ENV="$DOCKER_CONFIG_DIR/operations/operations.env"
if [ ! -f "$OPS_ENV" ]; then
  echo "FAIL: fresh setup did not seed operations/operations.env" >&2
  exit 1
fi

operations_password="$(sed -n 's/^SPRING_DATASOURCE_PASSWORD=//p' "$OPS_ENV")"
if [ -z "$operations_password" ]; then
  echo "FAIL: operations database password is empty" >&2
  exit 1
fi
if [ "$operations_password" = "__PICSURE_MYSQL_PASSWORD__" ]; then
  echo "FAIL: operations database password placeholder was not rendered" >&2
  exit 1
fi
if ! grep -Fq "CREATE USER 'picsure'@'%' IDENTIFIED BY '$operations_password'" "$TEST_DOCKER_LOG"; then
  echo "FAIL: operations environment password does not match the MySQL picsure user password" >&2
  exit 1
fi

OPERATIONS_JOB="$ROOT_DIR/initial-configuration/jenkins/jenkins-docker/jobs/PIC-SURE Operations Service Build and Deploy/config.xml"
if ! grep -Fq 'operations.env is required' "$OPERATIONS_JOB"; then
  echo "FAIL: operations build job does not fail clearly when operations.env is missing" >&2
  exit 1
fi
if grep -Eq 'touch (.*)?operations\.env' "$OPERATIONS_JOB"; then
  echo "FAIL: operations build job still creates an empty operations.env" >&2
  exit 1
fi

REMOTE_MYSQL_JOB="$ROOT_DIR/initial-configuration/jenkins/jenkins-docker/jobs/Configure Remote MySQL Instance/config.xml"
if ! grep -Fq '__PICSURE_MYSQL_PASSWORD__' "$REMOTE_MYSQL_JOB"; then
  echo "FAIL: remote MySQL job does not recognize the unresolved operations password placeholder" >&2
  exit 1
fi

echo "Operations service database password setup checks passed"
