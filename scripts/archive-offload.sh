#!/usr/bin/env bash
# Offload the xvdbz1 volume-archive to unit3, one directory per run.
#
# The archive dir holds already-exported docker volumes (greenbone,
# live-logger-db) parked on unit7's xvdbz1 disk — cold data sitting on the
# production box. Fleet rule: backups/replicas/archives live on unit3. Each
# run tars ONE not-yet-offloaded directory through a helper container (which
# sidesteps the root-owned files swoopg111 can't read), streams it to
# unit3:backups/volume-archive/unit7/<name>.tar.gz, verifies with gzip -t,
# then removes the local copy. A .done watermark tracks finished dirs, so the
# backlog drains over consecutive rotation ticks — and any dir that lands in
# the archive later gets offloaded on a future run without touching the rule.
#
# OFFLOAD_DELETE=0 keeps the local copy after a verified upload (additive
# mode — nothing freed, use for a trust-but-verify first pass).

set -uo pipefail

REPO="${REPO:-/home/swoopg111/projects/ser.ops}"
UNIT="${UNIT_NAME:-unit7}"
ARCHIVE_DIR="${ARCHIVE_DIR:-/home/swoopg111/mnt/xvdbz1/volume-archive}"
HELPER_IMAGE="${HELPER_IMAGE:-debian:bookworm-slim}"
BACKUP_HOST="${BACKUP_HOST:-unit3-tailscale}"
REMOTE_DIR="${REMOTE_DIR:-backups/volume-archive/$UNIT}"
STATE_DIR="${STATE_DIR:-$REPO/state}"
DONE_FILE="$STATE_DIR/archive-offload.done"
OFFLOAD_DELETE="${OFFLOAD_DELETE:-1}"
LOKEY_ENV="${LOKEY_ENV:-/home/swoopg111/projects/lokey/.env}"
LOCATOR_URL_DEFAULT="https://locator.theofficialblacksheepco.online"

TASK_NAME="${TASK_NAME:-archive-offload}"

mkdir -p "$STATE_DIR"

# Structured event stream. RUN_ID is inherited from rotate.sh when dispatched,
# so a task's events group with its own start/done; a manual out-of-band run
# gets its own RUN_ID. Falls back to a no-op if the lib is missing, so this
# script still works standalone.
# shellcheck source=../lib/event.sh
. "$REPO/lib/event.sh" 2>/dev/null || { event() { :; }; detail_kv() { printf '{}'; }; }

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

LOCK="$STATE_DIR/archive-offload.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
    log "another offload holds $LOCK — exiting"
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

[ -d "$ARCHIVE_DIR" ] || { log "no archive dir $ARCHIVE_DIR — nothing to do"; exit 0; }
touch "$DONE_FILE"

# First top-level directory not already marked done. Names are docker volume
# names — no spaces, fixed-string line match is safe.
target=""
for d in "$ARCHIVE_DIR"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    if ! grep -qxF "$name" "$DONE_FILE"; then
        target="$name"
        break
    fi
done

if [ -z "$target" ]; then
    log "archive backlog drained — nothing pending in $ARCHIVE_DIR"
    exit 0
fi

# Probe TWICE, ~20s apart. unit3 is a Mac mini that sleeps: a single failed
# probe proves nothing, and treating it as terminal is what stalled this drain
# until xvdbz1 hit 88%. A woken host usually answers the second probe.
probe_host() {
    ssh -o ConnectTimeout=8 -o BatchMode=yes "$BACKUP_HOST" \
        "mkdir -p '$REMOTE_DIR'" 2>/dev/null
}
if ! probe_host; then
    log "  $BACKUP_HOST did not answer — waking and retrying in 20s"
    event "$TASK_NAME" step "peer did not answer first probe, retrying" "" "" \
        "$(detail_kv host="$BACKUP_HOST")" 2>/dev/null || true
    sleep 20
    if ! probe_host; then
        log "WARN: $BACKUP_HOST unreachable — offload of $target deferred"
        event "$TASK_NAME" skip "peer unreachable (likely asleep) — deferring" "" "" \
            "$(detail_kv reason=peer_asleep host="$BACKUP_HOST" target="$target")" 2>/dev/null || true
        report "ser.ops-warn" "$UNIT: archive offload deferred — $BACKUP_HOST unreachable"
        # rc 75 = EX_TEMPFAIL: tells rotate.sh this was a deferral, not a
        # failure, so the task's interval is NOT consumed and it retries at the
        # next slot rather than waiting the full 120 minutes.
        exit 75
    fi
    log "  $BACKUP_HOST answered on retry — proceeding"
fi

remote_path="$REMOTE_DIR/${target}.tar.gz"
log "offloading $target -> $BACKUP_HOST:$remote_path"

# Same transport as backup_mount: read-only helper mount, tar.gz stream over
# ssh, remote .partial -> gzip -t -> rename. One retry for transient drops.
attempt_ok=0
for attempt in 1 2; do
    if docker run --rm -v "$ARCHIVE_DIR/$target:/data:ro" "$HELPER_IMAGE" \
           sh -c 'tar -czf - -C /data . 2>/dev/null || tar -czf - -C / data 2>/dev/null' \
       | ssh -o BatchMode=yes "$BACKUP_HOST" \
           "cat > '$remote_path.partial' && gzip -t '$remote_path.partial' && mv '$remote_path.partial' '$remote_path'"; then
        attempt_ok=1
        break
    fi
    log "  offload attempt $attempt failed for $target"
    event "$TASK_NAME" step "offload attempt $attempt failed" "" "" \
        "$(detail_kv target="$target" attempt="$attempt")"
done

if [ "$attempt_ok" -ne 1 ]; then
    MSG="$UNIT: archive offload FAILED for $target"
    log "$MSG"
    event "$TASK_NAME" fail "offload failed after 2 attempts" 1 "" \
        "$(detail_kv target="$target" host="$BACKUP_HOST")"
    report "ser.ops-warn" "$MSG"
    exit 1
fi

# Remote copy is verified (gzip -t passed before the rename) — record the
# artifact, which is the only evidence that actually counts.
event "$TASK_NAME" step "verified on remote" "" "" \
    "$(detail_kv target="$target" remote="$BACKUP_HOST:$remote_path" verified=gzip-t)"

if [ "$OFFLOAD_DELETE" = "1" ]; then
    # Parent dir is root-owned — the helper removes the entry too.
    if docker run --rm -v "$ARCHIVE_DIR:/arch" "$HELPER_IMAGE" \
        rm -rf "/arch/$target"; then
        log "  local copy removed: $target"
        event "$TASK_NAME" step "local copy removed" "" "" "$(detail_kv target="$target")"
    else
        log "  WARN: remote verified but local removal failed for $target"
        event "$TASK_NAME" step "remote verified but local removal FAILED" "" "" \
            "$(detail_kv target="$target" reason=local_rm_failed)"
    fi
fi

event "$TASK_NAME" done "offloaded $target" 0 "" \
    "$(detail_kv target="$target" host="$BACKUP_HOST" free_after="$(df -h "$ARCHIVE_DIR" 2>/dev/null | awk 'NR==2{print $4}')")"

echo "$target" >> "$DONE_FILE"
MSG="$UNIT: archive offload ok — $target -> $BACKUP_HOST:$remote_path (delete=$OFFLOAD_DELETE)"
log "$MSG"
report "ser.ops" "$MSG"
exit 0
