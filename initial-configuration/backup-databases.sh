#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: backup-databases.sh [NEW_BACKUP_DIRECTORY] [--skip-dictionary]

Back up auth and picsure from local AIO MySQL, plus the dictionary database
when its container exists. Stop application writers and migrations first;
leave the database containers running. Existing directories are never replaced.

Default directory: $HOME/picsure-backups/<UTC timestamp>
Container overrides: MYSQL_CONTAINER (picsure-db), DICTIONARY_CONTAINER (dictionary-db)
Credentials are read inside the containers. MySQL accounts and PostgreSQL roles
are not exported. Keep their existing configuration and credentials for restore.
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

backup_dir=""
skip_dictionary=false
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --skip-dictionary) skip_dictionary=true ;;
    -*) fail "Unknown option: $arg" ;;
    *) [ -z "$backup_dir" ] || fail 'Only one backup directory may be supplied'; backup_dir=$arg ;;
  esac
done
MYSQL_CONTAINER="${MYSQL_CONTAINER:-picsure-db}"
DICTIONARY_CONTAINER="${DICTIONARY_CONTAINER:-dictionary-db}"
for dependency in docker gzip; do
  command -v "$dependency" >/dev/null || fail "$dependency is required"
done
command -v sha256sum >/dev/null || command -v shasum >/dev/null || fail 'sha256sum or shasum is required'

[ "$(docker inspect --format '{{.State.Running}}' "$MYSQL_CONTAINER")" = true ] || fail "MySQL container $MYSQL_CONTAINER must be running"
docker exec "$MYSQL_CONTAINER" sh -c '
  : "${MYSQL_ROOT_PASSWORD:?MySQL root password is unavailable}"
  MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql --user=root --protocol=socket --execute="SELECT 1"
' >/dev/null

include_dictionary=false
if [ "$skip_dictionary" = false ] && docker container inspect "$DICTIONARY_CONTAINER" >/dev/null 2>&1; then
  include_dictionary=true
  [ "$(docker inspect --format '{{.State.Running}}' "$DICTIONARY_CONTAINER")" = true ] || fail "Dictionary container $DICTIONARY_CONTAINER must be running"
  dictionary_name=$(docker exec "$DICTIONARY_CONTAINER" sh -c '
    : "${POSTGRES_DB:?POSTGRES_DB is required for dictionary backup}"
    printf "%s\n" "$POSTGRES_DB"
  ')
  case "$dictionary_name" in
    postgres|template0|template1|''|*$'\n'*|*$'\r'*) fail 'Dictionary must use a dedicated application database' ;;
  esac
fi

backup_dir="${backup_dir:-${HOME:?}/picsure-backups/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$(dirname "$backup_dir")"
mkdir "$backup_dir" || fail "Backup directory must be new: $backup_dir"
backup_dir=$(cd "$backup_dir" && pwd)
cleanup() {
  local result=$?
  rm -f "$backup_dir"/*.partial
  if [ "$result" -ne 0 ]; then
    echo "Backup failed; $backup_dir is incomplete and must not be used for cutover." >&2
  fi
}
trap cleanup EXIT

printf 'Backing up auth and picsure from %s\n' "$MYSQL_CONTAINER"
docker exec "$MYSQL_CONTAINER" sh -c '
  : "${MYSQL_ROOT_PASSWORD:?MySQL root password is unavailable}"
  MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump --user=root --protocol=socket \
    --single-transaction --quick --routines --events --triggers \
    --hex-blob --no-tablespaces --set-gtid-purged=OFF --add-drop-database \
    --databases auth picsure
' | gzip > "$backup_dir/auth-picsure.sql.gz.partial"
gzip -t "$backup_dir/auth-picsure.sql.gz.partial"
mv "$backup_dir/auth-picsure.sql.gz.partial" "$backup_dir/auth-picsure.sql.gz"
checksum "$backup_dir/auth-picsure.sql.gz" > "$backup_dir/auth-picsure.sql.gz.sha256"

if [ "$include_dictionary" = true ]; then
  printf 'Backing up dictionary from %s\n' "$DICTIONARY_CONTAINER"
  docker exec "$DICTIONARY_CONTAINER" sh -c '
    exec pg_dump --username="${POSTGRES_USER:-postgres}" --dbname="$POSTGRES_DB" \
      --format=custom --create --no-owner --no-acl
  ' > "$backup_dir/dictionary.dump.partial"
  docker exec -i "$DICTIONARY_CONTAINER" pg_restore --list < "$backup_dir/dictionary.dump.partial" >/dev/null
  mv "$backup_dir/dictionary.dump.partial" "$backup_dir/dictionary.dump"
  checksum "$backup_dir/dictionary.dump" > "$backup_dir/dictionary.dump.sha256"
  printf '%s\n' "$dictionary_name" > "$backup_dir/dictionary-name"
  checksum "$backup_dir/dictionary-name" > "$backup_dir/dictionary-name.sha256"
  printf 'picsure-backup-v1 mysql dictionary\n' > "$backup_dir/backup-format"
else
  echo 'Dictionary backup omitted (container absent or --skip-dictionary supplied).'
  printf 'picsure-backup-v1 mysql\n' > "$backup_dir/backup-format"
fi
printf 'Backup complete: %s\nRehearse a restore before relying on it for cutover.\n' "$backup_dir"
