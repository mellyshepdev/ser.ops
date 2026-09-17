# ser.ops

Backup and optimisation tooling for the BlackSheep fleet.

Tracked in Linear under **Server optimizer** (team `BLA`).

## `pg_lzma_export`

Streams a PostgreSQL query straight into an `.xz` file. Constant memory, no
intermediate buffering of the result set.

```sh
make
./pg_lzma_export --table logs_archive --out archive.xz
```

Connection details come from the standard libpq environment variables
(`PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`, `PGPASSFILE`) or
from `PG_CONNINFO`. Nothing is hardcoded, and no password is passed in `argv`
where `ps` would expose it.

### Incremental export

The point of the tool. `logs_archive` is append-only — once `rollover.sh`
seals an hour bucket it never changes again — so there is no reason to
re-export history every night.

```sh
./pg_lzma_export --table logs_archive \
                 --since '2026-09-01 00:00:00+00' \
                 --out inc.xz
```

Track the last exported `hour_bucket` as a watermark and advance it only
after the transfer is confirmed. Re-export the newest bucket each run:
`rollover.sh` upserts into the current hour (`ON CONFLICT DO UPDATE` appends
to `payload`), so treat the newest bucket as mutable and everything older as
sealed.

Keep a periodic full export — weekly or monthly — so a restore never depends
on replaying an unbounded chain of increments.

### Why COPY rather than `SELECT` + `PQgetvalue`

- `PQgetvalue` returns `""` for SQL NULL, indistinguishable from an empty
  string. COPY encodes NULL as `\N`, so the distinction survives a restore.
- COPY escapes tabs, newlines and backslashes inside values. Hand-rolled
  string concatenation corrupts any row containing them — for a table of
  free-text log messages that is a certainty, not a risk.
- COPY streams. `PQexec` buffers the whole result client-side first.

The output payload is COPY text format, so restoring is just:

```sh
xz -dc inc.xz | psql -d live_logger_archive -c "\copy logs_archive FROM STDIN"
```

## Measured results

Against `logs_archive` on unit7, a two-hour slice, 2026-09-02:

| | |
| --- | --- |
| Raw COPY output | 66,335,501 bytes |
| `pg_lzma_export` preset 6 | 2,076,948 bytes — **31.9x** |
| `gzip -9`, same input | 2,959,465 bytes |
| **xz vs gzip** | **1.42x smaller** |
| Peak RSS | 156 MB |
| Throughput | 3.6 MB/s in (unit3, 2 physical cores, over Tailscale) |

Round-trip verified: `xz -dc` output is **byte-identical** to the same query
run through `psql ... COPY ... TO STDOUT`.

### Read these numbers carefully

Switching gzip → xz is a **1.42x** win. Exporting only new buckets instead of
the whole cluster is roughly a **50x** win — the current nightly `pg_dumpall`
produces ~546 MB, while a day of new archive buckets is single-digit MB.

The compressor is the small lever. Not sending unchanged rows is the large
one. See BLA-30.

## Memory, and why preset 9 is a trap

Encoder memory is set by the LZMA dictionary, not by the I/O buffers:

```
preset 0    3 MiB      preset 5   94 MiB
preset 1    9 MiB      preset 6   94 MiB   (default)
preset 2   17 MiB      preset 7  186 MiB
preset 3   32 MiB      preset 8  370 MiB
preset 4   48 MiB      preset 9  674 MiB
```

**unit7 has ~1 GB free.** Preset 9 there would be OOM-killed. Preset 6 is the
sane ceiling on that host, and lower is defensible — the difference between
preset 6 and 9 on this data is small next to the incremental-export win.

### Where to run it

Running the exporter on **unit3** and pulling from unit7 over the tailnet
moves the compression CPU and the ~94 MB encoder off the starved host onto
one with spare capacity. The cost is shipping raw bytes across the tailnet
instead of compressed ones — on a LAN/Tailscale link that is a good trade
given unit7 runs on 2 cores with 1 GB free. See BLA-31.

## Build

Requires `libpq` and `liblzma` development headers.

```sh
# Debian/Ubuntu
sudo apt-get install libpq-dev liblzma-dev

# macOS
brew install libpq xz
```

`make debug` builds with ASan and UBSan — worth running the benchmark under
it before trusting a change.

## `bench.sh`

Compares the tool against the existing `gzip -9` pipeline on real data at
several presets, and shows the incremental-vs-full delta. Run it on the host
holding the database.

## Ops on unit7

All ser.ops work runs through the rotation dispatcher — see `rotate.sh`
below. The incremental `logs_archive` export (live-logger-db) is rotation
task `export` (~hourly):

```sh
# one-shot
/home/swoopg111/projects/ser.ops/scripts/export-archive.sh
```

- Binary: `pg_lzma_export` (build via Debian container if host lacks `gcc`/`libpq-dev`)
- Runtime image: `ser.ops-export:latest` (`Dockerfile.runtime`)
- Output: `/home/swoopg111/backups/ser.ops/`
- Watermark: `state/logs_archive.watermark` (advanced only after `xz -t`)
- Events: locator `/api/events` as `ser.ops` / `ser.ops-warn` / `ser.ops-failed`
  (auth via `X-Locator-Admin-Key` from lokey's `.env`)
- Off-box copy tries `BACKUP_HOST` (default `unit9-mesh`); if SSH fails the
  file stays local and a **warn** event is raised — never silent.

## `backup-volumes.sh`

Per-container attached-volume backup, added after the unit8 loss proved that
configs-in-git is not enough — mailbox data, gitea repos, app state all lived
only in docker volumes that went down with the host.

For every container (running **or** stopped), every attached mount — named
volume or bind — is tarred read-only through a throwaway
`debian:bookworm-slim` helper container and **streamed straight to the backup
host over ssh**. Nothing stages on local disk, so the ~46 GB database dirs
can ship without touching unit7's 82%-full root.

```sh
# full sweep, on demand (normally run by the rotation — see below)
/home/swoopg111/projects/ser.ops/scripts/backup-volumes.sh

# targeted run — one service's state
ONLY_CONTAINERS="hub-postgres welcome" \
  /home/swoopg111/projects/ser.ops/scripts/backup-volumes.sh
```

- Destination: `unit3-tailscale:~/backups/volumes/<unit>/<yyyymmdd>/`
  (`BACKUP_HOST`, `REMOTE_DIR` overridable)
- Naming: `<container>__<dest-path|vol-name>__<stamp>.tar.gz`
- Manifest: `manifest-<stamp>.txt` ships with each run — pipe-separated
  `container|type|source|dest|archive|status`. It's the restore index.
- Orphans: named volumes not attached to any container are still archived
  (as `_unattached`) — deleted containers don't take their data with them.
- Shared volumes are archived once (first container seen wins; the rest are
  recorded in the manifest as `skip-shared-via-*`).
- Events: locator `/api/events` as `ser.ops` / `ser.ops-warn`.

### If the backup host is down

Falls back to local `~/backups/volumes/<stamp>/` — but **only for mounts ≤
`LOCAL_FALLBACK_MAX_MB` (4 GB)**. Bigger mounts are recorded as
`SKIP-oversize-no-remote` rather than eating the disk, and the run exits
nonzero so the warn event fires.

### Exclusions

Source paths matching `EXCLUDE_PATTERNS` (plus optional
`volume-backup-excludes.txt`, one regex per line) are never archived:

- `/` — lokey mounts the host root at `/host`; without this the "backup"
  would tar the entire box
- `/var/log`, `/var/lib/docker/containers`, `/var/run/docker.sock` —
  host logs, engine internals, the socket itself
- `/proc`, `/sys`, `/dev`, `/etc/{os-release,timezone,localtime}`

Note: `/var/lib/docker/volumes` is **not** excluded — that is where named
volume mountpoints live; it's most of what we're here for.

### Retention

Remote sets older than `KEEP_DAYS` (30) are pruned from the backup host each
run; local staging thins after `KEEP_LOCAL_DAYS` (7).

### Restore

```sh
# find the archive in the manifest
grep 'mycontainer' manifest-*.txt

# named volume — recreate, then untar into it
docker volume create myvol
scp unit3-tailscale:backups/volumes/unit7/<stamp>/<archive>.tar.gz .
docker run --rm -v myvol:/data -v "$PWD:/in" debian:bookworm-slim \
    sh -c 'tar -xzf /in/<archive>.tar.gz -C /data'

# bind mount — untar back over the recorded source path
tar -xzf <archive>.tar.gz -C /recorded/source/path
```

### Consistency, and the secrets caveat

These are **crash-consistent filesystem copies** — a live postgres data dir
tarred mid-write may not be a clean restore point. The pg_dump/mysqldump
jobs stay the clean-restore path for databases; this script is the
everything-else safety net (and a better-than-nothing for DBs).

Archives are plaintext tar.gz and some binds contain secrets (`.ssh`,
`secrets/`, `bao.token`). Access to the backup host is the trust boundary —
keep unit3's account locked down.

## `rotate.sh` — task rotation

ser.ops runs on a rotation, not fixed per-job crons. Cron ticks the
dispatcher every 30 min; each tick runs **exactly one** due task and
advances the round-robin pointer — it switches tasks every 30–60 min.

```sh
# cron (installed on unit7)
*/30 * * * * /home/swoopg111/projects/ser.ops/scripts/rotate.sh \
  >>/home/swoopg111/backups/ser.ops/rotate.log 2>&1
```

A task is eligible only when its min-interval has elapsed **and** its own
lockfile is free — a task still mid-flight is skipped, never queued or
doubled. If nothing is eligible the tick exits quietly.

| Task | Interval | What it does |
| --- | --- | --- |
| `export` | 55 min | incremental `logs_archive` xz export → unit3 |
| `vol-0/1/2` | 110 min | volume shards — containers hash-split into thirds, mounts ≤8 GB; full small-mount coverage ~6 h; orphan volumes ride `vol-2` |
| `vol-big` | 22 h | mounts >8 GB (the pgdata whales) — ~daily so they don't drag every tick |

Volume tasks run with `KEEP_DAYS=14` (30d of daily ~60 GB sets would
overrun unit3's disk). Sharding is `SHARD=i/n`; size gates
`MIN_MOUNT_MB`/`MAX_MOUNT_MB` use a 12 h `du` cache in
`state/volume-sizes.cache` so a 46 GB data dir isn't re-scanned every tick.

State lives in `state/rotate/`: `index` (round-robin pointer),
`<task>.last` (last attempt mtime), `rotate.lock`.

Adding a task = one line in `TASKS` (`name|min-interval-min|lockfile|cmd`)
— give it its own lockfile or share one to mutual-exclude with another job.

## Related

- `NOTES.md` — original design notes and scratch code.
- Linear: BLA-18 (mariadb secret-file bug), BLA-19 (broken `liv-log-pgdb-18.3`),
  BLA-21 (version-control `db-backup.sh`), BLA-30 (incremental export),
  BLA-31 (unit7 capacity).
