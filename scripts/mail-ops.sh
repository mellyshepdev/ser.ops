#!/usr/bin/env bash
# mail-ops.sh — rotation task: sweep IMAP inboxes, archive new mail to
# unit3, apply user rules (trash/keep), digest new arrivals to Linear.
#
# Accounts:  deploy/mail-accounts.conf   (GITIGNORED — app passwords)
#   # name|host|user|pass|trash_folder
#   gmail|imap.gmail.com|you@gmail.com|xxxx xxxx xxxx xxxx|[Gmail]/Trash
# Rules:     deploy/mail-rules.conf
#   # from:<glob>|subject:<glob>|keep|trash   (first match wins)
#   from:*@linkedin.com|trash
#
# Semantics:
#   - Every unseen message is archived (full RFC822 -> mbox.gz -> unit3)
#     BEFORE any rule action — nothing is lost, ever.
#   - trash = copy to the account's trash folder + \Deleted + EXPUNGE.
#     Recoverable from provider trash for ~30 days. Nothing is hard-deleted.
#   - keep/default = left in the inbox untouched.
#   - Digest of new arrivals -> Linear comment on LINEAR_MAIL_ISSUE +
#     ~/backups/mail/digest-<stamp>.txt.
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
UNIT_SELF=${UNIT_NAME:-unit7}
REMOTE_DIR=${REMOTE_DIR:-backups/mail}
LOCAL_DIR=${LOCAL_DIR:-/home/swoopg111/backups/mail}
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10"
STAMP=$(date +%Y%m%d-%H%M%S)

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

imap(){ # host user pass command -> stdout
  curl -s --connect-timeout 15 --max-time 60 \
    --user "$2:$3" "imaps://$1/INBOX" -X "$4" 2>/dev/null
}

fetch_msg(){ # host user pass uid -> RFC822 on stdout
  curl -s --connect-timeout 15 --max-time 120 \
    --user "$2:$3" "imaps://$1/INBOX;UID=$4" 2>/dev/null
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
      swept_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
      UNIQUE (account, uid)
    );
    CREATE TABLE IF NOT EXISTS sweeps (
      id         UUID DEFAULT gen_random_uuid() PRIMARY KEY,
      unit       STRING NOT NULL,
      run_id     STRING,
      accounts   INT, new_msgs INT, archived INT, trashed INT,
      note       STRING,
      swept_at   TIMESTAMPTZ NOT NULL DEFAULT now()
    );" >/dev/null 2>&1
}

# UNIQUE(account,uid) makes this the dedup source of truth. DO NOTHING means a
# re-run after a crash re-archives nothing and re-trashes nothing.
record_msg(){ # account uid from subject date action archive
  crsql -d "$CR_DB" -e "INSERT INTO messages
      (unit, account, uid, msg_from, subject, sent_raw, action, archive)
    VALUES ($(sqlq "$UNIT_SELF"), $(sqlq "$1"), $(sqlq "$2"), $(sqlq "$3"),
            $(sqlq "$4"), $(sqlq "$5"), $(sqlq "$6"), $(sqlq "$7"))
    ON CONFLICT (account, uid) DO NOTHING" >/dev/null 2>&1
}

record_sweep(){ # accounts new archived trashed note
  crsql -d "$CR_DB" -e "INSERT INTO sweeps
      (unit, run_id, accounts, new_msgs, archived, trashed, note)
    VALUES ($(sqlq "$UNIT_SELF"), $(sqlq "${RUN_ID:-}"), ${1:-0}, ${2:-0},
            ${3:-0}, ${4:-0}, $(sqlq "${5:-}"))" >/dev/null 2>&1
}

# Has this uid already been swept? DB first, falling back to the flat
# seen-file so a cockroach outage degrades to the old behaviour instead of
# re-archiving and re-trashing everything.
already_seen(){ # account uid seen_file
  if [ "$DB_OK" = 1 ]; then
    [ "$(crsql -d "$CR_DB" --format=csv -e \
        "SELECT count(*) FROM messages WHERE account=$(sqlq "$1") AND uid=$(sqlq "$2")" \
        | tail -1 | tr -d '[:space:]')" != "0" ] && return 0
  fi
  grep -qx "$2" "$3"
}

rule_action(){ # from subject -> keep|trash
  # `field` used to be parsed and then thrown away, so from:/subject: were
  # both matched against the two concatenated — a from: rule could fire on a
  # subject line. And $glob was quoted inside *"$glob"*, which made * a
  # literal asterisk: the documented from:*@linkedin.com example could never
  # match anything. Unquoted, wrapped in *...*, so plain substrings still work.
  local from=$1 subj=$2 pat act field glob hay
  [ -f "$RULES_FILE" ] || { echo keep; return; }
  while IFS='|' read -r pat act; do
    case "$pat" in ''|\#*) continue;; esac
    field=${pat%%:*}; glob=${pat#*:}
    case "$field" in
      from)    hay=$from ;;
      subject) hay=$subj ;;
      *)       hay="$from $subj" ;;
    esac
    # shellcheck disable=SC2254  # $glob is deliberately a pattern here
    case "$hay" in
      *$glob*) echo "${act:-keep}"; return;;
    esac
  done < "$RULES_FILE"
  echo keep
}

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
total_new=0 total_arch=0 total_trash=0 total_accts=0

while IFS='|' read -r name host user pass trashfld; do
  case "$name" in ''|\#*) continue;; esac
  [ -z "${pass:-}" ] && { log "$name: no password configured — skip"; continue; }
  trashfld=${trashfld:-Trash}

  seen_file="$STATE_DIR/seen-$name"
  touch "$seen_file"

  # UIDs of unseen mail, minus ones we've already processed
  total_accts=$((total_accts+1))
  uids=$(imap "$host" "$user" "$pass" "UID SEARCH UNSEEN" \
    | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | while read -r u; do
        already_seen "$name" "$u" "$seen_file" || echo "$u"
      done)
  [ -z "$uids" ] && { log "$name: nothing new"; continue; }

  month=$(date +%Y%m)
  mbox_tmp=$(mktemp)
  n=0
  for u in $uids; do
    # archive first — always
    fetch_msg "$host" "$user" "$pass" "$u" >> "$mbox_tmp" && total_arch=$((total_arch+1))
    # headers for digest + rules
    hdr=$(imap "$host" "$user" "$pass" \
      "UID FETCH $u (BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])")
    from=$(echo "$hdr" | grep -i '^From:' | head -1 | sed 's/^[Ff]rom: *//;s/\r//')
    subj=$(echo "$hdr" | grep -i '^Subject:' | head -1 | sed 's/^[Ss]ubject: *//;s/\r//')
    date_raw=$(echo "$hdr" | grep -i '^Date:' | head -1 | sed 's/^[Dd]ate: *//;s/\r//')
    act=$(rule_action "$from" "$subj")
    if [ "$act" = trash ]; then
      imap "$host" "$user" "$pass" "UID COPY $u \"$trashfld\"" >/dev/null
      imap "$host" "$user" "$pass" "UID STORE $u +FLAGS.SILENT (\\Deleted)" >/dev/null
      imap "$host" "$user" "$pass" "EXPUNGE" >/dev/null
      total_trash=$((total_trash+1))
      mark="[trashed]"
    else
      mark=""
    fi
    digest="${digest}$name | $subj | $from $mark\n"
    [ "$DB_OK" = 1 ] && record_msg "$name" "$u" "$from" "$subj" "$date_raw" \
        "${act:-keep}" "$REMOTE_HOST:$REMOTE_DIR/$name/$month.mbox.gz"
    echo "$u" >> "$seen_file"
    n=$((n+1)); total_new=$((total_new+1))
  done

  # ship the month's archive (append — decompress, concat, recompress)
  if [ -s "$mbox_tmp" ]; then
    remote_file="$REMOTE_DIR/$name/$month.mbox.gz"
    ssh $SSH_OPTS "$REMOTE_HOST" "mkdir -p ~/$REMOTE_DIR/$name" 2>/dev/null
    { ssh $SSH_OPTS "$REMOTE_HOST" "zcat ~/$remote_file 2>/dev/null"; cat "$mbox_tmp"; } \
      | gzip -1 | ssh $SSH_OPTS "$REMOTE_HOST" "cat > ~/$remote_file.new && mv ~/$remote_file.new ~/$remote_file" \
      && log "$name: archived $n msgs -> $remote_file" \
      || { mkdir -p "$LOCAL_DIR/$name"; cat "$mbox_tmp" | gzip -1 >> "$LOCAL_DIR/$name/$month.mbox.gz";
           log "$name: remote failed — archived locally"; }
  fi
  rm -f "$mbox_tmp"
done < "$ACCTS_FILE"

if [ "$total_new" -gt 0 ]; then
  notify "$(printf "mail sweep %s — %d new (%d archived, %d trashed)\n\n%b" \
    "$STAMP" "$total_new" "$total_arch" "$total_trash" "$digest")"
fi
[ "$DB_OK" = 1 ] && record_sweep "$total_accts" "$total_new" "$total_arch" \
    "$total_trash" "swept $total_accts account(s)"
log "done: $total_new new, $total_arch archived, $total_trash trashed"
