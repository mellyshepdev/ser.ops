#!/usr/bin/env bash
# Incremental logs_archive export (BLA-30) with locator event reporting.
#
# Runs pg_lzma_export against live-logger-db over the docker network, writes
# .xz under BACKUP_DIR, advances a local watermark only after xz -t succeeds,
# and posts success/failure to locator /api/events (X-Locator-Admin-Key).
#
# Remote ship to unit9 is attempted when BACKUP_HOST is reachable; otherwise
# the file stays local and the locator event says so — silent "success" with
# no off-box copy is how dumps went missing before.

set -euo pipefail

REPO="${REPO:-/home/swoopg111/projects/ser.ops}"
BIN="${BIN:-$REPO/pg_lzma_export}"
IMAGE="${IMAGE:-ser.ops-export:latest}"
NETWORK="${NETWORK:-live-logger-db_default}"
CONTAINER_DB="${CONTAINER_DB:-live-logger-db}"
DB="${DB:-live_logger_archive}"
TABLE="${TABLE:-logs_archive}"
COLUMN="${COLUMN:-hour_bucket}"
PRESET="${PRESET:-6}"
BACKUP_DIR="${BACKUP_DIR:-/home/swoopg111/backups/ser.ops}"
STATE_DIR="${STATE_DIR:-$REPO/state}"
WATERMARK="$STATE_DIR/${TABLE}.watermark"
KEEP_DAYS="${KEEP_DAYS:-30}"
UNIT="${UNIT_NAME:-unit7}"
# unit3 (Mac mini, ~770G free) is the off-box archive target, reached over
# Tailscale as the unit3-tailscale ssh alias. unit9-mesh remains available
# as a BACKUP_HOST override if unit3 drops off the tailnet.
BACKUP_HOST="${BACKUP_HOST:-unit3-tailscale}"
REMOTE_DIR="${REMOTE_DIR:-backups/ser.ops}"
LOKEY_ENV="${LOKEY_ENV:-/home/swoopg111/projects/lokey/.env}"
LOCATOR_URL_DEFAULT="https://locator.theofficialblacksheepco.online"

mkdir -p "$BACKUP_DIR" "$STATE_DIR"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# One export at a time — overlapping full dumps hammer the DB and waste disk.
LOCK="$STATE_DIR/export.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
    log "another export holds $LOCK — exiting"
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
                printf -v "$k" '%s' "$v"
                ;;
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

fail() {
    log "FAIL: $*"
    report "ser.ops-failed" "$UNIT: $*"
    exit 1
}

[ -x "$BIN" ] || fail "missing binary $BIN — build with: docker run --rm -v $REPO:/src -w /src debian:bookworm-slim bash -c 'apt-get update && apt-get install -y gcc make libpq-dev liblzma-dev && make'"

docker inspect "$CONTAINER_DB" >/dev/null 2>&1 \
    || fail "database container $CONTAINER_DB not running"

# Runtime image avoids apt-get on every tick.
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    log "building runtime image $IMAGE"
    docker build -f "$REPO/Dockerfile.runtime" -t "$IMAGE" "$REPO" \
        || fail "docker build of $IMAGE failed"
fi

# Credentials go in a 0600 env-file so they never appear in `ps` via docker -e.
ENV_FILE=$(mktemp "$STATE_DIR/pg.env.XXXXXX")
chmod 600 "$ENV_FILE"
cleanup_env() { rm -f "$ENV_FILE"; }
trap cleanup_env EXIT

{
    echo "PGHOST=$CONTAINER_DB"
    echo "PGPORT=5432"
    echo "PGDATABASE=$DB"
    echo "PGUSER=postgres"
    docker inspect "$CONTAINER_DB" --format '{{range .Config.Env}}{{println .}}{{end}}' \
        | sed -n 's/^POSTGRES_PASSWORD=/PGPASSWORD=/p' | head -1
} > "$ENV_FILE"
grep -q '^PGPASSWORD=.\+' "$ENV_FILE" || fail "POSTGRES_PASSWORD empty on $CONTAINER_DB"

# Newest hour is mutable (rollover upserts). Seal floor = start of current UTC hour.
SEAL_BEFORE=$(date -u +'%Y-%m-%d %H:00:00+00')
SINCE=""
if [ -f "$WATERMARK" ]; then
    SINCE=$(tr -d '\n' < "$WATERMARK")
fi

STAMP=$(date -u +%Y%m%d-%H%M%S)
OUT_NAME="${UNIT}-${TABLE}-${STAMP}.xz"
OUT="$BACKUP_DIR/$OUT_NAME"
TMP="$OUT.partial"

ARGS=(--table "$TABLE" --column "$COLUMN" --preset "$PRESET" --out "/out/$OUT_NAME.partial")
if [ -n "$SINCE" ]; then
    ARGS+=(--since "$SINCE")
    log "incremental since='$SINCE' seal_before='$SEAL_BEFORE'"
else
    log "full export (no watermark) seal_before='$SEAL_BEFORE'"
fi

# Export as postgres over the DB network. Password via --env-file, never argv/`ps`.
set +e
docker run --rm --network "$NETWORK" \
    -v "$BACKUP_DIR:/out" \
    --env-file "$ENV_FILE" \
    --entrypoint /usr/local/bin/pg_lzma_export \
    "$IMAGE" "${ARGS[@]}"
rc=$?
set -e
cleanup_env
trap - EXIT

[ "$rc" -eq 0 ] || fail "pg_lzma_export exited $rc"
[ -f "$TMP" ] || fail "missing output $TMP"

xz -t "$TMP" 2>/dev/null || { rm -f "$TMP"; fail "xz integrity check failed for $OUT_NAME"; }
mv -f "$TMP" "$OUT"
# Container writes as root when docker is rootful — reclaim for the operator.
if [ "$(id -u)" -ne 0 ]; then
    docker run --rm -v "$BACKUP_DIR:/out" debian:bookworm-slim \
        chown "$(id -u):$(id -g)" "/out/$OUT_NAME" 2>/dev/null || true
fi
SIZE=$(stat -c%s "$OUT" 2>/dev/null || stat -f%z "$OUT")
HUMAN=$(numfmt --to=iec-i --suffix=B "$SIZE" 2>/dev/null || echo "${SIZE}B")

# Advance watermark to the newest sealed bucket (exclusive lower bound next run).
# Query via docker exec — no host-side psql required.
NEW_WM=$(docker exec "$CONTAINER_DB" \
    psql -U postgres -d "$DB" -Atc \
    "SELECT COALESCE(max($COLUMN)::text, '') FROM $TABLE WHERE $COLUMN < timestamptz '$SEAL_BEFORE';" \
    2>/dev/null | tr -d '\r')

if [ -n "$NEW_WM" ]; then
    printf '%s\n' "$NEW_WM" > "$WATERMARK.tmp"
    mv -f "$WATERMARK.tmp" "$WATERMARK"
    log "watermark -> $NEW_WM"
fi

# Prune local aged copies.
find "$BACKUP_DIR" -name "${UNIT}-${TABLE}-*.xz" -mtime +"$KEEP_DAYS" -delete 2>/dev/null || true

REMOTE_NOTE="local-only ($BACKUP_DIR)"
if ssh -o ConnectTimeout=8 -o BatchMode=yes "$BACKUP_HOST" "mkdir -p $REMOTE_DIR" 2>/dev/null \
   && scp -o ConnectTimeout=8 -o BatchMode=yes -q "$OUT" "$BACKUP_HOST:$REMOTE_DIR/"; then
    ssh -o ConnectTimeout=8 -o BatchMode=yes "$BACKUP_HOST" \
        "find $REMOTE_DIR -name '${UNIT}-${TABLE}-*.xz' -mtime +$KEEP_DAYS -delete" 2>/dev/null || true
    REMOTE_NOTE="shipped to $BACKUP_HOST:$REMOTE_DIR"
else
    REMOTE_NOTE="LOCAL ONLY — $BACKUP_HOST unreachable; file at $OUT"
fi

MSG="$UNIT: $TABLE export $HUMAN ($OUT_NAME), wm=${NEW_WM:-none}, $REMOTE_NOTE"
log "$MSG"
if [[ "$REMOTE_NOTE" == LOCAL\ ONLY* ]]; then
    report "ser.ops-warn" "$MSG"
else
    report "ser.ops" "$MSG"
fi
