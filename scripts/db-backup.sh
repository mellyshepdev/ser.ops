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

env_of() {
    docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null
}

# Credentials may be supplied either as a plain env var or, when the stack uses
# docker secrets, as *_PASSWORD_FILE naming a path inside the container. Reading
# only the env var silently produced an empty password and a skipped dump.
secret_of() {
    local c=$1 val="" file=""
    shift
    for k in "$@"; do
        val=$(env_of "$c" | sed -n "s/^${k}=//p" | head -1)
        [ -n "$val" ] && { printf '%s' "$val"; return 0; }
    done
    for k in "$@"; do
        file=$(env_of "$c" | sed -n "s/^${k}_FILE=//p" | head -1)
        if [ -n "$file" ]; then
            docker exec "$c" cat "$file" 2>/dev/null
            return 0
        fi
    done
    return 0
}

# Record why a dump failed instead of only that it did. The reason lands in the
# locator event, so a recurring failure is diagnosable without shell access.
note_failure() {
    local c=$1 kind=$2 errfile=$3
    local why
    why=$(tail -1 "$errfile" 2>/dev/null | tr -d '\r' | cut -c1-120)
    failed=$((failed+1))
    details="$details $c($kind${why:+: $why})"
}

for c in $(docker ps --format '{{.Names}}'); do
    img=$(docker inspect "$c" --format '{{.Config.Image}}' 2>/dev/null)
    out="$STAGE/${UNIT}-${c}-${STAMP}.sql.gz"
    err="$STAGE/${c}.err"

    # Proxies and routers match the image globs below but hold no data, so a
    # dump attempt can only ever fail. Skipping them keeps real failures
    # visible instead of drowning them in noise that can never be fixed.
    case "$img" in
        *maxscale*|*proxysql*|*pgbouncer*|*pgpool*|*haproxy*) continue ;;
    esac

    case "$img" in
        *postgres*|*pgvector*)
            user=$(env_of "$c" | sed -n 's/^POSTGRES_USER=//p' | head -1)
            user="${user:-postgres}"
            pw=$(secret_of "$c" POSTGRES_PASSWORD)
            # --clean --if-exists so a restore overwrites cleanly instead of
            # erroring on objects that already exist.
            if docker exec -e PGPASSWORD="$pw" "$c" \
                   pg_dumpall -U "$user" --clean --if-exists 2>"$err" | gzip -9 > "$out" \
               && gzip -t "$out" 2>>"$err"; then
                ok=$((ok+1))
            else
                note_failure "$c" pg "$err"; rm -f "$out"
            fi
            ;;
        *mariadb*|*mysql*)
            pw=$(secret_of "$c" MARIADB_ROOT_PASSWORD MYSQL_ROOT_PASSWORD)
            dump=mariadb-dump
            docker exec "$c" sh -c 'command -v mariadb-dump' >/dev/null 2>&1 || dump=mysqldump
            # --single-transaction keeps InnoDB consistent without locking writes.
            if docker exec -e MYSQL_PWD="$pw" "$c" "$dump" -uroot --all-databases \
                   --single-transaction --quick 2>"$err" | gzip -9 > "$out" \
               && gzip -t "$out" 2>>"$err"; then
                ok=$((ok+1))
            else
                note_failure "$c" mysql "$err"; rm -f "$out"
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
    # A partial backup is a failed backup. Reporting it as a success event and
    # exiting 0 is how the pdns replica went unbacked-up for weeks without
    # anything raising its voice.
    if [ "$failed" -gt 0 ]; then
        report "db-backup-failed" "$msg (FAILED:$details)"
        echo "$msg (FAILED:$details)" >&2
        exit 1
    fi
    report "db-backup" "$msg"
    echo "$msg"
else
    report "db-backup-failed" "$UNIT: dumped $ok db(s) but transfer to $BACKUP_HOST failed"
    exit 1
fi
