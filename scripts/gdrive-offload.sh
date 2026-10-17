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
# Deliberately NOT included: unit3:~/backups (that IS the backup store), any
# live VM disk images under /var/lib/vz/images, anything mounted.

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
TARGETS=(
    "unit10|/var/lib/vz/dump"
    "unit10|/var/lib/vz/template/iso"
    "unit3-tailscale|/Users/swoopggainz/_archive"
    "unit3-tailscale|/Users/swoopggainz/Media"
    "unit3-tailscale|/Users/swoopggainz/Movies"
)

for t in "${TARGETS[@]}"; do
    IFS="|" read -r host path <<< "$t"
    key="$host:$path"
    grep -qxF "$key" "$DONE_FILE" && continue
    name=$(basename "$path")

    op=move; [ "$OFFLOAD_DELETE" = "0" ] && op=copy
    dest="$REMOTE/${host%%-tailscale}/$name"
    log "start $key -> $dest ($op, cap $MAX_TRANSFER)"
    event "ser.ops" "gdrive_offload_start" || :

    if ssh -o BatchMode=yes -o ConnectTimeout=15 "$host" \
        "RCLONE=\$(command -v rclone || echo \$HOME/bin/rclone); command -v \$RCLONE >/dev/null || RCLONE=\$HOME/.local/bin/rclone; \
         \$RCLONE $op $(printf %q "$path") $(printf %q "$dest") --max-transfer $MAX_TRANSFER --transfers 4 --checkers 4" ; then
        # empty source after a move = target fully drained
        if [ "$op" = move ] && ssh -o BatchMode=yes "$host" "[ -z \"\$(ls -A $(printf %q "$path") 2>/dev/null)\" ]"; then
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
    exit 0   # one target per tick — the rotation calls us again in 30 min
done

log "all targets watermarked — nothing due"
exit 0
