if [ -z "$(docker ps --format '{{.Names}}' | grep picsure-db)" ]; then
  echo "Cleaning up old configs"
  rm -rf $DOCKER_CONFIG_DIR/picsure-db
  rm -rf $DOCKER_CONFIG_DIR/flyway/*
  rm -rf $DOCKER_CONFIG_DIR/wildfly/standalone.xml
  cp -r config/flyway/* $DOCKER_CONFIG_DIR/flyway/
  cp -r config/wildfly/standalone.xml $DOCKER_CONFIG_DIR/wildfly/standalone.xml

  echo "Starting mysql server"
  echo "`openssl rand -base64 12`" > pass.tmp
  rm -f mysql-docker/.env
  echo "PICSURE_DB_ROOT_PASS=`cat pass.tmp`" >> mysql-docker/.env
  echo "PICSURE_DB_PASS=`cat pass.tmp`" >> mysql-docker/.env
  echo "PICSURE_DB_DATABASE=ignore" >> mysql-docker/.env
  echo "PICSURE_DB_USER=ignore" >> mysql-docker/.env
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

  echo "`openssl rand -base64 12`" > airflow.tmp
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "CREATE USER 'airflow'@'%' IDENTIFIED BY '`cat airflow.tmp`';";
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "GRANT ALL PRIVILEGES ON auth.* TO 'airflow'@'%';FLUSH PRIVILEGES;";
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "GRANT ALL PRIVILEGES ON picsure.* TO 'airflow'@'%';FLUSH PRIVILEGES;";
  sed -i'' -e s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g $DOCKER_CONFIG_DIR/flyway/auth/flyway-auth.conf
  sed -i'' -e s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g $DOCKER_CONFIG_DIR/flyway/auth/sql.properties
  sed -i'' -e s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g $DOCKER_CONFIG_DIR/flyway/picsure/flyway-picsure.conf
  sed -i'' -e s/__AIRFLOW_MYSQL_PASSWORD__/`cat airflow.tmp`/g $DOCKER_CONFIG_DIR/flyway/picsure/sql.properties
  #rm -f airflow.tmp

  echo "`openssl rand -base64 12`" > picsure.tmp
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "CREATE USER 'picsure'@'%' IDENTIFIED BY '`cat picsure.tmp`';";
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "GRANT ALL PRIVILEGES ON picsure.* to 'picsure'@'%';FLUSH PRIVILEGES";
  sed -i'' -e s/__PIC_SURE_MYSQL_PASSWORD__/`cat picsure.tmp`/g $DOCKER_CONFIG_DIR/wildfly/standalone.xml
  #rm -f picsure.tmp

  echo "`openssl rand -base64 12`" > auth.tmp
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "CREATE USER 'auth'@'%' IDENTIFIED BY '`cat auth.tmp`';";
  docker exec -t picsure-db mysql -u root -p`cat ../pass.tmp` -e "GRANT ALL PRIVILEGES ON auth.* to 'auth'@'%';FLUSH PRIVILEGES;";
  sed -i'' -e s/__AUTH_MYSQL_PASSWORD__/`cat auth.tmp`/g $DOCKER_CONFIG_DIR/wildfly/standalone.xml
  #rm -f auth.tmp

  cd $CWD
  #rm -f pass.tmp
else
  echo "You are already running a docker container named picsure-db. If you want to remove it, do so manually"
  echo "Don't forget to rm the $DOCKER_CONFIG_DIR/picsure-db volume too"
fi