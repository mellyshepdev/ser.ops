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

ENV REPO=/srv/ser.ops \
    STATE_DIR=/srv/ser.ops/state

WORKDIR /srv/ser.ops
ENTRYPOINT ["/srv/ser.ops/deploy/tick.sh"]
