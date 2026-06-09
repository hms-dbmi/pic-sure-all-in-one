#!/usr/bin/env bash
# =============================================================================
# PIC-SURE — JSON emission helpers
# =============================================================================
# Pure-bash (3.2+) helpers for emitting JSON from scripts. No jq dependency:
# jq is optional on the host (see run_jq in scripts/lib/common.sh for parsing).
#
# Conventions:
#   - json_str/json_raw/json_bool/json_null print a single `"key":value`
#     fragment with no trailing comma.
#   - json_obj/json_arr join already-formatted fragments with commas, so
#     callers accumulate fragments in a plain array and never track commas:
#
#       fields=()
#       fields+=("$(json_str name "$name")")
#       fields+=("$(json_bool present "$present")")
#       json_obj "${fields[@]}"
#
# Schemas emitted with these helpers are documented in docs/cli-contract.md.
# =============================================================================

# Print the JSON-escaped body of a string (no surrounding quotes).
# Handles backslash, double quote, and all ASCII control characters.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"

  # Remaining control characters (rare) need \u00XX escapes; only take the
  # slow character-by-character path when one is actually present.
  if [[ "$s" == *[$'\x01'-$'\x08\x0b\x0c\x0e'-$'\x1f']* ]]; then
    local out="" char i
    for ((i = 0; i < ${#s}; i++)); do
      char="${s:$i:1}"
      if [[ "$char" == [$'\x01'-$'\x08\x0b\x0c\x0e'-$'\x1f'] ]]; then
        out+=$(printf '\\u%04x' "'$char")
      else
        out+="$char"
      fi
    done
    s="$out"
  fi

  printf '%s' "$s"
}

# "key":"escaped value"
json_str() {
  printf '"%s":"%s"' "$1" "$(json_escape "$2")"
}

# "key":value  — value is emitted verbatim (numbers, booleans, nested JSON).
json_raw() {
  printf '"%s":%s' "$1" "$2"
}

# "key":true|false — accepts true/yes/1 (case-insensitive) as true.
json_bool() {
  case "$2" in
    true|TRUE|True|yes|YES|Yes|1) printf '"%s":true' "$1" ;;
    *) printf '"%s":false' "$1" ;;
  esac
}

# "key":null
json_null() {
  printf '"%s":null' "$1"
}

# "key":"value" when value is non-empty, "key":null otherwise.
json_str_or_null() {
  if [ -n "$2" ]; then
    json_str "$1" "$2"
  else
    json_null "$1"
  fi
}

# Join "key":value fragments into {...}
json_obj() {
  local IFS=,
  printf '{%s}' "$*"
}

# Join value fragments into [...]
json_arr() {
  local IFS=,
  printf '[%s]' "$*"
}

# "value" — a bare escaped string (for array elements).
json_quote() {
  printf '"%s"' "$(json_escape "$1")"
}
