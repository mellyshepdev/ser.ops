#!/usr/bin/env bash
# ser.ops task runner — executes ONE task under supervision. Spawned detached
# (setsid) by rotate.sh; never invoked by cron or by hand for real work.
#
#   run-task.sh <name> <interval_min> <lane> <slot> <budget_min> <lock> <command...>
#
# <slot> is the lane slot number the dispatcher reserved for us; we flock
# $STATE_DIR/lanes/<lane>.<slot> ourselves and hold it for our whole life —
# that is what bounds per-lane concurrency. <lock> is a bare lockfile name
# under $STATE_DIR/locks (shared by tasks that must serialize) or `-` for the
# per-task default.
#
# Hard guarantees this wrapper exists to enforce:
#   * NOTHING RUNS FOREVER — `timeout -k` caps the task at <budget>min + 60s
#     grace. A wedged multi-day task is impossible by construction.
#   * NOTHING RETRIES HOT — outcomes write .defer/.fails markers; the
#     dispatcher applies bounded backoff. A broken task cannot crash-loop.
#   * ALWAYS LEAVES A TRACE — .run marker written at start, removed on exit;
#     a start without done/fail shows up as a crash to the next tick.
#   * ALWAYS RELEASES — markers and locks live in files/flocks, all freed by
#     process exit even on SIGKILL.
set -u

NAME="${1:?usage: run-task.sh <name> <interval_min> <lane> <slot> <budget_min> <lock> <cmd>}"
INTERVAL_MIN="${2:?}"
LANE="${3:?}"
SLOT="${4:?}"
BUDGET_MIN="${5:?}"
LOCKNAME="${6:?}"
shift 6
CMD="$*"

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}"
STATE_DIR="${STATE_DIR:-$REPO/state}"
ROTATE_DIR="$STATE_DIR/rotate"
LOCKS_DIR="$STATE_DIR/locks"
RUNLOG_DIR="$STATE_DIR/runlogs"
UNIT="${UNIT_NAME:-$(hostname -s 2>/dev/null || echo unknown)}"
RUN_ID="${RUN_ID:-$(date +%s)-$$}"
export REPO STATE_DIR UNIT RUN_ID

mkdir -p "$ROTATE_DIR" "$LOCKS_DIR" "$RUNLOG_DIR" 2>/dev/null || true

# shellcheck source=../lib/event.sh
. "$REPO/lib/event.sh" 2>/dev/null || { event() { :; }; detail_kv() { printf '{}'; }; }
# shellcheck source=../lib/report.sh
. "$REPO/lib/report.sh" 2>/dev/null || report() { :; }

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

RUNFILE="$ROTATE_DIR/$NAME.run"
FAILFILE="$ROTATE_DIR/$NAME.fails"
DEFERFILE="$ROTATE_DIR/$NAME.defer"
RUNLOG="$RUNLOG_DIR/$NAME.log"

cleanup() { rm -f "$RUNFILE" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# Mark ourselves as the live runner. rotate.sh wrote "spawn:<epoch>" when it
# dispatched us; the pid here is what future ticks reap on.
echo "$$" > "$RUNFILE" 2>/dev/null || true

# Lane slot: the dispatcher reserved <lane>.<slot> for us — take the flock
# ourselves and hold it for our whole life. The 30s wait absorbs the
# probe->acquire handoff; losing means a bookkeeping anomaly, not a pile-up.
LANE_DIR="$STATE_DIR/lanes"
exec 6>>"$LANE_DIR/$LANE.$SLOT"
if ! flock -w 30 6; then
    log "run-task $NAME: lane slot $LANE.$SLOT not free at start — deferring"
    rm -f "$ROTATE_DIR/$NAME.last" 2>/dev/null || true
    echo "$(( $(date +%s) + 300 ))" > "$DEFERFILE" 2>/dev/null || true
    event "$NAME" skip "lane slot lost at start" "" "" \
        "$(detail_kv reason=lane_slot_lost lane="$LANE" slot="$SLOT")"
    exit 0
fi

# Task-level lock. A short wait covers a just-finishing predecessor; a longer
# hold means something outside our tracking owns it — defer, don't queue.
[ "$LOCKNAME" = "-" ] && LOCKNAME="$NAME"
TASKLOCK="$LOCKS_DIR/$LOCKNAME.lock"
exec 9>>"$TASKLOCK"
if ! flock -w 30 9; then
    log "run-task $NAME: task lock held >30s — deferring"
    # .last was stamped at dispatch; remove it so the deferral does not
    # consume the interval — the task is due again once .defer passes.
    rm -f "$ROTATE_DIR/$NAME.last" 2>/dev/null || true
    echo "$(( $(date +%s) + 300 ))" > "$DEFERFILE" 2>/dev/null || true
    event "$NAME" skip "task lock held at start" "" "" \
        "$(detail_kv reason=task_lock_held)"
    exit 0
fi

fails=$(cat "$FAILFILE" 2>/dev/null || echo 0)
case "$fails" in ''|*[!0-9]*) fails=0 ;; esac

log "run-task $NAME: start (lane=$LANE budget=${BUDGET_MIN}m fails=$fails)"
printf -- '--- run-task %s %s budget=%sm ---\n' "$NAME" "$(date -u +%FT%TZ)" "$BUDGET_MIN" \
    >> "$RUNLOG" 2>/dev/null || true
event "$NAME" start "runner started" "" "" \
    "$(detail_kv lane="$LANE" budget_min="$BUDGET_MIN" fails="$fails")"

t0=$(now_ms)
timeout -k 60 "${BUDGET_MIN}m" bash -c "$CMD" >> "$RUNLOG" 2>&1
rc=$?
dur=$(( $(now_ms) - t0 ))

if [ "$rc" -eq 0 ]; then
    rm -f "$FAILFILE" "$DEFERFILE" 2>/dev/null || true
    log "run-task $NAME: done in ${dur}ms"
    event "$NAME" done "completed" 0 "$dur" "$(detail_kv lane="$LANE")"
    exit 0
fi

if [ "$rc" -eq 75 ]; then
    # Temporary condition (peer asleep, remote down): retry soon, not a
    # failure — drop .last so only .defer gates the retry.
    rm -f "$ROTATE_DIR/$NAME.last" 2>/dev/null || true
    echo "$(( $(date +%s) + 600 ))" > "$DEFERFILE" 2>/dev/null || true
    log "run-task $NAME: deferred by task (rc=75)"
    event "$NAME" skip "task requested deferral" 75 "$dur" \
        "$(detail_kv reason=task_defer)"
    exit 0
fi

# Real failure: bounded backoff. Consecutive fails delay the retry
# exponentially (5,10,20,40,80min...) capped at the task interval; after 5
# straight fails we stop granting quick retries entirely and the task waits
# its natural interval. It can never loop hot and never die silently.
fails=$(( fails + 1 ))
echo "$fails" > "$FAILFILE" 2>/dev/null || true
if [ "$fails" -ge 6 ]; then
    backoff=0          # back to natural cadence; .last already consumed
else
    backoff=$(( 300 * (1 << (fails - 1)) ))
    cap=$(( INTERVAL_MIN * 60 ))
    [ "$backoff" -gt "$cap" ] && backoff="$cap"
fi
if [ "$backoff" -gt 0 ]; then
    echo "$(( $(date +%s) + backoff ))" > "$DEFERFILE" 2>/dev/null || true
fi

reason="task failed"
if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    reason="timeout after ${BUDGET_MIN}m"
fi
log "run-task $NAME: FAILED rc=$rc ($reason, fails=$fails, retry in ${backoff}s)"
event "$NAME" fail "$reason" "$rc" "$dur" \
    "$(detail_kv lane="$LANE" fails="$fails" retry_s="$backoff")"

# Locator alert — same channel the old dispatcher used for task failures.
report "ser.ops-warn" "$UNIT: task $NAME failed rc=$rc"
exit "$rc"
