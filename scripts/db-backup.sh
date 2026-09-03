#!/bin/bash
# Compressed dumps of every database container on this unit, shipped to a
# remote host and pruned by age.
#
# Deliberately dumps rather than copying data directories: a file-level copy of
# a running database is not crash-consistent and often restores as corrupt.
#
# Failures report to the locator's event log. A backup that fails silently is
# worse than no backup, because you believe you are covered.

set -uo pipefail

BACKUP_HOST="${BACKUP_HOST:-unit9-mesh}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/db}"
KEEP_DAYS="${KEEP_DAYS:-30}"
LOCATOR_URL="${LOCATOR_URL:-https://locator.theofficialblacksheepco.online}"
UNIT="${UNIT_NAME:-$(hostname)}"
STAMP=$(date -u +%Y%m%d-%H%M%S)
STAGE=$(mktemp -d /tmp/dbbak.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT

ok=0; failed=0; details=""

report() {
    curl -s --max-time 10 -X POST -H 'Content-Type: application/json' \
        -d "{\"type\":\"$1\",\"message\":\"$2\",\"unit\":\"$UNIT\"}" \
        "$LOCATOR_URL/api/events" >/dev/null 2>&1
}

for c in $(docker ps --format '{{.Names}}'); do
    img=$(docker inspect "$c" --format '{{.Config.Image}}' 2>/dev/null)
    out="$STAGE/${UNIT}-${c}-${STAMP}.sql.gz"

    case "$img" in
        *postgres*|*pgvector*)
            user=$(docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' \
                   | sed -n 's/^POSTGRES_USER=//p' | head -1)
            user="${user:-postgres}"
            # --clean --if-exists so a restore overwrites cleanly instead of
            # erroring on objects that already exist.
            if docker exec "$c" pg_dumpall -U "$user" --clean --if-exists 2>/dev/null | gzip -9 > "$out" \
               && [ -s "$out" ]; then
                ok=$((ok+1))
            else
                failed=$((failed+1)); details="$details $c(pg)"; rm -f "$out"
            fi
            ;;
        *mariadb*|*mysql*)
            pw=$(docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' \
                 | sed -n -e 's/^MARIADB_ROOT_PASSWORD=//p' -e 's/^MYSQL_ROOT_PASSWORD=//p' | head -1)
            dump=mariadb-dump
            docker exec "$c" sh -c 'command -v mariadb-dump' >/dev/null 2>&1 || dump=mysqldump
            # --single-transaction keeps InnoDB consistent without locking writes.
            if docker exec -e MYSQL_PWD="$pw" "$c" "$dump" -uroot --all-databases \
                   --single-transaction --quick 2>/dev/null | gzip -9 > "$out" \
               && [ -s "$out" ]; then
                ok=$((ok+1))
            else
                failed=$((failed+1)); details="$details $c(mysql)"; rm -f "$out"
            fi
            ;;
    esac
done

if [ "$ok" -eq 0 ]; then
    report "db-backup-failed" "$UNIT: no databases dumped successfully ($details )"
    exit 1
fi

size=$(du -sh "$STAGE" | awk '{print $1}')

if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$BACKUP_HOST" "mkdir -p $BACKUP_DIR" 2>/dev/null; then
    report "db-backup-failed" "$UNIT: dumped $ok db(s) but backup host $BACKUP_HOST unreachable — copies exist ONLY on $UNIT"
    exit 1
fi

if scp -o ConnectTimeout=10 -o BatchMode=yes -q "$STAGE"/*.sql.gz "$BACKUP_HOST:$BACKUP_DIR/" 2>/dev/null; then
    ssh -o ConnectTimeout=10 -o BatchMode=yes "$BACKUP_HOST" \
        "find $BACKUP_DIR -name '${UNIT}-*.sql.gz' -mtime +$KEEP_DAYS -delete" 2>/dev/null
    msg="$UNIT: backed up $ok db(s), $size, to $BACKUP_HOST"
    [ "$failed" -gt 0 ] && msg="$msg (FAILED:$details)"
    report "db-backup" "$msg"
    echo "$msg"
else
    report "db-backup-failed" "$UNIT: dumped $ok db(s) but transfer to $BACKUP_HOST failed"
    exit 1
fi
