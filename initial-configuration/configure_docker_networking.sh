#!/bin/bash
ifacename=`docker network ls | awk '/picsure/ {print "br-"$1}'`
sysctl -w net.ipv4.conf.$ifacename.route_localnet=1
iptables -t nat -I PREROUTING -i $ifacename -d picsure-db -p tcp --dport 3306 -j DNAT --to 127.0.0.1:3306
iptables -t filter -I INPUT -i $ifacename -d 127.0.0.1 -p tcp --dport 3306 -j ACCEPT