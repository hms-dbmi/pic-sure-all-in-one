#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
job_config="$repo_dir/initial-configuration/jenkins/jenkins-docker/jobs/Create Self-Signed SSL Certificate/config.xml"
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

workspace_dir="$temp_dir/workspace"
install_dir="$temp_dir/httpd-cert"
job_script="$temp_dir/job-command.sh"
mkdir -p "$workspace_dir" "$install_dir"

python3 - "$job_config" "$install_dir" > "$job_script" <<'PY'
import sys
import xml.etree.ElementTree as ET

job_config, install_dir = sys.argv[1:]
command = ET.parse(job_config).findtext(".//hudson.tasks.Shell/command") or ""
print(command.replace("/usr/local/docker-config/httpd/cert", install_dir))
PY

(
  cd "$workspace_dir"
  SERVERNAME=localhost sh "$job_script"
)

for certificate_file in server.key server.crt server.chain; do
  if [ ! -s "$install_dir/$certificate_file" ]; then
    echo "Missing generated certificate file: $certificate_file" >&2
    exit 1
  fi
done

openssl verify -CAfile "$install_dir/server.chain" "$install_dir/server.crt"

echo "Self-signed SSL certificate job checks passed"
