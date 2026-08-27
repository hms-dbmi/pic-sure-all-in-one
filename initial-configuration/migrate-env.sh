#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_CONFIG_DIR="${DOCKER_CONFIG_DIR:-/usr/local/docker-config}"
TEMPLATE_DIR="${MIGRATION_TEMPLATE_DIR:-$SCRIPT_DIR/config}"
SUMMARY=""

note() {
  echo "==> $1"
  SUMMARY="${SUMMARY}  - $1
"
}

fail() {
  echo "ERROR: $1" >&2
  exit 2
}

is_placeholder() {
  printf '%s' "$1" | grep -Eq '^__[A-Z_]+__$'
}

real_value() {
  local file=$1
  local key=$2
  local value

  value=$(sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -n 1)
  [ -n "$value" ] || return 1
  is_placeholder "$value" && return 1
  printf '%s\n' "$value"
}

complete_env() {
  local file=$1
  shift

  [ -f "$file" ] || return 1
  if grep -Eq '^[^#]*__[A-Z_]+__' "$file"; then
    return 1
  fi

  local key
  for key in "$@"; do
    real_value "$file" "$key" >/dev/null || return 1
  done
}

shared_value() {
  local key=$1
  shift
  local resolved=""
  local file
  local value

  for file in "$@"; do
    value=$(real_value "$file" "$key") || continue
    if [ -n "$resolved" ] && [ "$resolved" != "$value" ]; then
      fail "$key differs between existing env files; reconcile manually, then rerun"
    fi
    resolved="$value"
  done

  printf '%s\n' "$resolved"
}

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

file_owner() {
  if stat -c '%u:%g' "$1" >/dev/null 2>&1; then
    stat -c '%u:%g' "$1"
  else
    stat -f '%u:%g' "$1"
  fi
}

# mktemp creates files as 0600 and mv keeps that mode, which strips read
# access from files that services read as other users (e.g. bind-mounted
# httpd-vhosts.conf). Restore the target's mode and ownership before the
# rename; fall back to 0644 for brand-new files.
replace_file() {
  local temp_file=$1
  local target=$2

  if [ -f "$target" ]; then
    chmod "$(file_mode "$target")" "$temp_file"
    chown "$(file_owner "$target")" "$temp_file" 2>/dev/null || true
  else
    chmod 644 "$temp_file"
  fi
  mv "$temp_file" "$target"
}

upsert_env() {
  local key=$1
  local value=$2
  local file=$3
  local temp_file
  local existing_count
  local existing_value

  mkdir -p "$(dirname "$file")"
  if [ ! -f "$file" ]; then
    : > "$file"
  fi
  existing_count=$(grep -c "^${key}=" "$file" || true)
  existing_value=$(sed -n "s/^${key}=//p" "$file" | head -n 1)
  if [ "$existing_count" = 1 ] && [ "$existing_value" = "$value" ]; then
    return 0
  fi
  temp_file=$(mktemp "${file}.tmp.XXXXXX")

  awk -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    index($0, key "=") == 1 {
      if (!found) {
        print key "=" value
        found = 1
      }
      next
    }
    { print }
    END {
      if (!found) print key "=" value
    }
  ' "$file" > "$temp_file"
  replace_file "$temp_file" "$file"
}

migrate_legacy_options() {
  if [ -n "${HPDS_OPTS:-}" ]; then
    upsert_env CATALINA_OPTS " $HPDS_OPTS" "$DOCKER_CONFIG_DIR/hpds/hpds.env"
    note "hpds/hpds.env: migrated CATALINA_OPTS"
  fi

  if [ -n "${PSAMA_OPTS:-}" ]; then
    upsert_env JAVA_OPTS "$PSAMA_OPTS" "$DOCKER_CONFIG_DIR/psama/psama.env"
    note "psama/psama.env: migrated JAVA_OPTS"
  fi
}

find_source_xml() {
  local live_xml="$DOCKER_CONFIG_DIR/wildfly/standalone.xml"
  local candidate
  local newest=""

  if [ -f "$live_xml" ]; then
    printf '%s\n' "$live_xml"
    return 0
  fi

  for candidate in "$DOCKER_CONFIG_DIR"/wildfly.retired-*/standalone.xml; do
    [ -f "$candidate" ] || continue
    newest="$candidate"
  done
  printf '%s\n' "$newest"
}

xml_prop() {
  local source_xml=$1
  local name=$2
  [ -n "$source_xml" ] || return 0
  sed -n "s/.*java:global\/${name}\" value=\"\([^\"]*\)\".*/\1/p" "$source_xml" | head -n 1
}

xml_mysql_password() {
  local source_xml=$1
  [ -n "$source_xml" ] || return 0
  awk '
    /pool-name="PicsureDS"/ { in_picsure = 1 }
    in_picsure && /<password>/ {
      line = $0
      sub(/.*<password>/, "", line)
      sub(/<\/password>.*/, "", line)
      print line
      exit
    }
  ' "$source_xml"
}

valid_harvested_value() {
  local value=$1
  [ -n "$value" ] && ! is_placeholder "$value"
}

validate_substitution_value() {
  local name=$1
  local value=$2

  [ -n "$value" ] || fail "$name resolved to an empty value"
  is_placeholder "$value" && fail "$name resolved to an unsubstituted placeholder"
  case "$value" in
    *'|'*|*'&'*|*'\'*)
      fail "$name contains a character that is unsafe for environment-template substitution"
      ;;
  esac
}

install_env() {
  local subdirectory=$1
  local filename=$2
  shift 2
  local destination="$DOCKER_CONFIG_DIR/$subdirectory/$filename"
  local template="$TEMPLATE_DIR/$subdirectory/$filename"
  local backup="${destination}.pre-migration"
  local temp_file

  if complete_env "$destination" "$@"; then
    note "$subdirectory/$filename: already complete; left untouched"
    return 0
  fi

  [ -f "$template" ] || fail "migration template is missing: $template"
  mkdir -p "$(dirname "$destination")"
  if [ -f "$destination" ] && [ ! -f "$backup" ]; then
    cp "$destination" "$backup"
    note "$subdirectory/$filename: backed up incomplete file"
  fi

  temp_file=$(mktemp "${destination}.migration.XXXXXX")
  sed \
    -e "s|__TOKEN_INTROSPECTION_TOKEN__|$TOKEN_INTROSPECTION_TOKEN|g" \
    -e "s|__LOGGING_API_KEY__|$LOGGING_API_KEY|g" \
    -e "s|__PICSURE_APPLICATION_TOKEN__|$PICSURE_APPLICATION_TOKEN|g" \
    -e "s|__QUERY_SERVICE_INTERNAL_TOKEN__|$QUERY_SERVICE_INTERNAL_TOKEN|g" \
    -e "s|__PICSURE_MYSQL_PASSWORD__|$PICSURE_MYSQL_PASSWORD|g" \
    -e "s|__AGGREGATE_OBFUSCATION_SALT__|$AGGREGATE_OBFUSCATION_SALT|g" \
    "$template" > "$temp_file"
  replace_file "$temp_file" "$destination"
  complete_env "$destination" "$@" || fail "$subdirectory/$filename is incomplete after migration"
  note "$subdirectory/$filename: installed from current template"
}

migrate_gateway_open_access() {
  local gateway_env=$1
  local psama_env="$DOCKER_CONFIG_DIR/psama/psama.env"
  local open_access=false

  [ -f "$gateway_env" ] || return 0
  if [ -f "$psama_env" ]; then
    open_access=$(sed -n 's/^OPEN_IDP_PROVIDER_IS_ENABLED=//p' "$psama_env" | head -n 1)
  fi
  case "$open_access" in
    true|false) ;;
    *) open_access=false ;;
  esac

  upsert_env GATEWAY_OPEN_ACCESS_ENABLED "$open_access" "$gateway_env"
  note "gateway/gateway.env: open access set to $open_access to match psama.env"
}

migrate_service_envs() {
  local gateway_env="$DOCKER_CONFIG_DIR/gateway/gateway.env"
  local operations_env="$DOCKER_CONFIG_DIR/operations/operations.env"
  local query_env="$DOCKER_CONFIG_DIR/query/query.env"
  local logging_env="$DOCKER_CONFIG_DIR/logging/logging.env"
  local gateway_keys="TOKEN_INTROSPECTION_TOKEN LOGGING_API_KEY PICSURE_APPLICATION_TOKEN QUERY_SERVICE_INTERNAL_TOKEN"
  local operations_keys="SPRING_DATASOURCE_PASSWORD QUERY_SERVICE_INTERNAL_TOKEN PICSURE_APPLICATION_TOKEN"
  local query_keys="QUERY_SERVICE_INTERNAL_TOKEN AGGREGATE_OBFUSCATION_SALT PICSURE_APPLICATION_TOKEN"
  local source_xml
  local harvested_value
  local need_install=false

  source_xml=$(find_source_xml)

  QUERY_SERVICE_INTERNAL_TOKEN=$(shared_value QUERY_SERVICE_INTERNAL_TOKEN \
    "$gateway_env" "$operations_env" "$query_env")
  PICSURE_APPLICATION_TOKEN=$(shared_value PICSURE_APPLICATION_TOKEN \
    "$gateway_env" "$operations_env" "$query_env")
  LOGGING_API_KEY=$(shared_value LOGGING_API_KEY "$gateway_env" "$logging_env")

  # shellcheck disable=SC2086
  complete_env "$gateway_env" $gateway_keys || need_install=true
  # shellcheck disable=SC2086
  complete_env "$operations_env" $operations_keys || need_install=true
  # shellcheck disable=SC2086
  complete_env "$query_env" $query_keys || need_install=true

  TOKEN_INTROSPECTION_TOKEN=""
  PICSURE_MYSQL_PASSWORD=""
  AGGREGATE_OBFUSCATION_SALT=""

  if [ "$need_install" = true ]; then
    if TOKEN_INTROSPECTION_TOKEN=$(real_value "$gateway_env" TOKEN_INTROSPECTION_TOKEN); then
      note "TOKEN_INTROSPECTION_TOKEN: reused from existing gateway.env"
    else
      [ -n "$source_xml" ] || fail "required migration values are missing and no WildFly standalone.xml was found"
      harvested_value=$(xml_prop "$source_xml" token_introspection_token)
      valid_harvested_value "$harvested_value" || \
        fail "token_introspection_token is missing or unresolved in the WildFly configuration"
      TOKEN_INTROSPECTION_TOKEN="$harvested_value"
      note "TOKEN_INTROSPECTION_TOKEN: harvested from WildFly configuration"
    fi

    if PICSURE_MYSQL_PASSWORD=$(real_value "$operations_env" SPRING_DATASOURCE_PASSWORD); then
      note "PIC-SURE database password: reused from existing operations.env"
    else
      [ -n "$source_xml" ] || fail "required migration values are missing and no WildFly standalone.xml was found"
      harvested_value=$(xml_mysql_password "$source_xml")
      valid_harvested_value "$harvested_value" || \
        fail "PicsureDS password is missing or unresolved in the WildFly configuration"
      PICSURE_MYSQL_PASSWORD="$harvested_value"
      note "PIC-SURE database password: harvested from WildFly configuration"
    fi

    if [ -z "$QUERY_SERVICE_INTERNAL_TOKEN" ]; then
      QUERY_SERVICE_INTERNAL_TOKEN=$(openssl rand -hex 32)
      note "QUERY_SERVICE_INTERNAL_TOKEN: generated"
    else
      note "QUERY_SERVICE_INTERNAL_TOKEN: reused from existing env files"
    fi

    if [ -z "$PICSURE_APPLICATION_TOKEN" ]; then
      PICSURE_APPLICATION_TOKEN=$(openssl rand -hex 32)
      note "PICSURE_APPLICATION_TOKEN: generated"
    else
      note "PICSURE_APPLICATION_TOKEN: reused from existing env files"
    fi

    if AGGREGATE_OBFUSCATION_SALT=$(real_value "$query_env" AGGREGATE_OBFUSCATION_SALT); then
      note "AGGREGATE_OBFUSCATION_SALT: reused from existing query.env"
    else
      AGGREGATE_OBFUSCATION_SALT=$(openssl rand -hex 16)
      note "AGGREGATE_OBFUSCATION_SALT: generated"
    fi
  fi

  if [ -z "$LOGGING_API_KEY" ]; then
    harvested_value=$(xml_prop "$source_xml" logging_api_key)
    if valid_harvested_value "$harvested_value"; then
      LOGGING_API_KEY="$harvested_value"
      note "LOGGING_API_KEY: harvested from WildFly configuration"
    else
      LOGGING_API_KEY=$(openssl rand -hex 32)
      note "LOGGING_API_KEY: generated because no configured key was found"
    fi
  else
    note "LOGGING_API_KEY: reused from existing env files"
  fi

  if [ "$need_install" = true ]; then
    validate_substitution_value TOKEN_INTROSPECTION_TOKEN "$TOKEN_INTROSPECTION_TOKEN"
    validate_substitution_value PICSURE_MYSQL_PASSWORD "$PICSURE_MYSQL_PASSWORD"
    validate_substitution_value LOGGING_API_KEY "$LOGGING_API_KEY"
    validate_substitution_value QUERY_SERVICE_INTERNAL_TOKEN "$QUERY_SERVICE_INTERNAL_TOKEN"
    validate_substitution_value PICSURE_APPLICATION_TOKEN "$PICSURE_APPLICATION_TOKEN"
    validate_substitution_value AGGREGATE_OBFUSCATION_SALT "$AGGREGATE_OBFUSCATION_SALT"

    # shellcheck disable=SC2086
    install_env gateway gateway.env $gateway_keys
    # shellcheck disable=SC2086
    install_env operations operations.env $operations_keys
    # shellcheck disable=SC2086
    install_env query query.env $query_keys
  else
    note "gateway/operations/query env files are already complete"
  fi

  migrate_gateway_open_access "$gateway_env"

  if [ -f "$logging_env" ]; then
    upsert_env LOGGING_API_KEY "$LOGGING_API_KEY" "$logging_env"
    note "logging/logging.env: logging key synchronized"
  fi
}

migrate_actuator_exposure() {
  local relative_path
  local env_file

  for relative_path in \
    psama/psama.env \
    hpds/hpds.env \
    dictionary/dictionary.env \
    visualization/visualization.env \
    logging/logging.env; do
    env_file="$DOCKER_CONFIG_DIR/$relative_path"
    if [ ! -f "$env_file" ]; then
      note "$relative_path: not present; actuator migration skipped"
    elif grep -q '^PICSURE_ACTUATOR_EXPOSURE=' "$env_file"; then
      note "$relative_path: actuator exposure already configured"
    else
      upsert_env PICSURE_ACTUATOR_EXPOSURE health "$env_file"
      note "$relative_path: actuator health exposure added"
    fi
  done
}

migrate_httpd_routes() {
  local httpd_dir="$DOCKER_CONFIG_DIR/httpd"
  local config_file
  local temp_file
  local changed=false

  if [ ! -d "$httpd_dir" ]; then
    note "httpd: configuration directory not present; route migration skipped"
    return 0
  fi

  while IFS= read -r config_file; do
    if grep -q 'http://wildfly:8080/pic-sure-api-2/PICSURE/' "$config_file"; then
      temp_file=$(mktemp "${config_file}.migration.XXXXXX")
      sed 's|http://wildfly:8080/pic-sure-api-2/PICSURE/|http://gateway:8080/|g' \
        "$config_file" > "$temp_file"
      replace_file "$temp_file" "$config_file"
      note "httpd/$(basename "$config_file"): prepared gateway routing for the next restart"
      changed=true
    fi
  done < <(find "$httpd_dir" -type f -name '*.conf' -print | sort)

  # Repair configs that a previous run of this script left owner-only
  # (mktemp+mv made them 0600); httpd reads them as a different user.
  while IFS= read -r config_file; do
    chmod 644 "$config_file"
    note "httpd/$(basename "$config_file"): restored world-readable permissions"
    changed=true
  done < <(find "$httpd_dir" -type f -name '*.conf' ! -perm -004 -print | sort)

  if find "$httpd_dir" -type f -name '*.conf' -exec grep -l 'wildfly:8080' {} + 2>/dev/null | grep -q .; then
    fail "unrecognized WildFly references remain in active HTTPD *.conf files"
  fi

  if [ "$changed" = false ]; then
    note "httpd: active configuration already routes away from WildFly"
  fi
}

migrate_email_templates() {
  local source_dir="$DOCKER_CONFIG_DIR/wildfly/emailTemplates"
  local destination_dir="$DOCKER_CONFIG_DIR/psama/emailTemplates"

  if [ ! -d "$source_dir" ] || ! find "$source_dir" -mindepth 1 -maxdepth 1 -print | grep -q .; then
    note "emailTemplates: no legacy WildFly templates to copy"
    return 0
  fi

  if [ -d "$destination_dir" ] && find "$destination_dir" -mindepth 1 -maxdepth 1 -print | grep -q .; then
    note "emailTemplates: PSAMA destination already populated; left untouched"
    return 0
  fi

  mkdir -p "$destination_dir"
  cp -R "$source_dir/." "$destination_dir/"
  note "emailTemplates: copied legacy WildFly templates to PSAMA; source retained"
}

[ -d "$DOCKER_CONFIG_DIR" ] || fail "DOCKER_CONFIG_DIR '$DOCKER_CONFIG_DIR' is not a directory"
[ -d "$TEMPLATE_DIR" ] || fail "migration template directory '$TEMPLATE_DIR' is not a directory"

migrate_legacy_options
migrate_service_envs
migrate_actuator_exposure
migrate_httpd_routes
migrate_email_templates

echo ""
echo "================ migration summary ================"
if [ -n "$SUMMARY" ]; then
  printf '%s' "$SUMMARY"
else
  echo "  - No applicable environment changes"
fi
echo "==================================================="
echo "Next: run 'PIC-SURE Database Migrations', then 'PIC-SURE Pipeline' to perform the restart cutover."
