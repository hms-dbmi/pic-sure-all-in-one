#!/usr/bin/env bash
set -euo pipefail

blocked=()

while IFS= read -r -d '' path; do
  case "$path" in
    .env|.env.backup.*|.env.local|.env.development|.env.production|.env.test)
      blocked+=("$path")
      ;;
    certs/*)
      blocked+=("$path")
      ;;
    .data/*)
      blocked+=("$path")
      ;;
    dumps/*|backups/*|*.dump|*.dump.gz|*.bak|*.backup|*.sql.gz|*.log)
      blocked+=("$path")
      ;;
    *.pem|*.p12|*.pfx|*.jks|*.keystore)
      blocked+=("$path")
      ;;
    config/hpds/encryption_key)
      blocked+=("$path")
      ;;
    config/dictionary/dictionary.env)
      blocked+=("$path")
      ;;
    config/wildfly/application.truststore|config/psama/application.truststore)
      blocked+=("$path")
      ;;
    config/wildfly/visualization/pic-sure-visualization-resource/resource.properties)
      blocked+=("$path")
      ;;
    config/wildfly/deployments/*.war)
      blocked+=("$path")
      ;;
    repos/*/build/*|repos/*/target/*|repos/*/dist/*|repos/*/node_modules/*)
      blocked+=("$path")
      ;;
    repos/*/.svelte-kit/*|repos/*/coverage/*|repos/*/test-results/*|repos/*/playwright-report/*)
      blocked+=("$path")
      ;;
  esac
done < <(git diff --cached --name-only -z --diff-filter=ACMR)

if (( ${#blocked[@]} > 0 )); then
  printf 'Blocked commit: sensitive or generated files are staged:\n' >&2
  printf '  %s\n' "${blocked[@]}" >&2
  printf '\nRemove these from the index before committing.\n' >&2
  exit 1
fi
