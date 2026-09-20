# ser.ops structured event emitter — source this, don't execute it.
#
# Appends one JSON object per line to $STATE_DIR/events/YYYY-MM-DD.jsonl.
# Contract and field meanings: .claude/skills/serops-event-logging/SKILL.md
#
# Design rules, all load-bearing:
#   - No jq. Backup tasks exec inside containers that do not have it, and a
#     missing binary must never break a backup.
#   - Every path ends in `|| true`. Emitting telemetry must NEVER fail a task;
#     a full disk must not turn a backup failure into a backup crash.
#   - Every interpolated string is JSON-escaped. A volume name or error text
#     containing a quote or backslash would otherwise produce an unparseable
#     line and silently truncate the dashboard.

: "${STATE_DIR:=/home/swoopg111/projects/ser.ops/state}"
: "${UNIT:=${UNIT_NAME:-unit7}}"
: "${RUN_ID:=$(date +%s)-$$}"
EVENT_DIR="$STATE_DIR/events"

# Milliseconds since epoch.
# NOTE: `date +%s%3N` is NOT reliable here — on unit7 it returns full
# nanoseconds (19 digits), not 3 truncated digits. Derive ms from %N instead,
# and fall back to seconds*1000 if %N is unsupported (prints a literal "N").
now_ms() {
    local n
    n=$(date +%s%N 2>/dev/null) || n=""
    case "$n" in
        *[!0-9]*|"") echo $(( $(date +%s) * 1000 )) ;;
        *)           echo $(( n / 1000000 )) ;;
    esac
}

_esc() {
    printf '%s' "${1-}" \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g' \
        | tr -d '\000-\010\013\014\016-\037' \
        | tr '\n' ' '
}

# event <task> <phase> <msg> [rc] [dur_ms] [detail-json]
#   phase: tick | skip | start | step | done | fail   (closed set — UI switches on it)
event() {
    local task=${1:-rotate} phase=${2:-step} msg=${3:-} rc=${4:-null} dur=${5:-null} detail=${6:-}
    [ -n "$detail" ] || detail='{}'
    case "$rc"  in ''|*[!0-9-]*) rc=null ;;  esac
    case "$dur" in ''|*[!0-9-]*) dur=null ;; esac
    mkdir -p "$EVENT_DIR" 2>/dev/null || return 0
    printf '{"ts":"%s","unit":"%s","run_id":"%s","task":"%s","phase":"%s","msg":"%s","rc":%s,"dur_ms":%s,"detail":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$(_esc "$UNIT")" "$(_esc "$RUN_ID")" "$(_esc "$task")" "$(_esc "$phase")" "$(_esc "$msg")" \
        "$rc" "$dur" "$detail" \
        >> "$EVENT_DIR/$(date -u +%F).jsonl" 2>/dev/null || true
    return 0
}

# Convenience: build a flat {"k":"v",...} detail object from k=v arguments.
detail_kv() {
    local out="" k v first=1
    for kv in "$@"; do
        k=${kv%%=*}; v=${kv#*=}
        [ "$first" -eq 1 ] && first=0 || out="$out,"
        out="$out\"$(_esc "$k")\":\"$(_esc "$v")\""
    done
    printf '{%s}' "$out"
}
