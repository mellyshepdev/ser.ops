#!/usr/bin/env bash
# Sweep stray backup artifacts off this unit to unit3.
#
# Fleet rule: backups/replicas/archives live on unit3 — same rule
# archive-offload.sh enforces for the xvdbz1 volume-archive. This covers the
# other half: ~/backups on the production box itself.
#
# backup-dbs.sh streams straight to unit3, but stages into ~/backups/db/<day>
# whenever unit3 is unreachable and nothing ever collects that fallback
# afterwards. inventory-backup.sh, inventory-replicate.sh and
# locator-db-backup.sh only ever write locally, and ad-hoc .bak/.sql snapshots
# pile up beside them. Every one of those is a backup living on the disk it is
# meant to protect.
#
# rsync --remove-source-files deletes a local file only after that file has
# transferred and its checksum matched, so an interrupted run leaves the
# remainder in place rather than losing it. SWEEP_DELETE=0 keeps local copies
# after a verified upload (trust-but-verify first pass).

set -uo pipefail

REPO="${REPO:-/home/swoopg111/projects/ser.ops}"
UNIT="${UNIT_NAME:-unit7}"
SOURCE_DIR="${SOURCE_DIR:-/home/swoopg111/backups}"
BACKUP_HOST="${BACKUP_HOST:-unit3-tailscale}"
REMOTE_DIR="${REMOTE_DIR:-backups/swept/$UNIT}"
STATE_DIR="${STATE_DIR:-$REPO/state}"
KEEP_DAYS="${KEEP_DAYS:-30}"
# A dump still being written is not a backup yet; leave anything touched
# recently for the next tick rather than shipping a half-written file.
MIN_AGE_MIN="${MIN_AGE_MIN:-15}"
SWEEP_DELETE="${SWEEP_DELETE:-1}"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

TASK_NAME="${TASK_NAME:-sweep-backups}"

mkdir -p "$STATE_DIR"

# shellcheck source=../lib/event.sh
. "$REPO/lib/event.sh" 2>/dev/null || { event() { :; }; detail_kv() { printf '{}'; }; }

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

LOCK="${LOCK:-$STATE_DIR/sweep-backups.lock}"
exec 9>"$LOCK"
flock -n 9 || { log "sweep-backups already running"; exit 0; }

started=$(date +%s)

[ -d "$SOURCE_DIR" ] || {
    log "no $SOURCE_DIR — nothing to sweep"
    event "$TASK_NAME" done "no source dir" 0 "" "$(detail_kv source="$SOURCE_DIR")"
    exit 0
}

LIST=$(mktemp); ERR=$(mktemp)
trap 'rm -f "$LIST" "$ERR"' EXIT

# *.log excluded on purpose: the backup jobs append to their logs inside this
# same tree, and moving one mid-write cuts off a running job's output.
( cd "$SOURCE_DIR" && find . -type f ! -name '*.log' -mmin "+$MIN_AGE_MIN" -print ) \
    > "$LIST" 2>/dev/null
count=$(wc -l < "$LIST" | tr -d ' ')

if [ "$count" -eq 0 ]; then
    log "nothing to move from $SOURCE_DIR"
    event "$TASK_NAME" done "nothing to move" 0 "" "$(detail_kv source="$SOURCE_DIR")"
    exit 0
fi

size=$( cd "$SOURCE_DIR" && tr '\n' '\0' < "$LIST" \
        | du -ch --files0-from=- 2>/dev/null | tail -1 | awk '{print $1}' )
size="${size:-unknown}"

event "$TASK_NAME" step "sweeping $count file(s)" "" "" \
    "$(detail_kv files="$count" size="$size" dest="$BACKUP_HOST:$REMOTE_DIR")"

# unit3 asleep or unreachable is a deferral, not a failure — same semantics as
# archive-offload.sh. The files stay put and the next tick retries.
if ! ssh $SSH_OPTS "$BACKUP_HOST" "mkdir -p ~/$REMOTE_DIR" 2>/dev/null; then
    log "peer $BACKUP_HOST unreachable — deferring"
    event "$TASK_NAME" skip "peer unreachable — deferring" "" "" \
        "$(detail_kv peer="$BACKUP_HOST" files="$count" size="$size")"
    exit 0
fi

RSYNC_OPTS=(-a --files-from="$LIST" -e "ssh $SSH_OPTS")
[ "$SWEEP_DELETE" = "1" ] && RSYNC_OPTS+=(--remove-source-files)

if ! rsync "${RSYNC_OPTS[@]}" "$SOURCE_DIR/" "$BACKUP_HOST:$REMOTE_DIR/" 2>"$ERR"; then
    why=$(tail -1 "$ERR" | tr -d '\r' | cut -c1-140)
    log "transfer failed${why:+ — $why}"
    event "$TASK_NAME" fail "transfer to $BACKUP_HOST failed" 1 "" \
        "$(detail_kv peer="$BACKUP_HOST" files="$count" why="$why")"
    exit 1
fi

event "$TASK_NAME" step "verified on remote" "" "" \
    "$(detail_kv files="$count" size="$size")"

if [ "$SWEEP_DELETE" = "1" ]; then
    # rsync empties directories but leaves them; -mindepth 1 keeps SOURCE_DIR.
    find "$SOURCE_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null
fi

left=$( cd "$SOURCE_DIR" && find . -type f ! -name '*.log' -mmin "+$MIN_AGE_MIN" 2>/dev/null \
        | wc -l | tr -d ' ' )

# Retention runs on unit3 and is scoped to this unit's own directory, so one
# unit's pruning can never delete another's.
ssh $SSH_OPTS "$BACKUP_HOST" \
    "find ~/$REMOTE_DIR -type f -mtime +$KEEP_DAYS -delete" 2>/dev/null

dur=$(( ($(date +%s) - started) * 1000 ))
moved=$(( count - left ))

# Anything still here after a successful transfer is a backup on the disk it
# protects — the exact condition this task exists to clear — so it is a
# failure, not a partial success.
if [ "$SWEEP_DELETE" = "1" ] && [ "$left" -gt 0 ]; then
    log "done — $left file(s) still on $UNIT"
    event "$TASK_NAME" fail "moved $moved/$count, $left still local" 1 "$dur" \
        "$(detail_kv moved="$moved" left="$left" size="$size")"
    exit 1
fi

log "done — moved $moved file(s), $size, to $BACKUP_HOST:~/$REMOTE_DIR"
event "$TASK_NAME" done "swept $moved file(s), $size, to $BACKUP_HOST" 0 "$dur" \
    "$(detail_kv moved="$moved" size="$size" dest="$BACKUP_HOST:$REMOTE_DIR")"
