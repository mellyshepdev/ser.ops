#!/usr/bin/env bash
# ==============================================================================
# backup-puffbase-vm.sh — back up puffbase-vm state via the lokey exec channel.
#
# puffbase-vm has no inbound ssh for us (only lokey heartbeats OUT to the
# locator), so the standard backup-remote.sh ssh path can't reach it. This
# queues a /api/exec job that nohup-detaches the real work on the VM — exec
# jobs time out at 300s and a depot tar + tailnet scp can outrun that. The
# detached job tars the gitea depot volume (the repos puffbase hosts) and
# ~/projects/puffbase (compose + env), scp's both to unit3 over the tailnet,
# then drops a _done marker we poll for.
#
# VM-side scp key: ~/.ssh/id_ed25519 (puffbase-vm-serops) authorized on unit3.
# ==============================================================================
set -uo pipefail

LOCK=${LOCK:-/tmp/serops-backup-puffvm.lock}
exec 9>"$LOCK"; flock -n 9 || { echo "backup-puffbase-vm busy"; exit 0; }
log(){ echo "[$(date +%H:%M:%S)] $*"; }

LOCATOR_URL=${LOCATOR_URL:-http://127.0.0.1:50500}
LOCATOR_ENV=${LOCATOR_ENV:-/home/swoopg111/projects/locator/.env}
ADMIN_KEY=$(grep '^LOCATOR_ADMIN_KEY=' "$LOCATOR_ENV" | cut -d= -f2-)
[ -n "$ADMIN_KEY" ] || { log "no LOCATOR_ADMIN_KEY"; exit 1; }

DAY=$(date +%Y%m%d); STAMP=$(date +%H%M%S)
MARKER="backups/db/puffbase-vm/$DAY/_done-$STAMP"

# Detached on puffbase-vm; marker file on unit3 is the completion signal.
REMOTE_SCRIPT=$(cat <<VMSIDE
nohup bash -c '
  set -u
  SSH="ssh -i \$HOME/.ssh/id_ed25519 -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
  DST=swoopggainz@100.78.95.13
  \$SSH \$DST "mkdir -p backups/db/puffbase-vm/$DAY" || exit 1
  docker run --rm -v puffbase_depot-data:/src:ro node:22-bookworm-slim tar czf - -C /src . \
    | \$SSH \$DST "cat > backups/db/puffbase-vm/$DAY/depot-data-$STAMP.tar.gz" && echo depot-ok
  tar czf - -C "\$HOME" projects/puffbase 2>/dev/null \
    | \$SSH \$DST "cat > backups/db/puffbase-vm/$DAY/puffbase-project-$STAMP.tar.gz" && echo project-ok
  \$SSH \$DST "touch backups/db/puffbase-vm/$DAY/_done-$STAMP"
' > /tmp/serops-backup.log 2>&1 &
echo "detached pid \$!"
VMSIDE
)

payload=$(python3 -c "import json,sys; print(json.dumps({'unit':'puffbase-vm','label':'serops backup','script':sys.stdin.read()}))" <<<"$REMOTE_SCRIPT")
resp=$(curl -sf -X POST "$LOCATOR_URL/api/exec" \
  -H "X-Locator-Admin-Key: $ADMIN_KEY" -H "Content-Type: application/json" -d "$payload") \
  || { log "locator exec POST failed"; exit 1; }
cid=$(printf '%s' "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin)['command']['id'])")
log "queued $cid"

# The exec job returns fast (detached). Wait for the unit3 marker instead.
deadline=$(( $(date +%s) + ${PUFFVM_TIMEOUT:-1200} ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if ssh -o BatchMode=yes -o ConnectTimeout=8 unit3 "test -f ~/$MARKER" 2>/dev/null; then
    log "done — marker landed on unit3"
    ssh -o BatchMode=yes unit3 "ls -la ~/backups/db/puffbase-vm/$DAY/ | tail -5" 2>/dev/null
    exit 0
  fi
  sleep 30
done
log "TIMEOUT waiting for $MARKER — check /tmp/serops-backup.log on puffbase-vm"
exit 1
