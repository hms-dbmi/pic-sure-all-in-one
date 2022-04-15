#!/usr/bin/env bash

if [ -f /usr/local/docker-config/setProxy.sh ]; then
   . /usr/local/docker-config/setProxy.sh
fi

docker run --user 0:0 -d --privileged  --device /dev/fuse --network=host \
 -e http_proxy=$http_proxy \
 -e https_proxy=$https_proxy \
 -e no_proxy=$no_proxy \
 -v /var/jenkins_home:/var/jenkins_home \
 -v /var/lib/containers:/var/lib/containers \
 -v /usr/local/docker-config:/usr/local/docker-config \
 -v /run/podman/podman.sock:/run/podman/podman.sock \
 -v /root/.my.cnf:/root/.my.cnf \
 -v /root/.m2:/root/.m2 \
 -v /etc/hosts:/etc/hosts \
 -e DOCKER_HOST=unix:///run/podman/podman.sock \
 -v /etc/cni/net.d:/etc/cni/net.d \
 -p 8080:8080 --name jenkins pic-sure-jenkins:LATEST

docker restart jenkins
