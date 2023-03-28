#!/bin/bash

JENKINS_VERSION="2.387.1"

echo "Upgrading jenkins to "$JENKINS_VERSION

start_jenkins()
{
	if (($(ps -ef | grep -v grep |grep jenkins | wc -l) > 0))
	then
	    echo "Jenkins is running"
	else
	    echo "Starting jenkins..."
	    systemctl start jenkins
	    sleep 15
	    echo "Started jenkins...completed"
	fi
}

stop_jenkins()
{	
	if (($(ps -ef | grep -v grep |grep jenkins | wc -l) > 0))
	then
		echo "Stopping jenkins...."
	    systemctl stop jenkins
	    sleep 10
	else
		echo "Jenkins is not running"
	fi
}

update_jenkins()
{
	echo "Download the Jenkins version"
    cd /usr/share/jenkins
	rm -rf jenkins.war
	wget https://get.jenkins.io/war-stable/$JENKINS_VERSION/jenkins.war
}

stop_jenkins
update_jenkins
start_jenkins

