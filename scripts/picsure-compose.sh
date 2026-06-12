#!/usr/bin/env bash

set -euo pipefail

picsure_script_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

# Load an env file into the current shell (exported).
#
# Returns non-zero — without aborting the caller mid-load and without leaking
# `set -a` — when the file is syntactically invalid, or when its final command
# fails while sourcing. Runtime failures on earlier lines are skipped (errexit
# is suspended during the source so the set +a restore is guaranteed). Guard
# the call (`if picsure_load_env ...`) to handle invalid files gracefully;
# unguarded callers under `set -e` exit with the [env] message on stderr.
picsure_load_env() {
  local env_file="${1:-.env}"

  if [ ! -f "$env_file" ]; then
    return 0
  fi

  # Validate up front so a corrupted .env can't abort the caller mid-load.
  # Treat any parser stderr as invalid, not just a nonzero exit: bash 3.2's
  # `bash -n` exits 0 for an unexpected-EOF error (e.g. an unclosed paren).
  local parse_err
  if ! parse_err="$(bash -n "$env_file" 2>&1)" || [ -n "$parse_err" ]; then
    echo "[env] $env_file is not valid shell syntax; fix or regenerate it." >&2
    return 1
  fi

  # Suspend errexit around the source so `set +a` is always restored, even
  # if a line in the env file fails at runtime (e.g. a command substitution).
  local had_errexit=""
  case $- in *e*) had_errexit=1 ;; esac

  set +e
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  local rc=$?
  set +a
  if [ -n "$had_errexit" ]; then
    set -e
  fi

  return $rc
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

  # Pass the password via the MYSQL_PWD env var rather than mysql's -p argv
  # flag, so it never appears in the host `docker` process listing (ps). For
  # docker run/exec the env must cross the container boundary, hence -e. Use
  # -i so callers may stream SQL on stdin (keeping secret SQL out of argv too).
  if [ "${DB_MODE:-local}" = "remote" ]; then
    docker run --rm -i -e MYSQL_PWD="$pass" mysql:8.0 \
      mysql -h "$host" -P "$port" -u "$user" "$@"
  else
    docker exec -i -e MYSQL_PWD="$pass" picsure-db mysql -u"$user" "$@"
  fi
}
