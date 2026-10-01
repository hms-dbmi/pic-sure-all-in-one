#!/usr/bin/env bash
# Exercise the actual AIO vhost against synthetic backends in isolated Docker
# containers. Requires locally available Apache/Node images, curl and openssl.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APACHE_IMAGE="${HTTPD_TEST_IMAGE:-httpd:2.4.68-alpine3.23}"
NODE_IMAGE="${HTTPD_TEST_NODE_IMAGE:-node:24.19.0-alpine3.23}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/picsure-httpd-policy.XXXXXX")"
TEST_NAME="picsure-httpd-policy-$$"
BACKEND="$TEST_NAME-backend"
APACHE="$TEST_NAME-apache"
cleanup() {
  docker rm -f "$APACHE" "$BACKEND" >/dev/null 2>&1 || true
  docker network rm "$TEST_NAME" >/dev/null 2>&1 || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
fail() {
  echo "[httpd-policy] FAIL: $*" >&2
  docker logs "$APACHE" >&2 || true
  exit 1
}
for cmd in docker curl openssl; do command -v "$cmd" >/dev/null || fail "missing $cmd"; done
docker image inspect "$APACHE_IMAGE" "$NODE_IMAGE" >/dev/null || fail 'required images must exist locally (image names are configurable)'
mkdir -p "$TEST_ROOT/cert"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=localhost' \
  -keyout "$TEST_ROOT/cert/server.key" -out "$TEST_ROOT/cert/server.crt" >/dev/null 2>&1
cp "$TEST_ROOT/cert/server.crt" "$TEST_ROOT/cert/server.chain"
cat > "$TEST_ROOT/httpd.conf" <<'CONF'
ServerRoot /usr/local/apache2
ServerName localhost
LoadModule mpm_event_module modules/mod_mpm_event.so
LoadModule unixd_module modules/mod_unixd.so
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule mime_module modules/mod_mime.so
LoadModule log_config_module modules/mod_log_config.so
LoadModule env_module modules/mod_env.so
LoadModule headers_module modules/mod_headers.so
LoadModule setenvif_module modules/mod_setenvif.so
LoadModule proxy_module modules/mod_proxy.so
LoadModule proxy_http_module modules/mod_proxy_http.so
LoadModule rewrite_module modules/mod_rewrite.so
LoadModule ssl_module modules/mod_ssl.so
LoadModule socache_shmcb_module modules/mod_socache_shmcb.so
User www-data
Group www-data
ErrorLog /proc/self/fd/2
LogLevel warn
<Directory /usr/local/apache2/htdocs>
  Require all granted
</Directory>
Include /test/httpd-vhosts.conf
CONF
# Only module/bootstrap setup is synthetic; all routing and response policy
# directives come from the unmodified repository vhost.
cp "$ROOT/config/httpd/httpd-vhosts.conf" "$TEST_ROOT/httpd-vhosts.conf"
cat > "$TEST_ROOT/backend.js" <<'JS'
const http = require('http');
for (const [port, service] of [[3000, 'frontend'], [8080, 'gateway'], [8090, 'psama']]) {
  http.createServer((req, res) => {
    res.setHeader('X-Synthetic-Service', service);
    if (service === 'frontend' || req.url.startsWith('/swagger-ui')) {
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      if (service === 'frontend' && req.url !== '/without-csp') {
        res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'nonce-synthetic123'");
      }
      res.end('<html><script>window.synthetic=true</script><body>synthetic</body></html>');
    } else {
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify({service, path: req.url}));
    }
  }).listen(port, '0.0.0.0');
}
JS
docker network create "$TEST_NAME" >/dev/null
docker run -d --pull=never --name "$BACKEND" --network "$TEST_NAME" \
  --network-alias gateway --network-alias psama --network-alias httpd \
  -v "$TEST_ROOT/backend.js:/test/backend.js:ro" "$NODE_IMAGE" node /test/backend.js >/dev/null
request() {
  local scheme="$1" path="$2"
  local port="$TLS_PORT"
  [ "$scheme" = https ] || port="$HTTP_PORT"
  RESPONSE_CODE="$(curl --path-as-is --silent --show-error --insecure --max-time 5 \
    -H 'Host: localhost' -D "$TEST_ROOT/headers" -o "$TEST_ROOT/body" \
    -w '%{http_code}' "$scheme://127.0.0.1:$port$path")" || fail "request failed: $scheme $path"
}
expect_code() {
  local expected="$1" scheme="$2" path="$3"
  request "$scheme" "$path"
  [ "$RESPONSE_CODE" = "$expected" ] || fail "$scheme $path: expected $expected, got $RESPONSE_CODE"
}
expect_backend() {
  local service="$1" scheme="$2" path="$3"
  expect_code 200 "$scheme" "$path"
  tr -d '\r' < "$TEST_ROOT/headers" | grep -iq "^X-Synthetic-Service: $service$" || fail "$scheme $path did not reach $service"
}
expect_csp() {
  local expected="$1" count policy
  count="$(awk 'tolower($0) ~ /^content-security-policy:/ {n++} END {print n+0}' "$TEST_ROOT/headers")"
  [ "$count" -eq 1 ] || fail "expected one CSP, got $count"
  policy="$(tr -d '\r' < "$TEST_ROOT/headers" | sed -n 's/^Content-Security-Policy: //Ip')"
  [ "$policy" = "$expected" ] || fail "unexpected CSP: $policy"
}
FLOOR="default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; sandbox"
VIEWER="default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
for enabled in true false; do
  docker run -d --pull=never --name "$APACHE" --network "$TEST_NAME" \
    -p 127.0.0.1::443 -p 127.0.0.1::80 \
    -e HTTPD_PREFIX=/usr/local/apache2 -e "GATEWAY_DOCS_ENABLED=$enabled" \
    -v "$TEST_ROOT:/test:ro" -v "$TEST_ROOT/cert:/usr/local/apache2/cert:ro" \
    --entrypoint sh "$APACHE_IMAGE" -ec 'mkdir -p /usr/local/apache2/logs/ssl_mutex && exec httpd -f /test/httpd.conf -DFOREGROUND' >/dev/null
  TLS_PORT="$(docker port "$APACHE" 443/tcp | sed 's/.*://')" || fail "Apache did not publish TLS"
  HTTP_PORT="$(docker port "$APACHE" 80/tcp | sed 's/.*://')" || fail "Apache did not publish HTTP"
  ready=false
  for ((attempt=0; attempt<30; attempt++)); do
    if curl --silent --insecure --fail --max-time 1 "https://127.0.0.1:$TLS_PORT/picsure/health" >/dev/null 2>&1; then ready=true; break; fi
    sleep 0.2
  done
  [ "$ready" = true ] || fail 'Apache did not become ready'
  expect_code 200 https /picsure/health
  expect_backend frontend https /
  expect_csp "default-src 'self'; script-src 'nonce-synthetic123'"
  expect_backend frontend https /without-csp
  expect_csp "$FLOOR"
  expect_backend gateway https /picsure/operations/example
  expect_csp "$FLOOR"
  expect_backend psama https /psama/authentication/example
  expect_backend gateway http /picsure/operations/example
  # Prefix lookalikes are unrelated application routes, not documentation.
  expect_backend gateway https /picsure/openapi-adjacent
  expect_backend psama https /psama/v3/api-docs-adjacent
  for path in /picsure/openapi /picsure/openapi/ /picsure/openapi/gateway \
    /picsure/swagger-ui /picsure/swagger-ui/ /picsure/swagger-ui/swagger-ui-bundle.js \
    /psama/v3/api-docs /psama/v3/api-docs/ /psama/v3/api-docs.yaml \
    /picsure//openapi/gateway //picsure/swagger-ui /psama//v3/api-docs.yaml; do
    if [ "$enabled" = true ]; then
      case "$path" in *psama*) service=psama ;; *) service=gateway ;; esac
      expect_backend "$service" https "$path"
    else
      expect_code 404 https "$path"
      expect_code 404 http "$path"
    fi
  done
  if [ "$enabled" = true ]; then
    for path in /picsure/swagger-ui /picsure/swagger-ui/; do
      expect_backend gateway https "$path"
      expect_csp "$VIEWER"
    done
    expect_backend gateway https /picsure/swagger-ui/swagger-ui-bundle.js
    expect_csp "$FLOOR"
    expect_backend gateway http /picsure/openapi/gateway
  fi
  echo "[httpd-policy] docs=$enabled routing and CSP passed"
  docker rm -f "$APACHE" >/dev/null
done
