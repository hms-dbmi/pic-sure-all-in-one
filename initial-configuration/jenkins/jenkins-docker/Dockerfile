FROM docker.io/jenkins/jenkins:lts-rhel-ubi8-jdk11

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt

COPY config.xml /var/jenkins_home/config.xml

COPY scriptApproval.xml /var/jenkins_home/scriptApproval.xml

COPY hudson.tasks.Maven.xml /var/jenkins_home/hudson.tasks.Maven.xml

USER root

RUN yum -y install dnf-utils wget yum-utils net-tools

RUN dnf module install -y container-tools:rhel8

RUN yum -y install podman podman-remote

RUN systemctl enable podman.service

RUN systemctl enable podman.socket

RUN yum install -y podman-docker

RUN pwd

RUN whoami

RUN alias docker=podman

RUN podman --version

RUN docker --version

RUN wget https://www.apache.org/dist/maven/maven-3/3.6.3/binaries/apache-maven-3.6.3-bin.tar.gz -P /opt

RUN yum -y install java-11-openjdk

RUN tar -xvzf /opt/apache-maven-3.6.3-bin.tar.gz -C /opt

RUN rm /opt/apache-maven-3.6.3-bin.tar.gz

RUN yum install jq -y

RUN /usr/local/bin/install-plugins.sh < /usr/share/jenkins/ref/plugins.txt || echo "Some errors occurred during plugin installation."

RUN yum install -y iputils telnet