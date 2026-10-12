#!/usr/bin/env bash
# Photobooth / avatars backup (ser.ops) — the portal's photos, profile pictures,
# posts, friends and prefs. Two parts, both needed for a restore:
#   db     — pg_dump of comms-db's `postgres` database (member m_* schemas with
#            the photos rows + portal_shared posts/members)
#   images — the avatars_avatar_data volume (the photo bytes the rows point at)
# Each run lands as one folder, copied to TWO hosts on different providers, so
# losing one unit (as with unit8 on 2026-09-16) can't take the photos with it.
#
# Restore:
#   pg_restore -U swoopg111 -d postgres --clean --if-exists photobooth-db.dump
#   docker run --rm -v avatars_avatar_data:/data -v "$PWD":/b debian:bookworm-slim \
#     tar xzf /b/photobooth-images.tar.gz -C /data

set -uo pipefail

DB_CONTAINER="${DB_CONTAINER:-comms-db}"
DB_USER="${DB_USER:-swoopg111}"
DB_NAME="${DB_NAME:-postgres}"
VOLUME="${VOLUME:-avatars_avatar_data}"
HELPER_IMAGE="${HELPER_IMAGE:-debian:bookworm-slim}"
TARGETS="${TARGETS:-unit3-tailscale:backups/photobooth unit9:backups/photobooth}"
KEEP_DAYS="${KEEP_DAYS:-30}"
STAGE="${STAGE:-/home/swoopg111/backups/photobooth}"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

RUN=$(date -u +%Y%m%d-%H%M%S)
DIR="$STAGE/$RUN"
mkdir -p "$DIR"
fail=0

if docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc > "$DIR/photobooth-db.dump" \
   && [ -s "$DIR/photobooth-db.dump" ]; then
  log "db dump ok ($(du -h "$DIR/photobooth-db.dump" | cut -f1))"
else
  log "db dump FAILED"; fail=1
fi

if docker run --rm -v "$VOLUME":/data:ro "$HELPER_IMAGE" tar czf - -C /data . > "$DIR/photobooth-images.tar.gz" \
   && gzip -t "$DIR/photobooth-images.tar.gz"; then
  n=$(tar tzf "$DIR/photobooth-images.tar.gz" | grep -vc '/$')
  log "images ok ($n files, $(du -h "$DIR/photobooth-images.tar.gz" | cut -f1))"
else
  log "images tar FAILED"; fail=1
fi

(cd "$DIR" && sha256sum photobooth-* > SHA256SUMS)

copied=0
for t in $TARGETS; do
  host=${t%%:*}; path=${t#*:}
  if ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "mkdir -p '$path'" \
     && scp -q -r -o BatchMode=yes "$DIR" "$host:$path/" \
     && ssh -o BatchMode=yes "$host" "cd '$path/$RUN' && (sha256sum -c SHA256SUMS 2>/dev/null || shasum -a 256 -c SHA256SUMS) >/dev/null"; then
    log "copied + verified on $host:$path/$RUN"; copied=$((copied+1))
    ssh -o BatchMode=yes "$host" "find '$path' -mindepth 1 -maxdepth 1 -type d -mtime +$KEEP_DAYS -exec rm -rf {} +" || true
  else
    log "copy to $host FAILED"; fail=1
  fi
done

# The local copy is only a staging area — keep it until both targets have it.
if [ "$copied" -ge 2 ]; then rm -rf "$DIR"; else log "kept local copy $DIR ($copied/2 targets ok)"; fi
find "$STAGE" -mindepth 1 -maxdepth 1 -type d -mtime +"$KEEP_DAYS" -exec rm -rf {} + 2>/dev/null

[ "$fail" -eq 0 ] && log "done — $copied/2 locations" || { log "done with FAILURES — $copied/2 locations"; exit 1; }
