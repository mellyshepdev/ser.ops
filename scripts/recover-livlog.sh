#!/usr/bin/env bash
# Recover liv-log-pgdb-18.3 — the cluster has no login role because Postgres
# skipped initdb on a pre-populated volume, so POSTGRES_USER was never created.
#
# Single-user mode bypasses authentication entirely (it sidesteps the role
# lookup, which is why `trust` in pg_hba does not help here). We create a
# superuser, restart the container normally, then report what is inside.
#
# Read-only after the CREATE ROLE. Nothing is dropped or overwritten.
#
# Usage:  ./recover-livlog.sh
set -uo pipefail

CONTAINER="liv-log-pgdb-18.3"
VOLUME="liv-log-pgdb-183_liv-log-pgdb-18.3"
IMAGE="postgres:18.3"
PGDATA_IN="/var/lib/postgresql/data/pgdata"
ROLE="swoopg111"

say() { printf '\n=== %s ===\n' "$*"; }

say "1. current state"
state=$(docker inspect "$CONTAINER" --format '{{.State.Status}}' 2>/dev/null) || {
    echo "container $CONTAINER not found"; exit 1; }
echo "  $CONTAINER is: $state"

if [ "$state" = "running" ]; then
    echo "  stopping it (single-user mode needs an exclusive lock on the data dir)"
    docker stop "$CONTAINER" >/dev/null || { echo "  stop failed"; exit 1; }
    echo "  stopped"
fi

say "2. confirm the volume exists"
docker volume inspect "$VOLUME" --format '  {{.Name}}  ->  {{.Mountpoint}}' 2>/dev/null || {
    echo "  volume $VOLUME not found — check: docker volume ls | grep liv-log"; exit 1; }

say "3. create a superuser via single-user mode"
# --entrypoint postgres is essential: the image's docker-entrypoint.sh would
# otherwise intercept, check its own default PGDATA (/var/lib/postgresql/data),
# find no PG_VERSION there because the real cluster is in the pgdata subdir,
# and abort with "Database is uninitialized". We want the server binary
# directly, with no init logic in front of it.
#
# --user postgres because the server refuses to run as root, and bypassing the
# entrypoint also bypasses its usual gosu drop.
#
# The trailing argument is the database to open. A partially-restored cluster
# may lack `postgres`, so fall back to template1, which always exists.
recovered=0
for db in postgres template1; do
    echo "  trying single-user mode against '$db'..."
    out=$(printf 'CREATE ROLE %s SUPERUSER LOGIN;\n' "$ROLE" \
          | docker run --rm -i --user postgres \
              -e PGDATA="$PGDATA_IN" \
              --entrypoint postgres \
              -v "$VOLUME":/var/lib/postgresql/data \
              "$IMAGE" --single -D "$PGDATA_IN" "$db" 2>&1)
    echo "$out" | tail -12 | sed 's/^/    /'

    if echo "$out" | grep -qiE "already exists"; then
        echo "  role $ROLE already exists — continuing"
        recovered=1; break
    fi
    if ! echo "$out" | grep -qiE "FATAL|PANIC|Error:|could not"; then
        echo "  CREATE ROLE succeeded against '$db'"
        recovered=1; break
    fi
    echo "  '$db' did not work, trying next"
done

if [ "$recovered" -ne 1 ]; then
    echo
    echo "  Single-user mode failed against both databases."
    echo "  Paste the output above — the next option is pg_resetwal or"
    echo "  reading the cluster with a throwaway container, and which one"
    echo "  depends on the exact error."
    docker start "$CONTAINER" >/dev/null 2>&1
    exit 1
fi

say "4. restart the container"
docker start "$CONTAINER" >/dev/null && echo "  started" || { echo "  start failed"; exit 1; }

echo "  waiting for it to accept connections..."
for i in $(seq 1 30); do
    if docker exec "$CONTAINER" pg_isready -U "$ROLE" -d postgres >/dev/null 2>&1; then
        echo "  ready after ${i}s"; break
    fi
    sleep 1
done

say "5. what is actually in there"
if ! docker exec "$CONTAINER" psql -U "$ROLE" -d postgres -tAc "select 1" >/dev/null 2>&1; then
    echo "  still cannot connect as $ROLE — paste the output above"
    exit 1
fi

echo "-- databases --"
docker exec "$CONTAINER" psql -U "$ROLE" -d postgres -c \
  "SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size
     FROM pg_database WHERE NOT datistemplate ORDER BY pg_database_size(datname) DESC" 2>/dev/null

for db in $(docker exec "$CONTAINER" psql -U "$ROLE" -tAc \
        "SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn" 2>/dev/null); do
    echo "-- tables in $db --"
    docker exec "$CONTAINER" psql -U "$ROLE" -d "$db" -c \
      "SELECT relname,
              to_char(n_live_tup, 'FM999,999,999') AS approx_rows,
              pg_size_pretty(pg_total_relation_size(relid)) AS size
         FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC LIMIT 10" 2>/dev/null
done

say "6. row range, to compare against live-logger-db"
docker exec "$CONTAINER" psql -U "$ROLE" -d postgres -tAc \
  "SELECT 'checked'" >/dev/null 2>&1
for db in $(docker exec "$CONTAINER" psql -U "$ROLE" -tAc \
        "SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn" 2>/dev/null); do
    docker exec "$CONTAINER" psql -U "$ROLE" -d "$db" -tAc \
      "SELECT '$db.logs: ' || count(*) || ' rows, ' ||
              coalesce(min(received_at)::text,'-') || ' .. ' ||
              coalesce(max(received_at)::text,'-') FROM logs" 2>/dev/null
done

say "done"
echo "Nothing was deleted. If this turns out to be a dead migration, retiring it is:"
echo "  docker rm -f $CONTAINER && docker volume rm $VOLUME"
echo "Do NOT run that until you have compared the contents above with live-logger-db."
