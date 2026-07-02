#!/usr/bin/env bash
# Phase-1 gateway cutover (P1-2): toggle the DEPLOYED httpd vhosts file between
#   wildfly-direct : RewriteRule ^/picsure/(.*)$ http://wildfly:8080/pic-sure-api-2/PICSURE/$1
#   via-gateway    : RewriteRule ^/picsure/(.*)$ http://gateway:8080/$1
# and restart httpd. Operates on the runtime config (bind-mounted into the httpd
# container), NOT the repo template — the template keeps both rules with the
# gateway one commented until cutover is made permanent post-bake-in.
#
# Usage: ./gateway-cutover.sh {status|enable-timing|apply|revert}
#   status         show which target the deployed /picsure rules point at
#   enable-timing  idempotently append %D (microsecond service time) to the LogFormats
#   apply          wildfly -> gateway on both vhosts, then restart httpd
#   revert         gateway -> wildfly on both vhosts, then restart httpd (rollback)
#
# Env: DOCKER_CONFIG_DIR (default /usr/local/docker-config) or HTTPD_VHOSTS_FILE to
# point directly at the deployed vhosts file.
set -euo pipefail

CONF="${HTTPD_VHOSTS_FILE:-${DOCKER_CONFIG_DIR:-/usr/local/docker-config}/httpd/httpd-vhosts.conf}"
WILDFLY_TARGET='http://wildfly:8080/pic-sure-api-2/PICSURE/$1'
GATEWAY_TARGET='http://gateway:8080/$1'

[ -f "$CONF" ] || { echo "ERROR: vhosts file not found: $CONF (set DOCKER_CONFIG_DIR or HTTPD_VHOSTS_FILE)"; exit 1; }

status() {
    echo "Deployed file: $CONF"
    local n_wf n_gw
    n_wf=$(grep -F "$WILDFLY_TARGET" "$CONF" | grep -cv '^[[:space:]]*#' || true)
    n_gw=$(grep -F "$GATEWAY_TARGET" "$CONF" | grep -cv '^[[:space:]]*#' || true)
    echo "Active /picsure rules -> wildfly-direct: $n_wf, via-gateway: $n_gw"
    if [ "$n_gw" -gt 0 ] && [ "$n_wf" -eq 0 ]; then echo "STATE: via-gateway";
    elif [ "$n_wf" -gt 0 ] && [ "$n_gw" -eq 0 ]; then echo "STATE: wildfly-direct";
    else echo "STATE: MIXED/UNKNOWN — inspect $CONF manually"; fi
    if grep 'LogFormat' "$CONF" | grep -qF '%D'; then
        echo "TIMING: %D present in LogFormats"
    else
        echo "TIMING: %D NOT present (run enable-timing before baselining)"
    fi
}

swap() { # $1 = from-target, $2 = to-target, $3 = label
    local from="$1" to="$2" label="$3" tmp
    if ! grep -F "$from" "$CONF" | grep -qv '^[[:space:]]*#'; then
        echo "Nothing to do: no active rule pointing at '$from' in $CONF"; exit 1
    fi
    # one-time safety backup of the pre-gateway state
    [ -f "$CONF.pre-gateway.bak" ] || cp "$CONF" "$CONF.pre-gateway.bak"
    tmp=$(mktemp)
    # LITERAL replacement via index/substr (the targets contain $ and / which are
    # regex-special, so gsub/sed must not see them as patterns); comments untouched.
    awk -v from="$from" -v to="$to" '
        {
            if ($0 !~ /^[[:space:]]*#/ && index($0, "RewriteRule") > 0) {
                i = index($0, from)
                if (i > 0) {
                    $0 = substr($0, 1, i - 1) to substr($0, i + length(from))
                }
            }
            print
        }
    ' "$CONF" > "$tmp" && mv "$tmp" "$CONF"
    echo "Swapped active /picsure rules -> $label. Restarting httpd..."
    docker restart httpd >/dev/null
    status
}

enable_timing() {
    if grep 'LogFormat' "$CONF" | grep -qF '%D'; then
        echo "%D already present in LogFormats — nothing to do."; return
    fi
    local tmp; tmp=$(mktemp)
    # Append %D just before the closing quote of the three named LogFormats.
    sed -E 's/^([[:space:]]*LogFormat ".*)" (proxy-ssl|combined|proxy)$/\1 %D" \2/' "$CONF" > "$tmp" && mv "$tmp" "$CONF"
    echo "Added %D to LogFormats. Restarting httpd..."
    docker restart httpd >/dev/null
    status
}

case "${1:-}" in
    status)        status ;;
    enable-timing) enable_timing ;;
    apply)         swap "$WILDFLY_TARGET" "$GATEWAY_TARGET" "via-gateway" ;;
    revert)        swap "$GATEWAY_TARGET" "$WILDFLY_TARGET" "wildfly-direct" ;;
    *) echo "Usage: $0 {status|enable-timing|apply|revert}"; exit 1 ;;
esac
