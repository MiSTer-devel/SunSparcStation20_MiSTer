#!/usr/bin/env bash
# mount.sh [--hd0 FILE] [--hd1 FILE] [--cd FILE] [--nvram FILE] [--prom FILE]
#          [--mgl REV]
#
# Attach images without the OSD. FILE is a name in games/SunSparcStation/ or
# an absolute path on the MiSTer; "" detaches.
#
# --nvram is slot 3, the NVRAM image (an 8192-byte file, read at every core
# start and written back when the machine changes the NVRAM).
#
# --prom FILE is the OSD's Load ROM (CONF_STR "F0"): not remembered, so it
# needs --mgl, which launches the core with that ROM for one session (a
# normal start loads boot0.rom/boot.rom). To change the default ROM, copy it
# to games/SunSparcStation/boot.rom (scripts/board/lib.sh put_rom).
#
# With the remembered slots (CONF_STR "SC0" to "SC3"), MiSTer keeps each
# slot's image in /media/fat/config/<core>.s<n>: a fixed 1024-byte record,
# the absolute path NUL-padded (Main menu.cpp FileSaveConfig). The core
# remounts them at every start, so this writes the records and nothing else.
#
# --mgl REV (20) (disabled: launching goes through the OSD only) wrote a one-shot MGL (for builds without the
# SC slots, or with --prom) and launches the core with it through
# /dev/MiSTer_cmd. The rows an MGL names must be on the OSD's top page:
# slots 0-2 and Load ROM are; slot 3 (NVRAM image, P5) is not.
set -u
. "$(dirname "$0")/common.sh"
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
GAMES="/media/fat/games/$GAMES_DIR"
declare -A SLOT; MGL=""; PROM=""; PROMSET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --hd0) SLOT[0]="$2"; shift ;;
        --hd1) SLOT[1]="$2"; shift ;;
        --cd)  SLOT[2]="$2"; shift ;;
        --nvram) SLOT[3]="$2"; shift ;;
        --prom) PROM="$2"; PROMSET=1; shift ;;
        --mgl) MGL=$(rev_of "$2") || exit 2; shift ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac; shift
done
if [ "$PROMSET" = 1 ] && [ -z "$MGL" ]; then
    echo "--prom needs --mgl: Load ROM is not remembered" >&2; exit 2
fi
abs() { case "$1" in ""|/*) echo "$1" ;; *) echo "$GAMES/$1" ;; esac; }
if [ -n "$MGL" ]; then
    # An MGL launch goes through /dev/MiSTer_cmd, which the user has ruled
    # out (2026-10-19): cores load and ROMs are chosen through the OSD only
    # (scripts/board/osd_load.sh; Load ROM by hand)
    echo "mount.sh: --mgl is disabled: load the core and choose Load ROM through the OSD" >&2; exit 2
    X="<mistergamedescription>\n  <rbf>$MISTER_CORE_FOLDER/$MGL</rbf>\n"
    for n in "${!SLOT[@]}"; do
        [ -n "${SLOT[$n]}" ] && X="$X  <file delay=\"1\" type=\"s\" index=\"$n\" path=\"$(abs "${SLOT[$n]}")\"/>\n"
    done
    [ -n "$PROM" ] && X="$X  <file delay=\"1\" type=\"f\" index=\"0\" path=\"$(abs "$PROM")\"/>\n"
    X="$X</mistergamedescription>\n"
    printf "$X" | ssh "${SSH_OPTS[@]}" "$DEV" "cat > /tmp/sss.mgl && echo 'load_core /tmp/sss.mgl' > /dev/MiSTer_cmd" \
        && log "launched $MGL with /tmp/sss.mgl"
    exit
fi
for n in "${!SLOT[@]}"; do
    P=$(abs "${SLOT[$n]}")
    python3 -c "import sys; p=sys.argv[1].encode(); sys.stdout.buffer.write(p + bytes(1024-len(p)))" "$P" \
        | ssh "${SSH_OPTS[@]}" "$DEV" "cat > /media/fat/config/$GAMES_DIR.s$n" \
        && log "slot $n = ${P:-(empty)}"
done
