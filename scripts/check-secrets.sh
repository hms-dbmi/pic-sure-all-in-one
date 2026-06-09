#!/usr/bin/env bash
set -euo pipefail

if ! command -v gitleaks >/dev/null 2>&1; then
  cat >&2 <<'EOF'
Gitleaks is required for the pre-commit secret scan.

Install it, then retry:
  brew install gitleaks

Alternative install options:
  https://github.com/gitleaks/gitleaks#installing
EOF
  exit 1
fi

gitleaks protect --staged --redact --verbose
