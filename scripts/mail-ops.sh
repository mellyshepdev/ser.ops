#!/usr/bin/env bash
# mail-ops.sh — rotation task: sweep IMAP mailboxes, archive new mail to
# unit3, apply user rules (trash/keep/alert/forward), digest new arrivals to
# Linear.
#
# Accounts:  deploy/mail-accounts.conf   (GITIGNORED — app passwords)
#   # name|host|user|pass|trash_folder|folders
#   gmail|imap.gmail.com|you@gmail.com|xxxx xxxx xxxx xxxx|[Gmail]/Trash|INBOX,[Gmail]/All Mail,[Gmail]/Spam
#   The 6th field is optional — default INBOX. Comma-separated IMAP folders.
# Rules:     deploy/mail-rules.conf
#   # from:<glob>|subject:<glob>|action[,action...]   (first match wins)
#   from:*@linkedin.com|trash
#   Actions: keep (default), trash, alert (owner notify), forward (remail the
#   raw RFC822 to $FORWARD_TO over SMTP — the ebay-mail-poller's intake).
#
# Semantics:
#   - Every message not yet swept is archived (full RFC822 -> mbox.gz -> unit3)
#     BEFORE any rule action — nothing is lost, ever.
#   - Searches cover SEEN mail too: "I already read it on my phone" is exactly
#     how the 2026-09 eBay sale mails got missed — unseen-only sweeps skipped
#     them, and mails filed straight into labels never touch INBOX at all.
#     Dedup (account,folder,uid) + per-account Message-ID index make
#     re-finding old mail free and cross-folder copies single-processed.
#   - trash = copy to the account's trash folder + \Deleted + EXPUNGE.
#     Recoverable from provider trash for ~30 days. Nothing is hard-deleted.
#   - keep/default = left in place untouched.
#   - forward = remail verbatim to FORWARD_TO (default sales@) — from/subject
#     headers stay original so downstream parsers see the real mail.
#   - Digest of new arrivals -> Linear comment on LINEAR_MAIL_ISSUE +
#     ~/backups/mail/digest-<stamp>.txt.
#
# Windows: MAIL_SINCE_DAYS (default 2) bounds every folder search;
# MAIL_SINCE_DAYS_<FOLDERKEY> overrides per folder (FOLDERKEY = folder name
# uppercased, [^A-Z0-9]->_). MAIL_MAX_UIDS caps uid count per folder per run
# (default 150); MAIL_MAX_UIDS_<FOLDERKEY> likewise. For a deep backfill run
# detached, e.g.:  MAIL_SINCE_DAYS=400 MAIL_MAX_UIDS=20000 bash mail-ops.sh
set -u

REPO="${REPO:-/home/swoopg111/projects/ser.ops}"
ACCTS_FILE="${ACCTS_FILE:-$REPO/deploy/mail-accounts.conf}"
RULES_FILE="${RULES_FILE:-$REPO/deploy/mail-rules.conf}"
ENV_FILE="${ENV_FILE:-$REPO/deploy/ser_ops.env}"
STATE_DIR="$REPO/state/mail"
LOCK=${LOCK:-/tmp/serops-mail.lock}
REMOTE_HOST=${REMOTE_HOST:-unit3-tailscale}
# Metadata goes to CockroachDB, same store and same access pattern as
# backup-volumes-db.sh's volume_backups.backups. The mbox.gz on unit3 stays
# the off-box copy; the DB is the queryable index over it, so "what came in
# from whom, and did we bin it" stops being a grep over digest text files.
CR_CONTAINER=${CR_CONTAINER:-puffbase-cockroach}
CR_DB=${CR_DB:-mail_ops}
UNIT_SELF=${UNIT_NAME:-unit4}
REMOTE_DIR=${REMOTE_DIR:-backups/mail}
LOCAL_DIR=${LOCAL_DIR:-/home/swoopg111/backups/mail}
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10"
STAMP=$(date +%Y%m%d-%H%M%S)
# Forward target for the `forward` rule action — the sales pipeline mailbox on
# unit2's docker-mailserver (inbound SMTP is open on tailnet :25, no auth
# needed for delivery to hosted domains).
FORWARD_TO=${FORWARD_TO:-sales@theofficialblacksheepco.com}
# unit9's mail edge over tailnet — SMTP for forwards + owner alert mail, and
# the IMAP host used in deploy/mail-accounts.conf. The old 100.64.118.105
# (unit2-era relay) is gone from the tailnet entirely.
SMTP_HOST=${SMTP_HOST:-100.94.170.118}
SMTP_PORT=${SMTP_PORT:-465}
# Submission auth — any hosted mailbox works; set in deploy/ser_ops.env.
SMTP_USER=${SMTP_USER:-}
SMTP_PASS=${SMTP_PASS:-}
# Owner alert-mail recipient — the mailbox that actually gets read.
OWNER_NOTIFY_EMAIL=${OWNER_NOTIFY_EMAIL:-swoopg111@puff-base.com}

exec 9>"$LOCK"; flock -n 9 || { echo "mail-ops busy"; exit 0; }
mkdir -p "$STATE_DIR" "$LOCAL_DIR"
log(){ echo "[$(date +%H:%M:%S)] $*"; }

# This used to exit 0 silently, so the task consumed a rotation slot every
# cycle and looked healthy while having never archived a single message.
if [ ! -f "$ACCTS_FILE" ]; then
  log "NOT CONFIGURED: $ACCTS_FILE is missing, so no mailbox is being swept."
  log "  Copy deploy/mail-accounts.conf.example to deploy/mail-accounts.conf"
  log "  and fill in the app password field. Until then this task is a no-op."
  exit 0
fi
[ -f "$ENV_FILE" ] && . "$ENV_FILE" 2>/dev/null
LINEAR_KEY=${LINEAR_API_KEY:-}
LINEAR_ISSUE_ID=${LINEAR_MAIL_ISSUE:-}

# The host field used to be pasted straight into "imaps://$1/INBOX", which
# pinned every account to implicit TLS on 993. That does not reach the house
# mailboxes: unit9's mail edge cannot currently connect to the unit2 backend
# (haproxy logs the attempt as 1/-1/... sC), and dovecot refuses a plaintext
# LOGIN on 143, which curl reports as the very unhelpful "Login denied".
#
# So the host field now decides the transport:
#   host                -> imaps://host        implicit TLS, 993 (Gmail etc.)
#   host:143            -> imap://host:143     upgraded with STARTTLS
#   imap[s]://host:port -> used verbatim
#
# --ssl asks for a STARTTLS upgrade where one is offered and is a no-op on an
# already-encrypted imaps:// connection, so it is safe on every branch.
imap_url(){
  case "$1" in
    *://*) printf '%s' "$1" ;;
    *:143) printf 'imap://%s' "$1" ;;
    *)     printf 'imaps://%s' "$1" ;;
  esac
}

# Folder names go in the URL path — escape the characters curl and the IMAP
# layer care about ([ ] confuse curl's URL parser unless -g; spaces need %20).
folder_enc(){ printf '%s' "$1" | sed 's/\[/%5B/g; s/\]/%5D/g; s/ /%20/g; s/&/%26/g'; }
# Filesystem-safe key for per-folder state files and env-var suffixes.
folder_key(){ printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '_'; }

# Set IMAP_INSECURE=1 for a backend addressed by IP, whose certificate cannot
# match the hostname. It is still encrypted — only the name check is skipped.
IMAP_INSECURE=${IMAP_INSECURE:-0}
curl_tls(){ [ "$IMAP_INSECURE" = 1 ] && printf -- '--ssl -k' || printf -- '--ssl'; }

imap(){ # host user pass folder command -> stdout
  # shellcheck disable=SC2046  # curl_tls is deliberately word-split
  curl -sg --connect-timeout 15 --max-time 60 $(curl_tls) \
    --user "$2:$3" "$(imap_url "$1")/$(folder_enc "$4")" -X "$5" 2>/dev/null
}

fetch_msg(){ # host user pass folder uid -> RFC822 on stdout
  # shellcheck disable=SC2046
  curl -sg --connect-timeout 15 --max-time 120 $(curl_tls) \
    --user "$2:$3" "$(imap_url "$1")/$(folder_enc "$4");UID=$5" 2>/dev/null
}

# Authenticated SMTPS through unit9's mail edge — port 25 on the tailnet is
# the locator-edge relay which refuses delivery (Relay access denied); :587's
# AUTH stalls through the proxy; :465 SMTPS + any mailbox creds works.
smtp_send(){ # mail_from rcpt eml_file -> curl rc
  local extra=""
  [ -n "${SMTP_USER:-}" ] && extra="--user $SMTP_USER:$SMTP_PASS"
  # shellcheck disable=SC2086 # $extra is deliberately word-split
  curl -s --connect-timeout 10 --max-time 60 -k $extra \
    --mail-from "$1" --mail-rcpt "$2" -T "$3" \
    "${SMTP_URL:-smtps://$SMTP_HOST:$SMTP_PORT}" >/dev/null 2>&1
}

# Remail a raw RFC822 file to $FORWARD_TO — the message lands as-received
# (original From/Subject/body) so the ebay-mail-poller parses it natively.
forward_msg(){ # eml_file
  smtp_send "mail-ops@theofficialblacksheepco.com" "$FORWARD_TO" "$1"
}

# Deliver an alert as an actual email to the owner over the unit9 mail edge —
# this is the fallback/primary notify path while matrix-relay is down. The
# message body is read from stdin.
send_alert_mail(){ # subject
  local subj=$1 tmp
  tmp=$(mktemp)
  { printf 'From: ser.ops <mail-ops@theofficialblacksheepco.com>\r\n';
    printf 'To: %s\r\n' "$OWNER_NOTIFY_EMAIL";
    printf 'Subject: %s\r\n' "$subj";
    printf 'Date: %s\r\n\r\n' "$(date -R)";
    cat; printf '\r\n'; } > "$tmp"
  smtp_send "mail-ops@theofficialblacksheepco.com" "$OWNER_NOTIFY_EMAIL" "$tmp"
  local rc=$?; rm -f "$tmp"; return $rc
}

# Pull a short readable summary out of a raw RFC822 file for the digest and
# owner alert — the point of the notification is to know WHAT the mail says,
# not just that it arrived. Prefers the first MIME part (text/plain comes
# first in multipart/alternative); falls back to the post-header body for
# single-part mail; strips HTML tags, quoted-printable escapes, MIME residue.
extract_excerpt(){ # eml_file -> one-line excerpt (<= ~320 chars)
  local f=$1 b cte tmp=/tmp/ex.$$
  b=$(sed -n 's/^[Cc]ontent-[Tt]ype:.*[Bb]oundary=["'"'"']*\([^"'"'"'; ]*\).*/\1/p' "$f" \
      | head -1 | tr -d '\r')
  if [ -n "$b" ]; then
    awk -v b="--$b" -v out="$tmp" '
      index($0,b)==1 { if(part) exit; part=1; ph=1; next }
      part && ph && /^[Cc]ontent-[Tt]ransfer-[Ee]ncoding:/ { print > out".cte" }
      part && ph && /^[ \t\r]*$/ { ph=0; next }
      part && !ph { print > out }
    ' "$f"
    cte=$(cat "$tmp.cte" 2>/dev/null | tr -d '\r'); rm -f "$tmp.cte"
    case "$cte" in *base64*|*BASE64*) base64 -d "$tmp" 2>/dev/null > "$tmp.d" && mv "$tmp.d" "$tmp";; esac
  else
    awk 'f{print} /^[ \t\r]*$/{f=1}' "$f" > "$tmp"
    if grep -im1 '^Content-Transfer-Encoding: *base64' "$f" >/dev/null; then
      base64 -d "$tmp" 2>/dev/null > "$tmp.d" && mv "$tmp.d" "$tmp"
    fi
  fi
  grep -v '^--[A-Za-z0-9]' "$tmp" | sed 's/^Content-[A-Za-z-]*:.*//' \
    | sed -e 's/<[^>]*>/ /g' -e 's/&nbsp;/ /g' -e 's/&amp;/\&/g' \
          -e 's/=3D/=/g' -e 's/=[0-9A-Fa-f][0-9A-Fa-f]/ /g' -e 's/=$//' \
    | tr '\n\t' '  ' | tr -d '\r' | tr -s ' ' \
    | sed 's/^ *//;s/ *$//' | cut -c1-320
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Order/shipping watcher — every archived message is scanned for marketplace
# sale and shipment notices (eBay "you made the sale", "remember to ship",
# carrier tracking mails). Extracted fields POST to the inventory API, which
# settles stock + stamps tracking/buyer on sold_items. Config via env:
#   INVENTORY_SALE_URL — /api/ebay/sale endpoint (empty disables entirely)
#   INVENTORY_ADMIN_KEY — X-Admin-Key for that API
# ---------------------------------------------------------------------------
INVENTORY_SALE_URL=${INVENTORY_SALE_URL:-}
INVENTORY_ADMIN_KEY=${INVENTORY_ADMIN_KEY:-${SCANNER_ADMIN_KEY:-}}

order_parse(){ # account msg_file — silent unless a pattern fires
  [ -z "$INVENTORY_SALE_URL" ] && return 0
  local f=$2 subj body order itemnum buyer shipto track total carrier itemname
  subj=$(grep -im1 '^Subject:' "$f" | sed 's/^Subject: *//;s/\r//')
  case "$subj" in
    *"made the sale"*|*"emember to ship"*|*"rder confirmed"*|*"rder details"*|\
    *"has shipped"*|*"hipped"*|*"racking"*|*"hipping label"*|*"elivery"*) ;;
    *) return 0 ;;
  esac
  # Flatten to one line: join QP soft-breaks, strip tags, decode the common
  # entities. Order/item/tracking numbers are pure ASCII so they survive this.
  body=$(awk '{ line=$0; while (line ~ /=$/) { if (getline nxt) line=substr(line,1,length(line)-1) nxt; else break } print line }' "$f" \
         | sed -e 's/<[^>]*>/ /g' -e 's/&nbsp;/ /g' -e 's/&amp;/\&/g' \
               -e 's/=3[Dd]/=/g' -e 's/=[0-9A-Fa-f][0-9A-Fa-f]/ /g' \
         | tr '\n\t' '  ' | tr -d '\r' | tr -s ' ')
  order=$(printf '%s' "$body" | grep -oE '[0-9]{2}-[0-9]{5}-[0-9]{5}' | head -1)
  [ -z "$order" ] && return 0
  itemnum=$(printf '%s' "$body" | grep -ioE 'item number.{0,90}' | head -1 \
            | grep -oE '[0-9]{10,14}' | head -1)
  # eBay lays fields out 'Item Number <n> Buyer <user> Qty' — anchor the buyer
  # lookup after the item-number hit so 'buyer is waiting' doesn't match.
  buyer=$(printf '%s' "$body" | grep -ioE 'item number.{0,250}' | head -1 \
          | grep -ioE 'buyer[^a-z0-9_]{0,40}[a-z0-9_]+' | head -1 \
          | sed -E 's/^[Bb]uyer[^A-Za-z0-9_]*//')
  [ -z "$buyer" ] && buyer=$(printf '%s' "$body" \
          | grep -ioE 'buyer[^a-z0-9_]{0,40}[a-z0-9_]+' \
          | grep -ivE 'buyer[^a-z0-9_]+(is|was|the|a|will|has|paid|can|still|now)' \
          | head -1 | sed -E 's/^[Bb]uyer[^A-Za-z0-9_]*//')
  shipto=$(printf '%s' "$body" | grep -ioE 'ship to.{0,140}' | head -1 \
           | sed -E 's/^[Ss]hip to *//;s/ (Package|package|Qty|Item|tracking|Tracking|Total).*$//' )
  track=$(printf '%s' "$body" | grep -oE '1Z[0-9A-Z]{16}|9[0-9]{19,22}|TBA[0-9]{9,13}' | head -1)
  total=$(printf '%s' "$body" | grep -ioE 'total charged.{0,60}|order total.{0,60}|total:.{0,60}' | head -1 \
          | grep -oE '[0-9]+\.[0-9]{2}' | head -1)
  case "$track" in
    1Z*) carrier="UPS" ;; 9*) carrier="USPS" ;; TBA*) carrier="Amazon" ;; *) carrier="" ;;
  esac
  itemname=$(printf '%s' "$subj" | sed -E 's/.*(made the sale for|emember to ship) //I')

  # Sale email (item resolvable) vs shipping-only email.
  if [ -n "$itemnum" ]; then
    payload="{\"order_id\":\"$order\",\"buyer\":\"$buyer\",\"ship_to\":\"$shipto\",\"total\":\"$total\",\"items\":[{\"item_number\":\"$itemnum\",\"qty\":1,\"name\":\"$(printf '%s' "$itemname" | sed 's/"/\\"/g')\"}]}"
  else
    [ -z "$track" ] && [ -z "$buyer" ] && [ -z "$shipto" ] && return 0
    payload="{\"order_id\":\"$order\",\"tracking_number\":\"$track\",\"carrier\":\"$carrier\",\"buyer\":\"$buyer\",\"ship_to\":\"$shipto\",\"total\":\"$total\"}"
  fi
  resp=$(curl -s --max-time 15 -X POST "$INVENTORY_SALE_URL" \
        -H 'Content-Type: application/json' \
        -H "X-Admin-Key: $INVENTORY_ADMIN_KEY" \
        -d "$payload" 2>/dev/null)
  log "$1: orderwatch $order -> ${resp:-no-response}"
}

# SQL string literal — same quoting helper as backup-volumes-db.sh.
sqlq(){ printf "'%s'" "${1//\'/\'\'}"; }

crsql(){ docker exec "$CR_CONTAINER" cockroach sql --insecure "$@" 2>/dev/null; }

db_up(){ crsql -e "SELECT 1" >/dev/null 2>&1; }

ensure_schema(){
  crsql -e "CREATE DATABASE IF NOT EXISTS $CR_DB" >/dev/null 2>&1 || return 1
  crsql -d "$CR_DB" -e "
    CREATE TABLE IF NOT EXISTS messages (
      id        UUID DEFAULT gen_random_uuid() PRIMARY KEY,
      unit      STRING NOT NULL,
      account   STRING NOT NULL,
      uid       STRING NOT NULL,
      msg_from  STRING,
      subject   STRING,
      sent_raw  STRING,
      action    STRING,
      archive   STRING,
      swept_at  TIMESTAMPTZ NOT NULL DEFAULT now()
    );
    CREATE TABLE IF NOT EXISTS sweeps (
      id         UUID DEFAULT gen_random_uuid() PRIMARY KEY,
      unit       STRING NOT NULL,
      run_id     STRING,
      accounts   INT, new_msgs INT, archived INT, trashed INT,
      note       STRING,
      swept_at   TIMESTAMPTZ NOT NULL DEFAULT now()
    );" >/dev/null 2>&1
  # 2026-09-30: multi-folder sweeping — uid is only unique per folder, and the
  # same message appears under DIFFERENT uids in INBOX vs All Mail. folder +
  # msg_id columns carry that; dedup keys on (account, folder, uid) with
  # msg_id checked before body fetch so cross-folder copies are swept once.
  # Each migration runs separately and is individually idempotent — CRDB has
  # no ADD CONSTRAINT IF NOT EXISTS and rejects DROP CONSTRAINT on UNIQUE
  # indexes (DROP INDEX CASCADE is the form it accepts).
  crsql -d "$CR_DB" -e \
    "ALTER TABLE messages ADD COLUMN IF NOT EXISTS folder STRING NOT NULL DEFAULT 'INBOX'" >/dev/null 2>&1
  crsql -d "$CR_DB" -e \
    "ALTER TABLE messages ADD COLUMN IF NOT EXISTS msg_id STRING" >/dev/null 2>&1
  crsql -d "$CR_DB" -e \
    "ALTER TABLE messages ADD COLUMN IF NOT EXISTS excerpt STRING" >/dev/null 2>&1
  crsql -d "$CR_DB" -e \
    "DROP INDEX IF EXISTS messages@messages_account_uid_key CASCADE" >/dev/null 2>&1
  crsql -d "$CR_DB" --format=csv -e "SHOW CONSTRAINTS FROM messages" 2>/dev/null \
    | grep -q messages_acct_fold_uid_key \
    || crsql -d "$CR_DB" -e \
      "ALTER TABLE messages ADD CONSTRAINT messages_acct_fold_uid_key
       UNIQUE (account, folder, uid)" >/dev/null 2>&1
  return 0
}

# Bare ON CONFLICT DO NOTHING (no arbiter) — skips rows violating whichever
# unique constraint is live, so the mid-migration window is still safe.
record_msg(){ # account folder uid from subject date action archive msg_id excerpt
  crsql -d "$CR_DB" -e "INSERT INTO messages
      (unit, account, folder, uid, msg_from, subject, sent_raw, action, archive, msg_id, excerpt)
    VALUES ($(sqlq "$UNIT_SELF"), $(sqlq "$1"), $(sqlq "$2"), $(sqlq "$3"),
            $(sqlq "$4"), $(sqlq "$5"), $(sqlq "$6"), $(sqlq "$7"),
            $(sqlq "$8"), $(sqlq "$9"), $(sqlq "${10:-}"))
    ON CONFLICT DO NOTHING" >/dev/null 2>&1
}

record_sweep(){ # accounts new archived trashed forwarded note
  crsql -d "$CR_DB" -e "INSERT INTO sweeps
      (unit, run_id, accounts, new_msgs, archived, trashed, note)
    VALUES ($(sqlq "$UNIT_SELF"), $(sqlq "${RUN_ID:-}"), ${1:-0}, ${2:-0},
            ${3:-0}, ${4:-0}, $(sqlq "${5:-}"))" >/dev/null 2>&1
}

rule_action(){ # from subject account -> action token set (keep|trash|alert|forward,...)
  # `field` used to be parsed and then thrown away, so from:/subject: were
  # both matched against the two concatenated — a from: rule could fire on a
  # subject line. And $glob was quoted inside *"$glob"*, which made * a
  # literal asterisk: the documented from:*@linkedin.com example could never
  # match anything. Unquoted, wrapped in *...*, so plain substrings still work.
  # `account:` matches the mailbox name (first field of the accounts row) so a
  # whole mailbox can be routed — e.g. `account:partnerships|alert`.
  local from=$1 subj=$2 acct=$3 pat act field glob hay
  [ -f "$RULES_FILE" ] || { echo keep; return; }
  while IFS='|' read -r pat act; do
    case "$pat" in ''|\#*) continue;; esac
    field=${pat%%:*}; glob=${pat#*:}
    case "$field" in
      from)            hay=$from ;;
      subject)         hay=$subj ;;
      account|mailbox) hay=$acct ;;
      *)               hay="$from $subj" ;;
    esac
    # shellcheck disable=SC2254  # $glob is deliberately a pattern here
    case "$hay" in
      *$glob*) echo "${act:-keep}"; return;;
    esac
  done < "$RULES_FILE"
  echo keep
}

has_act(){ case ",$1," in *",$2,"*) return 0;; esac; return 1; }

notify(){
  local body=$1
  printf '%s\n' "$body" > "$LOCAL_DIR/digest-$STAMP.txt"
  if [ -n "$LINEAR_KEY" ] && [ -n "$LINEAR_ISSUE_ID" ]; then
    curl -s -X POST "https://api.linear.app/graphql" \
      -H "Authorization: $LINEAR_KEY" -H "Content-Type: application/json" \
      -d "$(jq -nc --arg i "$LINEAR_ISSUE_ID" --arg b "$body" \
        '{query:"mutation($i:String!,$b:String!){ commentCreate(input:{issueId:$i, body:$b}){ success } }",variables:{i:$i,b:$b}}')" \
      >/dev/null 2>&1 || true
  fi
}

DB_OK=0
if db_up && ensure_schema; then
  DB_OK=1
  log "cockroach $CR_DB ready — metadata will be recorded"
else
  log "cockroach unreachable — falling back to seen-files, archives still ship"
fi

digest=""
alerts=""
total_new=0 total_arch=0 total_trash=0 total_fwd=0 total_accts=0

# sweep_folder name host user pass trashfld folder — returns via globals:
#   sf_digest, sf_alerts, sf_new, sf_arch, sf_trash, sf_fwd, and appends
#   archived messages to $mbox_tmp (created by the caller).
sweep_folder(){
  local name=$1 host=$2 user=$3 pass=$4 trashfld=$5 folder=$6
  local fkey days since uids seen_file known msgid_file
  fkey=$(folder_key "$folder")
  # Per-folder window + cap: INBOX keeps the tight default; deeper folders
  # (All Mail) are allowed a wider window via env so past mail is covered.
  eval "days=\${MAIL_SINCE_DAYS_$(printf '%s' "$fkey" | tr 'a-z' 'A-Z'):-\${MAIL_SINCE_DAYS:-2}}"
  eval "maxuids=\${MAIL_MAX_UIDS_$(printf '%s' "$fkey" | tr 'a-z' 'A-Z'):-\${MAIL_MAX_UIDS:-150}}"
  since=$(date -d "-$days days" +%d-%b-%Y 2>/dev/null || date +%d-%b-%Y)

  seen_file="$STATE_DIR/seen-$name-$fkey"
  msgid_file="$STATE_DIR/msgid-$name"
  # Folder-scoped seen files are new (2026-09-30) — seed INBOX's from the
  # legacy single seen-file so its window isn't re-archived wholesale.
  if [ "$folder" = "INBOX" ] && [ -f "$STATE_DIR/seen-$name" ] \
      && [ ! -s "$seen_file" ]; then
    cp "$STATE_DIR/seen-$name" "$seen_file"
  fi
  touch "$seen_file" "$msgid_file"

  # Prefetch the known-uid set once (DB ∪ seen-file) instead of a cockroach
  # round-trip per uid — with seen mail in scope the candidate list is the
  # whole window, and per-uid queries turned sweeps into multi-minute stalls.
  known=$(mktemp)
  if [ "$DB_OK" = 1 ]; then
    crsql -d "$CR_DB" --format=csv -e \
      "SELECT uid FROM messages WHERE account=$(sqlq "$name") AND folder=$(sqlq "$folder")" \
      | tail -n +2 | tr -d '\r' >> "$known"
  fi
  cat "$seen_file" >> "$known"

  # IMAP speaks CRLF. Without the \r strip the last token off "* SEARCH 1"
  # is "1\r", which fails ^[0-9]+$ — so this found zero UIDs on every run and
  # reported "nothing new" no matter how full the mailbox was.
  #
  # Bound the search: a raw "UID SEARCH" on a Gmail All Mail holding tens of
  # thousands of messages makes Gmail silently drop the connection (verified:
  # 43.5K unseen, server closes after the command). A rolling SINCE window
  # keeps every sweep small; MAIL_MAX_UIDS caps worst case. SEEN mail is in
  # scope on purpose — dedup, not unreadness, is what makes a message "new".
  uids=$(imap "$host" "$user" "$pass" "$folder" "UID SEARCH SINCE $since" \
    | tr -d '\r' | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n \
    | tail -n "$maxuids" | while read -r u; do
        grep -Fxq "$u" "$known" || echo "$u"
      done)
  rm -f "$known"
  [ -z "$uids" ] && { log "$name/$folder: nothing new"; return; }

  local n=0
  for u in $uids; do
    # headers for digest + rules + cross-folder dedup (one fetch serves all)
    hdr=$(imap "$host" "$user" "$pass" "$folder" \
      "UID FETCH $u (BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID)])")
    from=$(echo "$hdr" | grep -i '^From:' | head -1 | sed 's/^[Ff]rom: *//;s/\r//')
    subj=$(echo "$hdr" | grep -i '^Subject:' | head -1 | sed 's/^[Ss]ubject: *//;s/\r//')
    date_raw=$(echo "$hdr" | grep -i '^Date:' | head -1 | sed 's/^[Dd]ate: *//;s/\r//')
    msg_id=$(echo "$hdr" | grep -i '^Message-Id:' | head -1 | sed 's/^[Mm]essage-[Ii]d: *//;s/\r//')
    # Same mail re-listed under another folder's uid — already swept once.
    if [ -n "$msg_id" ] && grep -Fxq "$msg_id" "$msgid_file"; then
      echo "$u" >> "$seen_file"; continue
    fi
    msg_tmp=$(mktemp)
    # archive first — always
    if ! fetch_msg "$host" "$user" "$pass" "$folder" "$u" > "$msg_tmp" \
        || [ ! -s "$msg_tmp" ]; then
      rm -f "$msg_tmp"; continue
    fi
    cat "$msg_tmp" >> "$mbox_tmp"; total_arch=$((total_arch+1))
    order_parse "$name" "$msg_tmp"
    # Header FETCH can come back unparsable (that was the "blank notification"
    # bug) — the full RFC822 is already on disk, so recover the fields from it.
    [ -z "$from" ] && from=$(grep -im1 '^From:' "$msg_tmp" | sed 's/^From: *//;s/\r//')
    [ -z "$subj" ] && subj=$(grep -im1 '^Subject:' "$msg_tmp" | sed 's/^Subject: *//;s/\r//')
    [ -z "$subj" ] && subj="(no subject)"
    act=$(rule_action "$from" "$subj" "$name")
    excerpt=$(extract_excerpt "$msg_tmp")
    mark=""
    if has_act "$act" forward; then
      if forward_msg "$msg_tmp"; then
        mark="[fwd->$FORWARD_TO]"; total_fwd=$((total_fwd+1)); sf_fwd=$((sf_fwd+1))
      else
        # Don't mark seen — the next sweep retries the forward. The message
        # stays archived (it's already in the mbox) and the DB insert is
        # dedup'd, so the retry only costs a refetch.
        log "$name/$folder: forward failed for uid $u — will retry next sweep"
        rm -f "$msg_tmp"; continue
      fi
    fi
    if has_act "$act" trash; then
      imap "$host" "$user" "$pass" "$folder" "UID COPY $u \"$trashfld\"" >/dev/null
      imap "$host" "$user" "$pass" "$folder" "UID STORE $u +FLAGS.SILENT (\\Deleted)" >/dev/null
      imap "$host" "$user" "$pass" "$folder" "EXPUNGE" >/dev/null
      total_trash=$((total_trash+1)); sf_trash=$((sf_trash+1))
      mark="$mark[trashed]"
    elif has_act "$act" alert; then
      mark="$mark[ALERT]"
      alerts="${alerts}${name}/${folder} | ${subj} | ${from}\n    ${excerpt}\n"
    fi
    rm -f "$msg_tmp"
    digest="${digest}${name}/${folder} | ${subj} | ${from} ${mark}\n    ${excerpt}\n"
    [ "$DB_OK" = 1 ] && record_msg "$name" "$folder" "$u" "$from" "$subj" \
        "$date_raw" "$act" "$REMOTE_HOST:$REMOTE_DIR/$name/$month.mbox.gz" "$msg_id" "$excerpt"
    echo "$u" >> "$seen_file"
    [ -n "$msg_id" ] && echo "$msg_id" >> "$msgid_file"
    n=$((n+1)); sf_new=$((sf_new+1)); total_new=$((total_new+1))
  done
}

while IFS='|' read -r name host user pass trashfld folders; do
  case "$name" in ''|\#*) continue;; esac
  [ -z "${pass:-}" ] && { log "$name: no password configured — skip"; continue; }
  trashfld=${trashfld:-Trash}
  folders=${folders:-INBOX}

  total_accts=$((total_accts+1))
  month=$(date +%Y%m)
  mbox_tmp=$(mktemp)
  sf_new=0 sf_arch=0 sf_trash=0 sf_fwd=0
  sf_digest="" sf_alerts=""

  IFS=',' read -ra folder_list <<< "$folders"
  for folder in "${folder_list[@]}"; do
    sweep_folder "$name" "$host" "$user" "$pass" "$trashfld" "$folder"
  done

  # ship the month's archive (append — decompress, concat, recompress)
  # ssh MUST run -n here: it reads stdin, and stdin inside this loop is
  # mail-accounts.conf — an interactive ssh eats the unprocessed account rows.
  if [ -s "$mbox_tmp" ]; then
    remote_file="$REMOTE_DIR/$name/$month.mbox.gz"
    ssh -n $SSH_OPTS "$REMOTE_HOST" "mkdir -p ~/$REMOTE_DIR/$name" 2>/dev/null
    { ssh -n $SSH_OPTS "$REMOTE_HOST" "zcat ~/$remote_file 2>/dev/null"; cat "$mbox_tmp"; } \
      | gzip -1 | ssh $SSH_OPTS "$REMOTE_HOST" "cat > ~/$remote_file.new && mv ~/$remote_file.new ~/$remote_file" \
      && log "$name: archived $sf_new msgs -> $remote_file" \
      || { mkdir -p "$LOCAL_DIR/$name"; cat "$mbox_tmp" | gzip -1 >> "$LOCAL_DIR/$name/$month.mbox.gz";
           log "$name: remote failed — archived locally"; }
  fi
  rm -f "$mbox_tmp"
done < "$ACCTS_FILE"

if [ "$total_new" -gt 0 ]; then
  notify "$(printf "mail sweep %s — %d new (%d archived, %d forwarded, %d trashed)\n\n%b" \
    "$STAMP" "$total_new" "$total_arch" "$total_fwd" "$total_trash" "$digest")"
fi

# Important mail -> owner. Two paths: an actual alert email over the unit9
# mail edge (always — it carries the excerpts, so the owner reads WHAT came
# in without opening the mailbox), and matrix-relay if one is configured.
# matrix-relay ESCALATE matches "MAIL ALERT"; the old 100.64.118.105 relay is
# gone from the tailnet, so MAIL_ALERT_URL stays empty unless a live relay
# is pointed at.
MAIL_ALERT_URL=${MAIL_ALERT_URL:-}
if [ -n "$alerts" ]; then
  n_alert=$(printf '%b' "$alerts" | grep -c '|')
  body=$(printf "MAIL ALERT — %d important email(s) arrived:\n\n%b" "$n_alert" "$alerts")
  printf '%s' "$body" | send_alert_mail "MAIL ALERT — $n_alert important email(s)" \
    && log "alert mail sent to $OWNER_NOTIFY_EMAIL for $n_alert message(s)" \
    || log "WARN: owner alert mail failed (SMTP $SMTP_HOST:$SMTP_PORT unreachable)"
  if [ -n "$MAIL_ALERT_URL" ]; then
    body_json=$(printf '%s' "$body" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' '\036' | sed 's/\x1e/\\n/g')
    curl -s --connect-timeout 8 --max-time 15 -X POST "$MAIL_ALERT_URL" \
      -H "Content-Type: application/json" \
      -d "{\"text\": \"$body_json\"}" \
      >/dev/null 2>&1 \
      && log "also relayed alert to matrix-relay" \
      || log "WARN: matrix-relay alert failed (relay unreachable)"
  fi
fi
[ "$DB_OK" = 1 ] && record_sweep "$total_accts" "$total_new" "$total_arch" \
    "$total_trash" "swept $total_accts account(s), $total_fwd forwarded"
log "done: $total_new new, $total_arch archived, $total_fwd forwarded, $total_trash trashed"
