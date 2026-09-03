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

## Related

- `NOTES.md` — original design notes and scratch code.
- Linear: BLA-18 (mariadb secret-file bug), BLA-19 (broken `liv-log-pgdb-18.3`),
  BLA-21 (version-control `db-backup.sh`), BLA-30 (incremental export),
  BLA-31 (unit7 capacity).
