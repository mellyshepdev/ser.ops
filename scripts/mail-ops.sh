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
REMOTE_DIR=${REMOTE_DIR:-backups/mail}
LOCAL_DIR=${LOCAL_DIR:-/home/swoopg111/backups/mail}
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10"
STAMP=$(date +%Y%m%d-%H%M%S)

exec 9>"$LOCK"; flock -n 9 || { echo "mail-ops busy"; exit 0; }
mkdir -p "$STATE_DIR" "$LOCAL_DIR"
log(){ echo "[$(date +%H:%M:%S)] $*"; }

[ -f "$ACCTS_FILE" ] || { log "no accounts file ($ACCTS_FILE) — nothing to do"; exit 0; }
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

rule_action(){ # subject-or-sender-line -> keep|trash
  local text=$1 pat act
  [ -f "$RULES_FILE" ] || { echo keep; return; }
  while IFS='|' read -r pat act; do
    case "$pat" in ''|\#*) continue;; esac
    local field=${pat%%:*} glob=${pat#*:}
    case "$text" in
      *"$glob"*) echo "${act:-keep}"; return;;
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

digest=""
total_new=0 total_arch=0 total_trash=0

while IFS='|' read -r name host user pass trashfld; do
  case "$name" in ''|\#*) continue;; esac
  [ -z "${pass:-}" ] && { log "$name: no password configured — skip"; continue; }
  trashfld=${trashfld:-Trash}

  seen_file="$STATE_DIR/seen-$name"
  touch "$seen_file"

  # UIDs of unseen mail, minus ones we've already processed
  uids=$(imap "$host" "$user" "$pass" "UID SEARCH UNSEEN" \
    | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | while read -r u; do
        grep -qx "$u" "$seen_file" || echo "$u"
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
    act=$(rule_action "$from $subj")
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
log "done: $total_new new, $total_arch archived, $total_trash trashed"
