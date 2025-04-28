# This script is used to migrate variable from the old start-picsure.sh
# which housed many configurable environment variables
# Those variables are now stored in their respective .env files in $DOCKER_CONFIG_DIR

# BEFORE running this script, run source start-picsure.sh


echo "Making config dirs for hpds, psama, httpd, and wildfly in $DOCKER_CONFIG_DIR"

mkdir -p $DOCKER_CONFIG_DIR/hpds
mkdir -p $DOCKER_CONFIG_DIR/psama
mkdir -p $DOCKER_CONFIG_DIR/httpd
mkdir -p $DOCKER_CONFIG_DIR/wildfly

echo "Populating config files with env vars from old start script"

echo "" >> $DOCKER_CONFIG_DIR/hpds/hpds.env
echo "CATALINA_OPTS= $HPDS_OPTS" >> $DOCKER_CONFIG_DIR/hpds/hpds.env

echo "" >> $DOCKER_CONFIG_DIR/psama/psama.env
echo "JAVA_OPTS=$PSAMA_OPTS" >> $DOCKER_CONFIG_DIR/psama/psama.env

echo "" >> $DOCKER_CONFIG_DIR/httpd/httpd.env

echo "" >> $DOCKER_CONFIG_DIR/wildfly/wildfly.env
echo "JAVA_OPTS=$WILDFLY_JAVA_OPTS $TRUSTSTORE_JAVA_OPTS" >> $DOCKER_CONFIG_DIR/wildfly/wildfly.env

echo "Done."
