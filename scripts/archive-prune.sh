#!/bin/sh
# archive-prune — delete log-archive buckets older than PRUNE_DAYS (default 30).
#
# The live_logger archive on unit10 (locator-pg.live_logger_archive) is the
# searchable store, not cold storage — ser.ops2 owns bounding it so the disk
# doesn't grow without end. Files on unit3/5TB keep their own lifecycle; this
# only prunes the pg table. Same connection pattern as livlog-rollover.sh.
set -u
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
STATE_DIR="${STATE_DIR:-$REPO/state}"
. "$REPO/lib/event.sh" 2>/dev/null || { event() { :; }; detail_kv() { printf '{}'; }; }
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

ARCH_HOST="${ARCH_HOST:-100.124.192.55}"
ARCH_DB="${ARCH_DB:-live_logger_archive}"
ARCH_USER="${ARCH_USER:-live_logger_rw}"
PGPASS="${PGPASS:-$HOME/.pgpass}"
PSQL_IMG="${PSQL_IMG:-postgres:16-alpine}"
PRUNE_DAYS="${PRUNE_DAYS:-30}"

psql_arch() {
    docker run --rm -i --network host -e PGPASSFILE=/.pgpass \
        -v "$PGPASS:/.pgpass:ro" "$PSQL_IMG" \
        psql -h "$ARCH_HOST" -U "$ARCH_USER" -d "$ARCH_DB" -v ON_ERROR_STOP=1 "$@"
}

[ -f "$PGPASS" ] || { log "missing $PGPASS"; exit 1; }

out=$(psql_arch -tAc "DELETE FROM logs_archive WHERE hour_bucket < now() - interval '${PRUNE_DAYS} days';" 2>&1) \
    || { log "prune failed: $out"; event archive-prune fail "prune failed: $out" 1 "" "$(detail_kv)"; exit 1; }
log "logs_archive pruned (> ${PRUNE_DAYS}d): $out"
event archive-prune done "logs_archive pruned (> ${PRUNE_DAYS}d): $out" 0 "" "$(detail_kv days="$PRUNE_DAYS")"
