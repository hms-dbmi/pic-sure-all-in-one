#!/bin/sh
# =============================================================================
# Create Java truststore with Let's Encrypt root certificates
# =============================================================================
# Generates JKS truststores for Wildfly and PSAMA with Let's Encrypt
# root CA certificates so they can make HTTPS calls (e.g., to Auth0).
#
# Usage: ./create-truststore.sh <output_dir>
# =============================================================================

set -eu

OUTPUT_DIR="${1:-.}"
STORE_PASS="password"
TMPDIR=$(mktemp -d)

echo "[truststore] Downloading Let's Encrypt root certificates..."
curl -sL https://letsencrypt.org/certs/isrgrootx1.der -o "$TMPDIR/isrgrootx1.der"
curl -sL https://letsencrypt.org/certs/lets-encrypt-r3.der -o "$TMPDIR/lets-encrypt-r3.der"

echo "[truststore] Creating truststore..."
keytool -import \
  -keystore "$OUTPUT_DIR/application.truststore" \
  -storepass "$STORE_PASS" \
  -noprompt -trustcacerts \
  -alias letsencryptauthority1 \
  -file "$TMPDIR/isrgrootx1.der" \
  -storetype JKS 2>/dev/null

keytool -import \
  -keystore "$OUTPUT_DIR/application.truststore" \
  -storepass "$STORE_PASS" \
  -noprompt -trustcacerts \
  -alias letsencryptauthority2 \
  -file "$TMPDIR/lets-encrypt-r3.der" \
  -storetype JKS 2>/dev/null

rm -rf "$TMPDIR"
echo "[truststore] Created: $OUTPUT_DIR/application.truststore"
