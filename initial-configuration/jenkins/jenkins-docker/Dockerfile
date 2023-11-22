FROM jenkins/jenkins:2.421-jdk11

COPY plugins.yml /usr/share/jenkins/ref/plugins.yml

COPY config.xml /var/jenkins_home/config.xml

COPY scriptApproval.xml /var/jenkins_home/scriptApproval.xml

COPY hudson.tasks.Maven.xml /var/jenkins_home/hudson.tasks.Maven.xml

USER root 

RUN echo deb http://archive.debian.org/debian stretch-backports main >> /etc/apt/sources.list

RUN apt update

RUN curl -fsSL https://get.docker.com | sh

RUN docker --version

RUN apt -y -t stretch-backports install openjdk-11-jdk-headless

RUN apt -y install maven

RUN apt install jq -y

RUN apt -y install uuid-runtime

RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.yml; exit 0
