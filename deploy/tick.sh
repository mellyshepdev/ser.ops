#!/usr/bin/env bash
# Container entrypoint: drive rotate.sh on the same 30-minute cadence the host
# cron used. Containerising changes WHERE the dispatcher runs, not how often --
# task intervals stay in rotate.sh's TASKS table, which is the one schedule.
#
# rotate.sh takes its own lock and runs exactly one due task per tick, so a
# long task delays the next tick instead of overlapping with it.
set -uo pipefail

REPO="${REPO:-/srv/ser.ops}"
TICK_SECONDS="${TICK_SECONDS:-1800}"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

term=0
# Sleep in one-second slices and check this, so `docker stop` is honoured in
# seconds rather than waiting out a full half-hour tick and being SIGKILLed.
trap 'term=1; log "signal received — stopping after this tick"' TERM INT

log "ser.ops dispatcher starting (repo=$REPO tick=${TICK_SECONDS}s unit=${UNIT_NAME:-unset})"

if [ ! -x "$REPO/scripts/rotate.sh" ]; then
    log "FATAL: $REPO/scripts/rotate.sh missing or not executable — is the repo bind-mounted?"
    exit 1
fi

while [ "$term" -eq 0 ]; do
    "$REPO/scripts/rotate.sh" || log "rotate.sh exited $?"
    slept=0
    while [ "$slept" -lt "$TICK_SECONDS" ] && [ "$term" -eq 0 ]; do
        sleep 1
        slept=$((slept + 1))
    done
done

log "dispatcher stopped"
