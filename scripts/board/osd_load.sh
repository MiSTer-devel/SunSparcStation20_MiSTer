#!/usr/bin/env bash
# osd_load.sh [REV] - (re)load the core through the MiSTer's OSD, as a user
# does: F12, Right (the System page), Enter ("Core": the cores' browser
# opens on the running core's file), Enter. So it loads the rbf that is
# running now: copy a new build over it first (deploy.sh --no-launch); load
# another core by hand through the OSD. Keys and screenshots go through
# misterkvms-cli ($MISTERKVMS, scripts/local.env). Never /dev/MiSTer_cmd,
# mrext or misterkvms-cli load-core (the user's rule, 2026-10-19).
# Afterwards it checks, read-only over ssh, that
# /media/fat/$MISTER_CORE_FOLDER/<REV>.rbf runs; status 1 if not.
#   scripts/board/osd_load.sh 20
set -u
. "$(dirname "$0")/../common.sh"
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
: "${MISTERKVMS:?set MISTERKVMS in scripts/local.env}"
REV=$(rev_of "${1:-20}") || exit 2
want="/media/fat/$MISTER_CORE_FOLDER/$REV.rbf"
running() { ssh "${SSH_OPTS[@]}" "$DEV" "ps | grep '[M]iSTer '" 2>/dev/null | grep -o '/media/fat/[^ ]*\.rbf'; }
cur=$(running)
if [ "$cur" != "$want" ]; then
    echo "osd_load: $cur is running, not $want: load it once by hand through the OSD (F12, System, Core)" >&2
    exit 1
fi
key() { "$MISTERKVMS" --mister "$MISTER_HOST" key "$1" > /dev/null 2>&1; sleep 0.5; }
key F12; key right; key enter; sleep 0.7; key enter
for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    [ "$(running)" = "$want" ] && { log "loaded $REV through the OSD"; exit 0; }
done
echo "osd_load: $want is not running after the OSD keys" >&2
exit 1
