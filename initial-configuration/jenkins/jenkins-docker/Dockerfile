FROM jenkins/jenkins:2.421-jdk11

COPY plugins.yml /usr/share/jenkins/ref/plugins.yml

COPY config.xml /var/jenkins_home/config.xml

COPY scriptApproval.xml /var/jenkins_home/scriptApproval.xml

COPY hudson.tasks.Maven.xml /var/jenkins_home/hudson.tasks.Maven.xml

USER root 

RUN echo deb http://archive.debian.org/debian stretch-backports main >> /etc/apt/sources.list

RUN apt-get update

RUN curl -fsSL https://get.docker.com | sh

RUN docker --version

RUN apt-get -y -t stretch-backports install openjdk-11-jdk-headless

RUN apt-get -y install maven

RUN apt-get install jq -y

RUN apt-get -y install uuid-runtime

#Installing chrome for running selenium test
RUN apt-get -y install wget
RUN wget https://dl-ssl.google.com/linux/linux_signing_key.pub -O /tmp/google.pub
RUN gpg --no-default-keyring --keyring /etc/apt/keyrings/google-chrome.gpg --import /tmp/google.pub
RUN echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main' | tee /etc/apt/sources.list.d/google-chrome.list
RUN apt-get update
RUN apt-get -y install google-chrome-stable

RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.yml
