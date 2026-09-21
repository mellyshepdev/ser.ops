# Runtime for the ser.ops task dispatcher.
#
# Deliberately a toolbox image, not an application image. The tasks shell out
# to the host's docker (dumps run as `docker exec` against sibling containers),
# ssh/rsync to unit3, and read the repo's own state/ directory. The scripts
# themselves stay on a bind mount, so `git pull` is the entire deploy and no
# rebuild is needed to ship a task change.
#
# Alpine's busybox applets are not enough here: the tasks use GNU-only flags
# (`du --files0-from`, `find -mmin`), so coreutils/findutils are installed
# explicitly rather than relied upon.
FROM docker:28-cli

RUN apk add --no-cache \
      bash \
      coreutils \
      findutils \
      util-linux \
      ca-certificates \
      curl \
      jq \
      openssh-client \
      rsync \
      tar \
      gzip \
      xz \
      python3 \
      tzdata

# compose pins `user: "1001:1001"` to match the host's swoopg111, but the base
# image has no passwd entry for that uid. OpenSSH refuses to start without one
# ("No user exists for uid 1001"), so EVERY ssh out of this container failed --
# which the backup script reported as "unit3-tailscale unreachable" and quietly
# downgraded to a local-disk fallback. The result was remote=0 on every run:
# backups of unit7 stored on unit7. /etc/passwd is root-owned, so the container
# cannot repair this at runtime; the entry has to be baked in here.
#
# getent guards both lines so the build still works if a future base image
# happens to ship a 1001 already.
RUN set -eux; \
    getent group  1001 >/dev/null || addgroup -g 1001 swoopg111; \
    getent passwd 1001 >/dev/null || adduser -D -u 1001 \
        -G "$(getent group 1001 | cut -d: -f1)" \
        -h /home/swoopg111 -s /bin/bash swoopg111

ENV REPO=/srv/ser.ops \
    STATE_DIR=/srv/ser.ops/state

WORKDIR /srv/ser.ops
ENTRYPOINT ["/srv/ser.ops/deploy/tick.sh"]
