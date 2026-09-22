#!/usr/bin/env bash
# backup-dbs.sh — logical dump of every database container on this host,
# compressed, streamed to unit3. Volume tars are crash-consistent; these
# are the clean restore points.
#
# Engines: postgres (pg_dump -Fc per db + pg_dumpall -g roles),
# mariadb/mysql (mariadb-dump --single-transaction per db), redis
# (BGSAVE rdb copy, masters only), cockroach (BACKUP into nodelocal,
# tarred out). Unknown/failed DBs are marked in the manifest, not fatal.
#
# Remote: unit3:~/backups/db/<host>/<yyyymmdd>/. Local fallback if the
# remote is unreachable. Nothing large stages on this disk.
set -u

HOST_TAG=$(hostname -s 2>/dev/null || echo unit7)
STAMP=$(date +%H%M%S)
DAY=$(date +%Y%m%d)
REMOTE_HOST=${REMOTE_HOST:-unit3-tailscale}
REMOTE_DIR=${REMOTE_DIR:-backups/db/${HOST_TAG}/${DAY}}
LOCAL_DIR=${LOCAL_DIR:-/home/swoopg111/backups/db/${DAY}}
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
LOCK=${LOCK:-/tmp/serops-backup-dbs.lock}
MANIFEST=$(mktemp)

exec 9>"$LOCK"; flock -n 9 || { echo "backup-dbs busy"; exit 0; }
log(){ echo "[$(date +%H:%M:%S)] $*"; }
manifest(){ echo "$1|$2|$3|$4" >> "$MANIFEST"; }

REMOTE_OK=0
if ssh $SSH_OPTS "$REMOTE_HOST" "mkdir -p ~/$REMOTE_DIR" 2>/dev/null; then
  REMOTE_OK=1
else
  mkdir -p "$LOCAL_DIR"
  log "WARN remote $REMOTE_HOST unreachable — staging locally at $LOCAL_DIR"
fi

# Staging lives on disk, not tmpfs: /tmp is RAM on this box and a single
# multi-GB dump through it is how the 08:00 run died on 2026-09-20.
STAGE_DIR="$HOME/backups/db/.staging"
mkdir -p "$STAGE_DIR"

# ship <archive-name> — reads a byte stream on stdin, gzip's it, lands it
# on unit3 (or local fallback). One retry on transient ssh drops.
ship(){
  local name=$1 tmp ok=0 i
  tmp=$(mktemp -p "$STAGE_DIR")
  gzip -1 > "$tmp" || { rm -f "$tmp"; return 1; }
  for i in 1 2; do
    if [ $REMOTE_OK -eq 1 ]; then
      cat "$tmp" | ssh $SSH_OPTS "$REMOTE_HOST" "cat > ~/$REMOTE_DIR/$name.gz" && ok=1
    else
      mv "$tmp" "$LOCAL_DIR/$name.gz" && ok=1; tmp=
    fi
    [ $ok -eq 1 ] && break
    log "  retry $name (attempt $i failed)"
    sleep 3
  done
  [ -n "$tmp" ] && rm -f "$tmp"
  [ $ok -eq 1 ]
}

emit_event(){
  local sev=$1 msg=$2
  curl -s -m 5 -X POST "http://100.99.131.20:50500/api/event" \
    -H 'content-type: application/json' \
    -d "{\"type\":\"backup-dbs\",\"severity\":\"$sev\",\"message\":$(echo "$msg" | jq -R .)}" \
    >/dev/null 2>&1 || true
}

# When the remote is down every run stages ~30G of dumps on /. If the disk
# is already tight, another full staging round can fill it — that's the same
# disk-full that killed pgdb-18.3 on 2026-09-18. Skip rather than pile up.
if [ $REMOTE_OK -eq 0 ]; then
  free_mb=$(df -Pm "$LOCAL_DIR" | awk 'NR==2{print $4}')
  if [ "${free_mb:-0}" -lt "${MIN_FREE_MB:-20480}" ]; then
    log "remote down AND ${free_mb}MB free < ${MIN_FREE_MB:-20480}MB — skipping to protect disk"
    emit_event warn "backup-dbs skipped: unit3 unreachable, ${free_mb}MB free on /"
    rm -f "$MANIFEST"
    exit 1
  fi
fi

containers=$(docker ps -a --format '{{.Names}}|{{.Image}}' 2>/dev/null)
# Optional filter: ONLY_DBS="hub-postgres mariadb-11.4" (space-sep names)
if [ -n "${ONLY_DBS:-}" ]; then
  keep=""; for line in $containers; do
    n=${line%%|*}
    case " $ONLY_DBS " in *" $n "*) keep="$keep $line";; esac
  done
  containers=$keep
fi
fails=0

# ---------- postgres ----------
for line in $containers; do
  name=${line%%|*}; img=${line##*|}
  case "$img" in postgres*|*postgres*|*pgvector*|*pg-autofailover*) ;; *) continue;; esac
  st=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)
  if [ "$st" != "true" ]; then manifest "$name" postgres - SKIP-stopped; continue; fi

  # superuser varies per container (POSTGRES_USER) — local socket is trust
  puser=$(docker exec "$name" printenv POSTGRES_USER 2>/dev/null)
  [ -z "$puser" ] && puser=postgres

  dbs=$(docker exec "$name" psql -U "$puser" -d postgres -Atc \
    "SELECT datname FROM pg_database WHERE datistemplate=false" 2>/dev/null)
  if [ -z "$dbs" ]; then
    log "$name: psql unreachable — SKIP"
    manifest "$name" postgres - FAIL-unreachable; fails=$((fails+1)); continue
  fi

  docker exec "$name" pg_dumpall -g -U "$puser" 2>/dev/null \
    | ship "${name}-globals-${STAMP}.sql" \
    && manifest "$name" postgres globals ok \
    || { manifest "$name" postgres globals FAIL; fails=$((fails+1)); }

  for db in $dbs; do
    log "$name: dumping $db"
    docker exec "$name" pg_dump -U "$puser" -Fc "$db" 2>/dev/null \
      | ship "${name}-${db}-${STAMP}.dump" \
      && manifest "$name" postgres "$db" ok \
      || { manifest "$name" postgres "$db" FAIL; fails=$((fails+1)); }
  done
done

# ---------- mariadb / mysql ----------
for line in $containers; do
  name=${line%%|*}; img=${line##*|}
  case "$img" in mariadb*|mysql*|*mariadb*) ;; *) continue;; esac
  st=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)
  if [ "$st" != "true" ]; then manifest "$name" mariadb - SKIP-stopped; continue; fi

  pw=$(docker exec "$name" printenv MARIADB_ROOT_PASSWORD 2>/dev/null)
  [ -z "$pw" ] && pw=$(docker exec "$name" printenv MYSQL_ROOT_PASSWORD 2>/dev/null)
  dumper=$(docker exec "$name" sh -c 'command -v mariadb-dump || command -v mysqldump' 2>/dev/null | head -1)
  if [ -z "$pw" ] || [ -z "$dumper" ]; then
    log "$name: no root pw or dumper — SKIP"
    manifest "$name" mariadb - FAIL-no-cred; fails=$((fails+1)); continue
  fi

  dbs=$(docker exec "$name" mariadb -u root "-p$pw" -Nse \
    "SELECT schema_name FROM information_schema.schemata
     WHERE schema_name NOT IN ('information_schema','performance_schema')" 2>/dev/null)
  for db in $dbs; do
    log "$name: dumping $db"
    docker exec "$name" "$dumper" -u root "-p$pw" --single-transaction --routines --triggers "$db" 2>/dev/null \
      | ship "${name}-${db}-${STAMP}.sql" \
      && manifest "$name" mariadb "$db" ok \
      || { manifest "$name" mariadb "$db" FAIL; fails=$((fails+1)); }
  done
done

# ---------- redis (masters only — replicas hold the same data) ----------
for line in $containers; do
  name=${line%%|*}; img=${line##*|}
  case "$img" in redis*|*redis*) ;; *) continue;; esac
  case "$name" in *sentinel*) manifest "$name" redis - SKIP-sentinel; continue;; esac
  st=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)
  if [ "$st" != "true" ]; then manifest "$name" redis - SKIP-stopped; continue; fi
  auth=$(docker exec "$name" printenv REDISCLI_AUTH 2>/dev/null)
  [ -z "$auth" ] && auth=$(docker exec "$name" printenv REDIS_PASSWORD 2>/dev/null)
  role=$(docker exec "$name" redis-cli ${auth:+-a "$auth"} info replication 2>/dev/null | grep -o 'role:[a-z]*' | head -1)
  if [ "$role" != "role:master" ]; then manifest "$name" redis - "SKIP-${role:-noauth}"; continue; fi

  log "$name: rdb snapshot"
  docker exec "$name" redis-cli ${auth:+-a "$auth"} --rdb /tmp/serops-dump.rdb >/dev/null 2>&1 \
    && docker exec "$name" cat /tmp/serops-dump.rdb 2>/dev/null | ship "${name}-rdb-${STAMP}.rdb" \
    && docker exec "$name" rm -f /tmp/serops-dump.rdb >/dev/null 2>&1 \
    && manifest "$name" redis rdb ok \
    || { manifest "$name" redis rdb FAIL; fails=$((fails+1)); }
done

# ---------- cockroach ----------
for line in $containers; do
  name=${line%%|*}; img=${line##*|}
  case "$img" in *cockroach*) ;; *) continue;; esac
  st=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)
  if [ "$st" != "true" ]; then manifest "$name" cockroach - SKIP-stopped; continue; fi

  log "$name: BACKUP into nodelocal"
  if docker exec "$name" cockroach sql --insecure \
      -e "BACKUP INTO 'nodelocal://1/serops-$STAMP'" >/dev/null 2>&1; then
    # Stream the backup set out WITHOUT staging it whole.
    #
    # This used to land in /tmp/crdb-$$.tar.gz first. On unit7 /tmp is a
    # tmpfs — RAM, not disk — and this tarball is 5.8 GB. On 2026-09-20 the
    # 00:47 run squeezed through while memory was free and the 08:00 run hit
    # FAIL-tar with only 4.0 GB MemAvailable against a 5.8 GB write. Staging a
    # multi-GB database backup through RAM on a 15 GB box with no swap cannot
    # be made reliable; the fix is to not stage it.
    #
    # Remote: pipe tar straight into ssh, so nothing large touches this box.
    # Local:  write straight to disk (/ has ~94 GB free), never tmpfs.
    # Both verify with `gzip -t` before the final rename, and leave a
    # .partial behind on failure rather than a truncated "good" archive —
    # same contract archive-offload.sh uses.
    crdb_ok=0
    if [ $REMOTE_OK -eq 1 ]; then
      rp="~/$REMOTE_DIR/${name}-backup-${STAMP}.tar.gz"
      if docker exec "$name" tar czf - -C /cockroach/cockroach-data/extern "serops-$STAMP" 2>/dev/null \
           | ssh $SSH_OPTS "$REMOTE_HOST" \
               "cat > $rp.partial && gzip -t $rp.partial && mv $rp.partial $rp"; then
        crdb_ok=1
      else
        manifest "$name" cockroach cluster FAIL-ship; fails=$((fails+1))
      fi
    else
      mkdir -p "$LOCAL_DIR"
      lp="$LOCAL_DIR/${name}-backup-${STAMP}.tar.gz"
      if docker exec "$name" tar czf - -C /cockroach/cockroach-data/extern "serops-$STAMP" 2>/dev/null \
           > "$lp.partial" && gzip -t "$lp.partial" && mv "$lp.partial" "$lp"; then
        crdb_ok=1
      else
        rm -f "$lp.partial"
        manifest "$name" cockroach cluster FAIL-tar; fails=$((fails+1))
      fi
    fi
    [ $crdb_ok -eq 1 ] && manifest "$name" cockroach cluster ok
    docker exec "$name" rm -rf "/cockroach/cockroach-data/extern/serops-$STAMP" >/dev/null 2>&1
  else
    log "$name: BACKUP failed (license?) — volume tar remains the fallback"
    manifest "$name" cockroach - SKIP-backup-failed
  fi
done

# ---------- manifest ----------
mf="$LOCAL_DIR/manifest-$STAMP.txt"; mkdir -p "$LOCAL_DIR"
cp "$MANIFEST" "$mf"
[ $REMOTE_OK -eq 1 ] && cat "$MANIFEST" | ssh $SSH_OPTS "$REMOTE_HOST" \
  "cat > ~/$REMOTE_DIR/manifest-$STAMP.txt" 2>/dev/null
rm -f "$MANIFEST"

# ---------- flush locally-staged days ----------
# Runs that found unit3 unreachable staged their dumps under
# $HOME/backups/db/<day>/. Nothing else ever pushes those — once the remote
# is back, rsync every pending day up and remove the local copy.
if [ $REMOTE_OK -eq 1 ]; then
  for d in "$HOME"/backups/db/*/; do
    [ -d "$d" ] || continue
    day=$(basename "$d")
    if rsync -a --timeout=120 -e "ssh $SSH_OPTS" "$d" \
        "$REMOTE_HOST:backups/db/${HOST_TAG}/" 2>/dev/null; then
      rm -rf "$d" && log "flushed staged day $day -> unit3"
    else
      log "WARN flush of $day failed — left in place"
    fi
  done
fi

if [ $fails -gt 0 ]; then
  emit_event warn "backup-dbs finished with $fails failure(s) — see manifest $STAMP"
  log "done — $fails failure(s)"
  exit 1
fi
emit_event info "backup-dbs ok — manifest $STAMP"
log "done — all dumps shipped"
