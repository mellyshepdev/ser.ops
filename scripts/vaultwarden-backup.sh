#!/usr/bin/env bash
# ==============================================================================
# vaultwarden db backup -> unit3
#
# pg_dump of the vaultwarden database in pgdb-18.3, shipped to unit3.
# The vault moved off embedded sqlite onto Postgres 2026-09-22 so it can be
# dumped crash-consistently; the sqlite volume remains as a rollback copy.
#
# Scoped to just this db rather than the fleet-wide db-backup.sh dumpall:
# unit3 is on a ~0.6MB/s hotspot uplink and a whole-instance pg_dumpall
# (odoo, inventory, crowdsec, openbao...) would take ages over it.
#
# Dumps rather than copying volumes: a file-level copy of a running database
# is not crash-consistent. Failures report to the locator event log — a
# backup that fails silently is worse than no backup.
# ==============================================================================
set -uo pipefail

LOCK=/tmp/vaultwarden-backup.lock
exec 9>"$LOCK"
flock -n 9 || { echo "vaultwarden-backup already running"; exit 0; }

BACKUP_HOST="${BACKUP_HOST:-unit3}"
BACKUP_DIR="${BACKUP_DIR:-backups/db}"
KEEP_DAYS="${KEEP_DAYS:-30}"
LOCATOR_URL="${LOCATOR_URL:-https://locator.theofficialblacksheepco.online}"
UNIT="${UNIT_NAME:-$(hostname)}"
STAMP=$(date -u +%Y%m%d-%H%M%S)
OUT="/tmp/${UNIT}-vaultwarden-${STAMP}.sql.gz"
trap 'rm -f "$OUT"' EXIT

report() {
    curl -s --max-time 10 -X POST -H 'Content-Type: application/json' \
        -d "{\"type\":\"$1\",\"message\":\"$2\",\"unit\":\"$UNIT\"}" \
        "$LOCATOR_URL/api/events" >/dev/null 2>&1
}

pgpw=$(docker inspect pgdb-18.3 --format '{{range .Config.Env}}{{println .}}{{end}}' \
       | sed -n 's/^POSTGRES_PASSWORD=//p' | head -1)

# --clean --if-exists so a restore overwrites cleanly instead of erroring on
# objects that already exist.
if ! docker exec -e PGPASSWORD="$pgpw" pgdb-18.3 \
        pg_dump -U postgres --clean --if-exists vaultwarden 2>/tmp/vw-dump.err \
        | gzip -9 > "$OUT" || ! gzip -t "$OUT" 2>/dev/null; then
    why=$(tail -1 /tmp/vw-dump.err 2>/dev/null | tr -d '\r' | cut -c1-120)
    report "db-backup-failed" "$UNIT: vaultwarden dump failed${why:+: $why}"
    exit 1
fi

size=$(du -sh "$OUT" | awk '{print $1}')

if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$BACKUP_HOST" "mkdir -p $BACKUP_DIR" 2>/dev/null; then
    report "db-backup-failed" "$UNIT: vaultwarden dumped but backup host $BACKUP_HOST unreachable — copy exists ONLY on $UNIT"
    exit 1
fi

if scp -o ConnectTimeout=10 -o BatchMode=yes -q "$OUT" "$BACKUP_HOST:$BACKUP_DIR/" 2>/dev/null; then
    ssh -o ConnectTimeout=10 -o BatchMode=yes "$BACKUP_HOST" \
        "find $BACKUP_DIR -name '${UNIT}-vaultwarden-*.sql.gz' -mtime +$KEEP_DAYS -delete" 2>/dev/null
    report "db-backup" "$UNIT: vaultwarden backed up, $size, to $BACKUP_HOST"
    echo "$UNIT: vaultwarden backed up, $size, to $BACKUP_HOST"
else
    report "db-backup-failed" "$UNIT: vaultwarden dumped but transfer to $BACKUP_HOST failed"
    exit 1
fi
