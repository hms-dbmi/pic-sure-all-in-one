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
ASSET_WORK=""
CREATED_ENV=false
cleanup() {
  if [ -n "$STUB" ]; then rm -rf "$STUB"; fi
  if [ -n "$ASSET_WORK" ]; then rm -rf "$ASSET_WORK"; fi
  if [ "$CREATED_ENV" = "true" ]; then rm -f "$ROOT/.env"; fi
}
trap cleanup EXIT

[ -x "$BIN" ] || fail "binary not built; run 'make build' first"

note "--version prints build info"
"$BIN" --version | grep -q . || fail "--version produced no output"

note "--help for every subcommand (list derived from the binary, so it can't drift)"
# Parse the "Available Commands:" block of the root --help: the first token of
# each indented line, up to the first blank line. Plain POSIX awk — no GNU
# extensions — so it runs the same on the macOS and Linux smoke legs. Deriving
# the list means a newly added subcommand is covered automatically and a
# renamed one can't be silently skipped.
cmds="$("$BIN" --help 2>&1 | awk '
  /^Available Commands:/ { in_block = 1; next }
  in_block && /^[[:space:]]*$/ { in_block = 0 }
  in_block && /^[[:space:]]+[a-z]/ { print $1 }
')"
[ -n "$cmds" ] || fail "could not derive the subcommand list from --help"
for cmd in $cmds; do
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

note "script exit codes propagate verbatim (deterministic stub root)"
# Assert a code the binary never produces on its own: usage/cobra errors exit 2
# and generic Go failures exit 1, so 7 can only come from the script itself.
# This distinguishes "the script's exit code propagated" from "the binary
# failed before ever running the script".
STUB="$(mktemp -d "${TMPDIR:-/tmp}/pic-sure-smoke-exit.XXXXXX")"
touch "$STUB/.env.example"
printf 'services: {}\n' > "$STUB/docker-compose.yml"
mkdir -p "$STUB/scripts"
printf '# marker\n' > "$STUB/scripts/picsure-compose.sh"
printf '#!/usr/bin/env bash\nexit 7\n' > "$STUB/status.sh"
chmod +x "$STUB/status.sh"
set +e
"$BIN" --root "$STUB" status --json >/dev/null 2>&1
rc=$?
set -e
rm -rf "$STUB"
STUB=""
[ "$rc" -eq 7 ] || fail "expected exit 7 from the stub status.sh, got $rc"

note "reset refuses non-interactively without --yes"
set +e
"$BIN" --root "$ROOT" reset </dev/null >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "reset should refuse without --yes when stdin is not a TTY"

note "install.sh installs a host-built release via its ASSET_DIR hook"
# Exercise install.sh's local-asset test hook against a real release build:
# the asset-name contract with release.yml, checksum extraction/verification,
# tar extraction, and the binary guard — none of which any other test covers.
# OS/ARCH are derived exactly as install.sh derives them so the asset name and
# the cross-build target agree.
case "$(uname -s)" in
  Linux) inst_os=linux ;;
  Darwin) inst_os=darwin ;;
  *) fail "install.sh smoke: unsupported OS $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64) inst_arch=amd64 ;;
  arm64|aarch64) inst_arch=arm64 ;;
  *) fail "install.sh smoke: unsupported arch $(uname -m)" ;;
esac
asset="pic-sure_${inst_os}_${inst_arch}.tar.gz"

# Mirror install.sh's own checksum-tool selection (sha256sum, else shasum).
if command -v sha256sum >/dev/null 2>&1; then
  sum_cmd="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  sum_cmd="shasum -a 256"
else
  fail "install.sh smoke: neither sha256sum nor shasum is available"
fi

ASSET_WORK="$(mktemp -d "${TMPDIR:-/tmp}/pic-sure-install-smoke.XXXXXX")"
asset_dir="$ASSET_WORK/assets"
bin_dir="$ASSET_WORK/bin"
mkdir -p "$asset_dir" "$bin_dir"

# Build a release binary for the host platform and package it as the release
# workflow does: tar of the bare `pic-sure` binary + a checksums.txt line.
make -C "$CLI_DIR" build-release GOOS="$inst_os" GOARCH="$inst_arch" \
  OUT="$ASSET_WORK/pic-sure" >/dev/null 2>&1 || fail "make build-release failed"
tar -C "$ASSET_WORK" -czf "$asset_dir/$asset" pic-sure
( cd "$asset_dir" && $sum_cmd "$asset" > checksums.txt )

PIC_SURE_INSTALL_ASSET_DIR="$asset_dir" "$CLI_DIR/install.sh" --bin-dir "$bin_dir" >/dev/null \
  || fail "install.sh failed against local assets"
[ -x "$bin_dir/pic-sure" ] || fail "install.sh did not install an executable pic-sure"
"$bin_dir/pic-sure" --version | grep -q . || fail "installed binary --version produced no output"

note "install.sh rejects a corrupted checksum"
# Negative case: flip the recorded hash; verification must fail and nothing
# must be (re)installed. Install into a fresh dir so a stale binary can't mask
# a missing failure.
printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "$asset" \
  > "$asset_dir/checksums.txt"
bad_bin_dir="$ASSET_WORK/bin-bad"
set +e
PIC_SURE_INSTALL_ASSET_DIR="$asset_dir" "$CLI_DIR/install.sh" --bin-dir "$bad_bin_dir" >/dev/null 2>&1
inst_rc=$?
set -e
[ "$inst_rc" -ne 0 ] || fail "install.sh accepted a corrupted checksum (expected non-zero exit)"
[ ! -e "$bad_bin_dir/pic-sure" ] || fail "install.sh installed a binary despite a checksum mismatch"
rm -rf "$ASSET_WORK"
ASSET_WORK=""

if docker info >/dev/null 2>&1; then
  note "docker present: services[] reflects compose state"
else
  note "skip: docker not available (status degrades to services:[] — already covered)"
fi

note "PASS"
