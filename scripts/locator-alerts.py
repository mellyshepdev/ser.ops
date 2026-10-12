#!/usr/bin/env python3
"""
locator-alerts.py — ser.ops watcher for Locator device alerts.

Polls Locator's /api/alerts (offline / gone silent / low battery off the
charger, the same rules the dashboard flashes red) and sends what changed
to every configured channel: email, Slack and Matrix.

  new alert      → "🚨 <device>: OFFLINE" etc., immediately
  still in alert → reminder every ALERT_REMIND_HOURS, for ALERT_REMIND_DAYS
  cleared        → "✅ <device> back to normal"
  Locator down   → one alert after LOCATOR_DOWN_CHECKS failed polls, one on recovery

One message per poll that has news, never one per device per poll. State
lives in $STATE_DIR/locator-alerts.json, so a restart doesn't re-announce.

Channels (each skipped quietly when unconfigured — see deploy/ser_ops.env):
  email   SMTP_USER/SMTP_PASS over SMTPS to SMTP_HOST:SMTP_PORT (unit9 mail
          edge), to OWNER_NOTIFY_EMAIL — same route mail-ops alerts use
  Slack   SLACK_WEBHOOK_URL (incoming webhook)
  Matrix  MATRIX_HOMESERVER_URL + MATRIX_ACCESS_TOKEN + MATRIX_ROOM_ID

Run: python3 scripts/locator-alerts.py            (loop, ALERT_POLL_SECONDS)
     python3 scripts/locator-alerts.py --once     (one poll)
     python3 scripts/locator-alerts.py --test     (send a test message to every channel)
Standard library only — the ser.ops image has no requests.
"""

import json
import os
import smtplib
import ssl
import sys
import time
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from email.message import EmailMessage

ENV = os.environ.get
LOCATOR_URL = ENV("LOCATOR_URL", "http://100.123.158.58:50500").rstrip("/")
GRID_KEY = ENV("LOCATOR_GRID_KEY", "")
POLL = int(ENV("ALERT_POLL_SECONDS", "60"))
REMIND_S = float(ENV("ALERT_REMIND_HOURS", "6")) * 3600
REMIND_MAX_S = float(ENV("ALERT_REMIND_DAYS", "3")) * 86400
DOWN_CHECKS = int(ENV("LOCATOR_DOWN_CHECKS", "3"))
STATE_FILE = os.path.join(ENV("STATE_DIR", "/srv/ser.ops/state"), "locator-alerts.json")
DASHBOARD = ENV("LOCATOR_DASHBOARD_URL", "https://locator.network")

SMTP_HOST = ENV("SMTP_HOST", "100.94.170.118")
SMTP_PORT = int(ENV("SMTP_PORT", "465"))
SMTP_USER, SMTP_PASS = ENV("SMTP_USER", ""), ENV("SMTP_PASS", "")
MAIL_TO = ENV("OWNER_NOTIFY_EMAIL", "swoopg111@puff-base.com")
MAIL_FROM = ENV("ALERT_MAIL_FROM", "locator-alerts@theofficialblacksheepco.com")

SLACK = ENV("SLACK_WEBHOOK_URL", "")
if "YOUR" in SLACK or "HERE" in SLACK:          # the shipped placeholder
    SLACK = ""
MX_URL, MX_TOKEN, MX_ROOM = ENV("MATRIX_HOMESERVER_URL", ""), ENV("MATRIX_ACCESS_TOKEN", ""), ENV("MATRIX_ROOM_ID", "")

REASON = {"offline": "OFFLINE", "stale": "GONE SILENT", "battery": "LOW BATTERY"}


def log(msg):
    print(f"{datetime.now(timezone.utc):%Y-%m-%dT%H:%M:%SZ} {msg}", flush=True)


def describe(a):
    r = REASON.get(a["reason"], a["reason"].upper())
    if a["reason"] == "battery" and a.get("battery") is not None:
        r += f" {a['battery']:.0f}%"
    secs = a.get("silent_seconds")
    if a["reason"] in ("offline", "stale") and secs:
        r += f" (last heard {ago(secs)} ago)"
    return f"{a['id']}: {r}"


def ago(secs):
    secs = int(secs)
    for unit, n in (("d", 86400), ("h", 3600), ("m", 60)):
        if secs >= n:
            return f"{secs // n}{unit}"
    return f"{secs}s"


# ── channels ────────────────────────────────────────────────────────────────
def send_email(subject, text):
    if not (SMTP_USER and SMTP_PASS):
        return None
    msg = EmailMessage()
    msg["From"], msg["To"], msg["Subject"] = MAIL_FROM, MAIL_TO, subject
    msg.set_content(text)
    ctx = ssl.create_default_context()
    ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE   # tailnet IP, same as mail-ops' curl -k
    with smtplib.SMTP_SSL(SMTP_HOST, SMTP_PORT, context=ctx, timeout=30) as s:
        s.login(SMTP_USER, SMTP_PASS)
        s.send_message(msg, from_addr=SMTP_USER, to_addrs=[MAIL_TO])
    return True


def _post_json(url, payload, headers=None, method="POST"):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), method=method,
                                 headers={"Content-Type": "application/json", **(headers or {})})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.status


def send_slack(subject, text):
    if not SLACK:
        return None
    return _post_json(SLACK, {"text": f"*{subject}*\n{text}"}) == 200


def send_matrix(subject, text):
    if not (MX_URL and MX_TOKEN and MX_ROOM):
        return None
    url = (f"{MX_URL.rstrip('/')}/_matrix/client/v3/rooms/{urllib.parse.quote(MX_ROOM)}"
           f"/send/m.room.message/{uuid.uuid4().hex}")
    return _post_json(url, {"msgtype": "m.text", "body": f"{subject}\n{text}"},
                      {"Authorization": f"Bearer {MX_TOKEN}"}, method="PUT") == 200


def notify(subject, lines):
    text = "\n".join(lines) + f"\n\nDashboard: {DASHBOARD}"
    sent = []
    for name, fn in (("email", send_email), ("slack", send_slack), ("matrix", send_matrix)):
        try:
            ok = fn(subject, text)
        except Exception as e:                    # one dead channel must not mute the others
            ok = False
            log(f"WARN {name} failed: {e}")
        if ok:
            sent.append(name)
        elif ok is False:
            log(f"WARN {name} did not accept the message")
    log(f"notified [{', '.join(sent) or 'no channel'}]: {subject} — {'; '.join(lines)}")
    return sent


# ── state + polling ─────────────────────────────────────────────────────────
def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"alerts": {}, "down_streak": 0, "down_announced": False}


def save_state(st):
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(st, f, indent=1)
    os.replace(tmp, STATE_FILE)


def fetch_alerts():
    req = urllib.request.Request(f"{LOCATOR_URL}/api/alerts", headers={"X-Locator-Grid-Key": GRID_KEY})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)["alerts"]


def poll(st):
    now = time.time()
    try:
        current = {a["id"]: a for a in fetch_alerts()}
    except Exception as e:
        st["down_streak"] = st.get("down_streak", 0) + 1
        log(f"Locator poll failed ({st['down_streak']}): {e}")
        if st["down_streak"] >= DOWN_CHECKS and not st.get("down_announced"):
            notify("🚨 Locator unreachable",
                   [f"ser.ops cannot read {LOCATOR_URL}/api/alerts ({st['down_streak']} checks in a row): {e}",
                    "Device alerts are blind until it is back."])
            st["down_announced"] = True
        return
    if st.get("down_announced"):
        notify("✅ Locator reachable again", ["Device alert checks have resumed."])
    st["down_streak"], st["down_announced"] = 0, False

    known = st.setdefault("alerts", {})
    new, changed, remind, cleared = [], [], [], []
    for did, a in current.items():
        k = known.get(did)
        if k is None:
            new.append(a)
            known[did] = {"reason": a["reason"], "since": now, "last_notified": now}
        elif k["reason"] != a["reason"]:
            changed.append(a)
            k.update(reason=a["reason"], last_notified=now)
        elif now - k["last_notified"] >= REMIND_S and now - k["since"] <= REMIND_MAX_S:
            remind.append((a, now - k["since"]))
            k["last_notified"] = now
    for did in [d for d in known if d not in current]:
        cleared.append(did)
        known.pop(did)

    lines = ([f"🚨 {describe(a)}" for a in new] + [f"⚠️ {describe(a)} (changed)" for a in changed] +
             [f"⏰ still: {describe(a)} — for {ago(dur)}" for a, dur in remind] +
             [f"✅ {d} back to normal" for d in cleared])
    if not lines:
        return
    bad = len(new) + len(changed)
    if bad:
        subject = f"🚨 Locator: {bad} device{'s' if bad > 1 else ''} need attention"
    elif remind:
        subject = f"⏰ Locator: {len(remind)} device{'s' if len(remind) > 1 else ''} still in alert"
    else:
        subject = "✅ Locator: devices back to normal"
    notify(subject, lines)


def main():
    if "--test" in sys.argv:
        sent = notify("🔔 Locator alerts test", ["This is a test from ser.ops locator-alerts."])
        sys.exit(0 if sent else 1)
    if not GRID_KEY:
        log("WARN LOCATOR_GRID_KEY is not set — /api/alerts will refuse every poll")
    log(f"watching {LOCATOR_URL} every {POLL}s; channels: "
        f"email={'on' if SMTP_USER else 'off'} slack={'on' if SLACK else 'off'} "
        f"matrix={'on' if MX_URL and MX_TOKEN and MX_ROOM else 'off'}")
    st = load_state()
    while True:
        try:
            poll(st)
            save_state(st)
        except Exception as e:
            log(f"poll error: {e}")
        if "--once" in sys.argv:
            return
        time.sleep(POLL)


if __name__ == "__main__":
    main()
