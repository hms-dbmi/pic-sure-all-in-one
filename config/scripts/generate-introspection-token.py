#!/usr/bin/env python3
"""
Generate a PIC-SURE introspection token (JWT).

This replaces the Java jwt-creator tool. It generates an HS256-signed JWT
with the same structure that PSAMA and Wildfly expect for internal
service-to-service authentication.

Usage:
    python3 generate-introspection-token.py <client_secret> <application_uuid> [ttl_days]

Output:
    The JWT token string (no newline), suitable for piping into env vars.

The token contains:
    - sub: "PSAMA_APPLICATION|<application_uuid>"
    - iss: "bar"
    - jti: "Foo"
    - iat: current time
    - exp: current time + ttl_days (default: 365)
"""

import sys
import hmac
import hashlib
import base64
import json
import time


def base64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode('ascii')


def create_jwt(secret: str, subject: str, ttl_days: int = 365) -> str:
    """Create an HS256 JWT matching the jwt-creator tool's output."""
    now = int(time.time())
    exp = now + (ttl_days * 86400)

    header = {"alg": "HS256", "typ": "JWT"}
    payload = {
        "sub": subject,
        "jti": "Foo",
        "iss": "bar",
        "iat": now,
        "exp": exp,
    }

    header_b64 = base64url_encode(json.dumps(header, separators=(',', ':')).encode())
    payload_b64 = base64url_encode(json.dumps(payload, separators=(',', ':')).encode())

    signing_input = f"{header_b64}.{payload_b64}"
    signature = hmac.new(
        secret.encode(),
        signing_input.encode(),
        hashlib.sha256
    ).digest()
    signature_b64 = base64url_encode(signature)

    return f"{header_b64}.{payload_b64}.{signature_b64}"


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: generate-introspection-token.py <client_secret> <application_uuid> [ttl_days]",
              file=sys.stderr)
        sys.exit(1)

    client_secret = sys.argv[1]
    application_uuid = sys.argv[2]
    ttl_days = int(sys.argv[3]) if len(sys.argv) > 3 else 365

    subject = f"PSAMA_APPLICATION|{application_uuid}"
    token = create_jwt(client_secret, subject, ttl_days)
    print(token, end='')
