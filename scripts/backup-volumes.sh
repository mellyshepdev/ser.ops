#!/usr/bin/env bash
# Per-container attached-volume backup (ser.ops).
#
# For every container (running or stopped), every attached mount — named
# volume or bind — is tarred read-only through a throwaway helper container
# and streamed straight to the off-box archive host over ssh. Nothing stages
# on local disk unless the remote host is unreachable, in which case mounts
# under LOCAL_FALLBACK_MAX_MB land in BACKUP_DIR instead.
#
# Why: the unit8 loss (2026-09-16) proved configs-in-git is not enough —
# maildata, gitea, odoo, wazuh state etc. lived only in volumes. DB data
# dirs are also tarred here (crash-consistent); the pg_dump/mysqldump jobs
# stay the clean-restore path, this is the everything-else safety net.
#
# Exclusions: mounts that would capture the host itself or pure noise —
# see EXCLUDE_PATTERNS below; extend via EXCLUDE_FILE (one regex per line).

set -uo pipefail

REPO="${REPO:-/home/swoopg111/projects/ser.ops}"
HELPER_IMAGE="${HELPER_IMAGE:-debian:bookworm-slim}"
BACKUP_DIR="${BACKUP_DIR:-/home/swoopg111/backups/volumes}"
STATE_DIR="${STATE_DIR:-$REPO/state}"
EXCLUDE_FILE="${EXCLUDE_FILE:-$REPO/volume-backup-excludes.txt}"
KEEP_DAYS="${KEEP_DAYS:-30}"
KEEP_LOCAL_DAYS="${KEEP_LOCAL_DAYS:-7}"
LOCAL_FALLBACK_MAX_MB="${LOCAL_FALLBACK_MAX_MB:-4096}"
UNIT="${UNIT_NAME:-unit7}"
# Rotation knobs (see rotate.sh):
#   SHARD=i/n      — only containers whose name-hash mod n == i
#   MIN_MOUNT_MB   — skip mounts smaller than this (the "big" task)
#   MAX_MOUNT_MB   — skip mounts bigger than this (the "small" shards)
SHARD="${SHARD:-}"
MIN_MOUNT_MB="${MIN_MOUNT_MB:-0}"
MAX_MOUNT_MB="${MAX_MOUNT_MB:-0}"
si=""; sn=""
if [ -n "$SHARD" ]; then si=${SHARD%/*}; sn=${SHARD#*/}; fi
BACKUP_HOST="${BACKUP_HOST:-unit3-tailscale}"
REMOTE_DIR="${REMOTE_DIR:-backups/volumes/$UNIT}"
LOKEY_ENV="${LOKEY_ENV:-/home/swoopg111/projects/lokey/.env}"
LOCATOR_URL_DEFAULT="https://locator.theofficialblacksheepco.online"

# Source paths matching these are skipped — the backup must never capture
# the host itself, the docker engine's own internals, or volatile logs.
EXCLUDE_PATTERNS=(
  '^/$'                          # lokey's / -> /host would tar the whole box
  '^/var/log'                    # host logs (fluent-bit, wazuh-agent, crowdsec)
  '^/var/lib/docker/containers'  # engine container dirs/logs (NOT volumes/ —
                                 # named volume mountpoints live there by design)
  '^/var/run/docker\.sock'       # the socket is not data
  '^/etc/(os-release|timezone|localtime)$'
  '^/proc|^/sys|^/dev'
)

mkdir -p "$BACKUP_DIR" "$STATE_DIR"
STAMP=$(date -u +%Y%m%d)
TS=$(date -u +%H%M%S)

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

LOCK="$STATE_DIR/backup-volumes.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
    log "another volume backup holds $LOCK — exiting"
    exit 0
fi

load_env_file() {
    local f=$1 k v
    [ -f "$f" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|\#*) continue ;; esac
        k=${line%%=*}; v=${line#*=}
        v=${v%\"}; v=${v#\"}; v=${v%\'}; v=${v#\'}
        case "$k" in
            LOCATOR_URL|LOCATOR_HOST_HEADER|LOCATOR_ADMIN_KEY)
                printf -v "$k" '%s' "$v" ;;
        esac
    done < "$f"
}

report() {
    local kind=$1 msg=$2
    load_env_file "$LOKEY_ENV"
    local url="${LOCATOR_URL:-$LOCATOR_URL_DEFAULT}"
    local host="${LOCATOR_HOST_HEADER:-}"
    local key="${LOCATOR_ADMIN_KEY:-}"
    local hdr=(-H 'Content-Type: application/json')
    [ -n "$key" ]  && hdr+=(-H "X-Locator-Admin-Key: $key")
    [ -n "$host" ] && hdr+=(-H "Host: $host")
    curl -sS --max-time 10 -X POST "${hdr[@]}" \
        -d "{\"type\":\"$kind\",\"message\":\"$msg\",\"unit\":\"$UNIT\"}" \
        "$url/api/events" >/dev/null 2>&1 || true
}

excluded() {
    local src=$1 pat
    for pat in "${EXCLUDE_PATTERNS[@]}"; do
        [[ $src =~ $pat ]] && return 0
    done
    [ -f "$EXCLUDE_FILE" ] || return 1
    while IFS= read -r pat || [ -n "$pat" ]; do
        case "$pat" in ''|\#*) continue ;; esac
        [[ $src =~ $pat ]] && return 0
    done < "$EXCLUDE_FILE"
    return 1
}

# Remote reachable? Probed once — controls stream-vs-local-fallback for the run.
REMOTE_OK=0
if ssh -o ConnectTimeout=8 -o BatchMode=yes "$BACKUP_HOST" \
     "mkdir -p '$REMOTE_DIR/$STAMP'" 2>/dev/null; then
    REMOTE_OK=1
else
    log "WARN: $BACKUP_HOST unreachable — local fallback for mounts <= ${LOCAL_FALLBACK_MAX_MB}MB"
fi

backup_mount() {
    # $1 container, $2 source (mountpoint or host path), $3 dest, $4 type,
    # $5 volume name (type=volume only — mountpoints all end in /_data and
    # are useless for naming/dedup).
    local cname=$1 src=$2 dest=$3 mtype=$4 vname=${5:-}
    local key out_name remote_path size_mb
    key=$(echo "${dest#/}" | tr '/ ' '__' | tr -cd '[:alnum:]_.-')
    [ "$mtype" = "volume" ] && key="vol-${vname:-$(basename "$src")}"
    key=$(echo "$key" | tr -cd '[:alnum:]_.-')
    out_name="${cname}__${key}__${STAMP}-${TS}.tar.gz"

    if [ "$REMOTE_OK" -eq 1 ]; then
        remote_path="$REMOTE_DIR/$STAMP/$out_name"
        # One retry — a transient tailscale/ssh drop mid-stream shouldn't lose
        # the mount's backup for a whole day.
        local attempt
        for attempt in 1 2; do
            if docker run --rm -v "$src:/data:ro" "$HELPER_IMAGE" \
                   sh -c 'tar -czf - -C /data . 2>/dev/null || tar -czf - -C / data 2>/dev/null' \
               | ssh -o BatchMode=yes "$BACKUP_HOST" \
                   "cat > '$remote_path.partial' && gzip -t '$remote_path.partial' && mv '$remote_path.partial' '$remote_path'"; then
                log "  ok  $cname $dest -> $BACKUP_HOST:$remote_path"
                manifest "$cname" "$mtype" "$src" "$dest" "$out_name" "ok-remote"
                return 0
            fi
            log "  FAIL(remote) $cname $dest (attempt $attempt)"
        done
        manifest "$cname" "$mtype" "$src" "$dest" "$out_name" "FAIL-remote"
        return 1
    fi

    # Local fallback: only for small mounts — the 46G DBs would eat the disk.
    size_mb=$(docker run --rm -v "$src:/data:ro" "$HELPER_IMAGE" \
                  sh -c 'du -sm /data 2>/dev/null | cut -f1' | tr -d '[:space:]')
    size_mb=${size_mb:-0}
    if [ "${size_mb:-0}" -gt "$LOCAL_FALLBACK_MAX_MB" ]; then
        log "  SKIP $cname $dest — ${size_mb}MB > local fallback cap, remote down"
        manifest "$cname" "$mtype" "$src" "$dest" "$out_name" "SKIP-oversize-no-remote"
        return 1
    fi
    mkdir -p "$BACKUP_DIR/$STAMP"
    if docker run --rm -v "$src:/data:ro" -v "$BACKUP_DIR/$STAMP:/out" "$HELPER_IMAGE" \
           sh -c "tar -czf '/out/$out_name.partial' -C /data . 2>/dev/null || tar -czf '/out/$out_name.partial' -C / data 2>/dev/null" \
       && gzip -t "$BACKUP_DIR/$STAMP/$out_name.partial"; then
        mv "$BACKUP_DIR/$STAMP/$out_name.partial" "$BACKUP_DIR/$STAMP/$out_name"
        log "  ok(local) $cname $dest -> $BACKUP_DIR/$STAMP/$out_name"
        manifest "$cname" "$mtype" "$src" "$dest" "$out_name" "ok-local"
        return 0
    fi
    rm -f "$BACKUP_DIR/$STAMP/$out_name.partial"
    log "  FAIL(local) $cname $dest"
    manifest "$cname" "$mtype" "$src" "$dest" "$out_name" "FAIL-local"
    return 1
}

# Mount sizes cached 12h — a full du of a 46G pgdata every rotation tick is
# wasted I/O on a live DB disk. Cache only consulted when a size gate is set.
SIZE_CACHE="$STATE_DIR/volume-sizes.cache"
SIZE_CACHE_MAX_AGE=$((12*3600))
mount_size_mb() {
    local src=$1 mb ts now
    now=$(date +%s)
    if [ -f "$SIZE_CACHE" ]; then
        read -r mb ts < <(awk -F'|' -v s="$src" '$1==s{m=$2;t=$3} END{if(m)print m,t}' "$SIZE_CACHE")
        if [ -n "${mb:-}" ] && [ $((now - ${ts:-0})) -lt "$SIZE_CACHE_MAX_AGE" ]; then
            echo "$mb"; return
        fi
    fi
    mb=$(docker run --rm -v "$src:/data:ro" "$HELPER_IMAGE" \
             sh -c 'du -sm /data 2>/dev/null | cut -f1' | tr -d '[:space:]')
    mb=${mb:-0}
    [ -f "$SIZE_CACHE" ] && grep -vF "$src|" "$SIZE_CACHE" > "$SIZE_CACHE.tmp" || true
    echo "$src|$mb|$now" >> "$SIZE_CACHE.tmp" 2>/dev/null || echo "$src|$mb|$now" > "$SIZE_CACHE.tmp"
    mv -f "$SIZE_CACHE.tmp" "$SIZE_CACHE"
    echo "$mb"
}

# Manifest: one line per attempted mount —
#   container | mount-type | source | destination | archive | status
# Restore without it is guesswork (the archive name hides the source path).
MANIFEST_DIR="$BACKUP_DIR/$STAMP"
MANIFEST="$MANIFEST_DIR/manifest-$STAMP-$TS.txt"
mkdir -p "$MANIFEST_DIR"

manifest() { printf '%s|%s|%s|%s|%s|%s\n' "$@" >> "$MANIFEST"; }

log "volume backup start (remote=$([ $REMOTE_OK -eq 1 ] && echo "$BACKUP_HOST:$REMOTE_DIR/$STAMP" || echo local-fallback))"

total=0; ok=0; failed=0; skipped=0
declare -A SEEN=()

# ONLY_CONTAINERS="a b c" limits the sweep — used for tests and for pulling
# a single service's state on demand.
for cid in $(docker ps -aq); do
    cname=$(docker inspect "$cid" --format '{{.Name}}' 2>/dev/null | tr -d '/')
    [ -n "$cname" ] || continue
    if [ -n "${ONLY_CONTAINERS:-}" ] && [[ " ${ONLY_CONTAINERS} " != *" $cname "* ]]; then
        continue
    fi
    if [ -n "$SHARD" ]; then
        h=$(printf '%s' "$cname" | cksum | cut -d' ' -f1)
        [ $((h % sn)) -eq "$si" ] || continue
    fi
    mounts=$(docker inspect "$cid" --format '{{range .Mounts}}{{.Type}}|{{.Source}}|{{.Destination}}|{{.Name}}{{"\n"}}{{end}}' 2>/dev/null)
    [ -n "$mounts" ] && log "container $cname"
    while IFS='|' read -r mtype src dest vname; do
        [ -n "$src" ] || continue
        if excluded "$src"; then
            log "  skip $cname $dest ($src — excluded)"
            manifest "$cname" "$mtype" "$src" "$dest" "-" "skip-excluded"
            skipped=$((skipped+1)); continue
        fi
        # Same volume attached to several containers → back it up once.
        if [ "$mtype" = "volume" ]; then
            if [ -n "${SEEN[$vname]:-}" ]; then
                log "  skip $cname $dest — volume already archived via ${SEEN[$vname]}"
                manifest "$cname" "$mtype" "$src" "$dest" "-" "skip-shared-via-${SEEN[$vname]}"
                skipped=$((skipped+1)); continue
            fi
            SEEN[$vname]=$cname
        fi
        # Size gates — rotation splits mounts into "small" shards (frequent)
        # and a "big" task (infrequent) so whales don't drag every tick.
        if [ "$MIN_MOUNT_MB" -gt 0 ] || [ "$MAX_MOUNT_MB" -gt 0 ]; then
            size_mb=$(mount_size_mb "$src")
            if [ "$MIN_MOUNT_MB" -gt 0 ] && [ "$size_mb" -lt "$MIN_MOUNT_MB" ]; then
                manifest "$cname" "$mtype" "$src" "$dest" "-" "skip-under-${MIN_MOUNT_MB}MB"
                skipped=$((skipped+1)); continue
            fi
            if [ "$MAX_MOUNT_MB" -gt 0 ] && [ "$size_mb" -gt "$MAX_MOUNT_MB" ]; then
                manifest "$cname" "$mtype" "$src" "$dest" "-" "skip-over-${MAX_MOUNT_MB}MB"
                skipped=$((skipped+1)); continue
            fi
        fi
        total=$((total+1))
        backup_mount "$cname" "$src" "$dest" "$mtype" "$vname" && ok=$((ok+1)) || failed=$((failed+1))
    done <<< "$mounts"
done

# Named volumes not attached to any container still hold data — catch orphans.
# Skipped under ONLY_CONTAINERS (a filtered run shouldn't re-label other
# containers' volumes as orphans); under sharding only the LAST shard runs
# the orphan pass so they land once per rotation, not once per shard.
ORPHAN_PASS=1
if [ -n "${ONLY_CONTAINERS:-}" ]; then ORPHAN_PASS=0; fi
if [ -n "$SHARD" ] && [ "$si" -ne $((sn - 1)) ]; then ORPHAN_PASS=0; fi
if [ "$ORPHAN_PASS" -eq 1 ]; then
for vol in $(docker volume ls -q); do
    [ -n "${SEEN[$vol]:-}" ] && continue
    src=$(docker volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null)
    [ -n "$src" ] || continue
    if [ "$MIN_MOUNT_MB" -gt 0 ] || [ "$MAX_MOUNT_MB" -gt 0 ]; then
        size_mb=$(mount_size_mb "$src")
        { [ "$MIN_MOUNT_MB" -gt 0 ] && [ "$size_mb" -lt "$MIN_MOUNT_MB" ]; } && continue
        { [ "$MAX_MOUNT_MB" -gt 0 ] && [ "$size_mb" -gt "$MAX_MOUNT_MB" ]; } && continue
    fi
    total=$((total+1))
    backup_mount "_unattached" "$src" "$vol" "volume" "$vol" && ok=$((ok+1)) || failed=$((failed+1))
done
fi

# Ship the manifest next to the archives — it's the restore index.
if [ "$REMOTE_OK" -eq 1 ] && [ -f "$MANIFEST" ]; then
    scp -o BatchMode=yes -q "$MANIFEST" \
        "$BACKUP_HOST:$REMOTE_DIR/$STAMP/" 2>/dev/null || \
        log "WARN: manifest copy failed"
fi

# Retention: thin local staging + remote sets older than KEEP_DAYS.
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$KEEP_LOCAL_DAYS" -exec rm -rf {} + 2>/dev/null || true
if [ "$REMOTE_OK" -eq 1 ]; then
    ssh -o BatchMode=yes "$BACKUP_HOST" \
        "find '$REMOTE_DIR' -mindepth 1 -maxdepth 1 -type d -mtime +$KEEP_DAYS -exec rm -rf {} +" 2>/dev/null || true
fi

MSG="$UNIT: volume backup $STAMP — $ok/$total archived, $failed failed, $skipped skipped, remote=$REMOTE_OK"
log "$MSG"
if [ "$failed" -gt 0 ]; then
    report "ser.ops-warn" "$MSG"
else
    report "ser.ops" "$MSG"
fi
[ "$failed" -eq 0 ] || exit 1
exit 0
