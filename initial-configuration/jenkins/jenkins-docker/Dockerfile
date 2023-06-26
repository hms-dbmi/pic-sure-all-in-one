FROM docker.io/jenkins/jenkins:lts-rhel-ubi8-jdk11

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt

COPY config.xml /var/jenkins_home/config.xml

COPY scriptApproval.xml /var/jenkins_home/scriptApproval.xml

COPY hudson.tasks.Maven.xml /var/jenkins_home/hudson.tasks.Maven.xml

USER root

RUN yum -y install dnf-utils wget yum-utils net-tools openssl iputils telnet jq java-11-openjdk dnsmasq zip

RUN yum -y install podman fuse-overlayfs --exclude container-selinux;

RUN dnf module install -y container-tools:rhel8

RUN yum -y install podman-plugins podman-remote

RUN yum install -y podman-docker

RUN alias docker=podman

RUN wget https://downloads.apache.org/maven/maven-3/3.9.3/binaries/apache-maven-3.9.3-bin.tar.gz -P /opt

RUN tar -xvzf /opt/apache-maven-3.9.3-bin.tar.gz -C /opt

RUN rm /opt/apache-maven-3.9.3-bin.tar.gz

RUN /usr/local/bin/install-plugins.sh < /usr/share/jenkins/ref/plugins.txt || echo "Some errors occurred during plugin installation."

