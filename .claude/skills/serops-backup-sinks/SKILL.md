---
name: serops-backup-sinks
description: >-
  Where ser.ops backups actually land — the two parallel sinks, why the CockroachDB sink destabilises production, and the disk limits that constrain any change. Use when changing a backup destination, adding a backup task, diagnosing disk pressure on unit7, or when asked "where are the backups", "why is cockroach restarting", "can I delete the archive". Not for scheduling cadence (use serops-scheduler).
---

# ser.ops backup sinks

**The expensive mistake this prevents:** treating the two sinks as
interchangeable, or deleting the "duplicate" archive. They are not duplicates —
one is the primary off-box copy, the other is a queryable secondary that is
actively harming the host.

## The two sinks

**Sink 1 — file tarballs (primary).**
`backup-volumes.sh` → `~/mnt/xvdbz1/volume-archive/<volume>/` → drained by
`archive-offload.sh` to `unit3:backups/volume-archive/unit7/<name>.tar.gz`,
verified with `gzip -t`, 14-day retention. The script comments call unit3
*"the primary off-box copy"*.

**Sink 2 — CockroachDB userfile (secondary).**
`backup-volumes-db.sh` → tar.gz staged in `$STATE_DIR/voldb-tmp` → `docker cp`
into the container → `cockroach userfile upload` into **`puffbase-cockroach`**,
plus a queryable metadata table. Task `voldb`, ~5h cadence.

## Why sink 2 is the problem

`puffbase-cockroach` is not a backup appliance. It also holds the live
databases **`puffbase`, `inventory`, `sales`, `snap_t03`**. As of 2026-09-20 its
`volume_backups` database held **497 userfile blobs across 331 tables**, with an
8.6G data directory.

Consequences, all observed:
- Backups compete for I/O with the production data they protect.
- `puffbase-cockroach` showed `RestartCount=4` (exit 0, **not** OOM — starved,
  then restarted by Locator's `restart_when_stopped: true`).
- A single container loss destroys production data **and** its backups together.

Every volume write hits `/dev/root` **three times**: stage → `docker cp` →
`userfile upload` — the same device as Docker and Cockroach.

**Disabling `voldb` is safe.** Sink 1 already covers the same mounts and is the
primary copy, so commenting out that one task table line leaves nothing
unbacked. It is the highest-value single I/O change available.

## Disk limits that constrain any change

| mount | size / free | note |
|---|---|---|
| `/` | 290G / 114G | Docker + Cockroach + `voldb-tmp` (~495M) |
| `~/mnt/xvdg` | 149G / 54G | holds **live `comms-db`** — not scratch space |
| `~/mnt/xvdbz1` | 106G / 13G (**88%**) | `volume-archive`, 10G across 4 dirs |

Both extra drives are **absent from `/etc/fstab`** and are root-owned —
`swoopg111` cannot create directories on them and `sudo` needs a password. Any
plan that writes to `~/mnt/xvdg` or `~/mnt/xvdbz1` as `swoopg111` **will fail
with `mkdir: Permission denied`** until SwoopG grants ownership. Verify writability
before designing around a path:

```bash
test -w ~/mnt/xvdbz1 && echo writable || echo "NOT writable — needs root"
```

## Never delete an archive to free space

`volume-archive` is not scratch. The correct way to reclaim xvdbz1 is to **run
the drain**, which copies to unit3 and verifies before removing:

```bash
env -u SSH_AUTH_SOCK bash ~/projects/ser.ops/scripts/archive-offload.sh
```
It moves **one directory per run** by design, so expect to run it repeatedly.
Standing rule: *"remove X" never means delete its data* — list what would go and
ask first.

## Before changing any sink

1. Confirm the *other* sink currently has a valid, recent copy (`gzip -t` on unit3).
2. Change one sink at a time.
3. Re-verify rung 5 of `serops-verification` before calling it done.
