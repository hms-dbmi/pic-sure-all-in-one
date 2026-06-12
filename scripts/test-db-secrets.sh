#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — DB Secret-Exposure Tests
# =============================================================================
# Local, non-network proof that the mysql helpers no longer leak the DB root
# password (or secret SQL such as the introspection token) on the host process
# listing. No real docker or mysql is involved.
#
# Mechanism: shim `docker` and `mysql` on PATH. The fake `docker` emulates the
# `docker exec`/`docker run` argument grammar — it consumes the container flags,
# turns `-e VAR=val` / `-e VAR` into real environment variables (this is how the
# password must cross the container boundary), and then runs the trailing
# command (our fake `mysql`) with stdin passed straight through. The fake
# `mysql` records exactly what a real mysql process would see: its argv, the
# MYSQL_PWD env var, and whatever arrives on stdin.
#
# The contract under test:
#   - the password is NEVER in the (host-visible) argv of docker or mysql
#   - the password DOES arrive via MYSQL_PWD
#   - secret SQL moved to stdin arrives on stdin, not argv
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/picsure-db-secrets-test.XXXXXX")"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

pass() { echo "[db-secrets-test] ok - $*"; }
fail() {
  echo "[db-secrets-test] fail - $*" >&2
  if [ -f "$CAPTURE_ARGV" ]; then
    echo "[db-secrets-test] --- captured argv ---" >&2
    cat "$CAPTURE_ARGV" >&2
  fi
  if [ -f "$CAPTURE_ENV" ]; then
    echo "[db-secrets-test] --- captured MYSQL_PWD ---" >&2
    cat "$CAPTURE_ENV" >&2
  fi
  if [ -f "$CAPTURE_STDIN" ]; then
    echo "[db-secrets-test] --- captured stdin ---" >&2
    cat "$CAPTURE_STDIN" >&2
  fi
  exit 1
}

SECRET_PASS="Sup3rSecret-Pa55!"
SECRET_TOKEN="eyJ.fake.introspection.jwt-DEADBEEF"

# Capture files written by the fake mysql shim.
CAPTURE_ARGV="$TEST_ROOT/argv"
CAPTURE_ENV="$TEST_ROOT/env"
CAPTURE_STDIN="$TEST_ROOT/stdin"

# --- Fake docker -----------------------------------------------------------
# Emulates `docker run [opts] IMAGE cmd...` and `docker exec [opts] NAME cmd...`.
# Promotes `-e VAR=val` / `-e VAR` to the environment, then runs `cmd...` with
# stdin passed through untouched.
mkdir -p "$TEST_ROOT/bin"
cat > "$TEST_ROOT/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
sub="${1:-}"
shift || true
case "$sub" in
  run|exec) ;;
  *) echo "fake-docker: unsupported subcommand: $sub" >&2; exit 99 ;;
esac

env_assignments=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -e)
      shift
      env_assignments+=("$1")
      shift
      ;;
    -e*)
      env_assignments+=("${1#-e}")
      shift
      ;;
    --rm|-i|-t|-d) shift ;;        # flags with no value
    --name|--network) shift 2 ;;    # flags with a value
    -*) shift ;;                    # ignore any other flag (best-effort)
    *)
      # First non-flag positional is the IMAGE (run) or container NAME (exec).
      shift
      break
      ;;
  esac
done

# Anything left is the command to run inside the "container".
exec env "${env_assignments[@]+"${env_assignments[@]}"}" "$@"
DOCKER
chmod +x "$TEST_ROOT/bin/docker"

# --- Fake mysql ------------------------------------------------------------
# Records the exact view a real mysql client process would expose: argv,
# MYSQL_PWD, and stdin. Appends so multiple calls in one scenario accumulate.
cat > "$TEST_ROOT/bin/mysql" <<MYSQL
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$CAPTURE_ARGV"
printf '%s\n' "\${MYSQL_PWD:-<unset>}" >> "$CAPTURE_ENV"
cat >> "$CAPTURE_STDIN"
MYSQL
chmod +x "$TEST_ROOT/bin/mysql"

reset_captures() {
  : > "$CAPTURE_ARGV"
  : > "$CAPTURE_ENV"
  : > "$CAPTURE_STDIN"
}

PATH="$TEST_ROOT/bin:$PATH"
export PATH

# Assertions ----------------------------------------------------------------
assert_pass_not_in_argv() {
  if grep -qF -- "$SECRET_PASS" "$CAPTURE_ARGV"; then
    fail "$1: password leaked into argv"
  fi
  pass "$1: password absent from argv"
}

assert_pass_in_env() {
  if ! grep -qF -- "$SECRET_PASS" "$CAPTURE_ENV"; then
    fail "$1: password not present in MYSQL_PWD"
  fi
  pass "$1: password present in MYSQL_PWD"
}

assert_token_not_in_argv() {
  if grep -qF -- "$SECRET_TOKEN" "$CAPTURE_ARGV"; then
    fail "$1: token leaked into argv"
  fi
  pass "$1: token absent from argv"
}

assert_token_on_stdin() {
  if ! grep -qF -- "$SECRET_TOKEN" "$CAPTURE_STDIN"; then
    fail "$1: token did not arrive on stdin"
  fi
  pass "$1: token arrived on stdin"
}

# Extract a single shell function body verbatim from a source file (from
# 'name() {' to the first line that is exactly '}'). This lets us exercise the
# REAL helper text without executing the whole script.
extract_function() {
  local file="$1" name="$2"
  awk -v fn="$name" '
    $0 ~ "^" fn "\\(\\) \\{" { capture=1 }
    capture { print }
    capture && $0 == "}" { exit }
  ' "$file"
}

# ===========================================================================
# 1. picsure_db_exec_mysql (scripts/picsure-compose.sh) — the canonical helper
# ===========================================================================
# Source it for real; it only defines functions.
# shellcheck source=scripts/picsure-compose.sh
source "$SCRIPT_DIR/scripts/picsure-compose.sh"

DB_ROOT_PASSWORD="$SECRET_PASS"
DB_ROOT_USER="root"
DB_HOST="picsure-db"
DB_PORT="3306"
export DB_ROOT_PASSWORD DB_ROOT_USER DB_HOST DB_PORT

# Local mode: docker exec path.
DB_MODE=local reset_captures
DB_MODE=local picsure_db_exec_mysql -e "SELECT 1;"
assert_pass_not_in_argv "picsure_db_exec_mysql/local"
assert_pass_in_env "picsure_db_exec_mysql/local"

# Local mode with SQL piped on stdin (proves the -i passthrough works).
reset_captures
printf 'UPDATE auth.application SET token=%s;\n' "'$SECRET_TOKEN'" \
  | DB_MODE=local picsure_db_exec_mysql
assert_token_not_in_argv "picsure_db_exec_mysql/local-stdin"
assert_token_on_stdin "picsure_db_exec_mysql/local-stdin"

# Remote mode: docker run path.
reset_captures
DB_MODE=remote picsure_db_exec_mysql -e "SELECT 1;"
assert_pass_not_in_argv "picsure_db_exec_mysql/remote"
assert_pass_in_env "picsure_db_exec_mysql/remote"

# ===========================================================================
# 2. db_mysql + sql_escape_quotes (seed-db.sh)
# ===========================================================================
SEED_FUNCS="$TEST_ROOT/seed-funcs.sh"
{
  extract_function "$SCRIPT_DIR/seed-db.sh" "db_mysql"
  extract_function "$SCRIPT_DIR/seed-db.sh" "sql_escape_quotes"
} > "$SEED_FUNCS"
# shellcheck disable=SC1090
source "$SEED_FUNCS"

# Local mode token UPDATE fed on stdin (mirrors seed-db.sh section 4).
DB_MODE=local reset_captures
INTRO_TOKEN_SQL=$(sql_escape_quotes "$SECRET_TOKEN")
DB_MODE=local db_mysql <<SQL
UPDATE auth.application SET token='$INTRO_TOKEN_SQL' WHERE name='PICSURE';
SQL
assert_pass_not_in_argv "seed db_mysql/local-token"
assert_pass_in_env "seed db_mysql/local-token"
assert_token_not_in_argv "seed db_mysql/local-token"
assert_token_on_stdin "seed db_mysql/local-token"

# Remote mode equivalent.
reset_captures
DB_MODE=remote db_mysql <<SQL
UPDATE auth.application SET token='$INTRO_TOKEN_SQL' WHERE name='PICSURE';
SQL
assert_pass_not_in_argv "seed db_mysql/remote-token"
assert_pass_in_env "seed db_mysql/remote-token"
assert_token_not_in_argv "seed db_mysql/remote-token"
assert_token_on_stdin "seed db_mysql/remote-token"

# sql_escape_quotes doubles a single quote (apostrophe-in-email regression).
got=$(sql_escape_quotes "o'brien@example.org")
if [ "$got" != "o''brien@example.org" ]; then
  fail "sql_escape_quotes: expected o''brien@example.org, got: $got"
fi
pass "sql_escape_quotes: doubles single quotes"

echo "[db-secrets-test] Complete"
