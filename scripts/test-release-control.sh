#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — Release Control Tests
# =============================================================================
# Local, non-network tests for release-control.sh.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/picsure-release-control-test.XXXXXX")"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

pass() { echo "[release-test] ok - $*"; }
fail() {
  echo "[release-test] fail - $*" >&2
  exit 1
}

assert_env() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local actual
  actual="$(grep "^${key}=" "$file" | tail -n 1 | cut -d= -f2- || true)"
  [ "$actual" = "$expected" ] || fail "Expected $key=$expected, got '$actual'"
}

assert_contains() {
  local file="$1"
  local text="$2"
  grep -Fq "$text" "$file" || fail "Expected '$text' in $file"
}

git_commit_all() {
  local repo="$1"
  local message="$2"
  git -C "$repo" add .
  git -C "$repo" commit -m "$message" >/dev/null
}

make_release_repo() {
  local repo="$TEST_ROOT/release-control-origin"
  mkdir -p "$repo"
  git -C "$repo" init -b main >/dev/null
  git -C "$repo" config user.email "release-test@example.org"
  git -C "$repo" config user.name "Release Test"

  cat > "$repo/build-spec.json" <<'JSON'
{
  "application": [
    { "project_job_git_key": "PSA", "git_hash": "api-main" },
    { "project_job_git_key": "PSH", "git_hash": "hpds-main" },
    { "project_job_git_key": "PSAMA", "git_hash": "psama-main" },
    { "project_job_git_key": "PSF", "git_hash": "frontend-main" },
    { "project_job_git_key": "PSM", "git_hash": "migrations-main" },
    { "project_job_git_key": "DICTIONARY", "git_hash": "dictionary-main" },
    { "project_job_git_key": "DICTIONARY_ETL", "git_hash": "dictionary-etl-main" },
    { "project_job_git_key": "PSV", "git_hash": "visualization-main" },
    { "project_job_git_key": "PSL", "git_hash": "logging-main" }
  ]
}
JSON
  git_commit_all "$repo" "main build spec"

  git -C "$repo" switch -c partial >/dev/null 2>&1
  cat > "$repo/build-spec.json" <<'JSON'
{
  "application": [
    { "project_job_git_key": "PSA", "git_hash": "api-partial" },
    { "project_job_git_key": "PSH", "git_hash": "hpds-partial" }
  ]
}
JSON
  git_commit_all "$repo" "partial build spec"
  git -C "$repo" switch main >/dev/null 2>&1

  echo "$repo"
}

write_env() {
  local file="$1"
  local release_repo="$2"
  local branch="$3"

  cat > "$file" <<EOF
RELEASE_CONTROL_REPO=$release_repo
RELEASE_CONTROL_BRANCH=$branch
EOF
}

run_release_control() {
  local env_file="$1"
  local cache_dir="$2"
  local repos_dir="$3"
  shift 3

  ENV_FILE="$env_file" \
    RELEASE_CONTROL_DIR="$cache_dir" \
    REPOS_DIR="$repos_dir" \
    "$SCRIPT_DIR/release-control.sh" "$@"
}

test_resolve_full_spec() {
  local release_repo="$1"
  local env_file="$TEST_ROOT/full.env"
  local output="$TEST_ROOT/full.out"

  write_env "$env_file" "$release_repo" main
  run_release_control "$env_file" "$TEST_ROOT/full-cache" "$TEST_ROOT/repos" --resolve-only >"$output" 2>&1

  assert_env "$env_file" PICSURE_REF api-main
  assert_env "$env_file" HPDS_REF hpds-main
  assert_env "$env_file" PSAMA_REF psama-main
  assert_env "$env_file" FRONTEND_REF frontend-main
  assert_env "$env_file" MIGRATIONS_REF migrations-main
  assert_env "$env_file" DICTIONARY_REF dictionary-main
  assert_env "$env_file" DICTIONARY_ETL_REF dictionary-etl-main
  assert_env "$env_file" LOGGING_REF logging-main
  assert_env "$env_file" VISUALIZATION_REF visualization-main
  assert_env "$env_file" LOGGING_CLIENT_REF main
  pass "resolved full build spec"
}

test_missing_keys_fall_back_to_main() {
  local release_repo="$1"
  local env_file="$TEST_ROOT/partial.env"
  local output="$TEST_ROOT/partial.out"

  write_env "$env_file" "$release_repo" partial
  run_release_control "$env_file" "$TEST_ROOT/partial-cache" "$TEST_ROOT/repos" --resolve-only >"$output" 2>&1

  assert_env "$env_file" PICSURE_REF api-partial
  assert_env "$env_file" HPDS_REF hpds-partial
  assert_env "$env_file" PSAMA_REF main
  assert_env "$env_file" FRONTEND_REF main
  assert_contains "$output" "PSAMA_REF missing from build-spec.json; falling back to main."
  pass "missing build-spec keys fall back to main"
}

test_missing_branch_falls_back_to_main() {
  local release_repo="$1"
  local env_file="$TEST_ROOT/missing-branch.env"
  local output="$TEST_ROOT/missing-branch.out"

  write_env "$env_file" "$release_repo" does-not-exist
  run_release_control "$env_file" "$TEST_ROOT/missing-branch-cache" "$TEST_ROOT/repos" --resolve-only >"$output" 2>&1

  assert_env "$env_file" RELEASE_CONTROL_BRANCH main
  assert_env "$env_file" PICSURE_REF api-main
  assert_contains "$output" "Release-control branch 'does-not-exist' was not found; falling back to main."
  pass "missing release-control branch falls back to main"
}

test_dry_run_does_not_mutate_env_or_cache() {
  local release_repo="$1"
  local env_file="$TEST_ROOT/dry-run.env"
  local before="$TEST_ROOT/dry-run.env.before"
  local cache_dir="$TEST_ROOT/dry-run-cache"
  local output="$TEST_ROOT/dry-run.out"

  write_env "$env_file" "$release_repo" main
  cp "$env_file" "$before"
  run_release_control "$env_file" "$cache_dir" "$TEST_ROOT/repos" --dry-run >"$output" 2>&1

  cmp -s "$env_file" "$before" || fail "Expected dry run to leave .env unchanged"
  [ ! -e "$cache_dir" ] || fail "Expected dry run not to create release-control cache"
  assert_contains "$output" "Dry run: using temporary release-control checkout"
  assert_contains "$output" "VISUALIZATION_REF"
  assert_contains "$output" "visualization-main"
  pass "dry-run leaves env and cache unchanged"
}

make_service_origin() {
  local origin="$TEST_ROOT/pic-sure-origin"
  local work="$TEST_ROOT/pic-sure-work"

  mkdir -p "$work"
  git -C "$work" init -b main >/dev/null
  git -C "$work" config user.email "release-test@example.org"
  git -C "$work" config user.name "Release Test"
  echo main > "$work/ref.txt"
  git_commit_all "$work" "main ref"
  echo tagged > "$work/ref.txt"
  git_commit_all "$work" "tagged ref"
  git -C "$work" tag api-tag
  git -C "$work" clone --bare . "$origin" >/dev/null 2>&1

  echo "$origin"
}

test_apply_checkout_ref() {
  local service_origin="$1"
  local env_file="$TEST_ROOT/apply.env"
  local repos_dir="$TEST_ROOT/apply-repos"
  local repo="$repos_dir/pic-sure"

  mkdir -p "$repos_dir"
  git clone "$service_origin" "$repo" >/dev/null 2>&1
  cat > "$env_file" <<'EOF'
PICSURE_REF=api-tag
HPDS_REF=main
PSAMA_REF=main
FRONTEND_REF=main
MIGRATIONS_REF=main
DICTIONARY_REF=main
DICTIONARY_ETL_REF=main
VISUALIZATION_REF=main
LOGGING_REF=main
LOGGING_CLIENT_REF=main
EOF

  run_release_control "$env_file" "$TEST_ROOT/apply-cache" "$repos_dir" --apply-only >/dev/null 2>&1
  [ "$(cat "$repo/ref.txt")" = "tagged" ] || fail "Expected pic-sure repo to check out api-tag"
  pass "apply-only checks out requested ref"
}

test_dirty_repo_is_not_moved() {
  local service_origin="$1"
  local env_file="$TEST_ROOT/dirty.env"
  local repos_dir="$TEST_ROOT/dirty-repos"
  local repo="$repos_dir/pic-sure"

  mkdir -p "$repos_dir"
  git clone "$service_origin" "$repo" >/dev/null 2>&1
  echo dirty > "$repo/ref.txt"
  cat > "$env_file" <<'EOF'
PICSURE_REF=api-tag
HPDS_REF=main
PSAMA_REF=main
FRONTEND_REF=main
MIGRATIONS_REF=main
DICTIONARY_REF=main
DICTIONARY_ETL_REF=main
VISUALIZATION_REF=main
LOGGING_REF=main
LOGGING_CLIENT_REF=main
EOF

  run_release_control "$env_file" "$TEST_ROOT/dirty-cache" "$repos_dir" --apply-only >"$TEST_ROOT/dirty.out" 2>&1
  [ "$(cat "$repo/ref.txt")" = "dirty" ] || fail "Expected dirty repo to remain unchanged"
  assert_contains "$TEST_ROOT/dirty.out" "pic-sure has local changes; skipping checkout to api-tag."
  pass "dirty repo checkout is skipped"
}

release_repo="$(make_release_repo)"
service_origin="$(make_service_origin)"

test_resolve_full_spec "$release_repo"
test_missing_keys_fall_back_to_main "$release_repo"
test_missing_branch_falls_back_to_main "$release_repo"
test_dry_run_does_not_mutate_env_or_cache "$release_repo"
test_apply_checkout_ref "$service_origin"
test_dirty_repo_is_not_moved "$service_origin"

echo "[release-test] complete"
