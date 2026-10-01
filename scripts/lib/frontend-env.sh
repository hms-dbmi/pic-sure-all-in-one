#!/usr/bin/env bash
# Public build-time configuration shared by release, compiled dev and HMR.
# Call after loading the AIO .env. Never import upstream example values: under
# override mode those would unintentionally lock settings managed by the admin UI.
picsure_frontend_env() {
  local env_file="$1" mode="${2:-production}" key value
  while IFS= read -r key; do
    # VITE_ is the frontend's public namespace. No stack/server credentials are
    # forwarded; AUTH0_CLIENT_SECRET and DB_* must never cross this boundary.
    case "$key" in
      VITE_RESOURCE_HPDS|VITE_RESOURCE_OPEN_HPDS|VITE_RESOURCE_VIZ) continue ;;
      VITE_THEME|VITE_ORIGIN) continue ;;
      VITE_[A-Z0-9_]*) ;;
      *) continue ;;
    esac
    value="${!key}"
    picsure_frontend_env_line "$key" "$value" || return
  done < <(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?(VITE_[A-Z0-9_]+)=.*/\2/p' "$env_file" | sort -u)
  picsure_frontend_env_line VITE_THEME "${PICSURE_THEME:-picsure}" || return
  if [ "$mode" = hmr ]; then
    picsure_frontend_env_line VITE_ORIGIN 'http://localhost:3000'
  elif [ "${VITE_ORIGIN+x}" = x ]; then
    picsure_frontend_env_line VITE_ORIGIN "$VITE_ORIGIN"
  fi
}

picsure_frontend_env_line() {
  # dotenv single quotes preserve $, #, backslashes and spaces literally. Reject
  # unsupported delimiters rather than silently changing the configured value.
  case "$2" in
    *"'"*|*$'\n'*|*$'\r'*) echo "Unsupported quote/newline in public frontend setting $1" >&2; return 1 ;;
  esac
  local value="$2"
  # Vite applies dotenv-expand even to single-quoted dotenv values.
  value="${value//\$/\\\$}"
  printf "%s='%s'\n" "$1" "$value"
}

# Execute a build with a generated .env, restoring any developer-owned file even
# if Docker fails. A subshell scopes the trap so callers' cleanup remains intact.
picsure_frontend_with_env() (
  local source_dir="$1" env_file="$2" backup
  shift 2
  backup="$(mktemp -d)" || exit 1
  if [ -e "$source_dir/.env" ] || [ -L "$source_dir/.env" ]; then
    cp -P "$source_dir/.env" "$backup/env" || exit 1
  fi
  trap 'rm -f "$source_dir/.env"; if [ -e "$backup/env" ] || [ -L "$backup/env" ]; then cp -P "$backup/env" "$source_dir/.env"; fi; rm -rf "$backup"' EXIT
  rm -f "$source_dir/.env"
  picsure_frontend_env "$env_file" > "$source_dir/.env" || exit 1
  "$@"
)
