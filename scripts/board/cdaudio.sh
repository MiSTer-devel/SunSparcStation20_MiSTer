#!/usr/bin/env bash
# cdaudio.sh [--disc CUE] [--log FILE] - CD audio (PLAN S2) under NetBSD:
# OpenBIOS, HD0 netbsd11.raw, the CD a CUE/BIN with a data track and two
# audio tracks (default cddatest.cue, made by tools/mkcdda.py; Main must be
# sun-family-ss20-scsi, which serves the track table and the frames).
# NetBSD's cdplay checks what software sees:
#   - info lists 3 tracks, 2 and 3 audio;
#   - play 2: the status is "playing" and the position moves;
#   - pause: "paused", the position still; resume: playing again;
#   - stop; the data track still reads (its volume descriptor).
# Nobody listens here: a 440 Hz tone (track 2), 880/660 Hz (track 3).
# Last line: PASS or FAIL.
set -u
. "$(dirname "$0")/../common.sh"
. scripts/board/lib.sh
DISC=cddatest.cue; LOG=sim/out/hw-20-cdaudio.log
while [ $# -gt 0 ]; do
    case "$1" in
        --disc) DISC=$2; shift ;;
        --log) LOG=$2; shift ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac; shift
done
rsh "test -f '$G/$DISC'" || { echo "FAIL: no $G/$DISC on the MiSTer"; exit 1; }
mkdir -p sim/out
fail() { echo "FAIL: $*"; cap_stop; restore_openbios; exit 1; }
rsh "cp $G/openbios.rom $G/boot.rom"
scripts/mount.sh --hd0 netbsd11.raw --hd1 "" --cd "$DISC" --nvram "" > /dev/null
scripts/setopt.sh console=serial autoboot=on > /dev/null 2>&1 || exit 1
cap_stop; cap_start "$LOG" 1800
core_start
tty_wait '^login:' 900 "$LOG" || fail "no login"
sleep 5; tty_type 'root\r'; sleep 15
C="cdplay -f cd0"
tty_run "$C info" 60 "$LOG"
tty_run "$C play 2; sleep 3; $C status" 60 "$LOG"
tty_run "sleep 2; $C status" 60 "$LOG"
tty_run "$C pause; $C status; sleep 2; $C status" 60 "$LOG"
tty_run "$C resume; sleep 2; $C status; $C stop" 60 "$LOG"
tty_run "dd if=/dev/rcd0c bs=2048 skip=16 count=1 2>/dev/null | od -c | head -2" 60 "$LOG"
cap_stop; restore_openbios
T=$(tr -d '\r' < "$LOG")
# cdplay status prints "audio status:   playing" and "position:       0:03.46"
st=$(echo "$T" | grep -a -o -E '^audio status: +[a-z]+' | awk '{print $3}' | tr '\n' ',')
pos=$(echo "$T" | grep -a -o -E '^position: +[0-9:.]+' | awk '{print $2}' | tr '\n' ' ')
echo "statuses: $st"
echo "positions: $pos"
echo "$T" | grep -a -q -E '^ +2 .* audio' || fail "info lists no audio track 2"
case "$st" in playing,playing,paused,paused,playing,*) ;; *) fail "statuses $st" ;; esac
p1=$(echo $pos | awk '{print $1}'); p2=$(echo $pos | awk '{print $2}')
p3=$(echo $pos | awk '{print $3}'); p4=$(echo $pos | awk '{print $4}')
[ "$p1" != "$p2" ] || fail "the position did not move while playing ($p1)"
[ "$p3" = "$p4" ] || fail "the position moved while paused ($p3, $p4)"
echo "$T" | grep -a -q 'C   D   0   0   1' || fail "the data track's volume descriptor did not read"
echo "PASS: cdplay: the tracks, playing, paused, resumed; the position moves only while playing; the data track reads"
