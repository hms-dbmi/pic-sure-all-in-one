#!/bin/bash
# =============================================================================
# PIC-SURE Database Initialization
# =============================================================================
# This script runs on first MySQL startup via /docker-entrypoint-initdb.d/
# It creates the databases and application users.
#
# MySQL's docker entrypoint:
#   - Only runs scripts in /docker-entrypoint-initdb.d/ on FIRST startup
#   - Provides $MYSQL_ROOT_PASSWORD in the environment
#   - Provides a `mysql` command that connects as root
# =============================================================================

set -e

echo "[picsure-init] Creating databases..."
mysql -u root -p"$MYSQL_ROOT_PASSWORD" <<-EOSQL
    CREATE DATABASE IF NOT EXISTS auth;
    CREATE DATABASE IF NOT EXISTS picsure;
EOSQL

echo "[picsure-init] Creating application users..."
mysql -u root -p"$MYSQL_ROOT_PASSWORD" <<-EOSQL
    CREATE USER IF NOT EXISTS 'picsure'@'%' IDENTIFIED BY '${DB_PICSURE_PASSWORD}';
    GRANT ALL PRIVILEGES ON picsure.* TO 'picsure'@'%';

    CREATE USER IF NOT EXISTS 'auth'@'%' IDENTIFIED BY '${DB_AUTH_PASSWORD}';
    GRANT ALL PRIVILEGES ON auth.* TO 'auth'@'%';

    CREATE USER IF NOT EXISTS 'airflow'@'%' IDENTIFIED BY '${DB_AIRFLOW_PASSWORD}';
    GRANT ALL PRIVILEGES ON auth.* TO 'airflow'@'%';
    GRANT ALL PRIVILEGES ON picsure.* TO 'airflow'@'%';

    FLUSH PRIVILEGES;
EOSQL

echo "[picsure-init] Database initialization complete."
