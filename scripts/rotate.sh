#!/usr/bin/env bash
# ser.ops dispatcher — parallel-lane scheduler.
#
# THE MODEL: deploy/tick.sh owns the slot clock (one wake-up per slot). Each
# wake-up, this script scans the task table ONCE and dispatches EVERY task
# that is due into a detached, supervised runner (scripts/run-task.sh), then
# exits. Tasks outlive the tick that spawned them — the dispatcher never
# waits on a task, so a slow task can no longer starve the fleet.
#
# THIS FIXES the three historical defects:
#   1. "one task per tick"  -> every due task dispatches each tick.
#   2. global lock held for task duration -> rotate.lock is held only for the
#      dispatch sweep itself (seconds); runners hold their OWN locks.
#   3. interval measured from completion -> .last is stamped at dispatch
#      (attempt start), so cadence is start-to-start.
#
# GUARANTEES:
#   * can't loop   — failures write .defer with bounded exponential backoff;
#                    after 5 consecutive fails a task waits its natural
#                    interval. rc=75 (tempfail) defers 10min, not failure.
#   * can't wedge  — every runner is `timeout -k` capped at its conf budget.
#   * can't starve — lanes (heavy=1, xfer=1, light=2 slots) bound how much
#                    runs concurrently per resource class; a busy heavy lane
#                    never blocks a light task.
#   * can't lie    — .run markers track live runners; a dead runner is reaped
#                    next tick as a `fail` event, never silently dropped.
#
# TASK TABLE: conf/tasks.$UNIT.conf, else conf/tasks.conf. Format:
#   name|interval_min|lane|budget_min|lock|command
# ser.ops is portable — no host paths or hostnames are hardcoded below; UNIT,
# REPO, STATE_DIR all come from the environment or are derived.
set -uo pipefail

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}"
SCRIPTS="$REPO/scripts"
STATE_DIR="${STATE_DIR:-$REPO/state}"
ROTATE_DIR="$STATE_DIR/rotate"
LANES_DIR="$STATE_DIR/lanes"
LOCKS_DIR="$STATE_DIR/locks"
RUNLOG_DIR="$STATE_DIR/runlogs"
UNIT="${UNIT_NAME:-$(hostname -s 2>/dev/null || echo unknown)}"
RUN_ID="${RUN_ID:-$(date +%s)-$$}"
export REPO STATE_DIR UNIT RUN_ID

mkdir -p "$ROTATE_DIR" "$LANES_DIR" "$LOCKS_DIR" "$RUNLOG_DIR"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# shellcheck source=../lib/event.sh
. "$REPO/lib/event.sh" 2>/dev/null || { event() { :; }; detail_kv() { printf '{}'; }; }
# shellcheck source=../lib/report.sh
. "$REPO/lib/report.sh" 2>/dev/null || report() { :; }

# Housekeeping (cheap, once per tick): 30d event retention + runlog cap.
find "$STATE_DIR/events" -name '*.jsonl' -mtime +30 -delete 2>/dev/null || true
find "$RUNLOG_DIR" -name '*.log' -size +5M -exec sh -c \
    'tail -n 2000 "$1" > "$1.tmp" && mv "$1.tmp" "$1"' _ {} \; 2>/dev/null || true

# Emit the tick BEFORE contending for the lock — wasted ticks must stay
# visible (that is how the old starvation went undetected).
event rotate tick "dispatcher tick" "" "" "$(detail_kv pid=$$ unit="$UNIT")"

# One dispatch sweep at a time. The lock is held only for the sweep — never
# for a task's duration.
exec 7>"$ROTATE_DIR/rotate.lock"
if ! flock -n 7; then
    log "another rotation tick holds the lock — exiting"
    event rotate skip "another rotation tick holds the lock" "" "" \
        "$(detail_kv reason=lock_held)"
    exit 0
fi

# Lane slot counts — how much of each resource class may run at once.
# heavy=1 keeps the box safe (only one disk-burner); xfer=1 bounds upload
# streams; light=2 lets small tasks fly regardless of heavy work.
LANE_SLOTS_HEAVY="${LANE_SLOTS_HEAVY:-1}"
LANE_SLOTS_XFER="${LANE_SLOTS_XFER:-1}"
LANE_SLOTS_LIGHT="${LANE_SLOTS_LIGHT:-2}"

lane_slots() {
    case "$1" in
        heavy) echo "$LANE_SLOTS_HEAVY" ;;
        xfer)  echo "$LANE_SLOTS_XFER" ;;
        *)     echo "$LANE_SLOTS_LIGHT" ;;   # unknown lane -> light
    esac
}

# --- load the task table -------------------------------------------------
CONF="$REPO/conf/tasks.$UNIT.conf"
[ -f "$CONF" ] || CONF="$REPO/conf/tasks.conf"
if [ ! -f "$CONF" ]; then
    log "no task table ($REPO/conf/tasks.$UNIT.conf or tasks.conf) — cannot schedule"
    event rotate fail "no task table found" "" "" "$(detail_kv reason=conf_missing conf="$CONF")"
    report "ser.ops-warn" "$UNIT: ser.ops dispatcher has no task table — nothing scheduled"
    exit 1
fi

TASKS=()
bad_lines=0
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    name=""; interval=""; lane=""; budget=""; lock=""; cmd=""
    IFS='|' read -r name interval lane budget lock cmd <<< "$line"
    name="${name// /}"; interval="${interval// /}"
    lane="${lane// /}"; budget="${budget// /}"; lock="${lock// /}"
    if [ -z "$name" ] || [ -z "$cmd" ]; then
        bad_lines=$((bad_lines + 1))
        continue
    fi
    case "$interval" in ''|*[!0-9]*) interval=60 ;; esac
    case "$budget"   in ''|*[!0-9]*) budget=60 ;; esac
    case "$lane" in heavy|xfer|light) ;; *) lane="light" ;; esac
    [ -z "$lock" ] && lock="-"
    # Expand path tokens — conf stays host-agnostic.
    cmd="${cmd//\$SCRIPTS/$SCRIPTS}"
    cmd="${cmd//\$REPO/$REPO}"
    cmd="${cmd//\$STATE_DIR/$STATE_DIR}"
    cmd="${cmd//\$LOCKS_DIR/$LOCKS_DIR}"
    TASKS+=("$name|$interval|$lane|$budget|$lock|$cmd")
done < "$CONF"

if [ "${#TASKS[@]}" -eq 0 ]; then
    log "task table $CONF parsed to zero tasks — cannot schedule"
    event rotate fail "task table empty or unparsable" "" "" \
        "$(detail_kv reason=conf_empty conf="$CONF")"
    exit 1
fi
[ "$bad_lines" -gt 0 ] && log "task table $CONF: $bad_lines malformed line(s) skipped"

# --- reap dead runners ----------------------------------------------------
# A .run marker is proof-of-life. "spawn:<epoch>" = dispatched but the runner
# never wrote its pid (>300s old = dead spawn). Numeric = runner pid; verify
# with kill -0. Anything dead is reaped as a failure — never silently dropped.
reaped=0
now=$(date +%s)
for entry in "${TASKS[@]}"; do
    IFS='|' read -r name _ <<< "$entry"
    RUNFILE="$ROTATE_DIR/$name.run"
    [ -f "$RUNFILE" ] || continue
    marker=$(cat "$RUNFILE" 2>/dev/null || echo "")
    dead=0
    case "$marker" in
        spawn:*)
            spawned=${marker#spawn:}
            case "$spawned" in ''|*[!0-9]*) spawned=0 ;; esac
            [ $(( now - spawned )) -gt 300 ] && dead=1 ;;
        ''|*[!0-9]*)
            dead=1 ;;
        *)
            kill -0 "$marker" 2>/dev/null || dead=1 ;;
    esac
    [ "$dead" -eq 0 ] && continue
    fails=$(cat "$ROTATE_DIR/$name.fails" 2>/dev/null || echo 0)
    case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
    fails=$(( fails + 1 ))
    echo "$fails" > "$ROTATE_DIR/$name.fails" 2>/dev/null || true
    rm -f "$RUNFILE" 2>/dev/null || true
    reaped=$((reaped + 1))
    log "task $name: runner lost (stale marker '$marker') — reaped, fails=$fails"
    event "$name" fail "runner lost — stale marker reaped" "" "" \
        "$(detail_kv reason=runner_lost marker="$marker" fails="$fails")"
    report "ser.ops-warn" "$UNIT: task $name runner died mid-flight (reaped)"
done

# --- dispatch sweep -------------------------------------------------------
IDX_FILE="$ROTATE_DIR/index"
last_idx=-1
[ -f "$IDX_FILE" ] && last_idx=$(cat "$IDX_FILE" 2>/dev/null || echo -1)
case "$last_idx" in ''|*[!0-9-]*) last_idx=-1 ;; esac

n=${#TASKS[@]}
dispatched=0
n_not_due=0
n_deferred=0
n_running=0
n_lane_busy=0
n_guarded=0

last_attempt() { [ -f "$ROTATE_DIR/$1.last" ] && stat -c%Y "$ROTATE_DIR/$1.last" 2>/dev/null || echo 0; }

for ((k=1; k<=n; k++)); do
    i=$(( (last_idx + k) % n ))
    IFS='|' read -r name interval lane budget lock cmd <<< "${TASKS[$i]}"

    # Live runner already owns this task.
    if [ -f "$ROTATE_DIR/$name.run" ]; then
        n_running=$((n_running + 1))
        continue
    fi

    # Due? Interval is measured start-to-start (.last stamped at dispatch).
    age=$(( now - $(last_attempt "$name") ))
    if [ "$age" -lt $((interval * 60)) ]; then
        n_not_due=$((n_not_due + 1))
        continue
    fi
    defer_until=$(cat "$ROTATE_DIR/$name.defer" 2>/dev/null || echo 0)
    case "$defer_until" in ''|*[!0-9]*) defer_until=0 ;; esac
    if [ "$defer_until" -gt "$now" ]; then
        n_deferred=$((n_deferred + 1))
        continue
    fi

    # Find a free lane slot. Probe with a subshell (fresh open-file-
    # description per probe — flock is per-OFD, so a probe must not reuse the
    # dispatcher's fds). The RUNNER acquires the slot itself by path: no fd
    # inheritance, so no lock can leak into a child and outlive the sweep.
    slots=$(lane_slots "$lane")
    slot_no=-1
    for ((s=0; s<slots; s++)); do
        if ( flock -n 8 ) 8>>"$LANES_DIR/$lane.$s" 2>/dev/null; then
            slot_no=$s
            break
        fi
    done
    if [ "$slot_no" -lt 0 ]; then
        log "task $name due but lane $lane full ($slots slot(s)) — skipping"
        event "$name" skip "due but lane full" "" "" \
            "$(detail_kv reason=lane_busy lane="$lane" age_s="$age")"
        n_lane_busy=$((n_lane_busy + 1))
        continue
    fi

    # Load guard — heavy/xfer only; light tasks always run (they're small, and
    # mail is how failures get reported in the first place).
    if [ "$lane" != "light" ] && [ -x "$SCRIPTS/loadguard.sh" ]; then
        RUN_ID="$RUN_ID" "$SCRIPTS/loadguard.sh" "$name" </dev/null >/dev/null 2>&1
        if [ "$?" -eq 75 ]; then
            log "task $name held back by loadguard — interval not consumed"
            n_guarded=$((n_guarded + 1))
            continue
        fi
    fi

    # Dispatch: stamp attempt-start (.last) and a spawn marker BEFORE forking,
    # so the next tick sees this task as owned even if the runner is slow to
    # exec. The runner replaces spawn:epoch with its pid, takes the lane slot
    # and task lock itself, then timeout-caps the command.
    touch "$ROTATE_DIR/$name.last" 2>/dev/null || true
    echo "spawn:$now" > "$ROTATE_DIR/$name.run" 2>/dev/null || true
    setsid -f "$SCRIPTS/run-task.sh" "$name" "$interval" "$lane" "$slot_no" "$budget" "$lock" "$cmd" \
        </dev/null >>"$RUNLOG_DIR/$name.log" 2>&1 &
    echo "$i" > "$IDX_FILE"
    dispatched=$((dispatched + 1))
    log "dispatched $name (lane=$lane slot=$slot_no budget=${budget}m age=${age}s)"
done

if [ "$dispatched" -gt 0 ]; then
    log "tick done — dispatched $dispatched task(s)"
    event rotate done "dispatched tasks" "" "" \
        "$(detail_kv dispatched="$dispatched" running="$n_running" lane_busy="$n_lane_busy" deferred="$n_deferred" guarded="$n_guarded" not_due="$n_not_due" conf="$CONF")"
else
    reason=none_free
    [ "$n_not_due" -gt 0 ] && [ $((n_running + n_lane_busy + n_deferred + n_guarded)) -eq 0 ] && reason=not_due
    log "tick idle — nothing dispatched"
    event rotate skip "no task dispatched" "" "" \
        "$(detail_kv reason="$reason" running="$n_running" lane_busy="$n_lane_busy" deferred="$n_deferred" guarded="$n_guarded" not_due="$n_not_due" reaped="$reaped")"
fi
exit 0
