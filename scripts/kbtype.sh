#!/usr/bin/env bash
# kbtype.sh TEXT... - type on the core's keyboard from this machine.
#
# Each argument is typed, then Enter, through misterkvms-cli ($MISTERKVMS in
# scripts/local.env), so the keys reach the core as PS/2 like a real
# keyboard: this is how to drive the Sun OBP's "ok" prompt, whose console is
# the screen and the keyboard. (Not mrext: the user's rule, 2026-10-19.)
#   scripts/kbtype.sh "setenv diag-device disk" boot
set -u
. "$(dirname "$0")/common.sh"
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
: "${MISTERKVMS:?set MISTERKVMS in scripts/local.env}"
for s in "$@"; do
    "$MISTERKVMS" --mister "$MISTER_HOST" type "$s\\n" > /dev/null 2>&1 || { log "kbtype: misterkvms-cli failed"; exit 1; }
    sleep 1
done
