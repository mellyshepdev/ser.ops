---
name: serops-webui
description: >-
  How to build, serve and verify the ser.ops transparency dashboard that renders the JSONL event stream — endpoints, live tail, binding rules, and browser verification. Use when asked to "build the ser.ops web UI", "show me what ser.ops is doing", "add a page for the logs", or when changing the dashboard or its API. Not for the event schema itself (use serops-event-logging) and not for scheduler internals (use serops-scheduler).
---

# ser.ops dashboard

**The expensive mistake this prevents:** building a dashboard that reads
`rotate.log` with a regex, or one that needs `pip install`. The first breaks the
moment a log line changes; the second cannot be installed — **`sudo` on unit7
requires a password**. The dashboard must run from the Python 3 standard library
alone, reading the JSONL contract in `serops-event-logging`.

## Hard constraints on unit7

- **No root.** No `apt`, no system-wide `pip`, no ports below 1024, no systemd
  unit installs. Run it as `swoopg111` or as a Docker container (that user is in
  the `docker` group).
- **Bind to the Tailscale IP, never `0.0.0.0`.** Every other service on unit7
  follows this (`100.99.131.20:3000`, `:3500`, `:26257`). The box has no public
  web exposure and must not gain one. Pick a free port and bind
  `100.99.131.20:<port>`.
- **Never serve `state/` as a static directory.** It contains lock files and
  staging data. Serve only the explicit endpoints below.
- Confirm the interpreter before writing code — do not assume:
  `ssh … 'python3 -V; command -v python3'`

## Endpoints

| route | returns |
|---|---|
| `GET /` | the single-page dashboard (self-contained HTML, no CDN — the box may be offline) |
| `GET /api/events?date=YYYY-MM-DD&since=<iso>&task=<name>&phase=<phase>` | JSON array of events, newest last |
| `GET /api/stream` | **SSE** (`text/event-stream`), one `data:` frame per new event |
| `GET /api/summary?date=YYYY-MM-DD` | per-task rollup: counts by phase, last `start`/`done`, median + max `dur_ms` |
| `GET /api/health` | dispatcher liveness — see below |

`/api/health` is the endpoint that answers the actual question "is ser.ops
working?". It must report, per task: last dispatch time, age vs. its
min-interval, and **today's skip count with reasons**. A dashboard that shows
only successes repeats the original failure — the skips are the signal.

## Rendering rules

- **Group by `run_id`**, not by timestamp. One dispatch is one collapsible row;
  `step` events nest inside it. Flat chronological lists are unreadable once
  `step` events exist.
- Colour by `phase`: `done` green, `fail` red, `skip` muted, `start`/`step`
  neutral. Never hide `skip` behind a filter that defaults to off.
- Show a **wasted-tick counter** for the day, prominently. `45 of 48 ticks did
  nothing` is the headline number this whole system exists to surface.
- Tail live via `/api/stream`; fall back to polling `/api/events?since=` if the
  EventSource errors. Always render correctly with JavaScript disabled for the
  first paint (server-render the last N events into the HTML).

## Reading the stream server-side

Tail the current day's file and re-open on UTC date rollover — a long-lived
handle silently stops producing events at midnight:

```python
path = EVENT_DIR / f"{datetime.now(timezone.utc):%F}.jsonl"
```
Re-evaluate that path on every poll, not once at startup.

Skip unparseable lines rather than crashing — a partially-written line is
normal when tailing a file being appended to:

```python
try:    ev = json.loads(line)
except ValueError:  continue
```

## Verify it in the browser — required, not optional

A dashboard is not done until it has been *seen*. Use the Chrome tools:

1. `mcp__claude-in-chrome__tabs_context_mcp`, then `tabs_create_mcp`.
2. `navigate` to `http://100.99.131.20:<port>/` (reachable from unit6 over
   Tailscale — confirm with `curl -s -o /dev/null -w '%{http_code}'` first).
3. `read_page` to confirm real events render, not an empty shell.
4. `read_console_messages` — a clean load must produce no errors.
5. Trigger a real task, then confirm a **new row appears without a reload**.
   This is the only proof the live tail works.

Report the HTTP status and what you actually saw. Never describe UI you have
not loaded.

## Retention

Prune with `find "$EVENT_DIR" -name '*.jsonl' -mtime +30 -delete` from the
dispatcher, not a separate cron entry — one scheduler, one place to look.
Never prune the current day's file.
