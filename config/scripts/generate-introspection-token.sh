#!/usr/bin/env bash
# Generate a PIC-SURE introspection token with the legacy jwt-creator tool.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

JWT_CREATOR_REPO="${JWT_CREATOR_REPO:-https://github.com/hms-dbmi/jwt-creator.git}"
JWT_CREATOR_REF="${JWT_CREATOR_REF:-v1.0.0}"
JWT_CREATOR_DIR="${JWT_CREATOR_DIR:-$ROOT_DIR/.data/jwt-creator}"
JWT_CREATOR_JAR="$JWT_CREATOR_DIR/target/generateJwt.jar"
MAVEN_CACHE="${MAVEN_CACHE:-maven_m2_cache}"
MAVEN_IMAGE="${JWT_CREATOR_MAVEN_IMAGE:-maven:3.9-eclipse-temurin-11}"
JWT_VERBOSE="${JWT_VERBOSE:-false}"
JWT_CREATOR_UPDATE="${JWT_CREATOR_UPDATE:-false}"

usage() {
  echo "Usage: $0 <client_secret> <application_uuid> [ttl_days]" >&2
}

if [ "$#" -lt 2 ]; then
  usage
  exit 1
fi

client_secret="$1"
application_uuid="$2"
ttl_days="${3:-365}"

if ! command -v docker >/dev/null 2>&1; then
  echo "[jwt] docker is required to run jwt-creator." >&2
  exit 1
fi

run_logged() {
  local log_file
  log_file="$(mktemp "${TMPDIR:-/tmp}/picsure-jwt-build.XXXXXX")"

  if [ "$JWT_VERBOSE" = "true" ]; then
    "$@"
    rm -f "$log_file"
    return 0
  fi

  if "$@" >"$log_file" 2>&1; then
    rm -f "$log_file"
    return 0
  fi

  echo "[jwt] Command failed: $*" >&2
  cat "$log_file" >&2
  rm -f "$log_file"
  return 1
}

mkdir -p "$(dirname "$JWT_CREATOR_DIR")"

if [ ! -d "$JWT_CREATOR_DIR/.git" ]; then
  run_logged git clone "$JWT_CREATOR_REPO" "$JWT_CREATOR_DIR"
else
  git -C "$JWT_CREATOR_DIR" remote set-url origin "$JWT_CREATOR_REPO"
  if [ "$JWT_CREATOR_UPDATE" = "true" ] || [ ! -f "$JWT_CREATOR_JAR" ]; then
    run_logged git -C "$JWT_CREATOR_DIR" fetch origin --tags --prune
  fi
fi

built_ref_file="$JWT_CREATOR_DIR/.picsure-built-ref"
if ! run_logged git -C "$JWT_CREATOR_DIR" checkout "$JWT_CREATOR_REF"; then
  run_logged git -C "$JWT_CREATOR_DIR" fetch origin --tags --prune
  run_logged git -C "$JWT_CREATOR_DIR" checkout "$JWT_CREATOR_REF"
fi
if [ "$JWT_CREATOR_UPDATE" = "true" ] && git -C "$JWT_CREATOR_DIR" rev-parse --verify --quiet "origin/$JWT_CREATOR_REF" >/dev/null; then
  run_logged git -C "$JWT_CREATOR_DIR" pull --ff-only origin "$JWT_CREATOR_REF"
fi
current_ref="$(git -C "$JWT_CREATOR_DIR" rev-parse HEAD)"
built_ref=""
if [ -f "$built_ref_file" ]; then
  built_ref="$(cat "$built_ref_file")"
fi

if [ ! -f "$JWT_CREATOR_JAR" ] || [ "$built_ref" != "$current_ref" ]; then
  docker volume create "$MAVEN_CACHE" >/dev/null
  run_logged docker run --rm \
    -v "$JWT_CREATOR_DIR:/src" \
    -v "$MAVEN_CACHE:/root/.m2" \
    -w /src \
    "$MAVEN_IMAGE" \
    mvn -B clean install
  printf '%s' "$current_ref" > "$built_ref_file"
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/picsure-jwt.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

secret_file="$tmp_dir/secret.txt"
printf '%s' "$client_secret" > "$secret_file"
chmod 600 "$secret_file"

docker run --rm \
  -v "$JWT_CREATOR_DIR/target:/jwt:ro" \
  -v "$tmp_dir:/work:ro" \
  "$MAVEN_IMAGE" \
  java -jar /jwt/generateJwt.jar /work/secret.txt sub "PSAMA_APPLICATION|${application_uuid}" "$ttl_days" day \
  | grep -v "Generating"
