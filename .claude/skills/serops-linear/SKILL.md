---
name: serops-linear
description: >-
  Read and file Linear issues from ser.ops via scripts/linear.sh — listing, searching, commenting, and deduplicated automated error filing for team BLA. Use when asked to "file this in Linear", "check the Linear issues", "what's on the board", "open a ticket for X", or when wiring ser.ops failures into issue tracking. Not for deciding whether a task actually failed (use serops-verification first).
---

# Linear from ser.ops

**The expensive mistake this prevents:** two of them. (1) Concluding "I have no
Linear integration" and stopping — there is no Linear MCP tool in Claude Code
here, but ser.ops holds a working API key and `scripts/linear.sh` wraps it.
(2) Wiring automated filing without dedupe, so one flapping task opens
hundreds of issues in a shared team board.

## The tool

`/home/swoopg111/projects/ser.ops/scripts/linear.sh` on **unit7**. Verified
working 2026-09-20 as `Shepherd Devoloper`, team **`BLA` / Blacksheeplinearspace`**.

```bash
cd ~/projects/ser.ops
./scripts/linear.sh whoami                       # verify the key before trusting output
./scripts/linear.sh list --limit 20              # newest by updatedAt
./scripts/linear.sh list --state "In Progress"
./scripts/linear.sh get BLA-32                   # full description + comments
./scripts/linear.sh search "backup"
./scripts/linear.sh comment BLA-32 "body"
./scripts/linear.sh create "Title" --desc "body" --priority 2
./scripts/linear.sh file-error <dedupe-key> "Title" "body"
```

Credentials come from `deploy/ser_ops.env` (`LINEAR_API_KEY`, `LINEAR_TEAM_KEY=BLA`).
That file is gitignored (`.gitignore:9`) and is **not** in the public GitHub
repo — verified across all five branches and full history. Keep it that way.

## Rules

- **Never pass the key as an argument** and never echo it. `argv` is world-readable
  through `ps`. The script sources it from the env file; do the same.
- **Build every payload with `jq`,** never string concatenation — issue titles and
  error text routinely contain quotes, backticks and newlines.
- **Reserved variable name:** `gql()` carries the GraphQL query under `__query`
  and strips it from the variables map. A caller variable named `__query` would
  be swallowed. This bit once already: the key used to be `q`, which silently
  deleted the caller's own `$q` and produced
  `Variable "$q" of required type "String!" was not provided` in `search` and
  `file-error`.
- **Automation files with `file-error`, never `create`.** It searches for an open
  issue carrying `serops-dedupe:<key>` in its description and comments on it
  instead of opening a duplicate. Choose a dedupe key that is stable across
  recurrences but distinct per failure mode — `voldb-lock-starvation`, not
  `voldb-failed-at-0705`.
- **Creating or commenting on an issue is outward-facing** — it appears on a
  shared team board. Confirm with SwoopG before the first write of a session;
  approval for one issue is not approval for a batch.

## Writing an issue worth reading

Existing BLA issues set the bar — they lead with the problem and the evidence,
e.g. *"unit9 has no backup of its own — and it holds every other unit's backups"*
with a `## Problem` section and a dated `Verified` line. Match that: state the
failure, the evidence that proves it, and the fix direction. A title that names
the consequence beats one that names the component.

## Verify before filing

Do not file from a `start` event or a cron entry. Climb the evidence ladder in
`serops-verification` first — an issue that says a backup failed when it merely
never got a slot sends someone chasing the wrong defect. Include the artifact
check you ran, or say explicitly that you could not run one.
