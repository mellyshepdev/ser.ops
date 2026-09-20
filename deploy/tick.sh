#!/usr/bin/env bash
# Container entrypoint: drive rotate.sh on fixed, wall-clock SLOTS.
#
# THE MODEL (this is the thing to preserve):
#   ser.ops works ONE job per slot, for up to a full slot, then moves to the
#   next job. A slot is an hour by default. That is the whole scheduling idea.
#
# WHAT THIS REPLACES AND WHY:
#   The previous loop was `rotate.sh; sleep 1800`, which sleeps AFTER the task
#   returns — so the real interval was (task duration + 30 min), not 30 min.
#   On 2026-09-20 archive-offload ran 3.2h, so the following tick landed 3h42m
#   later and six consecutive ticks logged "another rotation tick holds the
#   lock". Short tasks had the opposite problem: `mail` finished in 571ms and
#   the box then sat idle for the full half hour. Neither is "an hour per job".
#
#   Now the slot boundary is absolute: slot_end is computed BEFORE the task
#   starts, and we sleep only the remainder afterwards. A task that overruns
#   its slot simply means the next slot begins immediately — it can never push
#   the whole schedule later and later the way the old sleep-after did.
#
# SOFT DEADLINE CONTRACT:
#   SEROPS_DEADLINE (epoch seconds) is exported to every task. A task that can
#   work in chunks should finish the chunk it is on, decline to START another
#   past the deadline, and exit 0. Tasks that ignore it keep the old
#   run-to-completion behaviour, so this is backward compatible — nothing has
#   to be rewritten before this change is safe.
set -uo pipefail

REPO="${REPO:-/srv/ser.ops}"
# SLOT_SECONDS is the real knob. TICK_SECONDS is still honoured so an existing
# deployment that sets it keeps working rather than silently changing cadence.
SLOT_SECONDS="${SLOT_SECONDS:-${TICK_SECONDS:-3600}}"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

term=0
# Sleep in one-second slices and check this, so `docker stop` is honoured in
# seconds rather than waiting out a whole slot and being SIGKILLed.
trap 'term=1; log "signal received — stopping after this slot"' TERM INT

log "ser.ops dispatcher starting (repo=$REPO slot=${SLOT_SECONDS}s unit=${UNIT_NAME:-unset})"

if [ ! -x "$REPO/scripts/rotate.sh" ]; then
    log "FATAL: $REPO/scripts/rotate.sh missing or not executable — is the repo bind-mounted?"
    exit 1
fi

while [ "$term" -eq 0 ]; do
    slot_start=$(date +%s)
    slot_end=$(( slot_start + SLOT_SECONDS ))

    SEROPS_DEADLINE="$slot_end" \
    SEROPS_SLOT_SECONDS="$SLOT_SECONDS" \
        "$REPO/scripts/rotate.sh" || log "rotate.sh exited $?"

    now=$(date +%s)
    remain=$(( slot_end - now ))
    if [ "$remain" -le 0 ]; then
        # Task used its whole slot (or overran under the soft deadline).
        # Start the next slot straight away rather than adding a sleep on top.
        log "slot consumed ($(( now - slot_start ))s of ${SLOT_SECONDS}s) — next job now"
        continue
    fi

    log "job finished early — idling ${remain}s until the next slot boundary"
    slept=0
    while [ "$slept" -lt "$remain" ] && [ "$term" -eq 0 ]; do
        sleep 1
        slept=$((slept + 1))
    done
done

log "dispatcher stopped"
