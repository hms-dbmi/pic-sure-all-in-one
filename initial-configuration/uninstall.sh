#!/usr/bin/env bash

DO_CONTAINERS=false
DO_DOCKER=false
DO_NETWORKING=false
DO_MYSQL=false
DO_LOGS=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Selectively uninstall PIC-SURE components.

Options:
  --containers   Stop/remove all Docker containers, images, and prune volumes
  --docker       Stop and uninstall Docker engine, remove /var/lib/docker and \$DOCKER_CONFIG_DIR
  --networking   Remove configure_docker_networks service and script
  --mysql        Stop and uninstall MariaDB, remove config and data dirs
  --logs         Remove log directories and jenkins_home dirs under \$DOCKER_CONFIG_DIR
  --destructive  All of the above
  --help         Show this help message
EOF
}

if [ $# -eq 0 ]; then
    usage
    exit 1
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --containers)  DO_CONTAINERS=true ;;
        --docker)      DO_DOCKER=true ;;
        --networking)  DO_NETWORKING=true ;;
        --mysql)       DO_MYSQL=true ;;
        --logs)        DO_LOGS=true ;;
        --destructive)
            DO_CONTAINERS=true
            DO_DOCKER=true
            DO_NETWORKING=true
            DO_MYSQL=true
            DO_LOGS=true
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
    shift
done

remove_containers() {
    echo "Removing Docker containers and images..."
    systemctl is-active --quiet docker
    if [ $? != "0" ]; then
        echo "Starting docker..."
        systemctl start docker
    fi

    containers=$(docker ps -a -q)
    if [ ! -z "$containers" ]; then
        docker stop $(docker ps -a -q)
        docker rm $(docker ps -a -q)
    fi
    images=$(docker images -a -q)
    if [ ! -z "$images" ]; then
        docker rmi $(docker images -a -q)
    fi
    docker system prune -a --volumes -f
    docker volume prune -a -f
}

remove_docker() {
    echo "Uninstalling Docker engine..."
    systemctl stop docker
    rm -rf "$DOCKER_CONFIG_DIR"
    yum -y remove docker-ce docker-ce-cli containerd.io
    rm -rf /var/lib/docker
}

remove_networking() {
    echo "Removing Docker networking service..."
    systemctl disable configure_docker_networks
    rm -f /etc/systemd/system/configure_docker_networks.service
    rm -f /root/configure_docker_networking.sh
}

remove_mysql() {
    echo "Uninstalling MariaDB..."
    systemctl stop mariadb
    yum -y remove mariadb-server mariadb-client mariadb
    rm -f /etc/my.cnf
    rm -f ~/.my.cnf
    rm -rf /var/lib/mysql
}

remove_logs() {
    echo "Removing logs and jenkins_home directories..."
    rm -rf "$DOCKER_CONFIG_DIR"/jenkins_home
    rm -rf "$DOCKER_CONFIG_DIR"/jenkins_home_bak
    rm -rf "$DOCKER_CONFIG_DIR"/log/httpd-docker-logs
    rm -rf "$DOCKER_CONFIG_DIR"/log/jenkins-docker-logs
    rm -rf "$DOCKER_CONFIG_DIR"/log/wildfly-docker-logs
    rm -rf "$DOCKER_CONFIG_DIR"/log/wildfly-docker-os-logs
    rm -rf "$DOCKER_CONFIG_DIR"/log/mysqld.log
}

$DO_CONTAINERS && remove_containers
$DO_DOCKER && remove_docker
$DO_NETWORKING && remove_networking
$DO_MYSQL && remove_mysql
$DO_LOGS && remove_logs
