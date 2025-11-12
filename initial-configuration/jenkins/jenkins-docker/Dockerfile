FROM jenkins/jenkins:2.536-jdk21

COPY plugins.yml /usr/share/jenkins/ref/plugins.yml
COPY config.xml /var/jenkins_home/config.xml
COPY scriptApproval.xml /var/jenkins_home/scriptApproval.xml
COPY hudson.tasks.Maven.xml /var/jenkins_home/hudson.tasks.Maven.xml

USER root 

RUN echo deb http://archive.debian.org/debian stretch-backports main >> /etc/apt/sources.list

RUN apt-get update
RUN apt-get -y install apt-utils
RUN apt-get -y install maven
RUN apt-get -y install jq

RUN curl -fsSL https://get.docker.com | sh
RUN docker --version

RUN apt-get -y install uuid-runtime

RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.yml
