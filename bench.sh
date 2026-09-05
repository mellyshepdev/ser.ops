#!/usr/bin/env bash
# Benchmark pg_lzma_export against the existing gzip pipeline on real data.
#
# The question this answers: is the C/LZMA path actually worth swapping in?
# Run it on the host holding the database. It writes into a temp dir and
# cleans up after itself.
#
#   ./bench.sh --container live-logger-db --db live_logger --table logs_archive
#
set -euo pipefail

CONTAINER="live-logger-db"
DB="live_logger_archive"
TABLE="logs_archive"
USER_="swoopg111"
BIN="./pg_lzma_export"

while [ $# -gt 0 ]; do
    case "$1" in
        --container) CONTAINER=$2; shift 2;;
        --db)        DB=$2;        shift 2;;
        --table)     TABLE=$2;     shift 2;;
        --user)      USER_=$2;     shift 2;;
        --bin)       BIN=$2;       shift 2;;
        *) echo "unknown arg: $1" >&2; exit 2;;
    esac
done

[ -x "$BIN" ] || { echo "build first: make" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

hr() { printf '%s\n' "------------------------------------------------------------"; }
size() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1"; }
human() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "$1 bytes"; }

echo "container=$CONTAINER db=$DB table=$TABLE"
hr

# --- baseline: what the current pipeline does -------------------------------
echo "baseline: COPY | gzip -9   (what db-backup.sh effectively does)"
t0=$(date +%s.%N)
docker exec "$CONTAINER" psql -U "$USER_" -d "$DB" \
    -c "COPY (SELECT * FROM $TABLE) TO STDOUT" 2>/dev/null \
    | gzip -9 > "$TMP/base.gz"
t1=$(date +%s.%N)
gz_size=$(size "$TMP/base.gz")
gz_time=$(echo "$t1 - $t0" | bc)
printf "  %-12s %12s  %6.1fs\n" "gzip -9" "$(human "$gz_size")" "$gz_time"

# raw size for ratio maths
raw=$(docker exec "$CONTAINER" psql -U "$USER_" -d "$DB" -tAc \
        "SELECT pg_total_relation_size('$TABLE')" 2>/dev/null || echo 0)

hr
echo "pg_lzma_export at each preset"
for p in 1 3 6 9; do
    t0=$(date +%s.%N)
    PGHOST=${PGHOST:-127.0.0.1} PGDATABASE="$DB" PGUSER="$USER_" \
        "$BIN" --table "$TABLE" --preset "$p" --out "$TMP/p$p.xz" --quiet
    t1=$(date +%s.%N)
    sz=$(size "$TMP/p$p.xz")
    tm=$(echo "$t1 - $t0" | bc)
    vs=$(echo "scale=2; $gz_size / $sz" | bc)
    printf "  preset %-5s %12s  %6.1fs   %sx vs gzip\n" "$p" "$(human "$sz")" "$tm" "$vs"
done

hr
echo "incremental: only the last 24h of buckets"
SINCE=$(date -u -d '24 hours ago' '+%Y-%m-%d %H:%M:%S+00' 2>/dev/null \
     || date -u -v-24H '+%Y-%m-%d %H:%M:%S+00')
PGHOST=${PGHOST:-127.0.0.1} PGDATABASE="$DB" PGUSER="$USER_" \
    "$BIN" --table "$TABLE" --since "$SINCE" --out "$TMP/inc.xz" --quiet
inc=$(size "$TMP/inc.xz")
printf "  since %s\n" "$SINCE"
printf "  %-12s %12s\n" "incremental" "$(human "$inc")"
printf "  full nightly gzip was %s\n" "$(human "$gz_size")"
if [ "$inc" -gt 0 ]; then
    printf "  => %sx less data per run\n" "$(echo "scale=1; $gz_size / $inc" | bc)"
fi

hr
echo "raw table size: $(human "${raw:-0}")"
echo
echo "Read the incremental number, not the preset numbers. Changing the"
echo "compressor is a small multiple; not sending unchanged rows is a large one."
