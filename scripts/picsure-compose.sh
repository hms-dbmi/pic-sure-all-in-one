#!/usr/bin/env bash

set -euo pipefail

picsure_script_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

picsure_load_env() {
  local env_file="${1:-.env}"

  if [ -f "$env_file" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  fi
}

picsure_compose_files() {
  local root="${1:-$(picsure_script_dir)}"
  local files=(-f "$root/docker-compose.yml")

  if [ "${DB_MODE:-local}" = "remote" ]; then
    files+=(-f "$root/docker-compose.remote-db.yml")
  fi

  printf '%s\n' "${files[@]}"
}

picsure_compose_generated_env_files() {
  printf '%s\n' \
    "config/dictionary/dictionary.env"
}

picsure_compose_missing_generated_files() {
  local root="${1:-$(picsure_script_dir)}"
  local missing=false
  local rel

  while IFS= read -r rel; do
    if [ ! -f "$root/$rel" ]; then
      printf '%s\n' "$rel"
      missing=true
    fi
  done <<EOF
$(picsure_compose_generated_env_files)
EOF

  [ "$missing" = false ]
}

picsure_compose() {
  local root="${PICSURE_ROOT:-$(picsure_script_dir)}"
  local files=()
  while IFS= read -r item; do
    files+=("$item")
  done <<EOF
$(picsure_compose_files "$root")
EOF
  docker compose "${files[@]}" "$@"
}

picsure_db_exec_mysql() {
  local root="${PICSURE_ROOT:-$(picsure_script_dir)}"
  local host="${DB_HOST:-picsure-db}"
  local port="${DB_PORT:-3306}"
  local user="${DB_ROOT_USER:-root}"
  local pass="${DB_ROOT_PASSWORD:-}"

  if [ "${DB_MODE:-local}" = "remote" ]; then
    docker run --rm mysql:8.0 \
      mysql -h "$host" -P "$port" -u "$user" -p"$pass" "$@"
  else
    docker exec picsure-db mysql -u"$user" -p"$pass" "$@"
  fi
}
