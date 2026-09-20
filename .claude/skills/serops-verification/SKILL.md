---
name: serops-verification
description: >-
  How to prove ser.ops actually performed its tasks rather than assuming it did — the evidence ladder from artifacts on disk up to dispatcher logs. Use when asked to "verify ser.ops is working", "did the backup run", "check the schedule is being honoured", or before reporting any ser.ops task as done or fixed. Not for designing the schedule (use serops-scheduler) and not for the event schema (use serops-event-logging).
---

# Proving ser.ops did the work

**The expensive mistake this prevents:** reporting "the backup is running"
because cron has an entry, the script exists, or a log line says `start`.
SwoopG's standing rule is that **done means working, verified — an intent is
not an outcome.** A `start` with no matching `done` is a *failure*, and a green
cron entry proves only that cron exists.

## The evidence ladder — climb it in this order

Weakest to strongest. **Never report success from rungs 1–2 alone.**

1. **Config exists** — `crontab -l` shows the entry. Proves nothing ran.
2. **Dispatcher woke** — `rotate.log` has recent lines. Proves cron fired, not
   that a task ran. Most lines may be `another rotation tick holds the lock — exiting`.
3. **Task dispatched** — `state/rotate/<task>.last` mtime is recent, or a
   `start` event exists. Proves it began.
4. **Task completed** — a `done` event with `rc=0` whose `run_id` matches the
   `start`. Proves it finished cleanly.
5. **Artifact exists and is valid** — the thing the task was supposed to
   produce is on disk/remote, is non-empty, is newer than the run, and passes
   an integrity check. **This is the only rung that actually counts.**

## Rung-5 checks per task

```bash
# archive-offload -> did a tarball land on unit3, and is it intact?
ssh unit3-tailscale 'ls -la backups/volume-archive/unit7/ | tail -5'
ssh unit3-tailscale 'gzip -t backups/volume-archive/unit7/<name>.tar.gz && echo INTACT'

# backup-volumes -> archive pile changed and disk pressure moved
du -sh ~/mnt/xvdbz1/volume-archive; df -h ~/mnt/xvdbz1 | tail -1

# voldb -> blob count in CockroachDB actually grew
docker exec puffbase-cockroach ./cockroach userfile list --insecure | wc -l

# any task -> start/done balance for the day
awk -F'"phase":"' '{split($2,a,"\"");print a[1]}' \
  ~/projects/ser.ops/state/events/$(date -u +%F).jsonl | sort | uniq -c
```

`gzip -t` matters: `archive-offload.sh` already verifies with it before removing
the local copy, so an archive that fails `gzip -t` means the offload's own
guarantee broke — escalate rather than re-running blindly.

## Verify a *fix*, not just a run

After changing scheduling or throttling, measure the thing you claimed to
improve, before and after, and report both numbers:

```bash
# wasted ticks per day — the starvation metric
grep "another rotation tick holds the lock" ~/backups/ser.ops/rotate.log \
  | cut -c1-10 | sort | uniq -c | tail -7
# responsiveness of the services being starved
for p in 3000 3500; do curl -s -o /dev/null -w "$p: %{http_code} %{time_total}s\n" -m 15 http://100.99.131.20:$p/; done
```

Probe **more than once**. A single sample on a contended box is noise: during
one verification `userdash` improved 4.81s → 0.19s while port 3000
simultaneously degraded 0.17s → 4.28s. Reporting only the first would have been
a false win.

## Honest-reporting rules

- If a task has not run in the window, **say so with the timestamp**, do not
  say "it is scheduled".
- If you throttled something and load did not drop, say load did not drop.
  Redistributing contention is not fixing it.
- Distinguish **"up"** from **"healthy"**: PuffBase answered `200` in 7.2s cold
  and 0.78s warm — both are "up"; only one is healthy.
- Distinguish **"unreachable"** from **"asleep"**: `archive-offload` logged
  `unit3-tailscale unreachable`, but the same probe succeeded hours later. The
  host was asleep, not broken — see `serops-fleet-ssh`.
- Never assert a service's location from memory. Check unit9's `locator.yml`
  and `docker ps`. A stale note put PuffBase on Fly when it runs on unit7.

## The one-command health read

```bash
curl -s http://100.99.131.20:<port>/api/health | python3 -m json.tool
```
Once the dashboard exists this replaces the manual ladder — but only rungs 1–4.
**Rung 5 always requires looking at the artifact.**
