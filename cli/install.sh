#!/usr/bin/env bash
# =============================================================================
# pic-sure CLI — Installer
# =============================================================================
# Downloads the latest (or a pinned) pic-sure release binary for this
# OS/architecture, verifies its checksum, and installs it.
#
#   curl -fsSL https://raw.githubusercontent.com/hms-dbmi/pic-sure-all-in-one/main/cli/install.sh | bash
#
# Usage:
#   install.sh                      # latest release → ~/.local/bin
#   install.sh --bin-dir /usr/local/bin
#   install.sh --version v3.3.0
#   install.sh --repo OWNER/NAME    # override the GitHub repository
# =============================================================================

set -euo pipefail

REPO="hms-dbmi/pic-sure-all-in-one"
BIN_DIR="$HOME/.local/bin"
VERSION="latest"
# Test hook: point at a local directory holding the release assets instead
# of GitHub (used by CI/smoke to verify this script against a local build).
ASSET_DIR="${PIC_SURE_INSTALL_ASSET_DIR:-}"

say() { printf '%s\n' "$*"; }
fail() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --bin-dir)
      [ -n "${2:-}" ] || fail "--bin-dir requires a directory"
      BIN_DIR="$2"
      shift 2
      ;;
    --bin-dir=*) BIN_DIR="${1#*=}"; shift ;;
    --version)
      [ -n "${2:-}" ] || fail "--version requires a tag (e.g. v3.3.0)"
      VERSION="$2"
      shift 2
      ;;
    --version=*) VERSION="${1#*=}"; shift ;;
    --repo)
      [ -n "${2:-}" ] || fail "--repo requires OWNER/NAME"
      REPO="$2"
      shift 2
      ;;
    --repo=*) REPO="${1#*=}"; shift ;;
    -h|--help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

# --- platform detection ------------------------------------------------------
case "$(uname -s)" in
  Linux) OS=linux ;;
  Darwin) OS=darwin ;;
  *) fail "unsupported OS: $(uname -s) (linux and darwin are supported)" ;;
esac

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) fail "unsupported architecture: $(uname -m) (amd64 and arm64 are supported)" ;;
esac

# Asset naming contract with .github/workflows/release.yml.
ASSET="pic-sure_${OS}_${ARCH}.tar.gz"

# --- checksum tool -----------------------------------------------------------
if command -v sha256sum >/dev/null 2>&1; then
  CHECKSUM_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  CHECKSUM_CMD="shasum -a 256"
else
  fail "neither sha256sum nor shasum is available; install one to verify the download"
fi

# --- download ----------------------------------------------------------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pic-sure-install.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

if [ -n "$ASSET_DIR" ]; then
  say "Using local assets from $ASSET_DIR"
  cp "$ASSET_DIR/$ASSET" "$ASSET_DIR/checksums.txt" "$TMP/"
else
  command -v curl >/dev/null 2>&1 || fail "curl is required"
  if [ "$VERSION" = "latest" ]; then
    BASE_URL="https://github.com/$REPO/releases/latest/download"
  else
    BASE_URL="https://github.com/$REPO/releases/download/$VERSION"
  fi
  say "Downloading $ASSET ($VERSION) from $REPO..."
  curl -fsSL -o "$TMP/$ASSET" "$BASE_URL/$ASSET" \
    || fail "download failed: $BASE_URL/$ASSET (is there a release with this asset?)"
  curl -fsSL -o "$TMP/checksums.txt" "$BASE_URL/checksums.txt" \
    || fail "download failed: $BASE_URL/checksums.txt"
fi

# --- verify ------------------------------------------------------------------
# Compare hashes explicitly rather than via `-c`, whose handling of
# malformed lines varies between implementations (some warn and exit 0).
say "Verifying checksum ($CHECKSUM_CMD)..."
expected_hash="$(awk -v asset="$ASSET" '$2 == asset || $2 == "*"asset {print $1}' "$TMP/checksums.txt")"
[ -n "$expected_hash" ] || fail "checksums.txt has no entry for $ASSET"
actual_hash="$($CHECKSUM_CMD "$TMP/$ASSET" | awk '{print $1}')"
if [ "$actual_hash" != "$expected_hash" ]; then
  fail "checksum verification FAILED for $ASSET (expected $expected_hash, got $actual_hash) — aborting"
fi

# --- install -----------------------------------------------------------------
tar -C "$TMP" -xzf "$TMP/$ASSET"
[ -f "$TMP/pic-sure" ] || fail "archive did not contain the pic-sure binary"

mkdir -p "$BIN_DIR"
install -m 0755 "$TMP/pic-sure" "$BIN_DIR/pic-sure"

say ""
say "Installed: $BIN_DIR/pic-sure"
"$BIN_DIR/pic-sure" --version || true

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    say ""
    say "Note: $BIN_DIR is not on your PATH. Add it with:"
    say "  export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac

say ""
say "Get started: run 'pic-sure' inside a pic-sure-all-in-one checkout."
