#!/usr/bin/env bash
# =============================================================================
# PIC-SURE — Set a .env value
# =============================================================================
# Sets KEY=VALUE in this checkout's .env, creating .env from .env.example
# first if it does not exist. All programmatic .env writes (including from
# the pic-sure CLI) go through this script so value escaping and sed
# portability live in exactly one place (picsure_set_env_var in
# scripts/lib/common.sh).
#
# Usage:
#   scripts/env-set.sh KEY VALUE              # set/overwrite KEY
#   scripts/env-set.sh KEY VALUE --no-force   # keep an existing non-empty value
#   scripts/env-set.sh KEY -- VALUE           # `--` ends options, so VALUE may
#                                             # start with `--` (e.g. --weird)
#   scripts/env-set.sh KEY --stdin            # read VALUE from stdin (for
#                                             # secrets: keeps them out of argv)
#
# Exit codes: 0 on success, 2 on usage errors (bad key, missing args,
# multi-line value, missing .env.example).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${PICSURE_ROOT:-$SCRIPT_DIR}"
ENV_FILE="$ROOT/.env"
ENV_EXAMPLE="$ROOT/.env.example"

LOG_PREFIX="env-set"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}"
}

KEY=""
VALUE=""
VALUE_SET=false
FORCE=true
FROM_STDIN=false

# A literal `--` ends option parsing: every token after it is positional,
# so a VALUE beginning with `--` (e.g. user-typed wizard input) can be
# written. Once positional-only, even `--no-force`/`--stdin`/`-h` are values.
POSITIONAL_ONLY=false
add_positional() {
  if [ -z "$KEY" ]; then
    KEY="$1"
  elif [ "$VALUE_SET" = "false" ]; then
    VALUE="$1"
    VALUE_SET=true
  else
    error "Too many arguments: $1"
    usage >&2
    exit 2
  fi
}

for arg in "$@"; do
  if [ "$POSITIONAL_ONLY" = "true" ]; then
    add_positional "$arg"
    continue
  fi
  case "$arg" in
    --) POSITIONAL_ONLY=true ;;
    --no-force) FORCE=false ;;
    --stdin) FROM_STDIN=true ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      error "Unknown option: $arg"
      usage >&2
      exit 2
      ;;
    *)
      add_positional "$arg"
      ;;
  esac
done

if [ "$FROM_STDIN" = "true" ]; then
  if [ "$VALUE_SET" = "true" ]; then
    error "--stdin and a VALUE argument are mutually exclusive."
    usage >&2
    exit 2
  fi
  # $(cat) strips trailing newlines; embedded newlines are rejected below.
  VALUE="$(cat)"
  VALUE_SET=true
fi

if [ -z "$KEY" ] || [ "$VALUE_SET" = "false" ]; then
  error "KEY and VALUE are required."
  usage >&2
  exit 2
fi

# The key is interpolated into a grep/sed pattern by picsure_set_env_var,
# so restrict it to plain env-var names.
case "$KEY" in
  [A-Za-z_]*) ;;
  *)
    error "Invalid key: '$KEY' (must start with a letter or underscore)."
    exit 2
    ;;
esac
if printf '%s' "$KEY" | LC_ALL=C grep -q '[^A-Za-z0-9_]'; then
  error "Invalid key: '$KEY' (only letters, digits, and underscores allowed)."
  exit 2
fi

# .env values are single-line KEY=VALUE entries; embedded newlines would
# corrupt the file (and the sed replacement).
case "$VALUE" in
  *$'\n'*)
    error "Value for $KEY must not contain newlines."
    exit 2
    ;;
esac

# .env is both shell-sourced (picsure_load_env) and dotenv-parsed (docker
# compose), so a value with shell-special characters must be single-quoted
# or it changes meaning when sourced. Plain values stay unquoted to match
# the style of init.sh-generated entries.
case "$VALUE" in
  ''|*[!A-Za-z0-9_.,:/@%+=-]*)
    if [ -n "$VALUE" ]; then
      sq="'"
      sq_escaped="'\\''"
      VALUE="'${VALUE//$sq/$sq_escaped}'"
    fi
    ;;
esac

if [ ! -f "$ENV_FILE" ]; then
  if [ ! -f "$ENV_EXAMPLE" ]; then
    error ".env.example not found at $ENV_EXAMPLE; cannot create .env."
    exit 2
  fi
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  info "Created .env from .env.example"
fi

picsure_set_env_var "$ENV_FILE" "$KEY" "$VALUE" "$FORCE"
