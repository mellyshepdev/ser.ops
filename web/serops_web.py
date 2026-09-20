#!/usr/bin/env python3
"""ser.ops transparency dashboard.

Renders the JSONL event stream written by lib/event.sh. Python 3 standard
library ONLY — unit7's sudo needs a password, so nothing can be pip-installed.

Contract: .claude/skills/serops-webui/SKILL.md
"""
import json, os, re, time, threading, html
from datetime import datetime, timezone, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

REPO       = os.environ.get("REPO", "/home/swoopg111/projects/ser.ops")
STATE_DIR  = os.environ.get("STATE_DIR", f"{REPO}/state")
EVENT_DIR  = os.path.join(STATE_DIR, "events")
ROTATE_DIR = os.path.join(STATE_DIR, "rotate")
ROTATE_SH  = os.path.join(REPO, "scripts", "rotate.sh")
ROTATE_LOG = os.environ.get("ROTATE_LOG", "/home/swoopg111/backups/ser.ops/rotate.log")
BIND       = os.environ.get("SEROPS_BIND", "100.99.131.20")
PORT       = int(os.environ.get("SEROPS_PORT", "8137"))

PHASES = ("tick", "skip", "start", "step", "done", "fail")


def today():
    # Re-evaluated on every call: a handle opened once silently stops
    # producing events at the UTC date rollover.
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def event_path(date=None):
    return os.path.join(EVENT_DIR, f"{date or today()}.jsonl")


def read_events(date=None, since=None, task=None, phase=None, limit=None):
    out = []
    try:
        with open(event_path(date), "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue          # partially-written line; normal while tailing
                if since and ev.get("ts", "") <= since:
                    continue
                if task and ev.get("task") != task:
                    continue
                if phase and ev.get("phase") != phase:
                    continue
                out.append(ev)
    except FileNotFoundError:
        return []
    return out[-limit:] if limit else out


def task_table():
    """Parse the TASKS array out of rotate.sh so health reflects the real
    schedule rather than a copy that drifts."""
    tasks = {}
    try:
        with open(ROTATE_SH, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = re.match(r'\s*"([a-z0-9-]+)\|(\d+)\|', line)
                if m:
                    tasks[m.group(1)] = int(m.group(2))
    except OSError:
        pass
    return tasks


def summary(date=None):
    evs = read_events(date)
    per, runs = {}, {}
    for ev in evs:
        t = ev.get("task", "?")
        p = ev.get("phase", "?")
        d = per.setdefault(t, {k: 0 for k in PHASES})
        d[p] = d.get(p, 0) + 1
        if p in ("done", "fail") and isinstance(ev.get("dur_ms"), int):
            d.setdefault("_dur", []).append(ev["dur_ms"])
        if p in ("start", "done", "fail"):
            d[f"last_{p}"] = ev.get("ts")
        runs.setdefault(ev.get("run_id"), []).append(ev)
    for t, d in per.items():
        durs = sorted(d.pop("_dur", []))
        if durs:
            d["median_ms"] = durs[len(durs) // 2]
            d["max_ms"] = durs[-1]
    return per, runs, evs


def health():
    per, _, evs = summary()
    tasks = task_table()
    now = time.time()
    ticks = sum(1 for e in evs if e.get("phase") == "tick")
    skips = [e for e in evs if e.get("phase") == "skip"]
    reasons = {}
    for e in skips:
        r = (e.get("detail") or {}).get("reason", "unknown")
        reasons[r] = reasons.get(r, 0) + 1

    rows = []
    for name, interval in sorted(tasks.items()):
        last_file = os.path.join(ROTATE_DIR, f"{name}.last")
        try:
            mtime = os.path.getmtime(last_file)
            age_min = int((now - mtime) / 60)
            last_iso = datetime.fromtimestamp(mtime, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        except OSError:
            age_min, last_iso = None, None
        d = per.get(name, {})
        rows.append({
            "task": name, "interval_min": interval,
            "last_dispatch": last_iso, "age_min": age_min,
            # A task is overdue once it has gone longer than its interval plus
            # one full 4h rotation orbit (8 tasks x 30min tick).
            "overdue": (age_min is not None and age_min > interval + 240),
            "done": d.get("done", 0), "fail": d.get("fail", 0),
            "skip": d.get("skip", 0), "median_ms": d.get("median_ms"),
        })
    return {
        "unit": "unit7", "date": today(), "generated": datetime.now(timezone.utc).isoformat(),
        "ticks_today": ticks,
        "wasted_ticks": len([e for e in skips if (e.get("detail") or {}).get("reason") in ("lock_held", "none_free")]),
        "skip_reasons": reasons,
        "tasks": rows,
        "events_today": len(evs),
        "event_file": event_path(),
    }


# ---------------------------------------------------------------- page

PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>ser.ops — live</title><style>
:root{--bg:#0a0e13;--panel:#0f151d;--line:#1e2a37;--ink:#dbe4ee;--dim:#8296ab;
--faint:#54657a;--amber:#ffb454;--green:#4ce0a3;--cyan:#5bc9ff;--red:#ff6b6b;}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);
font:14px/1.55 ui-monospace,'JetBrains Mono',Menlo,Consolas,monospace;padding:16px}
h1{font-size:16px;margin:0 0 2px;letter-spacing:.06em}
.sub{color:var(--faint);font-size:12px;margin-bottom:14px}
.cards{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:16px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:8px;
padding:10px 14px;min-width:120px;flex:1 1 120px}
.card .n{font-size:22px;font-weight:700}.card .l{color:var(--dim);font-size:11px;text-transform:uppercase}
.bad .n{color:var(--red)}.good .n{color:var(--green)}.warn .n{color:var(--amber)}
table{width:100%;border-collapse:collapse;margin-bottom:18px;font-size:12.5px}
th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);white-space:nowrap}
th{color:var(--dim);font-weight:600;font-size:11px;text-transform:uppercase}
.wrap{overflow-x:auto}
.run{background:var(--panel);border:1px solid var(--line);border-radius:8px;margin-bottom:8px}
.run>summary{cursor:pointer;padding:8px 12px;list-style:none;display:flex;gap:10px;align-items:center;flex-wrap:wrap}
.run>summary::-webkit-details-marker{display:none}
.ev{padding:4px 12px 4px 30px;border-top:1px solid var(--line);color:var(--dim);display:flex;gap:10px;flex-wrap:wrap}
.pill{border-radius:99px;padding:1px 8px;font-size:11px;border:1px solid var(--line)}
.p-done{color:var(--green);border-color:#1d5c45}.p-fail{color:var(--red);border-color:#6b2b2b}
.p-skip{color:var(--faint)}.p-start,.p-step{color:var(--cyan);border-color:#1d4b63}
.p-tick{color:var(--faint);opacity:.75}
.ts{color:var(--faint)}.det{color:var(--faint);font-size:11px}
#live{display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--faint);margin-right:6px}
#live.on{background:var(--green)}
</style></head><body>
<h1>ser.ops — unit7</h1>
<div class="sub"><span id="live"></span><span id="livetxt">connecting…</span> · event file <span id="ef"></span></div>
<div class="cards" id="cards"></div>
<div class="wrap"><table id="tasks"><thead><tr><th>task</th><th>interval</th><th>last dispatch</th>
<th>age</th><th>done</th><th>fail</th><th>skip</th><th>median</th><th></th></tr></thead><tbody></tbody></table></div>
<h1 style="font-size:13px">activity</h1>
<div class="sub">grouped by run — newest first</div>
<div id="runs"></div>
<script>
const $=s=>document.querySelector(s);
let events=[], lastTs='';
const esc=s=>String(s==null?'':s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
function card(l,n,cls){return `<div class="card ${cls||''}"><div class="n">${n}</div><div class="l">${l}</div></div>`}
async function health(){
  const h=await (await fetch('api/health')).json();
  $('#ef').textContent=h.event_file;
  const waste=h.ticks_today?Math.round(100*h.wasted_ticks/h.ticks_today):0;
  $('#cards').innerHTML=
    card('ticks today',h.ticks_today)+
    card('wasted ticks',h.wasted_ticks+' ('+waste+'%)',waste>50?'bad':waste>20?'warn':'good')+
    card('events today',h.events_today)+
    card('tasks ok',h.tasks.filter(t=>!t.overdue).length+'/'+h.tasks.length,
         h.tasks.some(t=>t.overdue)?'warn':'good')+
    card('failures',h.tasks.reduce((a,t)=>a+t.fail,0),h.tasks.some(t=>t.fail)?'bad':'good');
  $('#tasks tbody').innerHTML=h.tasks.map(t=>`<tr>
    <td>${esc(t.task)}</td><td>${t.interval_min}m</td>
    <td class="ts">${esc(t.last_dispatch||'never')}</td>
    <td>${t.age_min==null?'—':t.age_min+'m'}</td>
    <td>${t.done}</td><td>${t.fail?'<b style="color:var(--red)">'+t.fail+'</b>':0}</td>
    <td>${t.skip}</td><td>${t.median_ms==null?'—':(t.median_ms/1000).toFixed(1)+'s'}</td>
    <td>${t.overdue?'<span class="pill p-fail">overdue</span>':''}</td></tr>`).join('');
}
function render(){
  const byRun=new Map();
  for(const e of events){ if(!byRun.has(e.run_id)) byRun.set(e.run_id,[]); byRun.get(e.run_id).push(e); }
  const runs=[...byRun.entries()].reverse().slice(0,60);
  $('#runs').innerHTML=runs.map(([rid,evs])=>{
    const term=evs.find(e=>e.phase==='done'||e.phase==='fail');
    const head=evs.find(e=>e.phase==='start')||evs[0];
    const ph=term?term.phase:(evs.some(e=>e.phase==='skip')?'skip':head.phase);
    const dur=term&&term.dur_ms!=null?(term.dur_ms/1000).toFixed(1)+'s':'';
    return `<details class="run"${ph==='fail'?' open':''}><summary>
      <span class="pill p-${ph}">${ph}</span>
      <b>${esc(head.task)}</b>
      <span class="ts">${esc(head.ts)}</span>
      <span class="det">${esc(head.msg)}</span>
      <span class="det">${dur}</span>
      <span class="det">${evs.length} ev</span></summary>
      ${evs.map(e=>`<div class="ev"><span class="pill p-${e.phase}">${e.phase}</span>
        <span class="ts">${esc(e.ts.slice(11))}</span><span>${esc(e.msg)}</span>
        <span class="det">${esc(JSON.stringify(e.detail||{}))}</span>
        ${e.rc!=null?'<span class="det">rc='+e.rc+'</span>':''}</div>`).join('')}
    </details>`}).join('')||'<div class="sub">no events yet today</div>';
}
async function boot(){
  events=await (await fetch('api/events')).json();
  if(events.length) lastTs=events[events.length-1].ts;
  render(); health();
  const es=new EventSource('api/stream');
  es.onopen=()=>{$('#live').className='on';$('#livetxt').textContent='live';};
  es.onmessage=m=>{const e=JSON.parse(m.data);events.push(e);lastTs=e.ts;render();health();};
  es.onerror=()=>{ $('#live').className=''; $('#livetxt').textContent='polling'; es.close(); poll(); };
}
async function poll(){ setInterval(async()=>{
  const n=await (await fetch('api/events?since='+encodeURIComponent(lastTs))).json();
  if(n.length){ events=events.concat(n); lastTs=n[n.length-1].ts; render(); }
  health();
},5000); }
boot();
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass                                  # don't spam rotate.log

    def _send(self, code, body, ctype="application/json; charset=utf-8", extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        one = lambda k: (q.get(k) or [None])[0]
        try:
            if u.path in ("/", "/index.html"):
                return self._send(200, PAGE, "text/html; charset=utf-8")
            if u.path == "/api/health":
                return self._send(200, json.dumps(health(), indent=1))
            if u.path == "/api/events":
                return self._send(200, json.dumps(read_events(
                    one("date"), one("since"), one("task"), one("phase"),
                    int(one("limit")) if one("limit") else 400)))
            if u.path == "/api/summary":
                per, runs, _ = summary(one("date"))
                return self._send(200, json.dumps({"tasks": per, "runs": len(runs)}, indent=1))
            if u.path == "/api/stream":
                return self.stream()
            return self._send(404, json.dumps({"error": "not found"}))
        except BrokenPipeError:
            return
        except Exception as e:                          # never 500 the dashboard
            try:
                self._send(500, json.dumps({"error": str(e)}))
            except Exception:
                pass

    def stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        seen = len(read_events())
        path = event_path()
        last_beat = time.time()
        while True:
            # Re-derive the path each loop so a UTC midnight rollover is picked up.
            if event_path() != path:
                path, seen = event_path(), 0
            evs = read_events()
            if len(evs) > seen:
                for ev in evs[seen:]:
                    self.wfile.write(f"data: {json.dumps(ev)}\n\n".encode())
                self.wfile.flush()
                seen = len(evs)
            elif time.time() - last_beat > 20:
                self.wfile.write(b": keepalive\n\n")   # keep proxies from idling us out
                self.wfile.flush()
                last_beat = time.time()
            time.sleep(1)


if __name__ == "__main__":
    os.makedirs(EVENT_DIR, exist_ok=True)
    srv = ThreadingHTTPServer((BIND, PORT), Handler)
    srv.daemon_threads = True
    print(f"ser.ops dashboard on http://{BIND}:{PORT}/  events={EVENT_DIR}", flush=True)
    srv.serve_forever()
