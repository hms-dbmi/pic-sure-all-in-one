FROM jenkins/jenkins:2.442-jdk11

COPY plugins.yml /usr/share/jenkins/ref/plugins.yml

COPY config.xml /var/jenkins_home/config.xml

COPY scriptApproval.xml /var/jenkins_home/scriptApproval.xml

COPY hudson.tasks.Maven.xml /var/jenkins_home/hudson.tasks.Maven.xml

USER root 

RUN echo deb http://archive.debian.org/debian stretch-backports main >> /etc/apt/sources.list

RUN apt-get update

RUN curl -fsSL https://get.docker.com | sh

RUN docker --version

RUN apt-get -y install maven


RUN apt-get install jq -y

# java 21
RUN apt-get install wget -y

RUN wget https://download.java.net/java/GA/jdk21.0.1/415e3f918a1f4062a0074a2794853d0d/12/GPL/openjdk-21.0.1_linux-x64_bin.tar.gz

RUN tar -xvf openjdk-21.0.1_linux-x64_bin.tar.gz

RUN mv jdk-21.0.1 /opt/java/

RUN apt-get -y install uuid-runtime

RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.yml
