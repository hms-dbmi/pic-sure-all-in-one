# Env-file helpers shared by Jenkins jobs; start-jenkins.sh mounts this at /scripts/env-file.sh.

require_file() {
    if [ ! -f "$1" ]; then
        echo "ERROR: Required configuration file not found: $1"
        exit 1
    fi
}

upsert_env() {
    local key=$1
    local value=$2
    local env_file=$3
    local temp_file="${env_file}.tmp.$$"

    UPSERT_ENV_VALUE="$value" awk -v key="$key" '
        BEGIN { found = 0; value = ENVIRON["UPSERT_ENV_VALUE"] }
        index($0, key "=") == 1 {
            if (!found) print key "=" value
            found = 1
            next
        }
        { print }
        END { if (!found) print key "=" value }
    ' "$env_file" > "$temp_file"
    cat "$temp_file" > "$env_file"
    rm "$temp_file"
}

# Docker --env-file uses the last of duplicate keys, so read that one
read_env() {
    local key=$1
    local env_file=$2
    sed -n "s/^${key}=//p" "$env_file" | tail -n 1
}

validate_env() {
    local key=$1
    local expected=$2
    local env_file=$3
    local actual
    actual="$(read_env "$key" "$env_file")"
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: $env_file contains $key=$actual; expected $key=$expected."
        exit 1
    fi
}
