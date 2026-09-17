#!/usr/bin/env bash
# ser.ops task rotation dispatcher.
#
# Cron ticks every 30 min; each tick runs exactly ONE due task, then the
# round-robin pointer advances — ser.ops "switches tasks" every 30–60 min
# instead of every job firing on its own fixed schedule.
#
# A task is eligible when BOTH:
#   - its min-interval has elapsed since its last attempt (state/rotate/*.last)
#   - its own lockfile is free (a still-running task is skipped, not queued)
# If nothing is eligible the tick exits quietly — that's normal.
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
  "db|350|$DB_LOCK|env LOCK=$DB_LOCK $SCRIPTS/backup-dbs.sh"
)

mkdir -p "$ROTATE_DIR"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# One dispatcher at a time — a previous tick still running means a task is
# mid-flight anyway.
exec 7>"$ROTATE_DIR/rotate.lock"
if ! flock -n 7; then
    log "another rotation tick holds the lock — exiting"
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
for ((k=1; k<=n; k++)); do
    i=$(( (last_idx + k) % n ))
    IFS='|' read -r name interval lock cmd <<< "${TASKS[$i]}"
    age=$(( now - $(last_attempt "$name") ))
    if [ "$age" -lt $((interval * 60)) ]; then
        continue                                        # not due yet
    fi
    if ! lock_free "$lock"; then
        log "task $name due but busy (lock $lock held) — next task"
        continue                                        # still running
    fi
    picked=$i
    break
done

if [ "$picked" -lt 0 ]; then
    log "no task due and free — tick idle"
    exit 0
fi

IFS='|' read -r name interval lock cmd <<< "${TASKS[$picked]}"
log "task $name start (rotation slot $picked/$((n-1)))"
bash -c "$cmd"
rc=$?
touch "$ROTATE_DIR/$name.last"
echo "$picked" > "$IDX_FILE"

if [ "$rc" -eq 0 ]; then
    log "task $name done"
else
    log "task $name FAILED rc=$rc"
    report "ser.ops-warn" "$UNIT: rotation task $name failed rc=$rc"
fi
exit "$rc"
