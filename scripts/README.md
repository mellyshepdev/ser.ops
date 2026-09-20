# scripts

Operational scripts that run on the fleet. Versioned here because they were not
versioned anywhere else: `db-backup.sh` existed only as identical copies on two
live hosts, and the fix it carries had never been recorded.

## db-backup.sh

Compressed dumps of every database container on a unit, shipped to a remote
host and pruned by age.

It dumps rather than copying data directories on purpose — a file-level copy of
a running database is not crash-consistent and often restores as corrupt.

### What it dumps

Every running container is inspected and matched on its image name:

| Image matches | Dump command |
| -- | -- |
| `*postgres*`, `*pgvector*` | `pg_dumpall --clean --if-exists` |
| `*mariadb*`, `*mysql*` | `mariadb-dump --all-databases --single-transaction --quick` (falls back to `mysqldump`) |
| `*maxscale*`, `*proxysql*`, `*pgbouncer*`, `*pgpool*`, `*haproxy*` | skipped |

The proxy skip matters: those images match the globs above but hold no data, so
a dump attempt can only ever fail. Skipping them keeps real failures visible
instead of drowning them in noise that can never be fixed.

Credentials come from the container's own environment, and from
`*_PASSWORD_FILE` when the stack supplies them as docker secrets. Reading only
the env var produced an empty password and a silently skipped dump — that is
how `mariadb-pdns-replica` went unbacked-up for weeks.

Each archive is verified with `gzip -t` before it counts as a success.

### Where it ships, and retention

```
scp <unit>-<container>-<UTC stamp>.sql.gz  ->  $BACKUP_HOST:$BACKUP_DIR
find $BACKUP_DIR -name '<unit>-*.sql.gz' -mtime +$KEEP_DAYS -delete
```

| Variable | Default |
| -- | -- |
| `BACKUP_HOST` | `unit9-mesh` |
| `BACKUP_DIR` | `/var/backups/db` |
| `KEEP_DAYS` | `30` |
| `LOCATOR_URL` | `https://locator.theofficialblacksheepco.online` |
| `UNIT_NAME` | `$(hostname)` |

Retention is applied on the backup host and scoped to this unit's own files, so
one unit's pruning cannot delete another's.

### How failures surface

Every outcome POSTs an event to `$LOCATOR_URL/api/events`.

| Situation | Event type | Exit |
| -- | -- | -- |
| All databases dumped and shipped | `db-backup` | 0 |
| Some dumped, some failed | `db-backup-failed` | 1 |
| Nothing dumped | `db-backup-failed` | 1 |
| Dumped but backup host unreachable | `db-backup-failed` | 1 |
| Dumped but transfer failed | `db-backup-failed` | 1 |

**A partial backup is treated as a failed backup.** Reporting partial success
as success, and exiting 0, is exactly how a missing replica backup stayed
invisible. The failure detail includes the last line of each dump's stderr, so
a recurring failure is diagnosable from the event alone, without shell access.

### Deployed at

| Unit | Path | Cron |
| -- | -- | -- |
| unit7 | `~/bin/db-backup.sh` | `0 3 * * *  BACKUP_HOST=unit9 UNIT_NAME=unit7` |
| unit8 | `/usr/local/bin/db-backup.sh` | `30 2 * * *  BACKUP_HOST=unit9-mesh UNIT_NAME=unit8` |

Both copies were byte-identical (`f27d9fa5037fe98c8a39046b77f20e1f`) when this
repo captured them, so there is no drift to reconcile — but nothing enforces
that. Deploying from here rather than editing in place is still an open
question (BLA-21).

### Known gaps

* **No size-regression check.** Every check is a liveness check; nothing
  compares a dump to yesterday's. Four consecutive nights once produced
  sub-megabyte archives where the previous night produced 233 MB, and every
  check passed — the archives were valid, just nearly empty. (BLA-34)
* **Databases only.** TLS keys, WireGuard keys, secrets and compose files are
  not backed up by anything. (BLA-22)
* **unit9 backs up nothing of its own**, while holding every other unit's
  backups and serving as PowerDNS ns2. (BLA-32)

## inspect-livlog.sh / recover-livlog.sh

live-logger database inspection and recovery helpers. Captured here in the same
pass, for the same reason — they existed only on one disk.
