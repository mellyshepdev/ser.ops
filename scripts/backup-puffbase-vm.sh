#!/usr/bin/env bash
# ==============================================================================
# backup-puffbase-vm.sh — commit and push puffbase git repos instead of tarring
# backup archives to unit3.
# ==============================================================================
set -uo pipefail

LOCK=${LOCK:-/tmp/serops-backup-puffvm.lock}
exec 9>"$LOCK"; flock -n 9 || { echo "backup-puffbase-vm busy"; exit 0; }
log(){ echo "[$(date +%H:%M:%S)] $*"; }

# 1. Sync /root/puffbase-app on unit10 directly over SSH (pushed to GitLab + GitHub)
if ssh -o BatchMode=yes -o ConnectTimeout=10 root@unit10 true 2>/dev/null; then
  log "unit10: syncing /root/puffbase-app to git remotes"
  ssh -o BatchMode=yes -o ConnectTimeout=15 root@unit10 '
    if [ -d /root/puffbase-app/.git ]; then
      cd /root/puffbase-app
      if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        git add -A
        git commit -m "auto(ser.ops): unit10 $(date -u +"%Y-%m-%d %H:%M")" --no-verify || true
      fi
      for r in $(git remote); do
        git push "$r" HEAD 2>&1 || true
      done
    fi
  '
fi

# 2. Sync ~/projects/puffbase on puffbase-vm via locator exec channel (git commit & push, no tar backups)
LOCATOR_URL=${LOCATOR_URL:-http://127.0.0.1:50500}
LOCATOR_ENV=${LOCATOR_ENV:-/home/swoopg111/projects/locator/.env}
ADMIN_KEY=$(grep '^LOCATOR_ADMIN_KEY=' "$LOCATOR_ENV" 2>/dev/null | cut -d= -f2-)
if [ -n "$ADMIN_KEY" ]; then
  REMOTE_SCRIPT=$(cat <<'VMSIDE'
if [ -d "$HOME/projects/puffbase/.git" ]; then
  cd "$HOME/projects/puffbase"
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    git add -A
    git commit -m "auto(ser.ops): puffbase-vm $(date -u +"%Y-%m-%d %H:%M")" --no-verify || true
  fi
  for r in $(git remote); do
    git push "$r" HEAD 2>&1 || true
  done
fi
VMSIDE
)
  payload=$(python3 -c "import json,sys; print(json.dumps({'unit':'puffbase-vm','label':'serops git sync','script':sys.stdin.read()}))" <<<"$REMOTE_SCRIPT")
  curl -sf -X POST "$LOCATOR_URL/api/exec" \
    -H "X-Locator-Admin-Key: $ADMIN_KEY" -H "Content-Type: application/json" -d "$payload" >/dev/null 2>&1 \
    && log "puffbase-vm: queued git commit & push" \
    || log "puffbase-vm: locator exec skipped/unreachable"
fi

log "done — puffbase git sync complete"
exit 0
