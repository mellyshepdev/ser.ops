#!/usr/bin/env bash
# Offload cold directories from unit3 + unit10 to gdrive2: (the 5TB Drive),
# one target per rotation tick, bounded at MAX_TRANSFER per run so a 25G
# folder drains across ticks instead of blowing the task budget.
#
# Each target is a host|path pair pushed through `rclone move` ON the remote
# host over ssh (rclone.conf was deployed fleet-wide 2026-10-17). Done targets
# land in state/gdrive-offload.done — files added to a finished dir later
# get picked up only on a fresh pass.
#
# OFFLOAD_DELETE=0 runs `rclone copy` instead — additive verify pass, sources
# stay put.
#
# unit3:~/backups rides in copy mode (Drive mirrors it); still excluded: any
# live VM disk images under /var/lib/vz/images, anything mounted.
#
# Fleet flow (SwoopG, 2026-10-22): every unit's ser.ops ships dumps to unit3;
# from unit3, dumps older than ARCHIVE_AGE move on to the 5TB Drive. The
# "move-old" op does that for unit3's db/ and volumes/ trees: rclone move
# --min-age, so recent restore points stay hot on unit3 and only aged ones
# leave. Those targets are never watermarked — new dumps age in every day.
ARCHIVE_AGE="${ARCHIVE_AGE:-14d}"

set -uo pipefail

REPO="${REPO:-/home/swoopg111/projects/ser.ops}"
STATE_DIR="${STATE_DIR:-$REPO/state}"
DONE_FILE="$STATE_DIR/gdrive-offload.done"
LOCK="$STATE_DIR/gdrive-offload.lock"
REMOTE="${REMOTE:-gdrive2:fleet-archive}"
MAX_TRANSFER="${MAX_TRANSFER:-4G}"
OFFLOAD_DELETE="${OFFLOAD_DELETE:-1}"
TASK_NAME="${TASK_NAME:-gdrive-offload}"

mkdir -p "$STATE_DIR"
# shellcheck source=../lib/event.sh
. "$REPO/lib/event.sh" 2>/dev/null || { event() { :; }; detail_kv() { printf '{}'; }; }
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

exec 9>"$LOCK"
if ! flock -n 9; then
    log "another offload holds $LOCK — exiting"
    exit 0
fi
touch "$DONE_FILE"

# host|abs_path — ssh aliases resolve over tailscale; rclone must exist on
# the remote (unit3 got ~/bin/rclone on 2026-10-17, linux units ~/.local/bin).
# op is move (drain to Drive, free the source) or copy (Drive mirrors the
# backup store — unit3 keeps hot backups, Drive keeps deep archive).
TARGETS=(
    "unit3-tailscale|/Users/swoopggainz/backups/db|move-old"
    "unit3-tailscale|/Users/swoopggainz/backups/volumes|move-old"
    "unit3-tailscale|/Users/swoopggainz/backups/swept|move-old"
    "unit3-tailscale|/Users/swoopggainz/backups|copy"
    "unit10|/var/lib/vz/dump"
    "unit10|/var/lib/vz/template/iso"
    "unit3-tailscale|/Users/swoopggainz/_archive"
    "unit3-tailscale|/Users/swoopggainz/Media"
    "unit3-tailscale|/Users/swoopggainz/Movies"
)

ROT_FILE="$STATE_DIR/gdrive-offload.rot"; LAST_IDX=-1
[ -f "$ROT_FILE" ] && LAST_IDX=$(cat "$ROT_FILE" 2>/dev/null || echo -1)
N=${#TARGETS[@]}
for off in $(seq 1 $N); do
    i=$(( (LAST_IDX + off) % N ))
    t="${TARGETS[$i]}"
    IFS="|" read -r host path target_op <<< "$t"
    key="$host:$path"
    grep -qxF "$key" "$DONE_FILE" && continue
    name=$(basename "$path")

    op=${target_op:-move}; [ "$OFFLOAD_DELETE" = "0" ] && op=copy
    dest="$REMOTE/${host%%-tailscale}/$name"
    extra=""
    if [ "$op" = move-old ]; then
        # land beside the copy-mode mirror (backups/<name>) so Drive has one
        # tree per dump set; source dirs emptied by the move are pruned
        op=move; extra="--min-age $ARCHIVE_AGE --delete-empty-src-dirs"
        dest="$REMOTE/${host%%-tailscale}/backups/$name"
        [ "$OFFLOAD_DELETE" = "0" ] && { op=copy; extra="--min-age $ARCHIVE_AGE"; }
        aged=1
    else
        aged=0
    fi
    log "start $key -> $dest ($op, cap $MAX_TRANSFER)"
    event "ser.ops" "gdrive_offload_start" || :

    if ssh -o BatchMode=yes -o ConnectTimeout=15 "$host" \
        "RCLONE=\$(command -v rclone || echo \$HOME/bin/rclone); command -v \$RCLONE >/dev/null || RCLONE=\$HOME/.local/bin/rclone; \
         \$RCLONE $op $(printf %q "$path") $(printf %q "$dest") --max-transfer $MAX_TRANSFER --cutoff-mode soft --transfers 4 --checkers 4 $extra" ; then
        # empty source after a move = target fully drained (aged targets
        # refill daily, so they are never watermarked)
        if [ "$op" = move ] && [ "$aged" = 0 ] && ssh -o BatchMode=yes "$host" "[ -z \"\$(ls -A $(printf %q "$path") 2>/dev/null)\" ]"; then
            echo "$key" >> "$DONE_FILE"
            log "done $key — source empty, watermarked"
        else
            log "partial $key — continues next tick"
        fi
        event "ser.ops" "gdrive_offload_ok" || :
    else
        log "FAILED $key"
        event "ser.ops-failed" "gdrive_offload_fail" || :
    fi
    echo "$i" > "$ROT_FILE"
    exit 0   # one target per tick — the rotation calls us again in 30 min
done

log "all targets watermarked — nothing due"
exit 0
