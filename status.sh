#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — Status
# =============================================================================
# Read-only summary of local configuration, release refs, repo state, Compose
# services, and migration readiness.
#
# Usage:
#   ./status.sh
#   ./status.sh --json   # machine-readable output (see docs/cli-contract.md)
#
# Exits 0 in both modes; statuses are reported in the output, not the exit code.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
PICSURE_ROOT="$SCRIPT_DIR"
export PICSURE_ROOT

LOG_PREFIX="status"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/scripts/lib/common.sh"

# shellcheck source=scripts/picsure-compose.sh
source "$SCRIPT_DIR/scripts/picsure-compose.sh"

JSON=false
for arg in "$@"; do
  case "$arg" in
    --json) JSON=true ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      error "Unknown option: $arg"
      exit 1
      ;;
  esac
done

ok() { echo -e "${PICSURE_GREEN}[ok]${PICSURE_NC} $*"; }
warn() { echo -e "${PICSURE_YELLOW}[warn]${PICSURE_NC} $*"; }
bad() { echo -e "${PICSURE_RED}[bad]${PICSURE_NC} $*"; }

section() {
  echo ""
  echo "== $* =="
}

REF_KEYS=(
  PICSURE_REF
  HPDS_REF
  PSAMA_REF
  FRONTEND_REF
  MIGRATIONS_REF
  DICTIONARY_REF
  DICTIONARY_ETL_REF
  VISUALIZATION_REF
  LOGGING_REF
  LOGGING_CLIENT_REF
)

# Parallel arrays (bash 3.2: no associative arrays): repo dir under repos/
# and the .env ref variable that targets it. Order matches REF_KEYS-ish
# historical output order.
# NOTE: duplicated in reset.sh (REPO_DIRS/REPO_ENVS) and mirrored by
# release-control.sh's apply_refs — keep the three in sync.
REPO_DIRS=(
  pic-sure
  pic-sure-hpds
  pic-sure-auth-microapp
  PIC-SURE-Frontend
  PIC-SURE-Migrations
  picsure-dictionary
  picsure-dictionary-etl
  PIC-SURE-Logging
  PIC-SURE-Logging-Client
  pic-sure-visualization-resource
)
REPO_ENVS=(
  PICSURE_REF
  HPDS_REF
  PSAMA_REF
  FRONTEND_REF
  MIGRATIONS_REF
  DICTIONARY_REF
  DICTIONARY_ETL_REF
  LOGGING_REF
  LOGGING_CLIENT_REF
  VISUALIZATION_REF
)

ref_value() {
  local key="$1"
  printf '%s' "${!key:-main}"
}

# Effective values shared by the human and JSON renderers — defaults live in
# exactly one place so the two output modes cannot drift.
eff_project_name() { printf '%s' "${COMPOSE_PROJECT_NAME:-picsure}"; }
eff_db_mode()      { printf '%s' "${DB_MODE:-local}"; }
eff_auth_mode()    { printf '%s' "${AUTH_MODE:-required}"; }
eff_image_tag()    { printf '%s' "${PICSURE_IMAGE_TAG:-LATEST}"; }
eff_db_port()      { printf '%s' "${DB_PORT:-3306}"; }

# Single collector for per-repo state, consumed by both renderers. Sets:
#   REPO_NAME, REPO_PRESENT (true/false), REPO_CURRENT, REPO_TARGET, REPO_STATE
collect_repo_info() {
  local repo_dir="$1"
  local env_name="$2"

  REPO_NAME="$(basename "$repo_dir")"
  REPO_TARGET="$(ref_value "$env_name")"
  REPO_CURRENT=""

  if [ ! -d "$repo_dir/.git" ]; then
    REPO_PRESENT=false
    REPO_STATE="missing"
    return 0
  fi

  REPO_PRESENT=true
  REPO_CURRENT="$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  if [ "$REPO_CURRENT" = "HEAD" ]; then
    REPO_CURRENT="$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null || echo detached)"
  fi

  REPO_STATE="clean"
  if ! git -C "$repo_dir" diff --quiet || ! git -C "$repo_dir" diff --cached --quiet; then
    REPO_STATE="dirty"
  fi
}

repo_status_line() {
  collect_repo_info "$1" "$2"

  if [ "$REPO_PRESENT" = "false" ]; then
    printf '  %-34s missing target=%s\n' "$REPO_NAME" "$REPO_TARGET"
    return 0
  fi

  printf '  %-34s current=%-18s target=%-18s %s\n' "$REPO_NAME" "$REPO_CURRENT" "$REPO_TARGET" "$REPO_STATE"
}

docker_reachable() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

release_control_commit() {
  if [ -n "${RELEASE_CONTROL_COMMIT:-}" ]; then
    printf '%s' "$RELEASE_CONTROL_COMMIT"
  elif [ -d "$SCRIPT_DIR/.data/release-control/.git" ]; then
    git -C "$SCRIPT_DIR/.data/release-control" rev-parse HEAD 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# JSON mode (schema documented in docs/cli-contract.md; schema_version 1)
# ---------------------------------------------------------------------------

repo_json() {
  collect_repo_info "$1" "$2"

  local fields=()
  fields+=("$(json_str name "$REPO_NAME")")
  fields+=("$(json_bool present "$REPO_PRESENT")")
  if [ "$REPO_PRESENT" = "true" ]; then
    fields+=("$(json_str current "$REPO_CURRENT")")
  else
    fields+=("$(json_null current)")
  fi
  fields+=("$(json_str target "$REPO_TARGET")")
  fields+=("$(json_str state "$REPO_STATE")")
  json_obj "${fields[@]}"
}

status_json() {
  # shellcheck source=scripts/lib/json.sh
  source "$SCRIPT_DIR/scripts/lib/json.sh"

  # --- env ---
  local env_present=false env_valid=""
  local env_valid_frag
  if [ -f "$ENV_FILE" ]; then
    env_present=true
    if picsure_load_env "$ENV_FILE" 2>/dev/null; then
      env_valid=true
      env_valid_frag="$(json_bool file_valid true)"
    else
      env_valid=false
      env_valid_frag="$(json_bool file_valid false)"
    fi
  else
    env_valid_frag="$(json_null file_valid)"
  fi

  local env_fields=()
  env_fields+=("$(json_bool file_present "$env_present")")
  env_fields+=("$env_valid_frag")
  env_fields+=("$(json_str compose_project_name "$(eff_project_name)")")
  env_fields+=("$(json_str db_mode "$(eff_db_mode)")")
  if [ "$(eff_db_mode)" = "remote" ]; then
    env_fields+=("$(json_str_or_null db_host "${DB_HOST:-}")")
    env_fields+=("$(json_str_or_null db_port "$(eff_db_port)")")
  else
    env_fields+=("$(json_null db_host)")
    env_fields+=("$(json_null db_port)")
  fi
  env_fields+=("$(json_str auth_mode "$(eff_auth_mode)")")
  env_fields+=("$(json_str picsure_image_tag "$(eff_image_tag)")")

  # --- release control ---
  local ref_fields=()
  local key
  for key in "${REF_KEYS[@]}"; do
    ref_fields+=("$(json_str "$key" "$(ref_value "$key")")")
  done

  local rc_fields=()
  rc_fields+=("$(json_str repo "${RELEASE_CONTROL_REPO:-https://github.com/hms-dbmi/pic-sure-baseline-release-control}")")
  rc_fields+=("$(json_str branch "${RELEASE_CONTROL_BRANCH:-main}")")
  rc_fields+=("$(json_str_or_null commit "$(release_control_commit)")")
  rc_fields+=("$(json_raw refs "$(json_obj "${ref_fields[@]}")")")

  # --- repos ---
  local repo_items=()
  local i
  for ((i = 0; i < ${#REPO_DIRS[@]}; i++)); do
    repo_items+=("$(repo_json "$SCRIPT_DIR/repos/${REPO_DIRS[$i]}" "${REPO_ENVS[$i]}")")
  done

  # --- docker + services ---
  local cli_present=false compose_available=false daemon=false
  local config_frag services_json="[]"
  if command -v docker >/dev/null 2>&1; then
    cli_present=true
    if docker compose version >/dev/null 2>&1; then
      compose_available=true
    fi
    if docker info >/dev/null 2>&1; then
      daemon=true
    fi
  fi

  if [ "$daemon" = "true" ] && [ "$compose_available" = "true" ]; then
    if picsure_compose config --quiet >/dev/null 2>&1; then
      config_frag="$(json_bool compose_config_valid true)"
    else
      config_frag="$(json_bool compose_config_valid false)"
    fi

    local ps_file
    ps_file="$(mktemp "${TMPDIR:-/tmp}/picsure-status-ps.XXXXXX")"
    picsure_compose ps --format json >"$ps_file" 2>/dev/null || true
    if [ -s "$ps_file" ]; then
      # -s + flatten normalizes both NDJSON (newer compose) and a single
      # JSON array (older compose) into one flat array of service objects.
      services_json="$(run_jq -s \
        'flatten | map({name: .Service, state: (.State // null), health: (if (.Health // "") == "" then null else .Health end), exit_code: (.ExitCode // null)}) | tojson' \
        "$ps_file" 2>/dev/null || echo '[]')"
    fi
    rm -f "$ps_file"
  else
    config_frag="$(json_null compose_config_valid)"
  fi

  local docker_fields=()
  docker_fields+=("$(json_bool cli_present "$cli_present")")
  docker_fields+=("$(json_bool compose_available "$compose_available")")
  docker_fields+=("$(json_bool daemon_reachable "$daemon")")
  docker_fields+=("$config_frag")

  # --- database ---
  local db_fields=()
  db_fields+=("$(json_str mode "$(eff_db_mode)")")
  if [ "$(eff_db_mode)" = "remote" ]; then
    db_fields+=("$(json_null service)")
    db_fields+=("$(json_str_or_null host "${DB_HOST:-}")")
    db_fields+=("$(json_str_or_null port "$(eff_db_port)")")
  else
    db_fields+=("$(json_str service picsure-db)")
    db_fields+=("$(json_null host)")
    db_fields+=("$(json_null port)")
  fi

  # --- migrations ---
  # Contract: this check must stay local-only (env vars, SQL dir layout, and
  # `docker compose config`); anything heavier belongs behind a new flag.
  local mig_fields=()
  if [ "$env_present" = "true" ] && [ "$env_valid" = "true" ]; then
    if ./run-migrations.sh --check >/dev/null 2>&1; then
      mig_fields+=("$(json_bool checked true)")
      mig_fields+=("$(json_bool ready true)")
      mig_fields+=("$(json_str message "Migration inputs look valid")")
    else
      mig_fields+=("$(json_bool checked true)")
      mig_fields+=("$(json_bool ready false)")
      mig_fields+=("$(json_str message "Migration input check failed; run ./run-migrations.sh --check")")
    fi
  else
    mig_fields+=("$(json_bool checked false)")
    mig_fields+=("$(json_null ready)")
    mig_fields+=("$(json_str message "Skipped because .env is missing or invalid")")
  fi

  # --- document ---
  local top=()
  top+=("$(json_raw schema_version 1)")
  top+=("$(json_str command status)")
  top+=("$(json_raw env "$(json_obj "${env_fields[@]}")")")
  top+=("$(json_raw release_control "$(json_obj "${rc_fields[@]}")")")
  top+=("$(json_raw repos "$(json_arr "${repo_items[@]}")")")
  top+=("$(json_raw docker "$(json_obj "${docker_fields[@]}")")")
  top+=("$(json_raw services "$services_json")")
  top+=("$(json_raw database "$(json_obj "${db_fields[@]}")")")
  top+=("$(json_raw migrations "$(json_obj "${mig_fields[@]}")")")
  json_obj "${top[@]}"
  echo ""
}

cd "$SCRIPT_DIR"

if [ "$JSON" = "true" ]; then
  status_json
  exit 0
fi

# ---------------------------------------------------------------------------
# Human mode
# ---------------------------------------------------------------------------

section "Environment"
if [ -f "$ENV_FILE" ]; then
  if ! picsure_load_env "$ENV_FILE" 2>/dev/null; then
    bad ".env is not valid shell syntax; fix or regenerate it (remaining fields show defaults)"
  else
    ok ".env found"
  fi
else
  warn ".env missing; run: cp .env.example .env"
fi

echo "  COMPOSE_PROJECT_NAME=$(eff_project_name)"
echo "  DB_MODE=$(eff_db_mode)"
if [ "$(eff_db_mode)" = "remote" ]; then
  echo "  DB_HOST=${DB_HOST:-unset}"
  echo "  DB_PORT=$(eff_db_port)"
fi
echo "  AUTH_MODE=$(eff_auth_mode)"
echo "  PICSURE_IMAGE_TAG=$(eff_image_tag)"

section "Release Control"
echo "  repo:   ${RELEASE_CONTROL_REPO:-https://github.com/hms-dbmi/pic-sure-baseline-release-control}"
echo "  branch: ${RELEASE_CONTROL_BRANCH:-main}"
rc_commit="$(release_control_commit)"
echo "  commit: ${rc_commit:-unknown}"

for key in "${REF_KEYS[@]}"; do
  printf '  %-24s %s\n' "$key" "$(ref_value "$key")"
done

section "Repos"
for ((i = 0; i < ${#REPO_DIRS[@]}; i++)); do
  repo_status_line "$SCRIPT_DIR/repos/${REPO_DIRS[$i]}" "${REPO_ENVS[$i]}"
done

section "Compose"
if ! command -v docker >/dev/null 2>&1; then
  bad "docker command not found"
elif ! docker compose version >/dev/null 2>&1; then
  bad "docker compose is unavailable"
elif ! docker_reachable; then
  warn "Docker daemon is not reachable; skipping service status"
else
  if picsure_compose config --quiet; then
    ok "Compose config is valid"
    echo ""
    picsure_compose ps
  else
    bad "Compose config is invalid"
    warn "Skipping service listing because Compose config is invalid"
  fi
fi

section "Database"
if [ ! -f "$ENV_FILE" ]; then
  warn "Skipping database checks because .env is missing"
elif [ "$(eff_db_mode)" = "remote" ]; then
  echo "  remote MySQL: ${DB_HOST:-unset}:$(eff_db_port)"
  echo "  run non-mutating check: ./bootstrap-remote-db.sh --check"
else
  echo "  bundled MySQL service: picsure-db"
fi

section "Migrations"
if [ ! -f "$ENV_FILE" ]; then
  warn "Skipping migration input check because .env is missing"
else
  migration_output="$(mktemp "${TMPDIR:-/tmp}/picsure-status-migrations.XXXXXX")"
  if ./run-migrations.sh --check >"$migration_output" 2>&1; then
    ok "Migration inputs look valid"
  else
    bad "Migration input check failed"
    cat "$migration_output"
  fi
  rm -f "$migration_output"
fi
