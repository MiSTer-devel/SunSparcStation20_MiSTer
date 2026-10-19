#!/usr/bin/env bash
# Push a revision's rbf (and optionally a boot.rom) to the MiSTer and launch it.
#   scripts/deploy.sh 20 [--rom FILE] [--rbf FILE] [--no-launch]
# The rbf goes to /media/fat/$MISTER_CORE_FOLDER/<revision>.rbf; boot.rom to
# /media/fat/games/SunSparcStation/boot.rom, which the framework uploads at
# every core start (ioctl index 0). The games folder is created if missing.
# Launch: through the OSD (scripts/board/osd_load.sh: reloads the running
# core's file, so the same name must be running already; never
# /dev/MiSTer_cmd or mrext, the user's rule).
set -u
. "$(dirname "$0")/common.sh"
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
REV=$(rev_of "${1:-}") || exit 2; shift
RBF="output_files/$REV.rbf"; ROM=""; LAUNCH=1
while [ $# -gt 0 ]; do
    case "$1" in
        --rom) ROM="$2"; shift ;;
        --rbf) RBF="$2"; shift ;;
        --no-launch) LAUNCH=0 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac; shift
done
[ -f "$RBF" ] || { log "$RBF does not exist"; exit 1; }
case "$(head -1 "output_files/$REV.fit.summary" 2>/dev/null)" in
    *Successful*|"") ;;
    *) log "the last fit of $REV did not succeed; not deploying"; exit 1 ;;
esac
GAMES="/media/fat/games/$GAMES_DIR"; CORES="/media/fat/$MISTER_CORE_FOLDER"
ssh "${SSH_OPTS[@]}" "$DEV" "mkdir -p '$GAMES' '$CORES'" || { log "cannot reach $DEV"; exit 1; }
push() {   # local remote
    scp -q "${SSH_OPTS[@]}" "$1" "$DEV:$2" || return 1
    [ "$(md5sum < "$1" | cut -d' ' -f1)" = "$(ssh "${SSH_OPTS[@]}" "$DEV" "md5sum < '$2'" | cut -d' ' -f1)" ] \
        || { log "md5 mismatch for $2"; return 1; }
    log "$1 -> $2 (md5 ok)"
}
if [ -n "$ROM" ]; then
    push "$ROM" "$GAMES/boot.rom" || exit 1
    # a Boot PROM record left by a build before the OSD standard
    # (FC0, config/<core>.f0) would replace it
    ssh "${SSH_OPTS[@]}" "$DEV" "rm -f /media/fat/config/$GAMES_DIR.f0"
fi
ssh "${SSH_OPTS[@]}" "$DEV" "test -f '$GAMES/boot.rom'" || log "warning: no $GAMES/boot.rom on the MiSTer"
push "$RBF" "$CORES/$REV.rbf" || exit 1
if [ "$LAUNCH" = 1 ]; then
    scripts/board/osd_load.sh "$REV"
fi
