#!/usr/bin/env bash

# A note to developers: if you use /usr/local/docker-config to refer to a place on the host file system
# 99 times out of 100 you are WRONG and you have just made a bug. Please:
# - Consider using $DOCKER_CONFIG_DIR instead
# - Challenge your own understanding of where files are located in docker and on the host file system and
# how that does or doesn't change the commands you run when inside Jenkins

DOCKER_CONFIG_DIR="${DOCKER_CONFIG_DIR:-/usr/local/docker-config}"

if [ -f "$DOCKER_CONFIG_DIR/setProxy.sh" ]; then
   . $DOCKER_CONFIG_DIR/setProxy.sh
fi

if [ -z "$(grep "VITE_ALLOW_EXPORT" $DOCKER_CONFIG_DIR/httpd/.env | grep 'false')" ]; then
    export EXPORT_SIZE="2000";
  else
    export EXPORT_SIZE="0";
  fi
fi

# Docker Volumes
export PICSURE_SETTINGS_VOLUME="-v $DOCKER_CONFIG_DIR/httpd/picsureui_settings.json:/usr/local/apache2/htdocs/picsureui/settings/settings.json"
export PICSURE_BANNER_VOLUME="-v $DOCKER_CONFIG_DIR/httpd/banner_config.json:/usr/local/apache2/htdocs/picsureui/settings/banner_config.json"
export PSAMA_SETTINGS_VOLUME="-v $DOCKER_CONFIG_DIR/httpd/psamaui_settings.json:/usr/local/apache2/htdocs/picsureui/psamaui/settings/settings.json"
export EMAIL_TEMPLATE_VOLUME="-v $DOCKER_CONFIG_DIR/wildfly/emailTemplates:/opt/jboss/wildfly/standalone/configuration/emailTemplates "
export TRUSTSTORE_VOLUME="-v $DOCKER_CONFIG_DIR/wildfly/application.truststore:/opt/jboss/wildfly/standalone/configuration/application.truststore"
export PSAMA_TRUSTSTORE_VOLUME="-v $DOCKER_CONFIG_DIR/psama/application.truststore:/usr/local/tomcat/conf/application.truststore"
if [ -f $DOCKER_CONFIG_DIR/httpd/custom_httpd_volumes ]; then
	export CUSTOM_HTTPD_VOLUMES=`cat $DOCKER_CONFIG_DIR/httpd/custom_httpd_volumes`
fi

# Start Commands
docker stop hpds && docker rm hpds
docker run --name=hpds --restart always --network=picsure \
  -v $DOCKER_CONFIG_DIR/hpds:/opt/local/hpds \
  -v $DOCKER_CONFIG_DIR/hpds/all:/opt/local/hpds/all \
  -v /var/log/hpds-logs/:/var/log/ \
  -v $DOCKER_CONFIG_DIR/hpds_csv/:/usr/local/docker-config/hpds_csv/ \
  -v $DOCKER_CONFIG_DIR/aws_uploads/:/gic_query_results/ \
  --env-file $DOCKER_CONFIG_DIR/hpds/hpds.env \
  -d hms-dbmi/pic-sure-hpds:LATEST

docker stop httpd && docker rm httpd

docker run --name=httpd --restart always --network=picsure \
    -v /var/log/httpd-docker-logs/:/app/logs/ \
    -v $DOCKER_CONFIG_DIR/httpd/cert:/usr/local/apache2/cert/ \
    -v $DOCKER_CONFIG_DIR/httpd/httpd-vhosts.conf:/usr/local/apache2/conf/extra/httpd-vhosts.conf \
    $CUSTOM_HTTPD_VOLUMES \
    --env-file $DOCKER_CONFIG_DIR/httpd/httpd.env \
    -p 80:80 \
    -p 443:443 \
    -d hms-dbmi/pic-sure-frontend:LATEST
docker exec httpd sed -i '/^#LoadModule proxy_wstunnel_module/s/^#//' conf/httpd.conf
docker restart httpd

docker stop psama && docker rm psama
docker run --name=psama --restart always \
  --network=picsure \
  --env-file $DOCKER_CONFIG_DIR/psama/.env \
  $EMAIL_TEMPLATE_VOLUME \
  $PSAMA_TRUSTSTORE_VOLUME \
  -d hms-dbmi/psama:LATEST

docker stop wildfly && docker rm wildfly
docker run --name=wildfly --restart always --network=picsure -u root \
  -v /var/log/wildfly-docker-logs/:/opt/jboss/wildfly/standalone/log/ \
  -v /etc/hosts:/etc/hosts \
  -v /var/log/wildfly-docker-os-logs/:/var/log/ \
  -v $DOCKER_CONFIG_DIR/wildfly/passthru/:/opt/jboss/wildfly/standalone/configuration/passthru/ \
  -v $DOCKER_CONFIG_DIR/wildfly/aggregate-data-sharing/:/opt/jboss/wildfly/standalone/configuration/aggregate-data-sharing/ \
  -v $DOCKER_CONFIG_DIR/wildfly/visualization/:/opt/jboss/wildfly/standalone/configuration/visualization/ \
  -v $DOCKER_CONFIG_DIR/wildfly/deployments/:/opt/jboss/wildfly/standalone/deployments/ \
  -v $DOCKER_CONFIG_DIR/wildfly/standalone.xml:/opt/jboss/wildfly/standalone/configuration/standalone.xml \
  $TRUSTSTORE_VOLUME \
  $EMAIL_TEMPLATE_VOLUME \
  -v $DOCKER_CONFIG_DIR/wildfly/wildfly_mysql_module.xml:/opt/jboss/wildfly/modules/system/layers/base/com/sql/mysql/main/module.xml  \
  -v $DOCKER_CONFIG_DIR/wildfly/mysql-connector-java-5.1.49.jar:/opt/jboss/wildfly/modules/system/layers/base/com/sql/mysql/main/mysql-connector-java-5.1.49.jar  \
  --env-file $DOCKER_CONFIG_DIR/wildfly/wildfly.env \
  -d hms-dbmi/pic-sure-wildfly:LATEST

if [ -d $DOCKER_CONFIG_DIR/dictionary ]; then
  docker compose -f $DOCKER_CONFIG_DIR/dictionary/docker-compose.yml --env-file $DOCKER_CONFIG_DIR/dictionary/.env up -d
fi
