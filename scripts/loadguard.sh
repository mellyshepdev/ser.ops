#!/usr/bin/env bash
# ser.ops load guard — decide whether the box can afford to start a heavy task.
#
#   loadguard.sh <task-name>
#     exit 0  -> safe to dispatch
#     exit 75 -> defer (EX_TEMPFAIL). rotate.sh treats 75 as "not a failure,
#                interval not consumed", so the task retries at its next slot.
#
# Why this exists: unit7 is 4 cores with no swap. On 2026-09-20 it reached load
# 47 and stopped answering SSH for ~40 minutes while backup tasks kept being
# dispatched into the pile. Every decision to hold back used to require a human
# asking "should I disable voldb?" — this encodes that judgement so ser.ops
# makes it itself, and writes down WHY.
#
# It is deliberately conservative in one direction: a guard that blocks forever
# is worse than a slow box, because backups stop. See the escape hatch below.

set -uo pipefail

REPO="${REPO:-/home/swoopg111/projects/ser.ops}"
STATE_DIR="${STATE_DIR:-$REPO/state}"
GUARD_DIR="$STATE_DIR/loadguard"
TASK="${1:?usage: loadguard.sh <task-name>}"

# shellcheck source=../lib/event.sh
. "$REPO/lib/event.sh" 2>/dev/null || { event() { :; }; detail_kv() { printf '{}'; }; }

mkdir -p "$GUARD_DIR" 2>/dev/null || true

NPROC=$(nproc 2>/dev/null || echo 4)

# Thresholds. Tuned to unit7's normal working range (~10-20 load while backups
# run) so routine work is NOT blocked — only genuine pile-ups are.
MAX_LOAD="${LOADGUARD_MAX_LOAD:-$(( NPROC * 6 ))}"      # 24 on a 4-core box
MIN_FREE_MB="${LOADGUARD_MIN_FREE_MB:-400}"
MAX_DSTATE="${LOADGUARD_MAX_DSTATE:-12}"                # procs blocked on I/O
MAX_DEFERRALS="${LOADGUARD_MAX_DEFERRALS:-6}"           # escape hatch

# Light tasks never get held back — they are cheap and some (mail) are how
# failures get reported in the first place.
case "$TASK" in
    mail|export) exit 0 ;;
esac

load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
load1_int=${load1%%.*}
free_mb=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 99999)
dstate=$(awk '$3=="D"{n++} END{print n+0}' <(ps -eo pid,comm,state --no-headers 2>/dev/null) 2>/dev/null || echo 0)

count_file="$GUARD_DIR/$TASK.deferrals"
deferrals=$(cat "$count_file" 2>/dev/null || echo 0)
case "$deferrals" in ''|*[!0-9]*) deferrals=0 ;; esac

reason=""
[ "$load1_int" -gt "$MAX_LOAD" ]   && reason="load ${load1} > ${MAX_LOAD}"
[ "$free_mb"   -lt "$MIN_FREE_MB" ] && reason="${reason:+$reason; }MemAvailable ${free_mb}MB < ${MIN_FREE_MB}MB"
[ "$dstate"    -gt "$MAX_DSTATE" ]  && reason="${reason:+$reason; }${dstate} procs blocked on I/O > ${MAX_DSTATE}"

if [ -z "$reason" ]; then
    # Healthy: clear any deferral streak so the escape hatch resets.
    rm -f "$count_file" 2>/dev/null || true
    event "$TASK" step "loadguard: clear to run" "" "" \
        "$(detail_kv guard=pass load="$load1" free_mb="$free_mb" dstate="$dstate")"
    exit 0
fi

# ESCAPE HATCH. A box that stays hot forever must not mean backups stop
# forever. After MAX_DEFERRALS consecutive holds, run anyway and say so —
# a late backup beats no backup, and the event records that we overrode.
if [ "$deferrals" -ge "$MAX_DEFERRALS" ]; then
    rm -f "$count_file" 2>/dev/null || true
    event "$TASK" step "loadguard: OVERRIDE after $deferrals deferrals — running despite pressure" "" "" \
        "$(detail_kv guard=override deferrals="$deferrals" reason="$reason" load="$load1")"
    exit 0
fi

echo $(( deferrals + 1 )) > "$count_file" 2>/dev/null || true
event "$TASK" skip "loadguard: deferring — $reason" "" "" \
    "$(detail_kv guard=defer reason="$reason" load="$load1" free_mb="$free_mb" dstate="$dstate" deferral="$(( deferrals + 1 ))" of="$MAX_DEFERRALS")"
exit 75
