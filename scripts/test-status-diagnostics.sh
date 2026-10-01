#!/usr/bin/env bash
# Hermetic integration test: exercise status JSON through a fake Docker CLI.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/scripts/lib" "$TEST_ROOT/bin"
cp "$ROOT/status.sh" "$TEST_ROOT/"
cp "$ROOT/scripts/picsure-compose.sh" "$TEST_ROOT/scripts/"
cp "$ROOT/scripts/lib/"{common,json,config}.sh "$TEST_ROOT/scripts/lib/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_ROOT/run-migrations.sh"
chmod +x "$TEST_ROOT/run-migrations.sh"
printf 'PICSURE_INTROSPECTION_TOKEN=01234567890123456789012345678901\n' > "$TEST_ROOT/.env"
cat > "$TEST_ROOT/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_LOG"
case "$*" in
  info|"compose version") exit 0 ;;
  *'config --quiet') exit 0 ;;
  *'ps --format json') echo '[]' ;;
  *'ps --services --filter status=running') printf '%s\n' hpds httpd gateway ;;
  *'/system/status') echo RUNNING ;;
  *'/PIC-SURE/v3/query/sync')
    case "$TEST_DATA" in
      locked) printf '  HTTP/1.1 403 Forbidden\n' >&2; exit 1 ;;
      unavailable) exit 1 ;;
      malformed) printf '  HTTP/1.1 200 OK\n\n' >&2; printf '<html>error</html>' ;;
      *) printf '  HTTP/1.1 200 OK\n\n' >&2; printf '42' ;;
    esac ;;
  *'/actuator/health')
    if [ "$TEST_DATA" = empty ]; then
      echo '  HTTP/1.1 503 Service Unavailable' >&2; exit 1
    fi
    printf '  HTTP/1.1 200 OK\n\n' >&2; printf '{"status":"UP"}' ;;
  *'https://127.0.0.1/')
    if [ "$TEST_CSP" = unavailable ]; then exit 1; fi
    if [ "$TEST_CSP" = error ]; then printf '  HTTP/1.1 500 Error\n  Content-Type: text/html\n'; exit 1; fi
    printf '  HTTP/1.1 200 OK\n  Content-Type: text/html; charset=utf-8\n'
    case "$TEST_CSP" in
      frontend) echo "  Content-Security-Policy: script-src 'nonce-abc'" ;;
      both) printf "  Content-Security-Policy: script-src 'nonce-abc'\n  Content-Security-Policy: default-src 'none'\n" ;;
      floor) echo "  Content-Security-Policy: default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; sandbox" ;;
      unrecognized) echo "  Content-Security-Policy: default-src 'self'" ;;
    esac ;;
  *) echo "Unexpected Docker invocation: $*" >&2; exit 1 ;;
esac
DOCKER
chmod +x "$TEST_ROOT/bin/docker"
export PATH="$TEST_ROOT/bin:$PATH" TEST_LOG="$TEST_ROOT/calls" TEST_DATA=ready TEST_CSP=frontend
status() { bash "$TEST_ROOT/status.sh" --json "$@"; }
status | jq -e '.schema_version == 1 and .data.ready == null and .data.checked == false and .http.csp_source == "unknown" and .env.introspection_configured == true' >/dev/null
if grep -q 'exec -T' "$TEST_LOG"; then echo 'Default status executed a container probe' >&2; exit 1; fi
for TEST_DATA in ready locked unavailable malformed empty; do
  export TEST_DATA
  case "$TEST_DATA" in ready) want=true ;; locked|empty) want=false ;; *) want=null ;; esac
  status --deep-health | jq -e --argjson want "$want" '.data.checked and .data.ready == $want and .health.healthy == true' >/dev/null
done
for TEST_CSP in frontend both floor none unrecognized error unavailable; do
  export TEST_CSP
  case "$TEST_CSP" in unrecognized|error|unavailable) want=unknown ;; *) want="$TEST_CSP" ;; esac
  status --deep-health | jq -e --arg want "$want" '.http.csp_source == $want' >/dev/null
done
for token in '' __PLACEHOLDER_LONG_ENOUGH_1234567890__; do
  printf 'PICSURE_INTROSPECTION_TOKEN=%s\n' "$token" > "$TEST_ROOT/.env"
  status | jq -e '.env.introspection_configured == false' >/dev/null
done
rm "$TEST_ROOT/.env"
status | jq -e '.env.introspection_configured == null' >/dev/null
echo '[status-diagnostics] all cases passed'
