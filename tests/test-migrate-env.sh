#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATION_SCRIPT="$ROOT_DIR/initial-configuration/migrate-env.sh"
TEMPLATE_DIR="$ROOT_DIR/initial-configuration/config"
TEST_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

env_value() {
  local key=$1
  local file=$2
  sed -n "s/^${key}=//p" "$file" | head -n 1
}

file_inode() {
  ls -di "$1" | awk '{print $1}'
}

file_mtime() {
  if stat -c '%Y' "$1" >/dev/null 2>&1; then
    stat -c '%Y' "$1"
  else
    stat -f '%m' "$1"
  fi
}

assert_line_count() {
  local expected=$1
  local pattern=$2
  local file=$3
  local actual
  actual=$(grep -c "$pattern" "$file" || true)
  [ "$actual" = "$expected" ] || fail "expected $expected line(s) matching $pattern in $file, found $actual"
}

assert_contains() {
  local file=$1
  local text=$2
  grep -Fq "$text" "$file" || fail "$file does not contain: $text"
}

assert_not_contains() {
  local file=$1
  local text=$2
  if grep -Fq "$text" "$file"; then
    fail "$file unexpectedly contains: $text"
  fi
}

replace_text() {
  local expression=$1
  local file=$2
  local temp_file
  temp_file=$(mktemp "${file}.test.XXXXXX")
  sed "$expression" "$file" > "$temp_file"
  mv "$temp_file" "$file"
}

seed_complete_service_envs() {
  local config_dir=$1
  mkdir -p \
    "$config_dir/gateway" \
    "$config_dir/operations" \
    "$config_dir/query" \
    "$config_dir/logging"

  cp "$TEMPLATE_DIR/gateway/gateway.env" "$config_dir/gateway/gateway.env"
  cp "$TEMPLATE_DIR/operations/operations.env" "$config_dir/operations/operations.env"
  cp "$TEMPLATE_DIR/query/query.env" "$config_dir/query/query.env"
  cp "$TEMPLATE_DIR/logging/logging.env" "$config_dir/logging/logging.env"

  for env_file in \
    "$config_dir/gateway/gateway.env" \
    "$config_dir/operations/operations.env" \
    "$config_dir/query/query.env" \
    "$config_dir/logging/logging.env"; do
    local temp_file
    temp_file=$(mktemp "${env_file}.test.XXXXXX")
    sed \
      -e 's/__TOKEN_INTROSPECTION_TOKEN__/existing-introspection/g' \
      -e 's/__LOGGING_API_KEY__/existing-logging/g' \
      -e 's/__PICSURE_APPLICATION_TOKEN__/existing-application/g' \
      -e 's/__QUERY_SERVICE_INTERNAL_TOKEN__/existing-internal/g' \
      -e 's/__PICSURE_MYSQL_PASSWORD__/existing-database/g' \
      -e 's/__AGGREGATE_OBFUSCATION_SALT__/existing-salt/g' \
      "$env_file" > "$temp_file"
    mv "$temp_file" "$env_file"
  done
}

seed_legacy_config() {
  local config_dir=$1
  mkdir -p "$config_dir/wildfly" "$config_dir/logging"
  cp "$TEMPLATE_DIR/logging/logging.env" "$config_dir/logging/logging.env"
  cat > "$config_dir/wildfly/standalone.xml" <<'EOF'
<server>
  <datasource pool-name="PicsureDS">
    <security>
      <user-name>picsure</user-name>
      <password>db-secret</password>
    </security>
  </datasource>
  <simple name="java:global/token_introspection_token" value="intro-secret"/>
  <simple name="java:global/logging_api_key" value="logging-secret"/>
</server>
EOF
}

run_migration() {
  local config_dir=$1
  shift
  DOCKER_CONFIG_DIR="$config_dir" \
    MIGRATION_TEMPLATE_DIR="$TEMPLATE_DIR" \
    "$MIGRATION_SCRIPT" "$@"
}

run_legacy_options_test() {
  local config_dir="$TEST_TMP_DIR/legacy-options"
  seed_complete_service_envs "$config_dir"
  mkdir -p "$config_dir/hpds" "$config_dir/psama"
  printf 'OTHER_HPDS_SETTING=true\n' > "$config_dir/hpds/hpds.env"
  printf 'OTHER_PSAMA_SETTING=true\n' > "$config_dir/psama/psama.env"

  DOCKER_CONFIG_DIR="$config_dir" \
    MIGRATION_TEMPLATE_DIR="$TEMPLATE_DIR" \
    HPDS_OPTS='-Xmx4g' \
    PSAMA_OPTS='-Xmx2g' \
    "$MIGRATION_SCRIPT" >/dev/null
  local hpds_inode
  local psama_inode
  touch -t 200001010000 "$config_dir/hpds/hpds.env" "$config_dir/psama/psama.env"
  hpds_inode=$(file_inode "$config_dir/hpds/hpds.env")
  psama_inode=$(file_inode "$config_dir/psama/psama.env")
  local hpds_mtime
  local psama_mtime
  hpds_mtime=$(file_mtime "$config_dir/hpds/hpds.env")
  psama_mtime=$(file_mtime "$config_dir/psama/psama.env")

  DOCKER_CONFIG_DIR="$config_dir" \
    MIGRATION_TEMPLATE_DIR="$TEMPLATE_DIR" \
    HPDS_OPTS='-Xmx4g' \
    PSAMA_OPTS='-Xmx2g' \
    "$MIGRATION_SCRIPT" >/dev/null

  assert_line_count 1 '^CATALINA_OPTS=' "$config_dir/hpds/hpds.env"
  assert_line_count 1 '^JAVA_OPTS=' "$config_dir/psama/psama.env"
  [ "$(env_value CATALINA_OPTS "$config_dir/hpds/hpds.env")" = ' -Xmx4g' ] || \
    fail "CATALINA_OPTS was not migrated"
  [ "$(env_value JAVA_OPTS "$config_dir/psama/psama.env")" = '-Xmx2g' ] || \
    fail "JAVA_OPTS was not migrated"
  [ "$hpds_inode" = "$(file_inode "$config_dir/hpds/hpds.env")" ] || \
    fail "unchanged HPDS env was replaced on rerun"
  [ "$psama_inode" = "$(file_inode "$config_dir/psama/psama.env")" ] || \
    fail "unchanged PSAMA env was replaced on rerun"
  [ "$hpds_mtime" = "$(file_mtime "$config_dir/hpds/hpds.env")" ] || \
    fail "unchanged HPDS env timestamp changed on rerun"
  [ "$psama_mtime" = "$(file_mtime "$config_dir/psama/psama.env")" ] || \
    fail "unchanged PSAMA env timestamp changed on rerun"

  echo "Legacy option migration checks passed"
}

run_secret_migration_test() {
  local config_dir="$TEST_TMP_DIR/secrets"
  local output_file="$TEST_TMP_DIR/secrets-output.txt"
  seed_legacy_config "$config_dir"

  run_migration "$config_dir" > "$output_file" 2>&1

  local gateway_env="$config_dir/gateway/gateway.env"
  local operations_env="$config_dir/operations/operations.env"
  local query_env="$config_dir/query/query.env"
  local logging_env="$config_dir/logging/logging.env"

  assert_contains "$gateway_env" 'TOKEN_INTROSPECTION_TOKEN=intro-secret'
  assert_contains "$operations_env" 'SPRING_DATASOURCE_PASSWORD=db-secret'
  assert_contains "$gateway_env" 'LOGGING_API_KEY=logging-secret'
  assert_contains "$logging_env" 'LOGGING_API_KEY=logging-secret'

  local internal_token
  local application_token
  local obfuscation_salt
  internal_token=$(env_value QUERY_SERVICE_INTERNAL_TOKEN "$gateway_env")
  application_token=$(env_value PICSURE_APPLICATION_TOKEN "$gateway_env")
  obfuscation_salt=$(env_value AGGREGATE_OBFUSCATION_SALT "$query_env")
  [ -n "$internal_token" ] || fail "internal token was not generated"
  [ -n "$application_token" ] || fail "application token was not generated"
  [ -n "$obfuscation_salt" ] || fail "obfuscation salt was not generated"
  [ "$internal_token" = "$(env_value QUERY_SERVICE_INTERNAL_TOKEN "$operations_env")" ] || \
    fail "operations internal token differs"
  [ "$internal_token" = "$(env_value QUERY_SERVICE_INTERNAL_TOKEN "$query_env")" ] || \
    fail "query internal token differs"
  [ "$application_token" = "$(env_value PICSURE_APPLICATION_TOKEN "$operations_env")" ] || \
    fail "operations application token differs"
  [ "$application_token" = "$(env_value PICSURE_APPLICATION_TOKEN "$query_env")" ] || \
    fail "query application token differs"

  for env_file in "$gateway_env" "$operations_env" "$query_env"; do
    if grep -Eq '^[^#]*__[A-Z_]+__' "$env_file"; then
      fail "$env_file retains an active placeholder"
    fi
  done
  for secret in intro-secret db-secret logging-secret "$internal_token" "$application_token" "$obfuscation_salt"; do
    assert_not_contains "$output_file" "$secret"
  done

  local missing_dir="$TEST_TMP_DIR/missing-source"
  mkdir -p "$missing_dir/logging"
  cp "$TEMPLATE_DIR/logging/logging.env" "$missing_dir/logging/logging.env"
  cp "$missing_dir/logging/logging.env" "$missing_dir/logging.before"
  if run_migration "$missing_dir" > "$TEST_TMP_DIR/missing-output.txt" 2>&1; then
    fail "migration succeeded without existing env values or WildFly configuration"
  fi
  cmp -s "$missing_dir/logging.before" "$missing_dir/logging/logging.env" || \
    fail "logging env changed before required secrets were validated"
  [ ! -e "$missing_dir/gateway/gateway.env" ] || fail "gateway env was written before validation"
  [ ! -e "$missing_dir/operations/operations.env" ] || fail "operations env was written before validation"
  [ ! -e "$missing_dir/query/query.env" ] || fail "query env was written before validation"

  local conflict_dir="$TEST_TMP_DIR/conflict"
  seed_complete_service_envs "$conflict_dir"
  replace_text 's/QUERY_SERVICE_INTERNAL_TOKEN=existing-internal/QUERY_SERVICE_INTERNAL_TOKEN=conflicting-internal/' \
    "$conflict_dir/operations/operations.env"
  local conflict_before
  conflict_before=$(cksum "$conflict_dir/operations/operations.env")
  if run_migration "$conflict_dir" > "$TEST_TMP_DIR/conflict-output.txt" 2>&1; then
    fail "migration succeeded with conflicting shared tokens"
  fi
  [ "$conflict_before" = "$(cksum "$conflict_dir/operations/operations.env")" ] || \
    fail "conflicting env changed on validation failure"

  echo "Secret resolution and validation checks passed"
}

run_idempotency_test() {
  local config_dir="$TEST_TMP_DIR/idempotency"
  seed_legacy_config "$config_dir"
  run_migration "$config_dir" >/dev/null

  local before
  before=$(cksum \
    "$config_dir/gateway/gateway.env" \
    "$config_dir/operations/operations.env" \
    "$config_dir/query/query.env" \
    "$config_dir/logging/logging.env")
  local backup_count_before
  backup_count_before=$(find "$config_dir" -name '*.pre-migration' -type f | wc -l | tr -d ' ')
  touch -t 200001010000 \
    "$config_dir/gateway/gateway.env" \
    "$config_dir/operations/operations.env" \
    "$config_dir/query/query.env" \
    "$config_dir/logging/logging.env"
  local inode_before
  inode_before="$(file_inode "$config_dir/gateway/gateway.env") \
$(file_inode "$config_dir/operations/operations.env") \
$(file_inode "$config_dir/query/query.env") \
$(file_inode "$config_dir/logging/logging.env")"
  local mtime_before
  mtime_before="$(file_mtime "$config_dir/gateway/gateway.env") \
$(file_mtime "$config_dir/operations/operations.env") \
$(file_mtime "$config_dir/query/query.env") \
$(file_mtime "$config_dir/logging/logging.env")"

  run_migration "$config_dir" >/dev/null

  [ "$before" = "$(cksum \
    "$config_dir/gateway/gateway.env" \
    "$config_dir/operations/operations.env" \
    "$config_dir/query/query.env" \
    "$config_dir/logging/logging.env")" ] || fail "successful rerun changed environment files"
  [ "$backup_count_before" = "$(find "$config_dir" -name '*.pre-migration' -type f | wc -l | tr -d ' ')" ] || \
    fail "successful rerun created an additional backup"
  [ "$inode_before" = "$(file_inode "$config_dir/gateway/gateway.env") \
$(file_inode "$config_dir/operations/operations.env") \
$(file_inode "$config_dir/query/query.env") \
$(file_inode "$config_dir/logging/logging.env")" ] || fail "successful rerun replaced an unchanged environment file"
  [ "$mtime_before" = "$(file_mtime "$config_dir/gateway/gateway.env") \
$(file_mtime "$config_dir/operations/operations.env") \
$(file_mtime "$config_dir/query/query.env") \
$(file_mtime "$config_dir/logging/logging.env")" ] || fail "successful rerun changed unchanged environment-file metadata"

  local gateway_before
  local operations_before
  gateway_before=$(cksum "$config_dir/gateway/gateway.env")
  operations_before=$(cksum "$config_dir/operations/operations.env")
  replace_text 's/AGGREGATE_OBFUSCATION_SALT=.*/AGGREGATE_OBFUSCATION_SALT=__AGGREGATE_OBFUSCATION_SALT__/' \
    "$config_dir/query/query.env"

  run_migration "$config_dir" >/dev/null
  [ "$gateway_before" = "$(cksum "$config_dir/gateway/gateway.env")" ] || fail "complete gateway env was rewritten"
  [ "$operations_before" = "$(cksum "$config_dir/operations/operations.env")" ] || fail "complete operations env was rewritten"
  [ -f "$config_dir/query/query.env.pre-migration" ] || fail "incomplete query env was not backed up"
  [ -n "$(env_value AGGREGATE_OBFUSCATION_SALT "$config_dir/query/query.env")" ] || \
    fail "query obfuscation salt was not repaired"
  assert_not_contains "$config_dir/query/query.env" '__AGGREGATE_OBFUSCATION_SALT__'
  run_migration "$config_dir" >/dev/null
  [ "$(find "$config_dir/query" -name 'query.env.pre-migration*' -type f | wc -l | tr -d ' ')" = 1 ] || \
    fail "partial-recovery rerun created another backup"

  echo "Environment migration idempotency checks passed"
}

run_ancillary_migration_test() {
  local config_dir="$TEST_TMP_DIR/ancillary"
  seed_complete_service_envs "$config_dir"
  mkdir -p \
    "$config_dir/httpd" \
    "$config_dir/wildfly/emailTemplates" \
    "$config_dir/psama/emailTemplates" \
    "$config_dir/hpds" \
    "$config_dir/dictionary" \
    "$config_dir/visualization"

  cat > "$config_dir/httpd/httpd-vhosts.conf" <<'EOF'
RewriteRule ^/picsure/(.*)$ "http://wildfly:8080/pic-sure-api-2/PICSURE/$1" [P,L]
EOF
  cat > "$config_dir/httpd/httpd-vhosts-ssloffload.conf" <<'EOF'
RewriteRule ^/picsure/(.*)$ http://wildfly:8080/pic-sure-api-2/PICSURE/$1 [P]
EOF
  printf 'http://wildfly:8080/backup-only\n' > "$config_dir/httpd/httpd-vhosts.conf.pre-migration"
  printf 'legacy template\n' > "$config_dir/wildfly/emailTemplates/legacy.html"
  printf 'HPDS_SETTING=true\n' > "$config_dir/hpds/hpds.env"
  printf 'PSAMA_SETTING=true\n' > "$config_dir/psama/psama.env"
  printf 'DICTIONARY_SETTING=true\n' > "$config_dir/dictionary/dictionary.env"
  printf 'VISUALIZATION_SETTING=true\n' > "$config_dir/visualization/visualization.env"

  run_migration "$config_dir" >/dev/null

  assert_contains "$config_dir/httpd/httpd-vhosts.conf" 'http://gateway:8080/$1'
  assert_contains "$config_dir/httpd/httpd-vhosts-ssloffload.conf" 'http://gateway:8080/$1'
  assert_contains "$config_dir/httpd/httpd-vhosts.conf.pre-migration" 'http://wildfly:8080/backup-only'
  assert_contains "$config_dir/wildfly/emailTemplates/legacy.html" 'legacy template'
  assert_contains "$config_dir/psama/emailTemplates/legacy.html" 'legacy template'

  for env_file in \
    "$config_dir/hpds/hpds.env" \
    "$config_dir/psama/psama.env" \
    "$config_dir/dictionary/dictionary.env" \
    "$config_dir/visualization/visualization.env" \
    "$config_dir/logging/logging.env"; do
    assert_line_count 1 '^PICSURE_ACTUATOR_EXPOSURE=' "$env_file"
  done

  printf 'new legacy template\n' > "$config_dir/wildfly/emailTemplates/new.html"
  printf 'destination owned\n' > "$config_dir/psama/emailTemplates/destination.txt"
  run_migration "$config_dir" >/dev/null
  [ ! -e "$config_dir/psama/emailTemplates/new.html" ] || \
    fail "non-empty PSAMA email template destination was overwritten"
  for env_file in \
    "$config_dir/hpds/hpds.env" \
    "$config_dir/psama/psama.env" \
    "$config_dir/dictionary/dictionary.env" \
    "$config_dir/visualization/visualization.env" \
    "$config_dir/logging/logging.env"; do
    assert_line_count 1 '^PICSURE_ACTUATOR_EXPOSURE=' "$env_file"
  done

  local unknown_dir="$TEST_TMP_DIR/unknown-route"
  seed_complete_service_envs "$unknown_dir"
  mkdir -p "$unknown_dir/httpd"
  printf 'ProxyPass /custom http://wildfly:8080/custom\n' > "$unknown_dir/httpd/custom.conf"
  if run_migration "$unknown_dir" > "$TEST_TMP_DIR/unknown-route-output.txt" 2>&1; then
    fail "migration accepted an unrecognized active WildFly route"
  fi

  assert_not_contains "$MIGRATION_SCRIPT" 'docker stop wildfly'
  assert_not_contains "$MIGRATION_SCRIPT" 'docker rm wildfly'
  assert_not_contains "$MIGRATION_SCRIPT" 'mv "$DOCKER_CONFIG_DIR/wildfly"'
  assert_not_contains "$MIGRATION_SCRIPT" 'rm -rf "$DOCKER_CONFIG_DIR/wildfly"'

  echo "Ancillary environment migration checks passed"
}

case "${1:-all}" in
  legacy-options)
    run_legacy_options_test
    ;;
  secrets)
    run_secret_migration_test
    ;;
  idempotency)
    run_idempotency_test
    ;;
  ancillary)
    run_ancillary_migration_test
    ;;
  all)
    run_legacy_options_test
    run_secret_migration_test
    run_idempotency_test
    run_ancillary_migration_test
    ;;
  *)
    fail "unknown test group: $1"
    ;;
esac
