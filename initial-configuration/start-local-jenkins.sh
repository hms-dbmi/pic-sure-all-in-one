#!/bin/bash

echo "Starting Jenkins Locally"
systemctl start jenkins
echo "Jenkins Startup completed checkikng jeknins process"
ps -aef|grep jenkins
if (($(ps -ef | grep -v grep |grep jenkins | wc -l) > 0))
then
    echo "Jenkins is up and running"
else
    echo "Jenkins is Stopped not running please check the logs"
fi
