#!/usr/bin/env bash
# ser.ops locator reporter — source this, don't execute it.
#
# Extracted from rotate.sh so BOTH the dispatcher and per-task runners can
# alert through the same channel. report() is a best-effort POST to the
# locator /api/events endpoint; every failure path ends in `|| true` —
# a reporting failure must never fail a task.
#
# Credentials come from a lokey env file (default $LOKEY_ENV) or the ambient
# environment; only the three whitelisted keys are read. UNIT must be set by
# the caller (dispatcher/runner derive it from UNIT_NAME or hostname).

: "${LOKEY_ENV:=$HOME/projects/lokey/.env}"
LOCATOR_URL_DEFAULT="${LOCATOR_URL_DEFAULT:-https://locator.theofficialblacksheepco.online}"

load_env_file() {
    local f=$1 k v
    [ -f "$f" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|\#*) continue ;; esac
        k=${line%%=*}; v=${line#*=}
        v=${v%\"}; v=${v#\"}; v=${v%\'}; v=${v#\'}
        case "$k" in
            LOCATOR_URL|LOCATOR_HOST_HEADER|LOCATOR_ADMIN_KEY)
                printf -v "$k" '%s' "$v" ;;
        esac
    done < "$f"
}

report() {
    local kind=$1 msg=$2
    load_env_file "$LOKEY_ENV"
    local url="${LOCATOR_URL:-$LOCATOR_URL_DEFAULT}"
    local host="${LOCATOR_HOST_HEADER:-}"
    local key="${LOCATOR_ADMIN_KEY:-}"
    local hdr=(-H 'Content-Type: application/json')
    [ -n "$key" ]  && hdr+=(-H "X-Locator-Admin-Key: $key")
    [ -n "$host" ] && hdr+=(-H "Host: $host")
    curl -sS --max-time 10 -X POST "${hdr[@]}" \
        -d "{\"type\":\"$kind\",\"message\":\"$msg\",\"unit\":\"$UNIT\"}" \
        "$url/api/events" >/dev/null 2>&1 || true
}
