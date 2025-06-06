#!/usr/bin/env bash
set -e

sed_inplace() {
  if sed --version 2>/dev/null | grep -q "GNU sed"; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

if [ -z $1 ]; then
  echo "Usage: ./convert-cert.sh path/to/cert.key path/to/cert.crt password-for-created-key"
  exit 1
fi
keypath=$1
crtpath=$2
jenkinspass=$3

echo "Configuring start-jenkins.sh"
sed_inplace "2 i JENKINS_OPTS_STR=\"--httpPort=-1 --httpsPort=8080 --httpsKeyStore=$DOCKER_CONFIG_DIR/jenkins_cert/certificate.pfx --httpsKeyStorePassword=$jenkinspass\"" mysql-docker/.env

echo "Converting cert and moving to $DOCKER_CONFIG_DIR/jenkins_cert/"
mkdir -p "$DOCKER_CONFIG_DIR/jenkins_cert/"
openssl pkcs12 -export -out "$DOCKER_CONFIG_DIR/jenkins_cert/certificate.pfx" -inkey $keypath -in $crtpath -passout pass:$jenkinspass

echo "Copying key to $DOCKER_CONFIG_DIR/jenkins_cert/"
cp "$keypath" "$DOCKER_CONFIG_DIR/jenkins_cert/https.key"

echo "Configuration done. Jenkins will use https and will run on 8080"


