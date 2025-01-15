#!/bin/bash
# If you would like to disable Jenkins login you can run this script.
# chmod +x disable_jenkins_security.sh
# ./disable_jenkins_security.sh

docker exec jenkins bash -c "sed -i 's/<useSecurity>true<\/useSecurity>/<useSecurity>false<\/useSecurity>/g' /var/jenkins_home/config.xml"
docker restart jenkins
