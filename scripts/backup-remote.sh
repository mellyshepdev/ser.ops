#!/usr/bin/env bash
# backup-remote.sh — run ser.ops' own database and config backups ON other
# units, landing everything on unit3.
#
# WHY THIS EXISTS
# ---------------
# backup-dbs.sh enumerates *local* docker containers, and ser.ops only runs on
# unit7. So unit7's databases were backed up daily and nothing else was: unit2
# — which holds the comms database (reech members, contacts, mail accounts,
# calendar, and the portal's photos/preferences) — had never been backed up at
# all, and neither had unit9's PowerDNS zones. unit8 dying is what that costs.
#
# HOW
# ---
# Rather than reimplement dumping per engine, this ships the existing
# backup-dbs.sh to each unit and runs it there with REMOTE_HOST=unit3. The
# remote's own hostname becomes HOST_TAG, so its dumps land in
# unit3:~/backups/db/<that-host>/<yyyymmdd>/ next to unit7's, with the same
# manifest format and the same retry/fallback behaviour. One implementation,
# many hosts — a second copy of that logic would drift.
#
# Units are named by ssh alias, never by address: every address in this fleet
# drifts, and two of them (unit4, unit8) stopped existing entirely.
#
# File-level extras are for state a database dump cannot reach — PowerDNS keeps
# its zones in a sqlite file on unit9, not in a container.
set -u

UNITS=${UNITS:-"unit2 unit9"}
REMOTE_HOST=${REMOTE_HOST:-unit3}
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
SCRIPTS=$(cd "$(dirname "$0")" && pwd)
LOCK=${LOCK:-/tmp/serops-backup-remote.lock}
DAY=$(date +%Y%m%d)
STAMP=$(date +%H%M%S)

exec 9>"$LOCK"; flock -n 9 || { echo "backup-remote busy"; exit 0; }
log(){ echo "[$(date +%H:%M:%S)] $*"; }

# Extra paths worth capturing per unit, beyond what the container dump covers.
# Space-separated; missing paths are skipped rather than failing the run.
extras_for(){
  case "$1" in
    unit9) echo "/var/lib/powerdns/pdns.sqlite3 /etc/caddy /etc/dnsdist" ;;
    unit2) echo "/home/swoopg111/server/networking/proxy/HAproxy/haproxy.cfg" ;;
    *)     echo "" ;;
  esac
}

fails=0
for unit in $UNITS; do
  log "=== $unit ==="

  if ! ssh $SSH_OPTS "$unit" true 2>/dev/null; then
    log "  UNREACHABLE — skipping"
    fails=$((fails+1))
    continue
  fi

  # --- databases -------------------------------------------------------
  # The script is copied fresh each run so a fix here reaches every unit
  # without a separate deploy step.
  if ssh $SSH_OPTS "$unit" "command -v docker >/dev/null 2>&1"; then
    if scp $SSH_OPTS -q "$SCRIPTS/backup-dbs.sh" "$unit:/tmp/serops-backup-dbs.sh" 2>/dev/null; then
      # REMOTE_HOST is passed through so the remote ships straight to unit3
      # rather than back here and out again.
      if ssh $SSH_OPTS "$unit" \
           "chmod +x /tmp/serops-backup-dbs.sh && REMOTE_HOST='$REMOTE_HOST' LOCK=/tmp/serops-dbs.lock /tmp/serops-backup-dbs.sh" \
           2>&1 | sed "s/^/  [$unit] /"; then
        log "  databases ok"
      else
        log "  databases FAILED"
        fails=$((fails+1))
      fi
      ssh $SSH_OPTS "$unit" "rm -f /tmp/serops-backup-dbs.sh" 2>/dev/null
    else
      log "  could not copy backup-dbs.sh"
      fails=$((fails+1))
    fi
  else
    log "  no docker — skipping container dumps"
  fi

  # --- file-level extras ----------------------------------------------
  extras=$(extras_for "$unit")
  if [ -n "$extras" ]; then
    # Tar on the remote and stream straight to unit3. Nothing stages here,
    # and nothing large crosses unit7 at all.
    present=$(ssh $SSH_OPTS "$unit" "for p in $extras; do [ -e \"\$p\" ] && printf '%s ' \"\$p\"; done" 2>/dev/null)
    if [ -n "${present// /}" ]; then
      name="${unit}-extras-${DAY}-${STAMP}.tar.gz"
      if ssh $SSH_OPTS "$unit" \
           "mkdir -p ~/.serops && sudo -n tar czf - $present 2>/dev/null || tar czf - $present 2>/dev/null" \
         | ssh $SSH_OPTS "$REMOTE_HOST" "mkdir -p ~/backups/db/$unit/$DAY && cat > ~/backups/db/$unit/$DAY/$name"; then
        log "  extras ok ($name)"
      else
        log "  extras FAILED"
        fails=$((fails+1))
      fi
    else
      log "  no extras present"
    fi
  fi
done

log "done — $fails failure(s)"
exit 0   # never fail the rotation: a unit being down is not a ser.ops fault
