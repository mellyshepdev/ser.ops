---
name: serops-scheduler
description: >-
  The rotate.sh dispatcher contract for ser.ops — how slots, min-intervals and locks interact, the starvation failure mode that silently kills most ticks, and how to add or retune a task without stalling the fleet. Use when asked to "change the ser.ops schedule", "add a task to rotate.sh", "make the offload run more often", "why has the backup not run since", or when tuning cadence. Not for reading the repo map (use serops-architecture) and not for proving a task ran (use serops-verification).
---

# ser.ops dispatcher — how scheduling really works

**The expensive mistake this prevents:** an agent reads the task table, sees
`archive-offload|120|...`, and tells the user "it runs every 2 hours." It does
not. On 2026-09-19, **45 of the day's 48 ticks did nothing at all.** Stating a
task table interval as the real cadence is the single most common wrong answer
about this system.

## The contract

`cron` runs **only** `rotate.sh`, every 30 minutes:

```
*/30 * * * * ionice -c3 nice -n19 /home/swoopg111/projects/ser.ops/scripts/rotate.sh >>/home/swoopg111/backups/ser.ops/rotate.log 2>&1
```

Each tick:

1. Takes a **global** `flock` on `state/rotate/rotate.lock`. If a previous tick
   is still running, it logs `another rotation tick holds the lock — exiting`
   and **exits 0 having done nothing**.
2. Walks the 8-entry `TASKS` array round-robin starting after `state/rotate/index`.
3. Picks the **first** task that is both **due** (`now - mtime(<task>.last) >= interval*60`)
   and whose own per-task lock is free.
4. Runs exactly **one** task, then `touch`es `<task>.last` and writes the slot to `index`.

Task table format is `name|min-interval-minutes|lockfile|command`:

| task | interval | notes |
|---|---|---|
| `export` | 55 | |
| `vol-0` / `vol-1` / `vol-2` | 110 | small mounts, `SHARD=N/3`, `MAX_MOUNT_MB=8192` |
| `vol-big` | 1320 | mounts >8GB, ~daily |
| `voldb` | 300 | **writes into `puffbase-cockroach`** — the contention source |
| `db` | 350 | |
| `mail` | 55 | |
| `archive-offload` | 120 | drains xvdbz1 → unit3 |

All `vol-*` share one lock (`VOL_LOCK`), so they serialize against each other.

## The three defects — cite these, don't rediscover them

**1. One task per tick × 8 tasks = a 4-hour best-case orbit.** With a 30-minute
tick, any given task's slot comes round every `8 × 30min = 4h` *at best*. A
`110`-minute interval can never actually produce a 110-minute cadence.

**2. The global lock converts one slow task into hours of dead ticks.** A
volume run observed at **1h44m** blocks every tick for its whole duration. Count
the damage:

```bash
grep "another rotation tick holds the lock" /home/swoopg111/backups/ser.ops/rotate.log \
  | cut -c1-10 | sort | uniq -c | tail -7
```
Observed trend — this is a worsening spiral, not noise:
```
      6 2026-09-17
     26 2026-09-18
     45 2026-09-19      <- 45 of 48 ticks wasted
```

**3. `<task>.last` is touched AFTER the task finishes** (`rotate.sh:127`, after
`bash -c "$cmd"` at line 125). So the interval clock measures time since
*completion*, not since *start*. A 2-hour task with a 110-minute interval is not
eligible again until 110 minutes after it ends — the longer a task runs, the
further it slips. Combined with defect 2, slow tasks progressively starve
everything else.

## Consequence chain to reason with

```
offload never gets a slot -> xvdbz1 fills (88%) -> volume runs get slower
   -> global lock held longer -> more ticks wasted -> offload gets even fewer slots
```
Breaking any one link relieves the others. The cheapest break is running
`archive-offload.sh` directly, out of band — it needs no slot.

## Rules for changing the schedule

- **Never raise a task's frequency to fix starvation.** The bottleneck is slot
  availability, not the interval. Lowering an interval on a starved dispatcher
  changes nothing and hides the real defect.
- **Touch `.last` before running, not after**, if you fix defect 3 — but then
  a crashed task no longer retries promptly, so pair it with explicit failure
  handling.
- **A long task must not hold the global lock.** Either run it detached from
  the dispatcher or scope the lock to the task.
- **Preserve `lock_free()`'s subshell form** — `( flock -n 8 ) 8>"$1"` probes
  with a fresh file descriptor, because `flock` is per open-file-description.
  Rewriting it without the subshell silently always reports "free".
- **Disabling `voldb` is safe** on its own terms: the script's own comment says
  *"unit3's tarballs remain the primary off-box copy"*, so commenting out that
  one line does not leave any volume without a backup. It is the highest-value
  single change for I/O relief.

## Verify a schedule change took effect

```bash
# what ran, and when it was last dispatched
for f in ~/projects/ser.ops/state/rotate/*.last; do
  printf '%-18s %s\n' "$(basename "$f" .last)" "$(date -r "$f" '+%m-%d %H:%M')"
done
# did the next tick dispatch or die on the lock?
tail -20 /home/swoopg111/backups/ser.ops/rotate.log
```
A healthy tick logs `task <name> start (rotation slot N/7)`. A starved one logs
`another rotation tick holds the lock — exiting`. If every recent line is the
latter, the change did not help.
