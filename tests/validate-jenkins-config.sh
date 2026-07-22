#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
jenkins_dir="$repo_dir/initial-configuration/jenkins/jenkins-docker"
jobs_dir="$jenkins_dir/jobs"
initial_config="$jobs_dir/Initial Configuration Pipeline/config.xml"
global_config="$jenkins_dir/config.xml"
update_script="$repo_dir/update-jenkins.sh"
archive_dir="$jenkins_dir/archived-jobs"
readme="$repo_dir/README.md"
jupyterhub_instructions="$repo_dir/jupyterhub_instructions.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file=$1
  local text=$2
  grep -Fq "$text" "$file" || fail "$file does not contain: $text"
}

assert_absent() {
  local file=$1
  local text=$2
  if grep -Fq "$text" "$file"; then
    fail "$file still contains: $text"
  fi
}

assert_contains "$initial_config" "name: &apos;AUTH0_TENANT&apos;, value: env.AUTH0_TENANT"
assert_contains "$initial_config" 'VITE_ALLOW_EXPORT_ENABLED=$env.VITE_ALLOW_EXPORT_ENABLED'
assert_absent "$initial_config" "TARGET_OBFUSCATION_THRESHOLD"
assert_absent "$initial_config" "OUTBOUND_EMAIL_USER"
assert_absent "$global_config" "Configure Outbound Email Settings"
test ! -d "$jobs_dir/Configure Outbound Email Settings" || fail "outbound-email job is still active"

assert_contains "$update_script" "jenkins.install.UpgradeWizard.state"
assert_contains "$update_script" "jenkins.install.InstallUtil.lastExecVersion"
assert_contains "$update_script" "restore_jenkins_env_value"
assert_contains "$update_script" "MYSQL_CONFIG_DIR"
assert_contains "$update_script" "MIGRATION_REPO"
assert_absent "$update_script" "project_specific_override_repo"
assert_absent "$update_script" 'sed_inplace "s|host|'
assert_absent "$update_script" 'sed_inplace "s|/usr/local/docker-config/|'

test ! -d "$jobs_dir/Add Site to Passthrough Service" || fail "deprecated add-site passthrough job is still active"
test ! -d "$jobs_dir/Build Passthru Image" || fail "deprecated passthrough build job is still active"
assert_absent "$global_config" "Add Site to Passthrough Service"
assert_absent "$global_config" "Build Passthru Image"
test ! -d "$jobs_dir/archived_jobs" || fail "legacy jobs are still inside the active jobs tree"
test -d "$archive_dir" || fail "legacy job archive is missing"

archive_count=$(find "$archive_dir" -mindepth 2 -maxdepth 2 -name config.xml -type f | wc -l | tr -d ' ')
test "$archive_count" = 9 || fail "expected 9 archived jobs, found $archive_count"
assert_contains "$archive_dir/README.md" "not copied into Jenkins"
assert_absent "$readme" 'To start or stop JupyterHub use the "Start JupyterHub" and "Stop JupyterHub" jobs.'
assert_contains "$jupyterhub_instructions" "archived and are not installed"

echo "Jenkins configuration checks passed"
