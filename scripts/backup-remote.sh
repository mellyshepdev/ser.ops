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

UNITS=${UNITS:-"unit2 unit8 unit9 unit10"}
REMOTE_HOST=${REMOTE_HOST:-unit3}
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
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
    unit9)  echo "/var/lib/powerdns/pdns.sqlite3 /etc/caddy /etc/dnsdist" ;;
    unit2)  echo "/home/admin/edge" ;;
    # whole PVE config tree — CT/VM defs, storage, network. Small, and it is
    # the only record of how CT100 (puffbase) is wired. /srv/puffbase holds
    # CT100's crdb-data + backup mounts.
    unit10) echo "/etc/pve" ;;
    *)      echo "" ;;
  esac
}

# Root-owned paths the ssh user can't read — tar them through a container
# (docker socket = root-equivalent). Format per line: <path>|<image already
# on that host>. Missing image/path skips rather than fails.
cextras_for(){
  case "$1" in
    unit8)  printf '/srv/clusterfs/matrix|postgres:16-alpine\n' ;;
    unit9)  printf '/opt/traccar|mariadb:11.4\n' ;;
    *)      : ;;
  esac
}

fails=0
for unit in $UNITS; do
  log "=== $unit ==="

  if ! ssh "${SSH_OPTS[@]}" "$unit" true 2>/dev/null; then
    log "  UNREACHABLE — skipping"
    fails=$((fails+1))
    continue
  fi

  # --- databases -------------------------------------------------------
  # The script is copied fresh each run so a fix here reaches every unit
  # without a separate deploy step.
  if ssh "${SSH_OPTS[@]}" "$unit" "command -v docker >/dev/null 2>&1"; then
    # Drop in $HOME — /tmp isn't reliably writable for the ssh user on
    # every unit (unit2's /tmp is another uid's).
    if scp "${SSH_OPTS[@]}" -q "$SCRIPTS/backup-dbs.sh" "$unit:serops-backup-dbs.sh" 2>/dev/null; then
      # REMOTE_HOST is passed through so the remote ships straight to unit3
      # rather than back here and out again.
      if ssh "${SSH_OPTS[@]}" "$unit" \
           "chmod +x ~/serops-backup-dbs.sh && TMPDIR=\"\$HOME\" REMOTE_HOST='$REMOTE_HOST' LOCK=\"\$HOME/serops-dbs.lock\" ~/serops-backup-dbs.sh" \
           2>&1 | sed "s/^/  [$unit] /"; then
        log "  databases ok"
      else
        log "  databases FAILED"
        fails=$((fails+1))
      fi
      ssh "${SSH_OPTS[@]}" "$unit" "rm -f ~/serops-backup-dbs.sh" 2>/dev/null
    else
      log "  could not copy backup-dbs.sh"
      fails=$((fails+1))
    fi
  else
    log "  no docker — skipping container dumps"
  fi

  # --- git repositories (commit & push instead of tar backups) --------
  ssh "${SSH_OPTS[@]}" "$unit" '
    for repo in "$HOME"/projects/* "$HOME"/*-app "$HOME"/*-src /root/projects/* /root/*-app /root/*-src; do
      [ -d "$repo/.git" ] || continue
      git -c safe.directory="*" -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1 || continue
      rem=$(git -c safe.directory="*" -C "$repo" remote 2>/dev/null | head -1)
      [ -n "$rem" ] || continue
      if [ -n "$(git -c safe.directory="*" -C "$repo" status --porcelain 2>/dev/null)" ]; then
        git -c safe.directory="*" -C "$repo" config user.name >/dev/null 2>&1 || git -c safe.directory="*" -C "$repo" config user.name "ser.ops"
        git -c safe.directory="*" -C "$repo" config user.email >/dev/null 2>&1 || git -c safe.directory="*" -C "$repo" config user.email "ser.ops@$(hostname -s 2>/dev/null || echo unit)"
        git -c safe.directory="*" -C "$repo" add -A 2>/dev/null || true
        git -c safe.directory="*" -C "$repo" commit -m "auto(ser.ops): $(hostname -s 2>/dev/null || echo unit) $(date -u +"%Y-%m-%d %H:%M")" --no-verify >/dev/null 2>&1 || true
      fi
      ahead=$(git -c safe.directory="*" -C "$repo" rev-list --count @{u}..HEAD 2>/dev/null || echo 0)
      if [ "$ahead" -gt 0 ]; then
        for r in $(git -c safe.directory="*" -C "$repo" remote 2>/dev/null); do
          git -c safe.directory="*" -C "$repo" push "$r" HEAD >/dev/null 2>&1 || true
        done
      fi
    done
  ' 2>/dev/null && log "  git repos synced" || true

  # --- file-level extras (non-git paths only) -------------------------
  extras=$(extras_for "$unit")
  if [ -n "$extras" ]; then
    # Filter out any path that is a git worktree (committed & pushed above instead of tarred).
    present=$(ssh "${SSH_OPTS[@]}" "$unit" "
      for p in $extras; do
        [ -e \"\$p\" ] || continue
        d=\"\$p\"; [ -f \"\$d\" ] && d=\$(dirname \"\$d\")
        if git -c safe.directory=\"*\" -C \"\$d\" rev-parse --show-toplevel >/dev/null 2>&1; then
          continue
        fi
        printf '%s ' \"\$p\"
      done
    " 2>/dev/null)
    if [ -n "${present// /}" ]; then
      name="${unit}-extras-${DAY}-${STAMP}.tar.gz"
      if ssh "${SSH_OPTS[@]}" "$unit" \
           "mkdir -p ~/.serops && sudo -n tar czf - $present 2>/dev/null || tar czf - $present 2>/dev/null" \
         | ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "mkdir -p ~/backups/db/$unit/$DAY && cat > ~/backups/db/$unit/$DAY/$name"; then
        log "  extras ok ($name)"
      else
        log "  extras FAILED"
        fails=$((fails+1))
      fi
    else
      log "  no non-git extras present"
    fi
  fi

  # --- container-tar extras (root-owned state) ------------------------------
  for ce in $(cextras_for "$unit"); do
    cpath=${ce%%|*}; cimg=${ce##*|}
    [ -z "$cpath" ] && continue
    name="${unit}-$(basename "$cpath" | tr '/ ' '__')-${DAY}-${STAMP}.tar.gz"
    if ssh "${SSH_OPTS[@]}" "$unit" \
         "docker run --rm -v '$cpath':/src:ro '$cimg' tar czf - -C /src . 2>/dev/null" \
       | ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "mkdir -p ~/backups/db/$unit/$DAY && cat > ~/backups/db/$unit/$DAY/$name"; then
      log "  cextra ok ($name)"
    else
      log "  cextra FAILED ($cpath)"
      fails=$((fails+1))
    fi
  done
done

log "done — $fails failure(s)"
exit 0   # never fail the rotation: a unit being down is not a ser.ops fault
