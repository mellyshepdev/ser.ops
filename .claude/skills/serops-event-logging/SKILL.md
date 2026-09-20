---
name: serops-event-logging
description: >-
  The structured JSONL event contract every ser.ops script must emit so the dashboard and audits can see each action. Use when adding logging to a ser.ops script, wiring a new task into the event stream, changing the event schema, or when asked to "make ser.ops verbose", "log every action", or "I want to see what ser.ops is doing". Not for building the UI that renders these events (use serops-webui) and not for scheduling (use serops-scheduler).
---

# ser.ops event log — the emission contract

**The expensive mistake this prevents:** scripts that only `printf` into
`rotate.log`. Plain text means nobody can answer "did the offload run today and
what did it move?" without grepping by eye, and `report()` currently fires
**only on failure**, so successful work leaves no trace at all. Silence then
gets misread as "nothing scheduled" instead of "nothing observable".

## Where events go

Append one JSON object per line to a **day-partitioned** file:

```
$STATE_DIR/events/YYYY-MM-DD.jsonl
```

Day partitioning keeps the dashboard's tail cheap and makes retention a simple
`find -mtime +N -delete`. Never rewrite an existing line — this file is an
append-only audit trail.

## Schema — every event, every time

```json
{"ts":"2026-09-20T07:08:31Z","unit":"unit7","run_id":"1758351600-4821","task":"archive-offload","phase":"start","msg":"draining volume-archive","rc":null,"dur_ms":null,"detail":{}}
```

| field | required | meaning |
|---|---|---|
| `ts` | yes | UTC, `date -u +%Y-%m-%dT%H:%M:%SZ` |
| `unit` | yes | always `unit7` here; keeps the stream mergeable across the fleet |
| `run_id` | yes | `<tick-epoch>-<pid>`, identical for every event in one dispatch — this is what groups a run in the UI |
| `task` | yes | task name from the `TASKS` table, or `rotate` for dispatcher-level events |
| `phase` | yes | one of `tick`, `skip`, `start`, `step`, `done`, `fail` (closed set — the UI switches on it) |
| `msg` | yes | one human line, no newlines |
| `rc` | on `done`/`fail` | integer exit code |
| `dur_ms` | on `done`/`fail` | integer milliseconds |
| `detail` | yes | object; `{}` when empty. Free-form per task (bytes moved, target host, volume name) |

**Phase meanings — do not blur these:**
- `tick` — dispatcher woke up. Emit on **every** cron fire, including wasted ones.
- `skip` — a tick did no work. `detail.reason` is `lock_held`, `not_due`, or `none_free`. **This is the most important event in the system**: skips are what revealed 45 of 48 ticks dying.
- `start` / `done` / `fail` — a task's lifecycle. Always pair a `start` with exactly one `done` or `fail`.
- `step` — progress inside a long task (per volume, per file). Optional but this is what makes the log "verbose" rather than "two lines per hour".

## The emitter

Source `lib/event.sh` from every script. It must be dependency-free POSIX-ish
bash — **no `jq`** (unit7's `swoopg111` has it, but the container images used by
backup tasks do not, and a missing binary must never break a backup).

JSON-escape every interpolated string. A volume name or error message
containing `"` or a backslash will otherwise produce an unparseable line and
silently truncate the dashboard.

```bash
# lib/event.sh
: "${STATE_DIR:=/home/swoopg111/projects/ser.ops/state}"
: "${UNIT:=unit7}"
: "${RUN_ID:=$(date +%s)-$$}"
EVENT_DIR="$STATE_DIR/events"

_esc() {                        # JSON string escape: backslash, quote, control
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
                           -e 's/\t/\\t/g' -e 's/\r/\\r/g' | tr -d '\000-\010\013\014\016-\037'
}

event() {                       # event <task> <phase> <msg> [rc] [dur_ms] [detail-json]
    local task=$1 phase=$2 msg=$3 rc=${4:-null} dur=${5:-null} detail=${6:-\{\}}
    mkdir -p "$EVENT_DIR" 2>/dev/null || return 0
    printf '{"ts":"%s","unit":"%s","run_id":"%s","task":"%s","phase":"%s","msg":"%s","rc":%s,"dur_ms":%s,"detail":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(_esc "$UNIT")" "$(_esc "$RUN_ID")" \
        "$(_esc "$task")" "$(_esc "$phase")" "$(_esc "$msg")" "$rc" "$dur" "$detail" \
        >> "$EVENT_DIR/$(date -u +%F).jsonl" 2>/dev/null || true
}
```

**`event()` must never fail a task.** Every path ends in `|| true` / `|| return 0`.
A full disk must not turn a backup failure into a backup *crash*.

## Wiring rules

- Emit `tick` **before** taking the global lock, so wasted ticks are recorded.
  Logging after the lock is why starvation stayed invisible.
- Wrap task dispatch to time it:
  `t0=$(date +%s%3N)` … `dur=$(( $(date +%s%3N) - t0 ))`.
- Keep the existing `log()` text output. The JSONL stream is **additive** —
  do not remove `rotate.log`, other tooling and humans read it.
- Keep `report()` for Locator alerts on `fail` only. Do not POST every event to
  Locator; the JSONL file is the firehose, Locator is the alert channel.

## Verify emission

```bash
# a tick must produce at least one event
tail -3 ~/projects/ser.ops/state/events/$(date -u +%F).jsonl
# every line must be valid JSON
python3 -c "import json,sys;[json.loads(l) for l in open(sys.argv[1])];print('all lines parse')" \
  ~/projects/ser.ops/state/events/$(date -u +%F).jsonl
# starts must balance against done+fail
awk -F'"phase":"' '{split($2,a,"\"");print a[1]}' ~/projects/ser.ops/state/events/$(date -u +%F).jsonl | sort | uniq -c
```
An unbalanced `start` count means a task is dying without emitting `fail` —
fix the trap, don't paper over it.
