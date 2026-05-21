#!/usr/bin/env bash
# Ensure .env.example contains placeholders/defaults, not deploy-time secrets.

set -euo pipefail

ENV_EXAMPLE="${1:-.env.example}"

if [ ! -f "$ENV_EXAMPLE" ]; then
  echo "$ENV_EXAMPLE not found." >&2
  exit 1
fi

failures=()

safe_placeholder() {
  local value="$1"

  case "$value" in
    ""|"''"|\"\"|"..."|"<"*">"|"your-"*|"example"*|"changeme"|"change-me"|"disabled"|"false"|"true")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

line_number=0
while IFS= read -r line || [ -n "$line" ]; do
  line_number=$((line_number + 1))

  case "$line" in
    ""|\#*)
      continue
      ;;
  esac

  if [[ "$line" == *"-----BEGIN "*PRIVATE*KEY* ]]; then
    failures+=("$line_number: private key material is not allowed")
    continue
  fi

  if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    value="${value%%#*}"
    value="${value%"${value##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"

    if [[ "$key" =~ TOKEN_EXPIRATION$ ]]; then
      continue
    fi

    if [[ "$key" =~ (SECRET|PASSWORD|TOKEN|API_KEY|PRIVATE_KEY|ACCESS_KEY) ]] && ! safe_placeholder "$value"; then
      failures+=("$line_number: $key must be empty or an obvious placeholder")
    fi
  fi

  if [[ "$line" =~ eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,} ]]; then
    failures+=("$line_number: JWT-looking value is not allowed")
  fi
done < "$ENV_EXAMPLE"

if (( ${#failures[@]} > 0 )); then
  printf '%s contains unsafe example values:\n' "$ENV_EXAMPLE" >&2
  printf '  %s\n' "${failures[@]}" >&2
  exit 1
fi
