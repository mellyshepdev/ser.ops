#!/usr/bin/env bash
# Report what is inside liv-log-pgdb-18.3 now that a login role exists.
# Read-only: selects and catalog queries only. Nothing is modified.
set -uo pipefail

C="liv-log-pgdb-18.3"
R="swoopg111"
# -d postgres matters: with no database specified libpq defaults to one named
# after the user, which does not exist here.
PSQL=(docker exec "$C" psql -U "$R" -d postgres)

say() { printf '\n=== %s ===\n' "$*"; }

say "connection"
if ! "${PSQL[@]}" -tAc "select current_user || ' @ ' || version()" 2>&1 | head -1; then
    echo "  cannot connect — paste this output"
    exit 1
fi

say "roles"
"${PSQL[@]}" -c "SELECT rolname, rolsuper, rolcanlogin FROM pg_roles WHERE rolcanlogin ORDER BY rolname" 2>&1

say "databases"
"${PSQL[@]}" -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size
                   FROM pg_database WHERE NOT datistemplate
                  ORDER BY pg_database_size(datname) DESC" 2>&1

DBS=$("${PSQL[@]}" -tAc "SELECT datname FROM pg_database
                          WHERE NOT datistemplate AND datallowconn
                            AND datname <> 'postgres'" 2>/dev/null)

for db in $DBS; do
    say "tables in $db"
    docker exec "$C" psql -U "$R" -d "$db" -c \
      "SELECT relname,
              to_char(n_live_tup,'FM999,999,999') AS approx_rows,
              pg_size_pretty(pg_total_relation_size(relid)) AS total
         FROM pg_stat_user_tables
        ORDER BY pg_total_relation_size(relid) DESC LIMIT 15" 2>&1

    # If it carries a logs table, get the real count and time span so it can be
    # compared against live-logger-db.
    if docker exec "$C" psql -U "$R" -d "$db" -tAc \
         "SELECT to_regclass('public.logs') IS NOT NULL" 2>/dev/null | grep -q t; then
        say "$db.logs — exact count and range"
        docker exec "$C" psql -U "$R" -d "$db" -c \
          "SELECT count(*) AS rows,
                  min(received_at) AS oldest,
                  max(received_at) AS newest
             FROM logs" 2>&1
        say "$db.logs — sample of 3 rows"
        docker exec "$C" psql -U "$R" -d "$db" -c \
          "SELECT id, unit, container, left(message, 60) AS message_head, received_at
             FROM logs ORDER BY received_at DESC LIMIT 3" 2>&1
    fi
done

say "compare: live-logger-db (the WORKING one)"
docker exec live-logger-db psql -U swoopg111 -d live_logger -c \
  "SELECT 'logs' AS tbl, count(*) AS rows, min(received_at) AS oldest, max(received_at) AS newest FROM logs
   UNION ALL
   SELECT 'logs_warm', count(*), min(received_at), max(received_at) FROM logs_warm" 2>&1

say "verdict inputs"
echo "Compare the row counts and time ranges above."
echo "  - overlapping range + fewer rows  => stalled migration, safe to retire"
echo "  - rows outside live-logger's range => unique data, keep and back it up"
echo
echo "Nothing has been deleted. Retire only after deciding:"
echo "  docker rm -f $C && docker volume rm liv-log-pgdb-183_liv-log-pgdb-18.3"
