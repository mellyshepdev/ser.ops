#!/usr/bin/env bash
# backup-dbs.sh — logical dump of every database container on this host,
# compressed, streamed to unit3. Volume tars are crash-consistent; these
# are the clean restore points.
#
# Engines: postgres (pg_dump -Fc per db + pg_dumpall -g roles; DBs over
# BIG_DB_BYTES get schema+small-tables as one -Fc and each oversized table
# as resumable timestamp-window COPY chunks), mariadb/mysql (mariadb-dump
# --single-transaction per db), redis (BGSAVE rdb copy, masters only),
# cockroach (BACKUP into nodelocal, tarred out). Unknown/failed DBs are
# marked in the manifest, not fatal.
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

# ---------- oversized postgres DBs ----------
# A DB over BIG_DB_BYTES as a single pg_dump stream can hold the rotation
# for many hours — the 101 GiB live_logger DB on comms-db ran ~12h on
# 2026-09-25 and would every day. Chunked model instead, matching the
# rotation's soft deadline: schema + tables <= BIG_TABLE_BYTES go as a
# normal -Fc pair, and each oversized table is COPY'd in CHUNK_SECONDS
# windows over its timestamp column. A bookmark per (container,db,table)
# in CHUNK_STATE_DIR resumes where the last run stopped — half now, half
# later. Once caught up only new rows dump; the CHUNK_LAG_SECONDS buffer
# lets rollovers (livlog moves 6h-old rows logs -> logs_warm) settle first.
# .copy files are plain COPY text — restore with COPY tbl FROM STDIN.
BIG_DB_BYTES=${BIG_DB_BYTES:-8589934592}        # 8 GiB
BIG_TABLE_BYTES=${BIG_TABLE_BYTES:-4294967296}  # 4 GiB
CHUNK_SECONDS=${CHUNK_SECONDS:-10800}           # 3h windows
CHUNK_LAG_SECONDS=${CHUNK_LAG_SECONDS:-86400}   # 24h settle window
MAX_CHUNKS_PER_RUN=${MAX_CHUNKS_PER_RUN:-4}
CHUNK_STATE_DIR=${CHUNK_STATE_DIR:-${STATE_DIR:-$HOME/backups/db}/chunks}
mkdir -p "$CHUNK_STATE_DIR"

psqlq(){ docker exec "$1" psql -U "$2" -d "$3" -Atc "$4" 2>/dev/null; }

# dump_chunked_table <container> <db> <pguser> <table>
dump_chunked_table(){
  local cname=$1 db=$2 puser=$3 tbl=$4
  local col bk start end_iso horizon label has n=0
  col=$(psqlq "$cname" "$puser" "$db" \
    "SELECT column_name FROM information_schema.columns
      WHERE table_schema='public' AND table_name='$tbl'
        AND data_type LIKE 'timestamp%'
        AND column_name IN ('received_at','event_time','created_at')
      ORDER BY CASE column_name WHEN 'received_at' THEN 0
                                WHEN 'event_time'  THEN 1 ELSE 2 END LIMIT 1")
  if [ -z "$col" ]; then
    log "$cname: $db.$tbl has no time column — whole-table dump"
    docker exec "$cname" pg_dump -U "$puser" -Fc --data-only -t "$tbl" "$db" 2>/dev/null \
      | ship "${cname}-${db}-${tbl}-${STAMP}.dump" \
      && manifest "$cname" postgres "$db.$tbl" ok \
      || { manifest "$cname" postgres "$db.$tbl" FAIL; fails=$((fails+1)); }
    return
  fi
  bk="$CHUNK_STATE_DIR/${cname}__${db}__${tbl}.bookmark"
  start=$(cat "$bk" 2>/dev/null || true)
  if [ -z "$start" ]; then
    start=$(psqlq "$cname" "$puser" "$db" \
      "SELECT to_char(min($col),'YYYY-MM-DD HH24:MI:SS+00') FROM $tbl")
    if [ -z "$start" ]; then
      manifest "$cname" postgres "$db.$tbl" SKIP-empty; return
    fi
    # one-time NULL-time slice so COPY coverage is complete
    docker exec "$cname" psql -U "$puser" -d "$db" -c \
      "COPY (SELECT * FROM $tbl WHERE $col IS NULL) TO STDOUT" 2>/dev/null \
      | ship "${cname}-${db}-${tbl}-null-${STAMP}.copy" \
      && manifest "$cname" postgres "$db.$tbl[null]" ok \
      || { manifest "$cname" postgres "$db.$tbl[null]" FAIL; fails=$((fails+1)); }
  fi
  horizon=$(psqlq "$cname" "$puser" "$db" \
    "SELECT to_char(now()-interval '${CHUNK_LAG_SECONDS} seconds','YYYY-MM-DD HH24:MI:SS+00')")
  while :; do
    # ISO text compares chronologically — cheap string guards
    [ ! "$start" \< "$horizon" ] && break
    end_iso=$(psqlq "$cname" "$puser" "$db" \
      "SELECT to_char('$start'::timestamptz+interval '${CHUNK_SECONDS} seconds','YYYY-MM-DD HH24:MI:SS+00')")
    [ "$end_iso" \> "$horizon" ] && end_iso=$horizon
    has=$(psqlq "$cname" "$puser" "$db" \
      "SELECT 1 FROM $tbl WHERE $col >= '$start'::timestamptz AND $col < '$end_iso'::timestamptz LIMIT 1")
    if [ -z "$has" ]; then
      echo "$end_iso" > "$bk.tmp" && mv "$bk.tmp" "$bk"; start=$end_iso; continue
    fi
    label=$(date -d "$start" +%Y%m%dT%H 2>/dev/null || echo "$start" | tr ' :' '__')
    log "$cname: $db.$tbl chunk [$start -> $end_iso)"
    docker exec "$cname" psql -U "$puser" -d "$db" -c \
      "COPY (SELECT * FROM $tbl WHERE $col >= '$start'::timestamptz AND $col < '$end_iso'::timestamptz ORDER BY $col) TO STDOUT" 2>/dev/null \
      | ship "${cname}-${db}-${tbl}-${label}-${STAMP}.copy" \
      && manifest "$cname" postgres "$db.$tbl[$start..$end_iso)" ok \
      || { manifest "$cname" postgres "$db.$tbl[$start..$end_iso)" FAIL; fails=$((fails+1)); break; }
    echo "$end_iso" > "$bk.tmp" && mv "$bk.tmp" "$bk"
    start=$end_iso
    n=$((n+1))
    if [ "$n" -ge "$MAX_CHUNKS_PER_RUN" ]; then
      log "$cname: $db.$tbl chunk cap ($MAX_CHUNKS_PER_RUN) — resumes next run"
      break
    fi
    if [ -n "${SEROPS_DEADLINE:-}" ] && [ "$(date +%s)" -ge "$((SEROPS_DEADLINE-120))" ]; then
      log "$cname: $db.$tbl deadline hit after $n chunk(s) — resumes next run"
      break
    fi
  done
  [ "$n" -gt 0 ] && emit_event info "backup-dbs: $db.$tbl advanced $n chunk(s) to $start"
}

# dump_big_db <container> <db> <pguser>
dump_big_db(){
  local cname=$1 db=$2 puser=$3 t excl=""
  local big_tables
  big_tables=$(psqlq "$cname" "$puser" "$db" \
    "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relkind='r'
        AND pg_total_relation_size(c.oid) > ${BIG_TABLE_BYTES}
      ORDER BY pg_total_relation_size(c.oid)")
  log "$cname: $db oversized ($(psqlq "$cname" "$puser" "$db" \
    "SELECT pg_size_pretty(pg_database_size('$db'))")) — chunked tables: ${big_tables:-none}"
  docker exec "$cname" pg_dump -U "$puser" -Fc --schema-only "$db" 2>/dev/null \
    | ship "${cname}-${db}-schema-${STAMP}.dump" \
    && manifest "$cname" postgres "$db:schema" ok \
    || { manifest "$cname" postgres "$db:schema" FAIL; fails=$((fails+1)); }
  for t in $big_tables; do excl="$excl -T $t"; done
  docker exec "$cname" pg_dump -U "$puser" -Fc --data-only $excl "$db" 2>/dev/null \
    | ship "${cname}-${db}-smalltables-${STAMP}.dump" \
    && manifest "$cname" postgres "$db:small-tables" ok \
    || { manifest "$cname" postgres "$db:small-tables" FAIL; fails=$((fails+1)); }
  for t in $big_tables; do
    dump_chunked_table "$cname" "$db" "$puser" "$t"
  done
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
    "SELECT datname, pg_database_size(datname) FROM pg_database
      WHERE datistemplate=false ORDER BY pg_database_size(datname)" 2>/dev/null)
  if [ -z "$dbs" ]; then
    log "$name: psql unreachable — SKIP"
    manifest "$name" postgres - FAIL-unreachable; fails=$((fails+1)); continue
  fi

  docker exec "$name" pg_dumpall -g -U "$puser" 2>/dev/null \
    | ship "${name}-globals-${STAMP}.sql" \
    && manifest "$name" postgres globals ok \
    || { manifest "$name" postgres globals FAIL; fails=$((fails+1)); }

  # smallest first — cheap DBs always dump before the chunked giants
  for line in $dbs; do
    db=${line%%|*}; dbsz=${line##*|}
    log "$name: dumping $db"
    if [ "${dbsz:-0}" -gt "$BIG_DB_BYTES" ]; then
      dump_big_db "$name" "$db" "$puser"
    else
      docker exec "$name" pg_dump -U "$puser" -Fc "$db" 2>/dev/null \
        | ship "${name}-${db}-${STAMP}.dump" \
        && manifest "$name" postgres "$db" ok \
        || { manifest "$name" postgres "$db" FAIL; fails=$((fails+1)); }
    fi
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

  # smallest first, same as postgres
  dbs=$(docker exec "$name" mariadb -u root "-p$pw" -Nse \
    "SELECT table_schema, COALESCE(SUM(data_length+index_length),0)
       FROM information_schema.tables
      WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys')
      GROUP BY table_schema ORDER BY 2" 2>/dev/null | awk '{print $1}')
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
