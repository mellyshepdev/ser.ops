---
name: serops-safe-changes
description: >-
  The pre-flight and rollback discipline for editing ser.ops on unit7 while backups are live — what to back up first, what needs root, and how to commit. Use before editing any script under /home/swoopg111/projects/ser.ops, changing unit7's crontab, or deploying ser.ops changes. Not for deciding what to change (use serops-scheduler or serops-backup-sinks).
---

# Changing ser.ops safely

**The expensive mistake this prevents:** editing a script on a box where a
2-hour backup is mid-flight, with no rollback, no commit, and no way to get
root when the plan turns out to need it. ser.ops is live infrastructure — the
only copy of some pipelines — and unit7 cannot be reimaged casually.

## Pre-flight — every time, in this order

**1. Is a task running right now?** Editing a script mid-execution changes
behaviour for the *running* process; bash reads scripts incrementally.

```bash
pgrep -af "ser.ops/scripts" ; ls -la ~/projects/ser.ops/state/rotate/rotate.lock
```
If a task is in flight, either wait or accept that the current run uses a
half-old script. Never edit `rotate.sh` while a tick holds the lock.

**2. Back up anything you are about to overwrite.**

```bash
crontab -l > ~/crontab.backup.$(date +%Y%m%d)     # before ANY crontab change
cd ~/projects/ser.ops && git status --short        # know what is already dirty
```
**Do not create `.bak` copies of scripts** — git is the history. Commit instead.

**3. Know what the repo already has uncommitted.** As of 2026-09-20 `rotate.sh`
and `deploy/ser_ops_daily_loop.sh` were modified and
`archive-offload.sh`, `backup-configs.sh`, `backup-volumes-db.sh` were
**untracked**. Working scripts existing only in the working tree is normal here;
do not `git checkout --` anything without reading it first — you would delete
the live implementation.

## What you cannot do

**`sudo` on unit7 requires a password.** You have no root. That rules out:
fstab edits, mounting drives, `apt install`, system-wide `pip`, installing
systemd units, ports below 1024, and `chown` on `~/mnt/xvdg` / `~/mnt/xvdbz1`.

When a plan needs root, **stop and hand SwoopG the exact commands** to run —
do not attempt and retry. Example handoff for the unmounted-drive risk:

```bash
sudo cp /etc/fstab /etc/fstab.bak
echo 'UUID=a48d917a-feea-47f9-99c2-c9669829f21a /home/swoopg111/mnt/xvdg    ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab
echo 'UUID=acf9bdb0-66e3-40b1-aa68-ed09ef52470e /home/swoopg111/mnt/xvdbz1 ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab
sudo findmnt --verify && sudo mount -a
```
`nofail` matters — a bad entry without it makes the box unbootable.

## Making the change

- **Preserve existing behaviour by default.** Additive changes (a new event
  emitter, a new endpoint) are strongly preferred over rewriting a working
  backup path. Keep `rotate.log` even after adding JSONL events.
- **Never change unrequested behaviour** — including styling, output format, or
  "cleanup" of code you were not asked to touch. Removing something the user
  liked is a real failure mode here.
- **Syntax-check before it can ever be dispatched:**
  `bash -n scripts/rotate.sh && echo OK` — a syntax error in the dispatcher
  stops **every** task silently.
- **Dry-run out of band** before trusting cron:
  `env -u SSH_AUTH_SOCK bash scripts/<task>.sh` — this reproduces cron's
  agent-less environment.

## Commit — do not leave work dangling

Changes must not sit uncommitted in the working tree; that is how the
untracked-script situation above arose.

```bash
cd ~/projects/ser.ops
git add -A && git commit -m "<what and why>"
```
`origin` is `https://github.com/mellyshepdev/ser.ops.git`. Push only if asked —
confirm before sending anything outward.

## Rollback

```bash
crontab ~/crontab.backup.<date>        # cron
cd ~/projects/ser.ops && git diff      # review, then: git checkout -- <file>
```
State the rollback path in your report, file by file, whenever you change
something live.
