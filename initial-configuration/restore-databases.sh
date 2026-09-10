#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: restore-databases.sh BACKUP_DIRECTORY [--yes]

Restore a directory created by backup-databases.sh. This DROPS and recreates auth,
picsure, and the dictionary database if included. Stop all application writers
and migrations; leave database containers running. Restore only trusted backups.

Container overrides: MYSQL_CONTAINER (picsure-db), DICTIONARY_CONTAINER (dictionary-db)
Use matching database versions and existing users/credentials. For rehearsal,
point these variables at isolated database containers with the same database names.
--yes confirms replacement and that writers are stopped (required without a TTY).
No application containers are stopped or restarted by this script.
EOF
}
fail() { echo "ERROR: $*" >&2; exit 1; }
checksum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
verify_file() {
  local file="$backup_dir/$1"
  local expected
  [ -s "$file" ] && [ -f "$file.sha256" ] || fail "Missing backup file or checksum: $1"
  expected=$(cat "$file.sha256")
  [[ "$expected" =~ ^[a-f0-9]{64}$ ]] || fail "Invalid checksum for $1"
  [ "$(checksum "$file")" = "$expected" ] || fail "Checksum mismatch: $1"
}

backup_dir=""
confirmed=false
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --yes) confirmed=true ;;
    -*) fail "Unknown option: $arg" ;;
    *) [ -z "$backup_dir" ] || fail 'Only one backup directory may be supplied'; backup_dir=$arg ;;
  esac
done
[ -n "$backup_dir" ] || { usage >&2; exit 1; }
[ -f "$backup_dir/backup-format" ] || fail 'Backup is incomplete or was not created by backup-databases.sh'
MYSQL_CONTAINER="${MYSQL_CONTAINER:-picsure-db}"
DICTIONARY_CONTAINER="${DICTIONARY_CONTAINER:-dictionary-db}"
for dependency in docker gzip; do
  command -v "$dependency" >/dev/null || fail "$dependency is required"
done
command -v sha256sum >/dev/null || command -v shasum >/dev/null || fail 'sha256sum or shasum is required'
case "$(cat "$backup_dir/backup-format")" in
  'picsure-backup-v1 mysql') include_dictionary=false ;;
  'picsure-backup-v1 mysql dictionary') include_dictionary=true ;;
  *) fail 'Unrecognized backup format' ;;
esac

# Validate every archive and target before the first database is changed.
verify_file auth-picsure.sql.gz
gzip -t "$backup_dir/auth-picsure.sql.gz"
[ "$(docker inspect --format '{{.State.Running}}' "$MYSQL_CONTAINER")" = true ] || fail "MySQL container $MYSQL_CONTAINER must be running"
docker exec "$MYSQL_CONTAINER" sh -c '
  : "${MYSQL_ROOT_PASSWORD:?MySQL root password is unavailable}"
  MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql --user=root --protocol=socket --execute="SELECT 1"
' >/dev/null
if [ "$include_dictionary" = true ]; then
  verify_file dictionary.dump
  verify_file dictionary-name
  [ "$(docker inspect --format '{{.State.Running}}' "$DICTIONARY_CONTAINER")" = true ] || fail "Dictionary container $DICTIONARY_CONTAINER must be running"
  target_dictionary=$(docker exec "$DICTIONARY_CONTAINER" sh -c '
    : "${POSTGRES_DB:?POSTGRES_DB is required for dictionary restore}"
    printf "%s\n" "$POSTGRES_DB"
  ')
  [ "$target_dictionary" = "$(cat "$backup_dir/dictionary-name")" ] || fail 'Dictionary database name differs from the backup'
  docker exec -i "$DICTIONARY_CONTAINER" pg_restore --list < "$backup_dir/dictionary.dump" >/dev/null
  docker exec "$DICTIONARY_CONTAINER" sh -c '
    exec psql --username="${POSTGRES_USER:-postgres}" --dbname=postgres --no-psqlrc \
      --set=ON_ERROR_STOP=1 --command="SELECT 1"
  ' >/dev/null
fi

printf 'Restore will REPLACE auth and picsure in %s.\n' "$MYSQL_CONTAINER"
if [ "$include_dictionary" = true ]; then
  printf 'It will also REPLACE database %s in %s.\n' "$target_dictionary" "$DICTIONARY_CONTAINER"
fi
if [ "$confirmed" = false ]; then
  [ -t 0 ] || fail 'Restore requires confirmation: rerun with --yes after stopping application writers'
  read -r -p 'With all writers stopped, type RESTORE to replace these databases: ' reply
  [ "$reply" = RESTORE ] || fail 'Restore cancelled'
fi

restore_failed() {
  local result=$?
  if [ "$result" -ne 0 ]; then
    echo 'Restore failed and databases may be partially restored. Keep applications stopped until recovery is complete.' >&2
  fi
}
trap restore_failed EXIT

gzip -dc "$backup_dir/auth-picsure.sql.gz" | docker exec -i "$MYSQL_CONTAINER" sh -c '
  MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql --user=root --protocol=socket --binary-mode
'
if [ "$include_dictionary" = true ]; then
  docker exec -i "$DICTIONARY_CONTAINER" sh -c '
    exec pg_restore --username="${POSTGRES_USER:-postgres}" --dbname=postgres \
      --clean --if-exists --create --exit-on-error --no-owner --no-acl
  ' < "$backup_dir/dictionary.dump"
fi
printf 'Restore complete. Verify data and Flyway history before starting compatible application images.\n'
