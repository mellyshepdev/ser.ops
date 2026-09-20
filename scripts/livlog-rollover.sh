#!/usr/bin/env bash
# ser.ops live-logger tiered rollover — batched replacement for the standalone
# ~/live-logger-db/rollover.sh cron job.
#
#   logs         (hot)  HOT_WINDOW of history — all the dashboard reads
#   logs_warm    (warm) full rows aged out of the buffer
#   logs_archive (cold) one compressed row per (unit, container, hour), ON UNIT3
#
# WHY THIS EXISTS
# ---------------
# The predecessor archived the ENTIRE backlog in a single unbatched statement:
# a full scan + sort + string_agg over the whole table, streamed to unit3 over
# a ~226ms link, on a 4-core box with no swap. It never once completed.
# logs_warm reached 45GB / 77.7M rows, each hourly tick held the lock for 6+
# hours while the next tick piled on, and on 2026-09-20 unit7 hit load 60 and
# stopped answering SSH. The archive on unit3 stopped advancing 2026-09-15.
#
# This fixes the SHAPE of the work, not the destination:
#   - Drains one WINDOW at a time (BATCH_HOURS), oldest first, looping until
#     the slot's soft deadline — so it uses the hour ser.ops gives it and no
#     more, rather than trying to do everything in one statement.
#   - Each window is split into SUBWINDOW_MIN slices, so a single string_agg
#     never materialises more than a few minutes of one container's logs.
#     logs_archive's unique key is (unit, container, hour_bucket) and its
#     upsert APPENDS payload, so slices of an hour merge into one archive row.
#   - Source rows are deleted only after the archive side reports a committed
#     INSERT for that exact window.
#
# SOFT DEADLINE: honours SEROPS_DEADLINE (epoch seconds, exported by
# deploy/tick.sh). A window already in flight is always finished — never
# interrupted mid-transfer — but a NEW window is not started past the
# deadline. Run standalone with no deadline set and it drains until caught up.
#
# Exit 75 (EX_TEMPFAIL) => "could not run, retry next slot"; rotate.sh does not
# consume the interval. Used when unit3 or comms-db is unreachable.

set -uo pipefail

REPO="${REPO:-/home/swoopg111/projects/ser.ops}"
STATE_DIR="${STATE_DIR:-$REPO/state}"
UNIT="${UNIT_NAME:-unit7}"

# The hot/warm tiers live in the comms-db container (pgvector/pgvector:pg16).
# NOT live-logger-db — that container has been stopped since 2026-09-19, which
# is also why export-archive.sh has been failing on every tick: the
# live_logger database moved and the tooling was never repointed.
CONTAINER="${CONTAINER:-comms-db}"
HOT_DB="${HOT_DB:-live_logger}"

# Cold archive on unit3 (fleet rule: archives live on unit3). Auth via ~/.pgpass.
ARCH_HOST="${ARCH_HOST:-100.78.95.13}"
ARCH_DB="${ARCH_DB:-live_logger_archive}"
ARCH_USER="${ARCH_USER:-live_logger_rw}"
PSQL_IMG="${PSQL_IMG:-postgres:16-alpine}"
PGPASS="${PGPASS:-$HOME/.pgpass}"

HOT_WINDOW="${HOT_WINDOW:-6 hours}"
ARCHIVE_AFTER="${ARCHIVE_AFTER:-3 days}"
BATCH_HOURS="${BATCH_HOURS:-6}"      # hour-buckets drained per window
SUBWINDOW_MIN="${SUBWINDOW_MIN:-10}"  # minutes per string_agg slice

LOG="${LOG:-$STATE_DIR/livlog-rollover.log}"
LOCK="${LOCK:-$STATE_DIR/livlog-rollover.lock}"

mkdir -p "$STATE_DIR"

# shellcheck source=../lib/event.sh
. "$REPO/lib/event.sh" 2>/dev/null || { event() { :; }; detail_kv() { printf '{}'; }; now_ms() { echo 0; }; }

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }

# One rollover at a time. A slow catch-up must not have the next slot stack a
# second heavyweight pass on top — that is precisely how the predecessor wedged.
exec 9>"$LOCK"
if ! flock -n 9; then
    log "another rollover holds the lock — exiting"
    event livlog skip "another rollover holds the lock" "" "" \
        "$(detail_kv reason=lock_held)"
    exit 0
fi

psql_hot() {
    docker exec -i "$CONTAINER" psql -U postgres -d "$HOT_DB" -v ON_ERROR_STOP=1 "$@"
}

# No psql client on the host — a throwaway container carries it, with ~/.pgpass
# mounted for the unit3 credentials.
psql_arch() {
    docker run --rm -i --network host -e PGPASSFILE=/.pgpass \
        -v "$PGPASS:/.pgpass:ro" "$PSQL_IMG" \
        psql -h "$ARCH_HOST" -U "$ARCH_USER" -d "$ARCH_DB" -v ON_ERROR_STOP=1 "$@"
}

defer() { log "DEFER: $*"; event livlog skip "deferred: $*" 75 "" "$(detail_kv reason=tempfail)"; exit 75; }
fail()  { log "FAIL: $*";  event livlog fail "$*" 1 "" "$(detail_kv)"; exit 1; }

# Soft deadline: true when a NEW window must not be started. Always returns
# false when no deadline is set, so a standalone run drains to completion.
past_deadline() {
    [ -n "${SEROPS_DEADLINE:-}" ] || return 1
    [ "$(date +%s)" -ge "$SEROPS_DEADLINE" ]
}

T0=$(now_ms)
log "rollover start (hot=$HOT_WINDOW archive=$ARCHIVE_AFTER batch=${BATCH_HOURS}h slice=${SUBWINDOW_MIN}m deadline=${SEROPS_DEADLINE:-none})"
event livlog start "rollover start" "" "" \
    "$(detail_kv hot="$HOT_WINDOW" batch_hours="$BATCH_HOURS" deadline="${SEROPS_DEADLINE:-none}")"

# --- Preflight ----------------------------------------------------------
# Both sides must be live BEFORE stage 1 moves anything. Stage 1 on its own
# grows logs_warm, which is the thing we are trying to drain.
docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true \
    || defer "container $CONTAINER not running"
psql_hot -tAc 'SELECT 1' >/dev/null 2>&1 \
    || defer "cannot query $HOT_DB on $CONTAINER"
[ -f "$PGPASS" ] || fail "missing $PGPASS — unit3 archive credentials"
psql_arch -tAc 'SELECT 1' >/dev/null 2>&1 \
    || defer "unit3 archive ($ARCH_HOST/$ARCH_DB) unreachable"

# --- Stage 1: hot -> warm ----------------------------------------------
# The dashboard only reads `logs`, so anything past the display window moves
# out wholesale. Single statement => a row is never in both tables and never
# in neither.
moved=$(psql_hot -tAc "
WITH moved AS (
    DELETE FROM logs
     WHERE received_at < now() - interval '${HOT_WINDOW}'
 RETURNING unit, container, message, level, tags, metadata, received_at
)
INSERT INTO logs_warm (unit, container, message, level, tags, metadata, received_at)
SELECT unit, container, message, level, tags, metadata, received_at FROM moved;
" 2>&1 | tail -1)
log "hot->warm: ${moved:-unknown}"
event livlog step "hot->warm ${moved:-unknown}" "" "" "$(detail_kv stage=hot_to_warm)"

# --- Stage 2: warm -> cold archive, window by window until the deadline --
CUT=$(psql_hot -tAc "SELECT (now() - interval '${ARCHIVE_AFTER}')::timestamptz" | tr -d '\r')
[ -n "$CUT" ] || fail "could not compute archive cutoff"

# Drain one bounded window. Returns 0 on success, 1 if nothing left to do.
drain_window() {
    local FLOOR WIN_END pending slices slice_start slice_end archived deleted

    # Oldest hour still pending. Empty => caught up.
    FLOOR=$(psql_hot -tAc "
    SELECT date_trunc('hour', min(received_at))::text
      FROM logs_warm WHERE received_at < timestamptz '${CUT}';" | tr -d '\r')
    [ -n "$FLOOR" ] || return 1

    WIN_END=$(psql_hot -tAc "
    SELECT LEAST(timestamptz '${FLOOR}' + interval '${BATCH_HOURS} hours',
                 timestamptz '${CUT}')::text;" | tr -d '\r')

    pending=$(psql_hot -tAc "
    SELECT count(*) FROM logs_warm
     WHERE received_at >= timestamptz '${FLOOR}'
       AND received_at <  timestamptz '${WIN_END}';" | tr -d '\r')

    # An empty window between real data: delete the gap so the floor advances
    # instead of the loop spinning on the same boundary forever.
    if [ "${pending:-0}" -eq 0 ]; then
        psql_hot -tAc "DELETE FROM logs_warm
         WHERE received_at >= timestamptz '${FLOOR}'
           AND received_at <  timestamptz '${WIN_END}';" >/dev/null 2>&1
        log "empty window [$FLOOR -> $WIN_END) skipped"
        return 0
    fi

    log "window [$FLOOR -> $WIN_END) holds ${pending} rows"

    psql_arch >/dev/null 2>&1 <<'SQL' || fail "could not prepare stage_archive on unit3"
DROP TABLE IF EXISTS stage_archive;
CREATE UNLOGGED TABLE stage_archive (
    unit TEXT, container TEXT, hour_bucket TIMESTAMPTZ,
    row_count INT, first_seen TIMESTAMPTZ, last_seen TIMESTAMPTZ, payload TEXT
);
SQL

    # Walk the window in SUBWINDOW_MIN slices, ascending. Peak memory is bounded
    # by the busiest container's traffic in SUBWINDOW_MIN minutes rather than by
    # the whole backlog. Ascending order matters: the upsert appends, so slices
    # must arrive oldest-first for the archived payload to stay chronological.
    slices=0
    slice_start="$FLOOR"
    while :; do
        slice_end=$(psql_hot -tAc "
        SELECT LEAST(timestamptz '${slice_start}' + interval '${SUBWINDOW_MIN} minutes',
                     timestamptz '${WIN_END}')::text;" | tr -d '\r')
        [ -n "$slice_end" ] || fail "could not compute slice end from $slice_start"

        psql_hot -c "\copy (
            SELECT unit,
                   container,
                   date_trunc('hour', received_at) AS hour_bucket,
                   count(*)                        AS row_count,
                   min(received_at)                AS first_seen,
                   max(received_at)                AS last_seen,
                   string_agg(
                       json_build_object(
                           't',  to_char(received_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MSZ'),
                           'l',  level,
                           'm',  message,
                           'tg', tags,
                           'md', metadata
                       )::text,
                       E'\n' ORDER BY received_at
                   ) AS payload
              FROM logs_warm
             WHERE received_at >= timestamptz '${slice_start}'
               AND received_at <  timestamptz '${slice_end}'
          GROUP BY unit, container, date_trunc('hour', received_at)
        ) TO STDOUT" \
        | psql_arch -c "\copy stage_archive (unit, container, hour_bucket, row_count, first_seen, last_seen, payload) FROM STDIN" \
            >/dev/null 2>&1 || fail "slice $slice_start -> $slice_end failed to stream"

        slices=$((slices + 1))
        slice_start="$slice_end"
        [ "$(psql_hot -tAc "SELECT timestamptz '${slice_start}' >= timestamptz '${WIN_END}';" | tr -d '\r')" = "t" ] && break
    done

    # Merge staging -> logs_archive. Appending payload on conflict is what lets
    # one hour arrive as several slices, and makes a retried window idempotent
    # at the hour level rather than duplicating whole buckets.
    archived=$(psql_arch -tAc "
    INSERT INTO logs_archive (unit, container, hour_bucket, row_count, first_seen, last_seen, payload)
    SELECT unit, container, hour_bucket, row_count, first_seen, last_seen, payload FROM stage_archive
        ON CONFLICT (unit, container, hour_bucket) DO UPDATE
        SET payload   = logs_archive.payload || E'\n' || EXCLUDED.payload,
            row_count = logs_archive.row_count + EXCLUDED.row_count,
            last_seen = GREATEST(logs_archive.last_seen, EXCLUDED.last_seen);
    " 2>&1 | tail -1)

    case "$archived" in
        INSERT*) : ;;
        *) fail "archive merge did not report an INSERT (got: ${archived:-empty}) — source rows NOT deleted" ;;
    esac

    # Only now is it safe to drop the source rows: the archive side has committed.
    deleted=$(psql_hot -tAc "
    DELETE FROM logs_warm
     WHERE received_at >= timestamptz '${FLOOR}'
       AND received_at <  timestamptz '${WIN_END}';" 2>&1 | tail -1)

    psql_arch -c "DROP TABLE IF EXISTS stage_archive;" >/dev/null 2>&1 || true

    log "archived [$FLOOR -> $WIN_END) ${pending} rows in $slices slices, merge=$archived, $deleted"
    event livlog step "archived $FLOOR -> $WIN_END (${pending} rows)" "" "" \
        "$(detail_kv floor="$FLOOR" win_end="$WIN_END" rows="$pending" slices="$slices")"
    return 0
}

windows=0
caught_up=0
while :; do
    # Soft deadline is checked BEFORE starting a window, never during one — a
    # transfer in flight always completes.
    if past_deadline; then
        log "slot deadline reached — stopping after $windows window(s), will resume next slot"
        break
    fi
    if ! drain_window; then
        caught_up=1
        log "nothing older than the cutoff — caught up"
        break
    fi
    windows=$((windows + 1))
done

remaining=$(psql_hot -tAc "
SELECT count(*) FROM logs_warm WHERE received_at < timestamptz '${CUT}';" 2>/dev/null | tr -d '\r')

DUR=$(( $(now_ms) - T0 ))
MSG="drained $windows window(s); backlog below cutoff: ${remaining:-unknown} rows"
log "$MSG"
event livlog done "$MSG" 0 "$DUR" \
    "$(detail_kv windows="$windows" remaining="${remaining:-unknown}" caught_up="$caught_up")"
