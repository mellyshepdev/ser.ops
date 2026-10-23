#!/bin/bash
# backup-snapshots.sh — vzdump every VM/CT on each Proxmox node, land dumps on unit3.
# ser.ops3 owns this. Dumps also age out to the 5TB drive via gdrive-offload's
# existing /var/lib/vz/dump target on unit10.
set -uo pipefail

NODES="${PROX_NODES:-unit10 unit13}"
BACKUP_HOST="${BACKUP_HOST:-unit3-tailscale}"
STAMP="${STAMP:-$(date +%Y%m%d)}"
MODE="${VZDUMP_MODE:-snapshot}"     # snapshot keeps guests online
COMPRESS="${COMPRESS:-zstd}"
WORK="${WORK:-/tmp/snap-dump}"
log() { echo "$(date -u +%FT%TZ) $*"; }
fail=0

for node in $NODES; do
  ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$node" true 2>/dev/null \
    || { log "$node: unreachable, deferring"; fail=75; continue; }

  log "$node: vzdump --all ($MODE) starting"
  ssh -o BatchMode=yes "root@$node" \
    "vzdump --all --mode $MODE --compress $COMPRESS --dumpdir /var/lib/vz/dump --quiet 2>&1" \
    || { log "$node: vzdump failed"; fail=1; continue; }

  # pull this node's dumps down, push to unit3, clean up locally
  dest="~/backups/snapshots/$node/$STAMP/"
  mkdir -p "$WORK/$node"
  rsync -az --timeout=900 -e "ssh -o BatchMode=yes" \
    "root@$node:/var/lib/vz/dump/" "$WORK/$node/" \
    || { log "$node: pull failed"; fail=1; continue; }
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$BACKUP_HOST" "mkdir -p $dest" 2>/dev/null \
    || { log "$node: unit3 unreachable — dumps held in $WORK/$node"; fail=75; continue; }
  rsync -az --timeout=900 -e "ssh -o BatchMode=yes" \
    "$WORK/$node/" "$BACKUP_HOST:$dest" \
    && rm -rf "$WORK/$node" \
    && log "$node: dumps landed on unit3 ($dest)" \
    || { log "$node: sweep failed — dumps still in $WORK/$node"; fail=1; }
done
exit $fail
