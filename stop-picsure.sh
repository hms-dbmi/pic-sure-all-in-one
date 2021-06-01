#!/usr/bin/env bash
docker stop hpds && docker rm hpds
docker stop httpd && docker rm httpd
docker stop wildfly && docker rm wildfly

