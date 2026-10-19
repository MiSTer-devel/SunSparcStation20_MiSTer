#!/usr/bin/env bash
# osd.sh KEY... [shot NAME] - drive the MiSTer as a user does: each KEY (a
# misterkvms-cli key name: F12, up, down, left, right, enter, esc, a combo
# such as ralt+f1+a for the Sun's Stop-A; or wS to wait S seconds) is
# pressed through misterkvms-cli ($MISTERKVMS in scripts/local.env), then
# the screen, the OSD included, is saved as sim/out/osd-NAME.png. Keys go
# 0.4 s apart: the OSD hides itself after a few idle seconds. The core's
# file browsers reopen on the file chosen last. Never mrext or MiSTer's
# own screenshot command (the user's rules).
#   scripts/board/osd.sh F12 w1 down down enter w1 shot cdrom
set -u
. "$(dirname "$0")/../common.sh"
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
: "${MISTERKVMS:?set MISTERKVMS in scripts/local.env}"
while [ $# -gt 0 ]; do
    case "$1" in
        shot) shift; break ;;
        w*) sleep "${1#w}" ;;
        *) "$MISTERKVMS" --mister "$MISTER_HOST" key "$1" > /dev/null 2>&1; sleep 0.4 ;;
    esac
    shift
done
mkdir -p sim/out
sleep 0.8
"$MISTERKVMS" --mister "$MISTER_HOST" screenshot "sim/out/osd-${1:-now}.png" > /dev/null 2>&1 \
    && echo "sim/out/osd-${1:-now}.png"
