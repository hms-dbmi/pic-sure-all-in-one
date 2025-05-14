#!/usr/bin/env bash

# A note to developers: if you use /usr/local/docker-config to refer to a place on the host file system
# 99 times out of 100 you are WRONG and you have just made a bug. Please:
# - Consider using $DOCKER_CONFIG_DIR instead
# - Challenge your own understanding of where files are located in docker and on the host file system and
# how that does or doesn't change the commands you run when inside Jenkins

DOCKER_CONFIG_DIR="${DOCKER_CONFIG_DIR:-/usr/local/docker-config}"
# Use this for file system checks. Use DOCKER_CONFIG_DIR for docker commands.
# Except for --env_file commands, which refer to the current file system, not the root fs
CURRENT_FS_DOCKER_CONFIG_DIR="${CURRENT_FS_DOCKER_CONFIG_DIR:-$DOCKER_CONFIG_DIR}"

if [ -f "$CURRENT_FS_DOCKER_CONFIG_DIR/setProxy.sh" ]; then
   . $CURRENT_FS_DOCKER_CONFIG_DIR/setProxy.sh
fi

# Optional services
[[ -d "$CURRENT_FS_DOCKER_CONFIG_DIR/hpds" ]] && INCLUDE_HPDS=true || INCLUDE_HPDS=false
echo "INCLUDE_HPDS=$INCLUDE_HPDS"
[[ -d "$CURRENT_FS_DOCKER_CONFIG_DIR/uploader" ]] && INCLUDE_UPLOADER=true || INCLUDE_UPLOADER=false
echo "INCLUDE_UPLOADER=$INCLUDE_UPLOADER"
[[ -d "$CURRENT_FS_DOCKER_CONFIG_DIR/dictionary" ]] && INCLUDE_DICTIONARY=true || INCLUDE_DICTIONARY=false
echo "INCLUDE_DICTIONARY=$INCLUDE_DICTIONARY"
[[ -d "$CURRENT_FS_DOCKER_CONFIG_DIR/dictionary/dump" ]] && INCLUDE_AGG_DICT=true || INCLUDE_AGG_DICT=false
echo "INCLUDE_AGG_DICT=$INCLUDE_AGG_DICT"
[[ -d "$CURRENT_FS_DOCKER_CONFIG_DIR/passthru" ]] && INCLUDE_PASSTHRU=true || INCLUDE_PASSTHRU=false
echo "INCLUDE_PASSTHRU=$INCLUDE_PASSTHRU"

# Docker Volumes
export PICSURE_BANNER_VOLUME="-v $DOCKER_CONFIG_DIR/httpd/banner_config.json:/usr/local/apache2/htdocs/picsureui/settings/banner_config.json"
export EMAIL_TEMPLATE_VOLUME="-v $DOCKER_CONFIG_DIR/wildfly/emailTemplates:/opt/jboss/wildfly/standalone/configuration/emailTemplates "
export TRUSTSTORE_VOLUME="-v $DOCKER_CONFIG_DIR/wildfly/application.truststore:/opt/jboss/wildfly/standalone/configuration/application.truststore"
export PSAMA_TRUSTSTORE_VOLUME="-v $DOCKER_CONFIG_DIR/psama/application.truststore:/usr/local/tomcat/conf/application.truststore"
if [ -f $DOCKER_CONFIG_DIR/httpd/custom_httpd_volumes ]; then
	export CUSTOM_HTTPD_VOLUMES=`cat $DOCKER_CONFIG_DIR/httpd/custom_httpd_volumes`
fi

# Docker networks
# External network. Can talk to the internet
docker network inspect picsure >/dev/null 2>&1 || docker network create picsure
# Internal networks. Cannot talk to the internet
docker network inspect dictionary >/dev/null 2>&1 || docker network create --internal dictionary
docker network inspect hpds >/dev/null 2>&1 || docker network create --internal hpds

# Start Commands
if $INCLUDE_HPDS; then
  docker stop hpds && docker rm hpds
  docker run --name=hpds --restart always --network=picsure --network=hpds \
    -v $DOCKER_CONFIG_DIR/hpds:/opt/local/hpds \
    -v $DOCKER_CONFIG_DIR/hpds/all:/opt/local/hpds/all \
    -v "$DOCKER_CONFIG_DIR"/log/hpds-logs/:/var/log/ \
    -v $DOCKER_CONFIG_DIR/hpds_csv/:/usr/local/docker-config/hpds_csv/ \
    -v $DOCKER_CONFIG_DIR/aws_uploads/:/gic_query_results/ \
    --env-file $CURRENT_FS_DOCKER_CONFIG_DIR/hpds/hpds.env \
    -d hms-dbmi/pic-sure-hpds:LATEST \
    || exit 2
fi

docker stop httpd && docker rm httpd
docker run --name=httpd --restart always --network=picsure \
    -v "$DOCKER_CONFIG_DIR"/log/httpd-docker-logs/:/app/logs/ \
    -v $DOCKER_CONFIG_DIR/httpd/cert:/usr/local/apache2/cert/ \
    -v $DOCKER_CONFIG_DIR/httpd/httpd-vhosts.conf:/usr/local/apache2/conf/extra/httpd-vhosts.conf \
    $CUSTOM_HTTPD_VOLUMES \
    -p 443:443 \
    --env-file $CURRENT_FS_DOCKER_CONFIG_DIR/httpd/httpd.env \
    -d hms-dbmi/pic-sure-frontend:LATEST \
    || exit 2
docker restart httpd

docker stop psama && docker rm psama
docker run --name=psama --restart always \
  --network=picsure \
  --env-file $CURRENT_FS_DOCKER_CONFIG_DIR/psama/psama.env \
  $EMAIL_TEMPLATE_VOLUME \
  $PSAMA_TRUSTSTORE_VOLUME \
  -d hms-dbmi/psama:LATEST \
  || exit 2

docker stop wildfly && docker rm wildfly
docker run --name=wildfly --restart always --network=picsure --network=hpds --network=dictionary -u root \
  -v "$DOCKER_CONFIG_DIR"/log/wildfly-docker-logs/:/opt/jboss/wildfly/standalone/log/ \
  -v /etc/hosts:/etc/hosts \
  -v "$DOCKER_CONFIG_DIR"/log/wildfly-docker-os-logs/:/var/log/ \
  -v $DOCKER_CONFIG_DIR/wildfly/passthru/:/opt/jboss/wildfly/standalone/configuration/passthru/ \
  -v $DOCKER_CONFIG_DIR/wildfly/aggregate-data-sharing/:/opt/jboss/wildfly/standalone/configuration/aggregate-data-sharing/ \
  -v $DOCKER_CONFIG_DIR/wildfly/visualization/:/opt/jboss/wildfly/standalone/configuration/visualization/ \
  -v $DOCKER_CONFIG_DIR/wildfly/standalone.xml:/opt/jboss/wildfly/standalone/configuration/standalone.xml \
  $TRUSTSTORE_VOLUME \
  $EMAIL_TEMPLATE_VOLUME \
  -v $DOCKER_CONFIG_DIR/wildfly/wildfly_mysql_module.xml:/opt/jboss/wildfly/modules/system/layers/base/com/sql/mysql/main/module.xml  \
  -v $DOCKER_CONFIG_DIR/wildfly/mysql-connector-java-5.1.49.jar:/opt/jboss/wildfly/modules/system/layers/base/com/sql/mysql/main/mysql-connector-java-5.1.49.jar  \
  --env-file $CURRENT_FS_DOCKER_CONFIG_DIR/wildfly/wildfly.env \
  -d hms-dbmi/pic-sure-wildfly:LATEST \
  || exit 2
# Workaround for macOS bind-mount limitations: macOS does not support atomic file moves on mounted volumes,
# causing "Device or resource busy" errors during hot deployments. We just copy the files into the running container.
docker cp "${DOCKER_CONFIG_DIR}/wildfly/deployments/." "wildfly:/opt/jboss/wildfly/standalone/deployments/"

if $INCLUDE_UPLOADER; then
  docker compose --profile production -f $CURRENT_FS_DOCKER_CONFIG_DIR/uploader/docker-compose.yml up -d
fi

if $INCLUDE_DICTIONARY; then
  docker start dictionary-db
  docker stop dictionary-api && docker rm dictionary-api
  docker run --name dictionary-api --restart always \
   --network=picsure --network=dictionary \
   --env-file $CURRENT_FS_DOCKER_CONFIG_DIR/dictionary/dictionary.env \
   -d avillach/dictionary-api:latest \
   || exit 2
fi

if $INCLUDE_AGG_DICT; then
  docker stop dictionary-dump && docker rm dictionary-dump
  docker run --name dictionary-api --restart always \
    --network=dictionary \
    --env-file $CURRENT_FS_DOCKER_CONFIG_DIR/dictionary/dictionary.env \
    -v $DOCKER_CONFIG_DIR/dictionary/dump/application.properties:/application.properties \
    -d avillach/dictionary-dump:latest \
   || exit 2
fi

if $INCLUDE_PASSTHRU; then
  docker stop passthru && docker rm passthru
  docker run --restart always --name passthru --network picsure \
    -v $DOCKER_CONFIG_DIR/passthru/application.properties:/application.properties \
    -d hms-dbmi/pic-sure-passthru:LATEST
fi
   
