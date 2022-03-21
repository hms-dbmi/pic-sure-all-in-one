#!/bin/bash

CWD=`pwd`
cd /var/jenkins_home/jobs
sed -i 's:docker run --privileged:docker run:g' */config.xml
sed -i 's:--privileged --network=picsure -v:--network=picsure -v:g' */config.xml
kill -9 $(ps -ef | pgrep -f "java")
cd $CWD
