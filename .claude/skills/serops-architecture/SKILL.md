---
name: serops-architecture
description: >-
  Ground truth for the ser.ops backup/ops automation system on unit7 — repo layout, every script's job, the state directory, disk topology, and which hosts are live. Use when asked to "change ser.ops", "add a ser.ops task", "why did the backup not run", "where does ser.ops write", or any work touching /home/swoopg111/projects/ser.ops. Read this FIRST, before any other serops-* skill. Not for running or verifying tasks (use serops-verification) and not for editing the dispatcher (use serops-scheduler).
---

# ser.ops — system map

**The expensive mistake this prevents:** agents assume ser.ops is a simple cron
backup script, change one thing, and break a live pipeline — or they report a
service as "on Fly" / "on unit8" from stale memory instead of reading the
registry. Everything below was verified on 2026-09-20. Re-verify before
asserting any of it as still true.

## Where it lives

| | |
|---|---|
| Host | **unit7** only |
| Path | `/home/swoopg111/projects/ser.ops` |
| SSH | `ssh -i ~/.ssh/unit7 swoopg111@100.99.131.20` (Tailscale IP — the `unit7` alias in `~/.ssh/config` has a stale `172.31.18.95` that times out) |
| Git | `origin` = `https://github.com/mellyshepdev/ser.ops.git` |
| Runs as | user `swoopg111` (uid 1001), in group `docker` |
| **sudo** | **requires a password — you cannot get root.** Anything needing root must be handed to SwoopG as a command to run. |

## Scripts and what each one is for

| script | job | primary sink |
|---|---|---|
| `scripts/rotate.sh` | the dispatcher — cron calls only this | — |
| `scripts/backup-volumes.sh` | tar+gzip docker volumes, sharded | `~/mnt/xvdbz1/volume-archive` then unit3 |
| `scripts/backup-volumes-db.sh` | **second sink** — same mounts, into CockroachDB `userfile` | `puffbase-cockroach` on unit7 |
| `scripts/archive-offload.sh` | drain `volume-archive` → unit3, one dir per run | `unit3:backups/volume-archive/unit7/` |
| `scripts/backup-dbs.sh` | logical dumps of every DB container | unit3 |
| `scripts/backup-configs.sh` | config capture | — |
| `scripts/export-archive.sh` | export task | — |
| `scripts/mail-ops.sh` | inbox sweep, rules, Linear digest | unit3 |

`deploy/ser-ops-daily.{service,timer}` exist but the timer is **`inactive`** —
ser.ops is driven by **cron**, not systemd. Do not "fix" the timer expecting it
to be the live path.

## State directory

`$REPO/state` (`STATE_DIR`), with `$STATE_DIR/rotate` (`ROTATE_DIR`) holding
dispatcher bookkeeping:

```
state/rotate/index              # last dispatched slot number
state/rotate/<task>.last        # touched when a task FINISHES (see serops-scheduler)
state/rotate/rotate.lock        # global dispatcher lock
state/<task>.lock               # per-task locks
state/voldb-tmp/                # staging for backup-volumes-db.sh, ~495M, on /
state/archive-offload.done
```

Logs: `/home/swoopg111/backups/ser.ops/rotate.log` (plain text, appended).

## Disk topology — read before writing anything large

| device | size / free | mounted at | holds | in `/etc/fstab`? |
|---|---|---|---|---|
| `/dev/xvda1` | 290G / 114G | `/` | Docker, Cockroach, `state/voldb-tmp` | yes |
| `/dev/xvdg1` | 149G / 54G | `~/mnt/xvdg` | **`comms-db` (LIVE)**, `oldlivlog`, `oldpg183` | **NO** |
| `/dev/xvdbz1` | 106G / 13G (88%) | `~/mnt/xvdbz1` | `volume-archive` | **NO** |

UUIDs: `xvdg1` = `a48d917a-feea-47f9-99c2-c9669829f21a`,
`xvdbz1` = `acf9bdb0-66e3-40b1-aa68-ed09ef52470e`.

**Both extra drives are hand-mounted and absent from fstab.** A reboot drops
them; Docker then recreates `~/mnt/xvdg/comms-db` as an empty dir and the live
`comms-db` Postgres starts on nothing. Adding fstab entries needs root — hand
the commands to SwoopG, do not attempt it.

`/mnt/_db`, `/mnt/databases`, `/mnt/xvdg1` are empty root-owned prepared mount
points with nothing mounted on them.

## Fleet reality (2026-09-20)

Live: **unit2, unit3, unit5, unit6, unit7, unit9**.
**unit4 and unit8 are decommissioned** — do not SSH to them, do not deploy to
them, do not treat "unit8 disk full" as an open incident. Their services were
recreated elsewhere.

The service registry of record is **unit9**'s
`/root/projects/locator/locator.yml` — check it before claiming where anything
runs. `ssh unit9` works from unit6 directly.

## Telemetry hook that already exists

`rotate.sh` defines `report()`, which POSTs to Locator:

```
POST $LOCATOR_URL/api/events
{"type":"<kind>","message":"<msg>","unit":"unit7"}
headers: X-Locator-Admin-Key, Host (both optional, from $LOKEY_ENV)
```

It is currently called **only on failure**. Any observability work should reuse
this function rather than inventing a second telemetry path — see
`serops-event-logging`.

## Verify this map is still current

```bash
ssh -i ~/.ssh/unit7 swoopg111@100.99.131.20 \
  'cd ~/projects/ser.ops && git log --oneline -3 && ls scripts/ && df -h | grep -E "xvd" && findmnt -rno TARGET,SOURCE | grep xvd'
```
If `df` shows a drive `findmnt`/fstab does not, the reboot risk above is still open.
