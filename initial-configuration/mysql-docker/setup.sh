sed_inplace() {
  if sed --version 2>/dev/null | grep -q "GNU sed"; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

if [ -z "$(docker ps --format '{{.Names}}' | grep picsure-db)" ]; then
  echo "Cleaning up old configs"
  rm -r "${DOCKER_CONFIG_DIR:?}"/*
  cp -r config/* "$DOCKER_CONFIG_DIR"/
  rm -f "$MYSQL_CONFIG_DIR"/.my.cnf

  echo "Starting mysql server"
  echo "$( < /dev/urandom tr -dc @^=+$*%_A-Z-a-z-0-9 | head -c${1:-24})" > pass.tmp
  rm -f mysql-docker/.env

  # shellcheck disable=SC2129
  echo "PICSURE_DB_ROOT_PASS=`cat pass.tmp`" >> mysql-docker/.env
  echo "PICSURE_DB_PASS=`cat pass.tmp`" >> mysql-docker/.env
  echo "PICSURE_DB_DATABASE=ignore" >> mysql-docker/.env
  echo "PICSURE_DB_USER=ignore" >> mysql-docker/.env
  echo "DOCKER_CONFIG_DIR=$DOCKER_CONFIG_DIR" >> mysql-docker/.env

  echo "Configuring .my.cnf"
  # shellcheck disable=SC2129
  touch "$DOCKER_CONFIG_DIR"/.my.cnf
  echo "[mysql]" >> "$DOCKER_CONFIG_DIR"/.my.cnf
  echo "user=root" >> "$DOCKER_CONFIG_DIR"/.my.cnf
  echo "password=\"$(cat pass.tmp)\"" >> "$DOCKER_CONFIG_DIR"/.my.cnf
  echo "host=picsure-db" >> "$DOCKER_CONFIG_DIR"/.my.cnf
  echo "port=3306" >> "$DOCKER_CONFIG_DIR"/.my.cnf
  echo "Waiting for MySQL to become healthy..."

  cd mysql-docker
  docker compose up -d

  SECONDS=0
  TIMEOUT=180
  while [ $SECONDS -lt $TIMEOUT ]; do
      HEALTH=$(docker inspect --format='{{.State.Health.Status}}' picsure-db)
      if [ "$HEALTH" = "healthy" ]; then
          echo "MySQL is up and healthy."
          break
      fi
      echo "Waiting for MySQL to become healthy..."
      sleep 10
  done

  if [ "$HEALTH" != "healthy" ]; then
      echo "MySQL did not become healthy within $TIMEOUT seconds."
      exit
  fi

  echo "MYSQL_CONFIG_DIR $MYSQL_CONFIG_DIR"
  echo "DOCKER_CONFIG_DIR $DOCKER_CONFIG_DIR"
  mkdir -p "$MYSQL_CONFIG_DIR"
  cp "$DOCKER_CONFIG_DIR"/.my.cnf "$MYSQL_CONFIG_DIR"/.my.cnf
  docker cp "$MYSQL_CONFIG_DIR"/.my.cnf picsure-db:/root/.my.cnf

  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "CREATE DATABASE picsure;"
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "CREATE DATABASE auth;"

  echo "` < /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-24}`" > airflow.tmp
  cat airflow.tmp
  docker exec -t picsure-db mysql -u root -p$(cat ../pass.tmp) -e "CREATE USER 'airflow'@'%' IDENTIFIED BY '$(cat airflow.tmp)';";
  docker exec -t picsure-db mysql -u root -p$(cat ../pass.tmp) -e "GRANT ALL PRIVILEGES ON auth.* TO 'airflow'@'%';FLUSH PRIVILEGES;";
  docker exec -t picsure-db mysql -u root -p$(cat ../pass.tmp) -e "GRANT ALL PRIVILEGES ON picsure.* TO 'airflow'@'%';FLUSH PRIVILEGES;";
  sed_inplace s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g "$DOCKER_CONFIG_DIR/flyway/auth/flyway-auth.conf"
  sed_inplace s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g "$DOCKER_CONFIG_DIR/flyway/auth/sql.properties"
  sed_inplace s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g "$DOCKER_CONFIG_DIR/flyway/picsure/flyway-picsure.conf"
  sed_inplace s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g "$DOCKER_CONFIG_DIR/flyway/picsure/sql.properties"
  rm -f airflow.tmp

  echo "` < /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-24}`" > picsure.tmp
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "CREATE USER 'picsure'@'%' IDENTIFIED BY '`cat picsure.tmp`';";
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "GRANT ALL PRIVILEGES ON picsure.* to 'picsure'@'%';FLUSH PRIVILEGES";
  sed_inplace s/__PIC_SURE_MYSQL_PASSWORD__/`cat picsure.tmp`/g "$DOCKER_CONFIG_DIR/wildfly/standalone.xml"
  rm -f picsure.tmp

  echo "` < /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-24}`" > auth.tmp
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "CREATE USER 'auth'@'%' IDENTIFIED BY '`cat auth.tmp`';";
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "GRANT ALL PRIVILEGES ON auth.* to 'auth'@'%';FLUSH PRIVILEGES;";
  sed_inplace s/__AUTH_MYSQL_PASSWORD__/`cat auth.tmp`/g "$DOCKER_CONFIG_DIR/psama/.env"
  rm -f auth.tmp

  cd $CWD
  rm -f pass.tmp
else
  echo "You are already running a docker container named picsure-db. If you want to remove it, do so manually"
  echo "Don't forget to rm the $DOCKER_CONFIG_DIR/picsure-db volume too"
fi