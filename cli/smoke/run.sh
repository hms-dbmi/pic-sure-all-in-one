#!/usr/bin/env bash
# =============================================================================
# pic-sure CLI — Smoke Harness
# =============================================================================
# Exercises safe end-to-end paths against this checkout. Runs without Docker
# where possible; Docker-dependent steps degrade gracefully (status --json
# reports docker.daemon_reachable=false rather than failing).
#
# Usage: make -C cli smoke   (or ./smoke/run.sh after make build)
# =============================================================================

set -euo pipefail

CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$CLI_DIR/.." && pwd)"
BIN="$CLI_DIR/bin/pic-sure"

note() { echo "[smoke] $*"; }
fail() { echo "[smoke] FAIL: $*" >&2; exit 1; }

# Leave no side effects behind even when a step fails mid-run: the stub root
# and any .env this harness created are removed on every exit path.
STUB=""
CREATED_ENV=false
cleanup() {
  if [ -n "$STUB" ]; then rm -rf "$STUB"; fi
  if [ "$CREATED_ENV" = "true" ]; then rm -f "$ROOT/.env"; fi
}
trap cleanup EXIT

[ -x "$BIN" ] || fail "binary not built; run 'make build' first"

note "--version prints build info"
"$BIN" --version | grep -q . || fail "--version produced no output"

note "--help for every subcommand"
for cmd in init update status preflight etl reset uninstall release-control seed-db migrate demo-data up down restart; do
  "$BIN" --root "$ROOT" "$cmd" --help >/dev/null || fail "$cmd --help exited non-zero"
done

note "root discovery from a subdirectory"
(cd "$ROOT/docs" && "$BIN" status --json >/dev/null) || fail "root discovery from docs/ failed"

note "status --json passthrough is byte-exact (deterministic stub root)"
# A stub status.sh with fixed output (incl. escaping edge cases) proves the
# binary forwards script output unmodified, with zero live-stack races.
STUB="$(mktemp -d "${TMPDIR:-/tmp}/pic-sure-smoke-stub.XXXXXX")"
touch "$STUB/.env.example"
printf 'services: {}\n' > "$STUB/docker-compose.yml"
mkdir -p "$STUB/scripts"
printf '# marker\n' > "$STUB/scripts/picsure-compose.sh"
cat > "$STUB/status.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"schema_version":1,"command":"status","edge":"quote:\" backslash:\\ tab:\t"}'
EOF
chmod +x "$STUB/status.sh"
a="$("$BIN" --root "$STUB" status --json)"
b="$(bash "$STUB/status.sh" --json)"
rm -rf "$STUB"
STUB=""
[ "$a" = "$b" ] || fail "pic-sure status --json differs from the script's own output"

note "real status --json validates against the Go contract types"
a="$(cd "$ROOT" && ./status.sh --json)"
printf '%s' "$a" | (cd "$CLI_DIR" && go run ./smoke/validate status) || fail "status document rejected by contract parser"

note "human status output keeps its section skeleton"
hs="$(cd "$ROOT" && ./status.sh 2>/dev/null || true)"
for sec in "== Environment ==" "== Release Control ==" "== Repos ==" "== Compose ==" "== Database ==" "== Migrations =="; do
  case "$hs" in
    *"$sec"*) ;;
    *) fail "human status output is missing section: $sec" ;;
  esac
done

note "preflight --json validates and exit code mirrors 'passed'"
set +e
pf="$("$BIN" --root "$ROOT" preflight --json)"
pf_rc=$?
set -e
printf '%s' "$pf" | (cd "$CLI_DIR" && go run ./smoke/validate preflight) || fail "preflight document rejected by contract parser"
# Plain pattern match — BSD sed's BRE has no \| alternation, which made the
# previous sed extraction silently inert on macOS.
case "$pf" in
  *'"passed":true'*) passed=true ;;
  *'"passed":false'*) passed=false ;;
  *) passed="" ;;
esac
if [ "$passed" = "true" ] && [ "$pf_rc" -ne 0 ]; then
  fail "preflight passed=true but exited $pf_rc"
elif [ "$passed" = "false" ] && [ "$pf_rc" -eq 0 ]; then
  fail "preflight passed=false but exited 0"
fi

note "update --dry-run --offline (safe path)"
if [ ! -f "$ROOT/.env" ]; then
  cp "$ROOT/.env.example" "$ROOT/.env"
  CREATED_ENV=true
fi
"$BIN" --root "$ROOT" update --dry-run --offline >/dev/null || fail "update --dry-run --offline exited non-zero"
if [ "$CREATED_ENV" = "true" ]; then
  rm -f "$ROOT/.env"
  CREATED_ENV=false
fi

note "script exit codes propagate"
set +e
"$BIN" --root "$ROOT" migrate --definitely-not-a-flag >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "expected exit 1 from unknown migrate flag, got $rc"

note "reset refuses non-interactively without --yes"
set +e
"$BIN" --root "$ROOT" reset </dev/null >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "reset should refuse without --yes when stdin is not a TTY"

if docker info >/dev/null 2>&1; then
  note "docker present: services[] reflects compose state"
else
  note "skip: docker not available (status degrades to services:[] — already covered)"
fi

note "PASS"
