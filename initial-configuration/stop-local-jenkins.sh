#!/bin/bash

systemctl stop jenkins
sleep 5

if (($(ps -ef | grep -v grep |grep jenkins | wc -l) >= 0))
then
	echo "Jenkins is Stopped successfully"
else
	echo "Jenkins is still up and running please check the logs"
fi

