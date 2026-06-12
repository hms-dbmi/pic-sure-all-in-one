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

# gitleaks 8.19 deprecated `protect` in favour of `git --pre-commit`; the old
# subcommand is dropped entirely in later releases. Prefer the modern form,
# probing the installed binary's own help so this works across versions
# without parsing version strings.
if gitleaks git --help 2>/dev/null | grep -q -- '--pre-commit'; then
  gitleaks git --pre-commit --staged --redact --verbose
else
  gitleaks protect --staged --redact --verbose
fi
