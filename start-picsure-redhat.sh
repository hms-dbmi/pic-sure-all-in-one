#!/usr/bin/env bash

if [ -f "/usr/local/docker-config/setProxy.sh" ]; then
   . /usr/local/docker-config/setProxy.sh
fi


if [ -z "$(grep queryExportType /usr/local/docker-config/httpd/picsureui_settings.json | grep DISABLED)" ]; then
	export EXPORT_SIZE="2000";
else
	export EXPORT_SIZE="0";
fi

export WILDFLY_JAVA_OPTS="-Xms2g -Xmx4g -XX:MetaspaceSize=96M -XX:MaxMetaspaceSize=256m -Djava.net.preferIPv4Stack=true $PROXY_OPTS"
export HPDS_OPTS="-XX:+UseParallelGC -XX:SurvivorRatio=250 -Xms1g -Xmx16g -server -jar hpds.jar -httpPort 8080 -DCACHE_SIZE=1500 -DSMALL_TASK_THREADS=1 -DLARGE_TASK_THREADS=1 -DSMALL_JOB_LIMIT=100 -DID_BATCH_SIZE=$EXPORT_SIZE -DALL_IDS_CONCEPT=NONE -DID_CUBE_NAME=NONE"
export PICSURE_SETTINGS_VOLUME="-v /usr/local/docker-config/httpd/picsureui_settings.json:/usr/local/apache2/htdocs/picsureui/settings/settings.json"
export PSAMA_SETTINGS_VOLUME="-v /usr/local/docker-config/httpd/psamaui_settings.json:/usr/local/apache2/htdocs/picsureui/psamaui/settings/settings.json"
export EMAIL_TEMPLATE_VOUME="-v /usr/local/docker-config/wildfly/emailTemplates:/opt/jboss/wildfly/standalone/configuration/emailTemplates "

sed  '/wildfly/d' /etc/hosts > hosts.new && cat hosts.new > /etc/hosts
sed  '/httpd/d' /etc/hosts > hosts.new && cat hosts.new > /etc/hosts
sed  '/hpds/d' /etc/hosts > hosts.new && cat hosts.new > /etc/hosts

# these debug options can be added to wildfly or hpds container startup to enable remote debugging or profiling.
# Don't forget to add a port mapping too!
export DEBUG_OPTS="-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=0.0.0.0:8000"
export PROFILING_OPTS="-Dcom.sun.management.jmxremote.port=9000 -Dcom.sun.management.jmxremote.authenticate=false -Dcom.sun.management.jmxremote.ssl=false -Djava.rmi.server.hostname=localhost"

if [ -f /usr/local/docker-config/wildfly/application.truststore ]; then
	export TRUSTSTORE_VOLUME="-v /usr/local/docker-config/wildfly/application.truststore:/opt/jboss/wildfly/standalone/configuration/application.truststore"
   	export TRUSTSTORE_JAVA_OPTS="-Djavax.net.ssl.trustStore=/opt/jboss/wildfly/standalone/configuration/application.truststore -Djavax.net.ssl.trustStorePassword=password"
fi

docker network inspect picsure --format "{{.Name}}: {{.Id}}" 2>&1  ||  docker network create picsure
docker network inspect hpdsNet --format "{{.Name}}: {{.Id}}" 2>&1  ||  docker network create hpdsNet

docker stop hpds && docker rm -f hpds
docker run --name=hpds --hostname=hpds --restart always --network=hpdsNet \
  -v /etc/hosts:/etc/hosts \
  -v /usr/local/docker-config/hpds:/opt/local/hpds \
  -v /usr/local/docker-config/hpds/all:/opt/local/hpds/all \
  -v /var/log/hpds-logs/:/var/log/ \
  --entrypoint=java \
  -d hms-dbmi/pic-sure-hpds:LATEST $HPDS_OPTS

if [ -f /usr/local/docker-config/httpd/custom_httpd_volumes ]; then
	export CUSTOM_HTTPD_VOLUMES=`cat /usr/local/docker-config/httpd/custom_httpd_volumes`
fi

if [ -f /usr/local/docker-config/httpd/connections.json ]; then
        export CONNECTIONS_VOLUME="-v /usr/local/docker-config/httpd/connections.json:/usr/local/apache2/htdocs/picsureui/psamaui/login/connections.json"
fi

docker stop httpd && docker rm -f httpd
docker run --security-opt label=disable --name=httpd --hostname=httpd --restart always --network=picsure \
  -v /etc/hosts:/etc/hosts \
  -v /var/log/httpd-docker-logs/:/usr/local/apache2/logs/ \
  $PICSURE_SETTINGS_VOLUME \
  $PSAMA_SETTINGS_VOLUME \
  -v /usr/local/docker-config/httpd/cert:/usr/local/apache2/cert/ \
  $CUSTOM_HTTPD_VOLUMES \
  $CONNECTIONS_VOLUME \
  -p 80:80 \
  -p 443:443 \
  -d hms-dbmi/pic-sure-ui-overrides:LATEST
docker exec httpd sed -i '/^#LoadModule proxy_wstunnel_module/s/^#//' conf/httpd.conf
docker restart httpd

docker stop wildfly && docker rm -f wildfly
docker create --security-opt label=disable --name=wildfly --hostname=wildfly --restart always --network=picsure -u root \
  -v /var/log/wildfly-docker-logs/:/opt/jboss/wildfly/standalone/log/ \
  -v /etc/hosts:/etc/hosts \
  -v /var/log/wildfly-docker-os-logs/:/var/log/ \
  -v /usr/local/docker-config/wildfly/passthru/:/opt/jboss/wildfly/standalone/configuration/passthru/ \
  -v /usr/local/docker-config/wildfly/aggregate-data-sharing/:/opt/jboss/wildfly/standalone/configuration/aggregate-data-sharing/ \
  -v /usr/local/docker-config/wildfly/deployments/:/opt/jboss/wildfly/standalone/deployments/ \
  -v /usr/local/docker-config/wildfly/standalone.xml:/opt/jboss/wildfly/standalone/configuration/standalone.xml \
  $TRUSTSTORE_VOLUME \
  $EMAIL_TEMPLATE_VOUME \
  -v /usr/local/docker-config/wildfly/wildfly_mysql_module.xml:/opt/jboss/wildfly/modules/system/layers/base/com/sql/mysql/main/module.xml  \
  -v /usr/local/docker-config/wildfly/mysql-connector-java-5.1.49.jar:/opt/jboss/wildfly/modules/system/layers/base/com/sql/mysql/main/mysql-connector-java-5.1.49.jar  \
  -e JAVA_OPTS="$WILDFLY_JAVA_OPTS $TRUSTSTORE_JAVA_OPTS" \
   hms-dbmi/pic-sure-jbosseap:LATEST

docker network connect hpdsNet wildfly
docker start wildfly

httpIP=$(podman  inspect --format '{{ .NetworkSettings.Networks.picsure.IPAddress }}' httpd);
wildflyIP=$(podman  inspect --format '{{ .NetworkSettings.Networks.picsure.IPAddress }}' wildfly);
hpdsIP=$(podman  inspect --format '{{ .NetworkSettings.Networks.hpdsNet.IPAddress }}' hpds);

echo "$httpIP httpd httpd" >> /etc/hosts
echo "$wildflyIP wildfly wildfly" >> /etc/hosts
echo "$hpdsIP hpds hpds" >> /etc/hosts