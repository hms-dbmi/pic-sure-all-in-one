#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
job_config="$repo_dir/initial-configuration/jenkins/jenkins-docker/jobs/Migrate PIC-SURE Environment/config.xml"

python3 - "$job_config" <<'PY'
import sys
import xml.etree.ElementTree as ET

job_config = sys.argv[1]
root = ET.parse(job_config).getroot()

scm_url = root.findtext(".//hudson.plugins.git.UserRemoteConfig/url") or ""
if scm_url != "https://github.com/hms-dbmi/pic-sure-all-in-one.git":
    raise SystemExit(f"Unexpected migration job SCM URL: {scm_url}")

parameters = {}
for definition in root.findall(".//parameterDefinitions/*"):
    name = definition.findtext("name")
    if name:
        parameters[name] = definition.findtext("defaultValue") or ""
if parameters.get("git_hash") != "pic_sure_api_mono_repo":
    raise SystemExit("Migration job git_hash does not default to pic_sure_api_mono_repo")

command = root.findtext(".//hudson.tasks.Shell/command") or ""
required = [
    "set -euo pipefail",
    "export DOCKER_CONFIG_DIR=/usr/local/docker-config",
    "./initial-configuration/migrate-env.sh",
]
for text in required:
    if text not in command:
        raise SystemExit(f"Migration job command does not contain: {text}")

for forbidden in [
    "token_introspection_token",
    "PicsureDS",
    "docker stop wildfly",
    "docker rm wildfly",
    "wildfly.retired",
]:
    if forbidden in command:
        raise SystemExit(f"Migration job embeds implementation or destructive behavior: {forbidden}")
PY

echo "Jenkins environment migration job checks passed"
