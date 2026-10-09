#!/usr/bin/env bash
# backup-mailstore.sh — rotation task: archive unit9's docker-mailserver
# store (/home/swoopg111/mailserver: mail-data + config + accounts.txt) to
# unit3. This is the gap that lost partnerships@tikurbego.com's mail when
# unit2's docker volumes were wiped: the mailstore had NO backup anywhere —
# the IMAP sweep only copies mail it has already seen, and backup-volumes
# never covered the mailserver unit.
#
# Path: unit9 tar (stream) -> unit3 ~/backups/mailstore/unit9/mailserver-<stamp>.tar.gz
# Retention: last 7 archives.
set -u

REPO="${REPO:-/home/swoopg111/projects/ser.ops}"
SRC_HOST=${SRC_HOST:-unit9}
MAIL_CONTAINER=${MAIL_CONTAINER:-mailserver}
REMOTE_HOST=${REMOTE_HOST:-unit3-tailscale}
REMOTE_DIR=${REMOTE_DIR:-backups/mailstore/unit9}
SSH_CFG=${SSH_CFG:-$HOME/.ssh/config}
SSH_OPTS="-F $SSH_CFG -o BatchMode=yes -o ConnectTimeout=10"
LOCK=${LOCK:-/tmp/serops-mailstore.lock}
STAMP=$(date +%Y%m%d-%H%M%S)

exec 9>"$LOCK"; flock -n 9 || { echo "mailstore busy"; exit 0; }
log(){ echo "[$(date +%H:%M:%S)] $*"; }

# Stream straight through — nothing lands on this host. The tar runs INSIDE
# the mailserver container (root): /var/mail is the full Maildir store and
# /tmp/docker-mailserver holds the generated account config. A second ssh
# writes it on unit3 atomically (.new -> rename).
if ssh $SSH_OPTS "$SRC_HOST" \
      "docker exec $MAIL_CONTAINER tar -C / -czf - var/mail tmp/docker-mailserver 2>/dev/null" \
   | ssh $SSH_OPTS "$REMOTE_HOST" \
      "mkdir -p ~/$REMOTE_DIR && cat > ~/$REMOTE_DIR/mailserver-$STAMP.tar.gz.new && mv ~/$REMOTE_DIR/mailserver-$STAMP.tar.gz.new ~/$REMOTE_DIR/mailserver-$STAMP.tar.gz"; then
  size=$(ssh -n $SSH_OPTS "$REMOTE_HOST" "stat -f%z ~/$REMOTE_DIR/mailserver-$STAMP.tar.gz 2>/dev/null || stat -c%s ~/$REMOTE_DIR/mailserver-$STAMP.tar.gz")
  log "mailstore archived -> $REMOTE_HOST:$REMOTE_DIR/mailserver-$STAMP.tar.gz ($size bytes)"
else
  log "FAIL: mailstore archive stream failed (unit9 read or unit3 write)"
  exit 1
fi

# retain the last 7
ssh -n $SSH_OPTS "$REMOTE_HOST" \
  "cd ~/$REMOTE_DIR && ls -1t mailserver-*.tar.gz 2>/dev/null | tail -n +8 | xargs rm -f"
log "done"
