#!/usr/bin/env bash
docker stop hpds && docker rm -f hpds
docker stop httpd && docker rm -f httpd
docker stop wildfly && docker rm -f wildfly

sed  '/wildfly/d' /etc/hosts > hosts.new && cat hosts.new > /etc/hosts
sed  '/httpd/d' /etc/hosts > hosts.new && cat hosts.new > /etc/hosts
sed  '/hpds/d' /etc/hosts > hosts.new && cat hosts.new > /etc/hosts

