#!/usr/bin/env bash
# =============================================================================
# PIC-SURE All-in-One — Repo Reset Tests
# =============================================================================
# Local, non-network tests for reset.sh's git-preserving --repos reset.
#
# SAFETY: these tests must NEVER run reset.sh's destructive main flow against
# the real checkout (it removes certs/, .data/, generated config under the real
# SCRIPT_DIR). Instead each test SOURCES reset.sh — which stops before the
# teardown when sourced — and calls reset_repos() directly against a fixture
# REPOS_DIR / ENV_FILE in a temp dir. Sourcing happens in a subshell so the
# fixture env never leaks between tests.
#
# The contract under test: reset.sh --repos resets each repo's WORKING TREE to
# its release ref (discarding uncommitted changes) while NEVER deleting .git —
# local branches, local commits, and the reflog must survive.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/picsure-repo-reset-test.XXXXXX")"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

pass() { echo "[repo-reset-test] ok - $*"; }

# LAST_LOG is set by run_reset_repos so a failing assertion can dump the reset
# output that produced it before the EXIT trap wipes the temp dir.
LAST_LOG=""
fail() {
  echo "[repo-reset-test] fail - $*" >&2
  if [ -n "$LAST_LOG" ] && [ -f "$LAST_LOG" ]; then
    echo "[repo-reset-test] --- reset output ($(basename "$LAST_LOG")) ---" >&2
    cat "$LAST_LOG" >&2
    echo "[repo-reset-test] --- end reset output ---" >&2
  fi
  exit 1
}

git_commit_all() {
  local repo="$1"
  local message="$2"
  git -C "$repo" add -A
  git -C "$repo" commit -m "$message" >/dev/null
}

# make_service_origin: a bare origin with main (two commits) and a v1 tag.
make_service_origin() {
  local origin="$1"
  local work="$TEST_ROOT/origin-work"

  mkdir -p "$work"
  git -C "$work" init -b main >/dev/null
  git -C "$work" config user.email "repo-reset-test@example.org"
  git -C "$work" config user.name "Repo Reset Test"
  echo v0 > "$work/ref.txt"
  git_commit_all "$work" "initial"
  git -C "$work" tag v1
  echo main-tip > "$work/ref.txt"
  git_commit_all "$work" "main tip"
  git -C "$work" clone --bare . "$origin" >/dev/null 2>&1
}

# make_fixture_repo: clone origin into repos/<name>, then add LOCAL-ONLY work:
#   - a local branch "my-feature" that origin does not have
#   - a local commit on top of main that origin does not have
#   - a dirty working tree (uncommitted edit + an untracked file)
# Echoes the sha of the local commit so the caller can assert reachability.
make_fixture_repo() {
  local repos_dir="$1"
  local name="$2"
  local repo="$repos_dir/$name"

  mkdir -p "$repos_dir"
  git clone "$TEST_ROOT/origin.git" "$repo" >/dev/null 2>&1
  git -C "$repo" config user.email "repo-reset-test@example.org"
  git -C "$repo" config user.name "Repo Reset Test"

  # Local-only branch (never pushed).
  git -C "$repo" switch -c my-feature >/dev/null 2>&1
  echo "local feature work" > "$repo/feature.txt"
  git_commit_all "$repo" "local feature commit"

  # Local-only commit on main (never pushed) — capture its sha.
  git -C "$repo" switch main >/dev/null 2>&1
  echo "precious local work" > "$repo/local-only.txt"
  git_commit_all "$repo" "precious local commit"
  git -C "$repo" rev-parse HEAD

  # Dirty working tree: an uncommitted edit + an untracked file.
  echo "uncommitted edit" >> "$repo/ref.txt"
  echo "untracked junk" > "$repo/untracked.txt"
}

write_env() {
  local file="$1"
  local ref="$2"
  # reset.sh maps the pic-sure repo dir to PICSURE_REF (status.sh mapping).
  cat > "$file" <<EOF
COMPOSE_PROJECT_NAME=picsure-reset-test
PICSURE_REF=$ref
EOF
}

# run_reset_repos: source reset.sh in a SUBSHELL (so the teardown flow is
# skipped and the fixture env does not leak) and invoke reset_repos() against
# the fixture dirs. Output goes to the given log file.
run_reset_repos() {
  local env_file="$1"
  local repos_dir="$2"
  local log="$3"
  LAST_LOG="$log"
  (
    set --   # clear positionals so reset.sh's arg loop sees nothing when sourced
    ENV_FILE="$env_file"
    REPOS_DIR="$repos_dir"
    export ENV_FILE REPOS_DIR
    # reset.sh stops before its teardown flow when sourced (BASH_SOURCE guard),
    # defining reset_repos() for us to call against the fixture dirs.
    # shellcheck disable=SC1091  # dynamic path, resolved at runtime from SCRIPT_DIR
    source "$SCRIPT_DIR/reset.sh"
    reset_repos
  ) >"$log" 2>&1
}

# --- Test: branch ref reset preserves history -------------------------------
test_reset_to_branch_preserves_history() {
  local repos_dir="$TEST_ROOT/branch-repos"
  local repo="$repos_dir/pic-sure"
  local env_file="$TEST_ROOT/branch.env"
  local local_sha
  local_sha="$(make_fixture_repo "$repos_dir" pic-sure)"
  write_env "$env_file" main

  run_reset_repos "$env_file" "$repos_dir" "$TEST_ROOT/branch.out"

  # Dirty tree gone: tracked edit reverted, untracked file removed.
  [ "$(cat "$repo/ref.txt")" = "main-tip" ] \
    || fail "expected ref.txt reset to origin/main content (got: $(cat "$repo/ref.txt"))"
  [ ! -e "$repo/untracked.txt" ] || fail "expected untracked file to be cleaned"
  git -C "$repo" diff --quiet || fail "expected a clean working tree after reset"

  # Checked out at the target ref (origin/main tip).
  [ "$(git -C "$repo" rev-parse HEAD)" = "$(git -C "$repo" rev-parse origin/main)" ] \
    || fail "expected HEAD at origin/main after reset"

  # .git preserved: local branch still listed.
  git -C "$repo" branch --format='%(refname:short)' | grep -qx my-feature \
    || fail "expected local branch 'my-feature' to survive the reset"

  # .git preserved: the local-only commit is still reachable (object DB/reflog).
  git -C "$repo" cat-file -e "$local_sha^{commit}" 2>/dev/null \
    || fail "expected local-only commit $local_sha to remain reachable"

  pass "branch reset discards dirty tree, keeps local branch + commit"
}

# --- Test: tag ref reset detaches and preserves history ---------------------
test_reset_to_tag_preserves_history() {
  local repos_dir="$TEST_ROOT/tag-repos"
  local repo="$repos_dir/pic-sure"
  local env_file="$TEST_ROOT/tag.env"
  local local_sha
  local_sha="$(make_fixture_repo "$repos_dir" pic-sure)"
  write_env "$env_file" v1

  run_reset_repos "$env_file" "$repos_dir" "$TEST_ROOT/tag.out"

  # Detached at the tag, dirty tree gone.
  [ "$(cat "$repo/ref.txt")" = "v0" ] \
    || fail "expected ref.txt reset to tag v1 content (got: $(cat "$repo/ref.txt"))"
  git -C "$repo" diff --quiet || fail "expected a clean working tree after tag reset"
  [ "$(git -C "$repo" rev-parse HEAD)" = "$(git -C "$repo" rev-parse v1)" ] \
    || fail "expected HEAD at tag v1 after reset"

  # History preserved across the detach.
  git -C "$repo" branch --format='%(refname:short)' | grep -qx my-feature \
    || fail "expected local branch 'my-feature' to survive the tag reset"
  git -C "$repo" cat-file -e "$local_sha^{commit}" 2>/dev/null \
    || fail "expected local-only commit to remain reachable after tag reset"

  pass "tag reset detaches, keeps local branch + commit"
}

# --- Test: conflicting dirty edit on a feature branch (CRITICAL regression) --
# Regression for the branch-pointer bug: sitting on my-feature with a COMMITTED
# change to a file the target ref also changes, plus a conflicting dirty edit
# on top. The buggy flow: `git switch main` fails on the dirty conflict (stderr
# suppressed), HEAD stays on my-feature, and `git reset --hard origin/main`
# then moves MY-FEATURE's pointer to origin/main — orphaning the local commits.
# The fix discards the dirty tree first and refuses the hard reset unless HEAD
# is verifiably on the target branch.
test_conflicting_dirty_on_feature_branch() {
  local repos_dir="$TEST_ROOT/conflict-repos"
  local repo="$repos_dir/pic-sure"
  local env_file="$TEST_ROOT/conflict.env"

  mkdir -p "$repos_dir"
  git clone "$TEST_ROOT/origin.git" "$repo" >/dev/null 2>&1
  git -C "$repo" config user.email "repo-reset-test@example.org"
  git -C "$repo" config user.name "Repo Reset Test"

  # Sit on a feature branch with a COMMITTED edit to ref.txt (differs from
  # main's content), then a conflicting DIRTY edit to the same file.
  git -C "$repo" switch -c my-feature >/dev/null 2>&1
  echo "feature change" > "$repo/ref.txt"
  git_commit_all "$repo" "feature edit to ref.txt"
  local feature_sha
  feature_sha="$(git -C "$repo" rev-parse my-feature)"
  echo "conflicting dirty edit" > "$repo/ref.txt"

  write_env "$env_file" main
  run_reset_repos "$env_file" "$repos_dir" "$TEST_ROOT/conflict.out"

  # HEAD must land on main at origin/main with the dirty edit discarded.
  [ "$(git -C "$repo" branch --show-current)" = "main" ] \
    || fail "expected HEAD on main after reset (got: '$(git -C "$repo" branch --show-current)')"
  [ "$(git -C "$repo" rev-parse HEAD)" = "$(git -C "$repo" rev-parse origin/main)" ] \
    || fail "expected HEAD at origin/main after reset"
  [ "$(cat "$repo/ref.txt")" = "main-tip" ] \
    || fail "expected conflicting dirty edit discarded (got: $(cat "$repo/ref.txt"))"

  # THE critical assertion: my-feature's pointer must not have moved.
  [ "$(git -C "$repo" rev-parse my-feature)" = "$feature_sha" ] \
    || fail "my-feature moved from $feature_sha to $(git -C "$repo" rev-parse my-feature) — branch pointer was clobbered"

  pass "conflicting dirty edit on feature branch: pointer preserved, reset clean"
}

# --- Test: offline (broken origin) falls back to local refs -----------------
# Documents the offline behavior: when fetch fails (no reachable origin) but
# the target ref still resolves from already-local tracking refs, the reset
# still happens against those local refs rather than aborting.
test_offline_uses_local_refs() {
  local repos_dir="$TEST_ROOT/offline-repos"
  local repo="$repos_dir/pic-sure"
  local env_file="$TEST_ROOT/offline.env"
  local local_sha
  local_sha="$(make_fixture_repo "$repos_dir" pic-sure)"
  write_env "$env_file" main

  # Break the remote so `fetch` fails — local origin/main tracking ref remains.
  git -C "$repo" remote set-url origin "$TEST_ROOT/does-not-exist.git"

  run_reset_repos "$env_file" "$repos_dir" "$TEST_ROOT/offline.out"

  grep -q "could not fetch origin" "$TEST_ROOT/offline.out" \
    || fail "expected an offline fetch warning"
  # Still reset to the locally-known origin/main, dirty tree gone.
  [ "$(cat "$repo/ref.txt")" = "main-tip" ] \
    || fail "expected offline reset to local origin/main content"
  git -C "$repo" diff --quiet || fail "expected a clean tree after offline reset"
  git -C "$repo" cat-file -e "$local_sha^{commit}" 2>/dev/null \
    || fail "expected local-only commit to survive offline reset"
  pass "offline reset falls back to local refs, keeps history"
}

# --- Test: a missing repo warns and does not abort --------------------------
test_missing_repo_is_skipped() {
  local repos_dir="$TEST_ROOT/missing-repos"
  local env_file="$TEST_ROOT/missing.env"
  mkdir -p "$repos_dir"   # exists but holds no managed repo
  write_env "$env_file" main

  run_reset_repos "$env_file" "$repos_dir" "$TEST_ROOT/missing.out"
  grep -q "pic-sure is missing; skipping repo reset." "$TEST_ROOT/missing.out" \
    || fail "expected a skip warning for the missing repo"
  pass "missing repo warns and continues"
}

make_service_origin "$TEST_ROOT/origin.git"

test_reset_to_branch_preserves_history
test_reset_to_tag_preserves_history
test_conflicting_dirty_on_feature_branch
test_offline_uses_local_refs
test_missing_repo_is_skipped

echo "[repo-reset-test] complete"
