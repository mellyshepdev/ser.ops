#!/usr/bin/env bash
# ser.ops task rotation dispatcher.
#
# THE MODEL: one job per SLOT, worked for up to a full slot (1 hour by
# default), then the pointer moves to the next job. deploy/tick.sh owns the
# slot clock and exports SEROPS_DEADLINE; this script picks who gets the slot.
#
# SOFT DEADLINE: SEROPS_DEADLINE (epoch seconds) is inherited by the task
# command. A task that works in chunks should finish the chunk it is on,
# decline to START another past the deadline, then exit 0. Tasks that ignore
# it run to completion as before — overrunning a slot is tolerated, the next
# slot just starts late. Nothing had to be rewritten for this to be safe.
#
# A task is eligible when BOTH:
#   - its min-interval has elapsed since its last attempt (state/rotate/*.last)
#   - its own lockfile is free (a still-running task is skipped, not queued)
# If nothing is eligible the tick exits quietly — that's normal.
#
# NOTE ON INTERVALS: with N tasks at one hour each a full cycle already takes
# N hours, so any min-interval below N*60 never actually gates anything. The
# short values below (55, 110) are inherited from when this ran every 30 min
# and are kept only so a task cannot double-run if the slot length is lowered.
#
# Task table: name|min-interval-min|task-lockfile|command
set -uo pipefail

REPO="${REPO:-/home/swoopg111/projects/ser.ops}"
SCRIPTS="$REPO/scripts"
STATE_DIR="$REPO/state"
ROTATE_DIR="$STATE_DIR/rotate"
UNIT="${UNIT_NAME:-unit7}"
LOKEY_ENV="${LOKEY_ENV:-/home/swoopg111/projects/lokey/.env}"
LOCATOR_URL_DEFAULT="https://locator.theofficialblacksheepco.online"

VOL_LOCK="$STATE_DIR/backup-volumes.lock"
EXP_LOCK="$STATE_DIR/export.lock"
DB_LOCK="$STATE_DIR/backup-dbs.lock"

# Small mounts rotate through 3 shards (~every 2h each → full coverage ~6h).
# Mounts >8GB are the "big" task (~daily) — pgdata whales don't drag ticks.
# Orphan volumes ride the last shard. Volume tasks keep 14d on unit3 —
# 30d of daily ~60GB sets would overrun its disk.
TASKS=(
  "export|55|$EXP_LOCK|$SCRIPTS/export-archive.sh"
  "vol-0|110|$VOL_LOCK|env SHARD=0/3 MAX_MOUNT_MB=8192 KEEP_DAYS=14 $SCRIPTS/backup-volumes.sh"
  "vol-1|110|$VOL_LOCK|env SHARD=1/3 MAX_MOUNT_MB=8192 KEEP_DAYS=14 $SCRIPTS/backup-volumes.sh"
  "vol-2|110|$VOL_LOCK|env SHARD=2/3 MAX_MOUNT_MB=8192 KEEP_DAYS=14 $SCRIPTS/backup-volumes.sh"
  "vol-big|1320|$VOL_LOCK|env MIN_MOUNT_MB=8192 KEEP_DAYS=14 $SCRIPTS/backup-volumes.sh"
  # Second sink: same mounts, but the archive lands in cockroach's userfile
  # store + a queryable metadata table on unit7. ~5h cadence — unit3's
  # tarballs remain the primary off-box copy.
  "voldb|300|$STATE_DIR/voldb.lock|$SCRIPTS/backup-volumes-db.sh"
  "db|350|$DB_LOCK|env LOCK=$DB_LOCK $SCRIPTS/backup-dbs.sh"
  # IMAP_INSECURE=1 because the reech mailbox is reached at unit2's VPC
  # address (172.31.3.133:143) rather than by name: unit9's mail edge
  # cannot currently connect to its unit2 backend, so mail.theofficial-
  # blacksheepco.com is not a usable route. The connection is still
  # STARTTLS-encrypted; only the hostname check is skipped, which a
  # certificate for the name can never satisfy when dialled by IP.
  # Drop this the moment the edge is repaired and the host field can go
  # back to the real name.
  "mail|55|$STATE_DIR/mail.lock|env LOCK=$STATE_DIR/mail.lock IMAP_INSECURE=1 $SCRIPTS/mail-ops.sh"
  # Fleet rule: archives live on unit3. One dir per run drains the xvdbz1
  # volume-archive pile without a multi-hour monolith copy; once drained the
  # task no-ops until something new lands in the archive.
  "archive-offload|120|$STATE_DIR/archive-offload.lock|$SCRIPTS/archive-offload.sh"
  # Same fleet rule, the other half: ~/backups on the production box
  # itself. backup-dbs.sh stages there whenever unit3 is unreachable and
  # nothing ever collected the fallback; the inventory and locator jobs
  # only ever write locally. Daily (1440) — these are leftovers, not a
  # hot path, and a tick spent here is a tick not spent on volumes.
  "sweep-backups|1440|$STATE_DIR/sweep-backups.lock|$SCRIPTS/sweep-backups.sh"
  # live-logger tiered rollover (hot->warm->unit3). Replaces the standalone
  # `17 * * * * ~/live-logger-db/rollover.sh` cron line, which archived the
  # entire backlog in one unbatched statement, wedged for 6+ hours holding its
  # lock, and let logs_warm reach 45GB/77.7M rows. 60min so the 6h hot window
  # drains steadily; heavy, so loadguard gets to defer it — the old cron had no
  # such brake and kept firing straight into the 2026-09-20 load-47 pile-up.
  "livlog|60|$STATE_DIR/livlog-rollover.lock|$SCRIPTS/livlog-rollover.sh"
)

mkdir -p "$ROTATE_DIR"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# Structured event stream (additive — rotate.log stays as-is).
# shellcheck source=../lib/event.sh
. "$REPO/lib/event.sh" 2>/dev/null || event() { :; }

# Retention: keep 30 days of event files. Done here so there is ONE scheduler
# and one place to look; never prunes the current day.
find "$STATE_DIR/events" -name '*.jsonl' -mtime +30 -delete 2>/dev/null || true

# Emit the tick BEFORE contending for the lock. Logging after the lock is
# exactly why tick starvation stayed invisible: on 2026-09-19, 45 of 48 ticks
# exited here and left no machine-readable trace.
event rotate tick "cron tick" "" "" "$(detail_kv pid=$$)"

# One dispatcher at a time — a previous tick still running means a task is
# mid-flight anyway.
exec 7>"$ROTATE_DIR/rotate.lock"
if ! flock -n 7; then
    log "another rotation tick holds the lock — exiting"
    event rotate skip "another rotation tick holds the lock" "" "" \
        "$(detail_kv reason=lock_held)"
    exit 0
fi

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

# Is the task's own lock free right now? (flock is per open-file-description —
# probing with a fresh fd on the same file detects a live holder.)
lock_free() { ( flock -n 8 ) 8>"$1"; }

last_attempt() { [ -f "$ROTATE_DIR/$1.last" ] && stat -c%Y "$ROTATE_DIR/$1.last" || echo 0; }

IDX_FILE="$ROTATE_DIR/index"
last_idx=-1
[ -f "$IDX_FILE" ] && last_idx=$(cat "$IDX_FILE" 2>/dev/null || echo -1)
n=${#TASKS[@]}
now=$(date +%s)

picked=-1
n_not_due=0
n_busy=0
for ((k=1; k<=n; k++)); do
    i=$(( (last_idx + k) % n ))
    IFS='|' read -r name interval lock cmd <<< "${TASKS[$i]}"
    age=$(( now - $(last_attempt "$name") ))
    if [ "$age" -lt $((interval * 60)) ]; then
        n_not_due=$((n_not_due + 1))
        continue                                        # not due yet
    fi
    if ! lock_free "$lock"; then
        log "task $name due but busy (lock $lock held) — next task"
        event "$name" skip "due but lock held" "" "" \
            "$(detail_kv reason=task_lock_held lock="$lock" age_s="$age")"
        n_busy=$((n_busy + 1))
        continue                                        # still running
    fi
    picked=$i
    break
done

if [ "$picked" -lt 0 ]; then
    log "no task due and free — tick idle"
    event rotate skip "no task due and free" "" "" \
        "$(detail_kv reason=none_free not_due="$n_not_due" busy="$n_busy")"
    exit 0
fi

IFS='|' read -r name interval lock cmd <<< "${TASKS[$picked]}"

# Load guard — decide whether the box can afford this task before starting it.
# Encodes the judgement that used to require a human ("should voldb run while
# cockroach is thrashing?"). Exit 75 means defer: the interval is NOT consumed,
# but the rotation pointer DOES advance, so a held-back heavy task lets the
# next task have the slot instead of monopolising every tick.
if [ -r "$SCRIPTS/loadguard.sh" ]; then
    RUN_ID="$RUN_ID" bash "$SCRIPTS/loadguard.sh" "$name"
    guard_rc=$?
    if [ "$guard_rc" -eq 75 ]; then
        log "task $name held back by loadguard — interval not consumed, pointer advanced"
        echo "$picked" > "$IDX_FILE"
        exit 0
    fi
fi

# Budget the task actually has. Reported so a slow job can be told apart from
# a job that was simply handed a short remainder of a slot.
budget=""
if [ -n "${SEROPS_DEADLINE:-}" ]; then
    budget=$(( SEROPS_DEADLINE - $(date +%s) ))
    [ "$budget" -lt 0 ] && budget=0
fi

log "task $name start (rotation slot $picked/$((n-1))${budget:+, ${budget}s of slot left})"
event "$name" start "rotation slot $picked/$((n-1))" "" "" \
    "$(detail_kv slot="$picked" interval_min="$interval" budget_s="${budget:-unset}")"

# Mark the attempt BEFORE running, not after. Touching .last post-run made the
# interval clock measure time since COMPLETION, so the longer a task ran the
# further it slipped — a 2h task on a 110min interval was not eligible again
# until 110min after it ended. Side effect to keep in mind: a task that fails
# immediately now waits its full interval before retrying, which is deliberate
# (it prevents a broken task from crash-looping through every tick).
prev_last=$(last_attempt "$name")
touch "$ROTATE_DIR/$name.last"
echo "$picked" > "$IDX_FILE"

t0=$(now_ms)
bash -c "$cmd"
rc=$?
dur=$(( $(now_ms) - t0 ))

# rc 75 (EX_TEMPFAIL) = "could not run, try again soon" — e.g. archive-offload
# finding unit3 asleep. A deferral must NOT consume the interval: restoring the
# previous .last mtime lets the task retry at its next slot instead of waiting
# the full interval. This is what let a sleeping peer stall the drain until
# xvdbz1 reached 88%.
if [ "$rc" -eq 75 ]; then
    if [ "$prev_last" -gt 0 ] 2>/dev/null; then
        touch -d "@$prev_last" "$ROTATE_DIR/$name.last" 2>/dev/null || true
    else
        rm -f "$ROTATE_DIR/$name.last" 2>/dev/null || true
    fi
    log "task $name deferred (rc=75) — interval not consumed, will retry"
    event "$name" skip "deferred, will retry at next slot" "$rc" "$dur" \
        "$(detail_kv reason=deferred_tempfail slot="$picked")"
    exit 0
fi

if [ "$rc" -eq 0 ]; then
    log "task $name done"
    event "$name" done "completed" "$rc" "$dur" "$(detail_kv slot="$picked")"
else
    log "task $name FAILED rc=$rc"
    event "$name" fail "task failed" "$rc" "$dur" "$(detail_kv slot="$picked")"
    report "ser.ops-warn" "$UNIT: rotation task $name failed rc=$rc"
fi
exit "$rc"
