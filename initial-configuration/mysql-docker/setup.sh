if [ -z "$(docker ps --format '{{.Names}}' | grep picsure-db)" ]; then
  echo "Cleaning up old configs"
  rm -r "${DOCKER_CONFIG_DIR:?}"/*
  cp -r config/* "$DOCKER_CONFIG_DIR"/

  echo "Starting mysql server"
  echo "$( < /dev/urandom tr -dc @^=+$*%_A-Z-a-z-0-9 | head -c${1:-24})" > pass.tmp
  rm -f mysql-docker/.env
  # shellcheck disable=SC2129
  echo "PICSURE_DB_ROOT_PASS=`cat pass.tmp`" >> mysql-docker/.env
  echo "PICSURE_DB_PASS=`cat pass.tmp`" >> mysql-docker/.env
  echo "PICSURE_DB_DATABASE=ignore" >> mysql-docker/.env
  echo "PICSURE_DB_USER=ignore" >> mysql-docker/.env

  echo "Configuring .my.cnf"
  # shellcheck disable=SC2129
  echo "[mysql]" >> "$HOME"/.my.cnf
  echo "user=root" >> "$HOME"/.my.cnf
  echo "password=\"$(cat pass.tmp)\"" >> "$HOME"/.my.cnf
  echo "host=picsure-db" >> "$HOME"/.my.cnf
  echo "port=3306" >> "$HOME"/.my.cnf

  cd mysql-docker
  docker compose up -d

  echo "Waiting for MySQL to become healthy..."
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


  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "CREATE DATABASE picsure;"
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "CREATE DATABASE auth;"

  echo "` < /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-24}`" > airflow.tmp
  cat airflow.tmp
  docker exec -t picsure-db mysql -u root -p$(cat ../pass.tmp) -e "CREATE USER 'airflow'@'%' IDENTIFIED BY '$(cat airflow.tmp)';";
  docker exec -t picsure-db mysql -u root -p$(cat ../pass.tmp) -e "GRANT ALL PRIVILEGES ON auth.* TO 'airflow'@'%';FLUSH PRIVILEGES;";
  docker exec -t picsure-db mysql -u root -p$(cat ../pass.tmp) -e "GRANT ALL PRIVILEGES ON picsure.* TO 'airflow'@'%';FLUSH PRIVILEGES;";
  sed -i s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g $DOCKER_CONFIG_DIR/flyway/auth/flyway-auth.conf
  sed -i s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g $DOCKER_CONFIG_DIR/flyway/auth/sql.properties
  sed -i s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g $DOCKER_CONFIG_DIR/flyway/picsure/flyway-picsure.conf
  sed -i s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g $DOCKER_CONFIG_DIR/flyway/picsure/sql.properties
  rm -f airflow.tmp

  echo "` < /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-24}`" > picsure.tmp
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "CREATE USER 'picsure'@'%' IDENTIFIED BY '`cat picsure.tmp`';";
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "GRANT ALL PRIVILEGES ON picsure.* to 'picsure'@'%';FLUSH PRIVILEGES";
  sed -i s/__PIC_SURE_MYSQL_PASSWORD__/`cat picsure.tmp`/g $DOCKER_CONFIG_DIR/wildfly/standalone.xml
  rm -f picsure.tmp

  echo "` < /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-24}`" > auth.tmp
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "CREATE USER 'auth'@'%' IDENTIFIED BY '`cat auth.tmp`';";
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "GRANT ALL PRIVILEGES ON auth.* to 'auth'@'%';FLUSH PRIVILEGES;";
  sed -i s/__AUTH_MYSQL_PASSWORD__/`cat auth.tmp`/g $DOCKER_CONFIG_DIR/wildfly/standalone.xml
  rm -f auth.tmp

  cd $CWD
  rm -f pass.tmp
else
  echo "You are already running a docker container named picsure-db. If you want to remove it, do so manually"
  echo "Don't forget to rm the $DOCKER_CONFIG_DIR/picsure-db volume too"
fi