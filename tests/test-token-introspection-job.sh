#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
job_config="$repo_dir/initial-configuration/jenkins/jenkins-docker/jobs/Configure PIC-SURE Token Introspection Token/config.xml"

python3 - "$job_config" <<'PY'
import sys
import xml.etree.ElementTree as ET

command = ET.parse(sys.argv[1]).findtext(".//hudson.tasks.Shell/command") or ""

if "old_token_introspection_token" in command:
    raise SystemExit("Token job still replaces the previous token value")
if "grep -q '^TOKEN_INTROSPECTION_TOKEN='" not in command:
    raise SystemExit("Token job does not detect an existing gateway token setting")
if "TOKEN_INTROSPECTION_TOKEN=$new_token_introspection_token" not in command:
    raise SystemExit("Token job does not write the gateway token by key")
PY

echo "Token introspection fresh-configuration checks passed"
