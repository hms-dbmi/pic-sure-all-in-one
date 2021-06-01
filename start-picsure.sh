#!/usr/bin/env bash

if [ -f "/usr/local/docker-config/setProxy.sh" ]; then
   . /usr/local/docker-config/setProxy.sh
fi

export WILDFLY_JAVA_OPTS="-Xms2g -Xmx4g -XX:MetaspaceSize=96M -XX:MaxMetaspaceSize=256m -Djava.net.preferIPv4Stack=true $PROXY_OPTS"
export HPDS_OPTS="-XX:+UseParallelGC -XX:SurvivorRatio=250 -Xms1g -Xmx16g -server -jar hpds.jar -httpPort 8080 -DCACHE_SIZE=1500 -DSMALL_TASK_THREADS=1 -DLARGE_TASK_THREADS=1 -DSMALL_JOB_LIMIT=100 -DID_BATCH_SIZE=2000 -DALL_IDS_CONCEPT=NONE -DID_CUBE_NAME=NONE"
export PICSURE_SETTINGS_VOLUME="-v /usr/local/docker-config/httpd/picsureui_settings.json:/usr/local/apache2/htdocs/picsureui/settings/settings.json"
export PSAMA_SETTINGS_VOLUME="-v /usr/local/docker-config/httpd/psamaui_settings.json:/usr/local/apache2/htdocs/psamaui/settings/settings.json"
export EMAIL_TEMPLATE_VOUME="-v /usr/local/docker-config/wildfly/emailTemplates:/opt/jboss/wildfly/standalone/configuration/emailTemplates "

docker stop hpds && docker rm hpds
docker run --name=hpds --restart always --network=picsure \
  -v /usr/local/docker-config/hpds:/opt/local/hpds \
  -v /usr/local/docker-config/hpds/all:/opt/local/hpds/all \
  -v /var/log/hpds-logs/:/var/log/ \
  --entrypoint=java \
  -d hms-dbmi/pic-sure-hpds:LATEST $HPDS_OPTS

docker stop httpd && docker rm httpd
docker run --name=httpd --restart always --network=picsure \
  -v /var/log/httpd-docker-logs/:/usr/local/apache2/logs/ \
  $PICSURE_SETTINGS_VOLUME \
  $PSAMA_SETTINGS_VOLUME \
  -v /usr/local/docker-config/httpd/cert:/usr/local/apache2/cert/ \
  -v /usr/local/docker-config/httpd/httpd-vhosts-ssloffload.conf:/usr/local/apache2/conf/extra/httpd-vhosts.conf \
  -p 80:80 \
  -p 443:443 \
  -d hms-dbmi/pic-sure-ui-overrides:LATEST
docker exec httpd sed -i '/^#LoadModule proxy_wstunnel_module/s/^#//' conf/httpd.conf
docker restart httpd

docker stop wildfly && docker rm wildfly
docker run --name=wildfly --restart always --network=picsure -u root \
  -v /var/log/wildfly-docker-logs/:/opt/jboss/wildfly/standalone/log/ \
  -v /var/log/wildfly-docker-os-logs/:/var/log/ \
  -v /usr/local/docker-config/wildfly/passthru/:/opt/jboss/wildfly/standalone/configuration/passthru/ \
  -v /usr/local/docker-config/wildfly/deployments/:/opt/jboss/wildfly/standalone/deployments/ \
  -v /usr/local/docker-config/wildfly/standalone.xml:/opt/jboss/wildfly/standalone/configuration/standalone.xml \
  $EMAIL_TEMPLATE_VOUME \
  -v /usr/local/docker-config/wildfly/wildfly_mysql_module.xml:/opt/jboss/wildfly/modules/system/layers/base/com/sql/mysql/main/module.xml  \
  -v /usr/local/docker-config/wildfly/mysql-connector-java-5.1.38.jar:/opt/jboss/wildfly/modules/system/layers/base/com/sql/mysql/main/mysql-connector-java-5.1.38.jar \
  -e JAVA_OPTS="$WILDFLY_JAVA_OPTS" \
  -d hms-dbmi/pic-sure-wildfly:LATEST

