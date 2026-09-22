#!/usr/bin/env bash
# Per-container attached-volume backup into CockroachDB (ser.ops).
#
# Sibling of backup-volumes.sh — same sweep, same exclusions and shared-volume
# dedup, but the archive lands INSIDE the database instead of on unit3:
#
#   payload  -> `cockroach userfile` blob storage (puffbase-cockroach on unit7)
#   metadata -> volume_backups.backups (unit/container/source/dest/sha256/bytes)
#
# Why both stores: unit3's tarballs are the off-box safety net; the DB copy is
# queryable and lives on the DB server — the two losses that motivated it
# (unit8 2026-09-16, unit4 2026-09-17) were both "configs in git but the
# volumes gone" events.
#
# Size gate is strict and deliberate: mounts above MAX_MOUNT_MB stay on the
# unit3 tarball path and the pg_dump/mysqldump jobs — multi-GB blobs do not
# belong in userfile storage. Staging is bounded by that same cap: one tar
# file at a time on local disk, deleted after upload.
#
# Coverage differs from backup-volumes.sh: it sweeps remote units too (over
# ssh), because the units most likely to be rebuilt are exactly the ones whose
# volumes were never backed up. UNITS controls the list.

set -uo pipefail

REPO="${REPO:-/home/swoopg111/projects/ser.ops}"
HELPER_IMAGE="${HELPER_IMAGE:-debian:bookworm-slim}"
STATE_DIR="${STATE_DIR:-$REPO/state}"
EXCLUDE_FILE="${EXCLUDE_FILE:-$REPO/volume-backup-excludes.txt}"
MAX_MOUNT_MB="${MAX_MOUNT_MB:-2048}"
UNITS="${UNITS:-unit7 unit2}"
CR_CONTAINER="${CR_CONTAINER:-puffbase-cockroach}"
CR_USERFILE_BASE="${CR_USERFILE_BASE:-volume-backups}"
STAGE_DIR="${STAGE_DIR:-$STATE_DIR/voldb-tmp}"
LOKEY_ENV="${LOKEY_ENV:-/home/swoopg111/projects/lokey/.env}"
LOCATOR_URL_DEFAULT="https://locator.theofficialblacksheepco.online"
UNIT_SELF="${UNIT_NAME:-unit7}"

# Same idea as backup-volumes.sh — never capture the host, engine internals,
# or volatile noise.
EXCLUDE_PATTERNS=(
  '^/$'
  '^/var/log'
  '^/var/lib/docker/containers'
  '^/var/run/docker\.sock'
  '^/etc/(os-release|timezone|localtime)$'
  '^/proc|^/sys|^/dev'
)

mkdir -p "$STATE_DIR" "$STAGE_DIR"
STAMP=$(date -u +%Y%m%d)
TS=$(date -u +%H%M%S)

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

LOCK="$STATE_DIR/backup-volumes-db.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
    log "another DB volume backup holds $LOCK — exiting"
    exit 0
fi

load_env_file() {
    local f=$1 k v
    [ -f "$f" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|\#*) continue ;; esac
        k=${line%%=*}; v=${line#*=}
        v=${v%\"}; v=${v#\"}; v=${v%\'}
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
        -d "{\"type\":\"$kind\",\"message\":\"$msg\",\"unit\":\"$UNIT_SELF\"}" \
        "$url/api/events" >/dev/null 2>&1 || true
}

# docker on the target unit — local for our own box, ssh for the others.
run_docker() {
    local unit=$1; shift
    if [ "$unit" = "$UNIT_SELF" ]; then
        docker "$@"
    else
        # ssh joins argv with spaces and the REMOTE shell re-parses it, so an
        # arg like --format '{{range .Mounts}}{{.Type}}|{{.Source}}...' arrives
        # as unquoted pipes and the remote shell runs "{{.Source}}" as a
        # command — silently producing empty output. Single-quote each arg so
        # it survives the second parse.
        local arg q=""
        for arg in "$@"; do
            q+="'${arg//\'/\'\\\'\'}' "
        done
        ssh -o ConnectTimeout=10 -o BatchMode=yes "$unit" "docker ${q% }"
    fi
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

# SQL string literal — our inputs are container/volume/paths, but quote anyway.
sqlq() { printf "'%s'" "${1//\'/\'\'}"; }

record() {
    # unit container mtype src dest archive bytes sha256 status
    docker exec "$CR_CONTAINER" cockroach sql --insecure \
        -d volume_backups -e "INSERT INTO backups
            (unit, container, mount_type, source, destination, archive, bytes, sha256, status)
          VALUES ($(sqlq "$1"), $(sqlq "$2"), $(sqlq "$3"), $(sqlq "$4"),
                  $(sqlq "$5"), $(sqlq "$6"), ${7:-0}, $(sqlq "$8"), $(sqlq "$9"))" \
        >/dev/null 2>&1
}

mount_size_mb() {
    local unit=$1 src=$2 mb
    mb=$(run_docker "$unit" run --rm -v "$src:/data:ro" "$HELPER_IMAGE" \
             sh -c 'du -sm /data 2>/dev/null | cut -f1' 2>/dev/null | tr -d '[:space:]')
    echo "${mb:-0}"
}

backup_mount() {
    local unit=$1 cname=$2 src=$3 dest=$4 mtype=$5 vname=${6:-}
    local key out_name stage sha bytes mb uf_dest
    key=$(echo "${dest#/}" | tr '/ ' '__' | tr -cd '[:alnum:]_.-')
    [ "$mtype" = "volume" ] && key="vol-${vname:-$(basename "$src")}"
    key=$(echo "$key" | tr -cd '[:alnum:]_.-')
    out_name="${unit}__${cname}__${key}__${STAMP}-${TS}.tar.gz"
    uf_dest="$CR_USERFILE_BASE/$STAMP/$out_name"
    stage="$STAGE_DIR/$out_name"

    mb=$(mount_size_mb "$unit" "$src")
    if [ "${mb:-0}" -gt "$MAX_MOUNT_MB" ]; then
        log "  SKIP $unit $cname $dest — ${mb}MB > ${MAX_MOUNT_MB}MB cap (unit3 + db-dumps own it)"
        record "$unit" "$cname" "$mtype" "$src" "$dest" "-" 0 "-" "skip-oversize"
        return 0
    fi

    # Stream the tar from wherever the mount lives into one staged file, then
    # hand it to userfile. Staging is bounded by the size cap above.
    if [ "$unit" = "$UNIT_SELF" ]; then
        docker run --rm -v "$src:/data:ro" "$HELPER_IMAGE" \
            sh -c 'tar -czf - -C /data . 2>/dev/null || tar -czf - -C / data 2>/dev/null' \
            > "$stage" 2>/dev/null
    else
        ssh -o ConnectTimeout=10 -o BatchMode=yes "$unit" \
            "docker run --rm -v '$src:/data:ro' '$HELPER_IMAGE' \
               sh -c 'tar -czf - -C /data . 2>/dev/null || tar -czf - -C / data 2>/dev/null'" \
            > "$stage" 2>/dev/null
    fi

    if ! gzip -t "$stage" 2>/dev/null; then
        log "  FAIL(tar) $unit $cname $dest"
        record "$unit" "$cname" "$mtype" "$src" "$dest" "-" 0 "-" "FAIL-tar"
        rm -f "$stage"
        return 1
    fi

    sha=$(sha256sum "$stage" | cut -d' ' -f1)
    bytes=$(stat -c%s "$stage")

    # The file has to exist inside the cockroach container for `userfile
    # upload`; the container's /tmp is fine for a bounded copy.
    if docker cp "$stage" "$CR_CONTAINER:/tmp/vb-upload.tar.gz" \
       && docker exec "$CR_CONTAINER" sh -c \
            "cockroach userfile upload /tmp/vb-upload.tar.gz '$uf_dest' --insecure >/dev/null 2>&1 && rm -f /tmp/vb-upload.tar.gz"; then
        log "  ok  $unit $cname $dest -> crdb:$uf_dest (${bytes}B)"
        record "$unit" "$cname" "$mtype" "$src" "$dest" "$uf_dest" "$bytes" "$sha" "ok"
        rm -f "$stage"
        return 0
    fi
    docker exec "$CR_CONTAINER" rm -f /tmp/vb-upload.tar.gz 2>/dev/null || true
    log "  FAIL(upload) $unit $cname $dest"
    record "$unit" "$cname" "$mtype" "$src" "$dest" "-" 0 "-" "FAIL-upload"
    rm -f "$stage"
    return 1
}

total=0; ok=0; failed=0; skipped=0

for unit in $UNITS; do
    # Remote reachable? Skip the whole unit quietly if not — one bad unit must
    # not strand the rest of the sweep.
    if ! run_docker "$unit" ps -aq >/dev/null 2>&1; then
        log "unit $unit unreachable — skipping"
        continue
    fi
    declare -A SEEN=()
    for cid in $(run_docker "$unit" ps -aq); do
        cname=$(run_docker "$unit" inspect "$cid" --format '{{.Name}}' 2>/dev/null | tr -d '/')
        [ -n "$cname" ] || continue
        if [ -n "${ONLY_CONTAINERS:-}" ] && [[ " ${ONLY_CONTAINERS} " != *" $cname "* ]]; then
            continue
        fi
        mounts=$(run_docker "$unit" inspect "$cid" \
            --format '{{range .Mounts}}{{.Type}}|{{.Source}}|{{.Destination}}|{{.Name}}{{"\n"}}{{end}}' 2>/dev/null)
        [ -n "$mounts" ] && log "container $unit/$cname"
        while IFS='|' read -r mtype src dest vname; do
            [ -n "$src" ] || continue
            total=$((total+1))
            if excluded "$src"; then
                log "  skip $unit $cname $dest ($src — excluded)"
                skipped=$((skipped+1)); continue
            fi
            if [ "$mtype" = "volume" ]; then
                if [ -n "${SEEN[$vname]:-}" ]; then
                    log "  skip $unit $cname $dest — volume already archived via ${SEEN[$vname]}"
                    skipped=$((skipped+1)); continue
                fi
                SEEN[$vname]=$cname
            fi
            backup_mount "$unit" "$cname" "$src" "$dest" "$mtype" "$vname" \
                && ok=$((ok+1)) || failed=$((failed+1))
        done <<< "$mounts"
    done
done

log "done: ok=$ok failed=$failed skipped=$skipped of $total mounts"
report "backup-volumes-db" "ok=$ok failed=$failed skipped=$skipped of $total mounts ($UNITS)"
[ "$failed" -eq 0 ]
