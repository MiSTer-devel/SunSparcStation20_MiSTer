#!/usr/bin/env bash
# audio.sh solaris|netbsd|obp [--obp FILE] [--log FILE] - the SS20's audio
# card (a CS4231 + APC as on the SS5, in SBus slot 3, with an FCode PROM of
# its own). Nobody listens here, so the checks are the ones software sees:
#
#   solaris  OpenBIOS, HD0 sol8-ss20.img: the CS4231 node is in the device
#            tree, audiocs attaches, and 16000 bytes written to /dev/audio
#            (8 kHz mu-law, the default) take about 2 s: playback runs at
#            the sample rate, with the APC DMA and its interrupts working
#            (too fast: no rate; a hang: no interrupt)
#   solaris-obp  the same under the Sun OBP (--obp FILE, ss20-obp.nvr)
#   netbsd   OpenBIOS, HD0 netbsd11.raw: audiocs0 attaches, and the same
#            write takes about 2 s
#   obp      the Sun OBP (--obp FILE) with ss20-obp.nvr, no disk: at ok,
#            the node the slot's FCode PROM built has its properties, and
#            slot e's DBRI node is named dbri-absent (the image at slot e
#            +0x1000: without a name NeXTSTEP faults, DEC-4)
#
# Last line: PASS or FAIL. The sound itself reaches AUDIO_L/R (HDMI and the
# analog output) like the SS5's: listen to check it.
set -u
. "$(dirname "$0")/../common.sh"
. scripts/board/lib.sh
WHAT=${1:-}; shift || true
OBP=""; LOG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --obp) OBP=$2; shift ;;
        --log) LOG=$2; shift ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac; shift
done
case "$WHAT" in solaris|solaris-obp|netbsd|obp) ;; *) echo "usage: $0 solaris|solaris-obp|netbsd|obp [--obp FILE] [--log FILE]" >&2; exit 2 ;; esac
: "${LOG:=sim/out/hw-20-audio-$WHAT.log}"
mkdir -p sim/out
fail() { echo "FAIL: $*"; cap_stop; restore_openbios; exit 1; }

if [ "$WHAT" = obp ]; then
    [ -f "$OBP" ] || { echo "obp needs --obp FILE (the Sun PROM image)"; exit 2; }
    put_rom "$OBP" || exit 1
    scripts/mount.sh --hd0 "" --hd1 "" --cd "" --nvram ss20-obp.nvr > /dev/null
    scripts/setopt.sh console=serial autoboot=on > /dev/null 2>&1 || exit 1
    cap_stop; cap_start "$LOG" 300
    core_start
    tty_wait '^ok |ok $' 300 "$LOG" || fail "no ok prompt"
    sleep 3
    TTY_DELAY=40000 tty_type 'show-attrs /iommu@f,e0000000/sbus@f,e0001000/SUNW,CS4231@3,c000000\r'; sleep 8
    TTY_DELAY=40000 tty_type 'show-attrs /iommu@f,e0000000/sbus@f,e0001000/dbri-absent\r'; sleep 8
    cap_stop; restore_openbios
    t=$(tr -d '\r' < "$LOG" | tr -cd '\11\12\40-\176')
    echo "$t" | grep -a 'CS4231' | head -3
    echo "$t" | grep -a -E '^(intr|interrupts|reg|device_type) ' | head -6
    # show-attrs (OBP 2.x: the rest of the line is the path; .attributes is
    # its .properties) of the node: show-devs is not used,
    # its pager would swallow the next keys
    if ! echo "$t" | grep -a -q -E '^name +dbri-absent'; then
        echo "FAIL: slot e's node is not named dbri-absent"; exit 1
    fi
    if echo "$t" | grep -a -q -E '^name +SUNW,CS4231' && echo "$t" | grep -a -q -E '^interrupts +0*5'; then
        echo "PASS: the Sun OBP built SUNW,CS4231@3,c000000 from the slot's FCode, and dbri-absent at slot e"; exit 0
    fi
    echo "FAIL: no SUNW,CS4231 node"; exit 1
fi

NVR=""
if [ "$WHAT" = solaris-obp ]; then
    [ -f "$OBP" ] || { echo "solaris-obp needs --obp FILE (the Sun PROM image)"; exit 2; }
    put_rom "$OBP" || exit 1; NVR=ss20-obp.nvr
else
    rsh "cp $G/openbios.rom $G/boot.rom"
fi
case "$WHAT" in solaris*) HD0=sol8-ss20.img; want='console login:' ;; netbsd) HD0=netbsd11.raw; want='^login:' ;; esac
scripts/mount.sh --hd0 "$HD0" --hd1 "" --cd "" --nvram "$NVR" > /dev/null
scripts/setopt.sh console=serial autoboot=on > /dev/null 2>&1 || exit 1
cap_stop; cap_start "$LOG" 1800
core_start
tty_wait "$want" 900 "$LOG" || fail "no login"
sleep 5; tty_type 'root\r'; sleep 15
if [ "$WHAT" != netbsd ]; then
    # an image installed elsewhere (sol8-ss20: under QEMU) has /dev/sound
    # links to that machine's path: devfsadm makes them for slot 3
    tty_run 'devfsadm -i audiocs; prtconf | grep -i cs4231; ls -l /dev/sound/0' 120 "$LOG"
    tty_run 'dd if=/dev/zero bs=8000 count=2 > /tmp/a.raw; timex dd if=/tmp/a.raw of=/dev/audio bs=8000' 60 "$LOG"
    node=$(tr -d '\r' < "$LOG" | grep -a -c -i 'SUNW,CS4231, instance')
    drv=$(tr -d '\r' < "$LOG" | grep -a -c -i 'audiocs')
else
    tty_run 'dmesg | grep -i -E "audiocs|audio[0-9]"' 60 "$LOG"
    # written through a write-only open: dd opens its output O_RDWR, which
    # starts NetBSD's recording track too, and cs4231_sbus runs its
    # playback and capture soft handlers on one level (both on either
    # interrupt), so with capture running each block counts about twice
    # and the play ends in about half the time (the APC keeps the 48 kHz
    # pace: tests/cpu/src/audiotest.S)
    tty_run 'dd if=/dev/zero bs=8000 count=2 > /tmp/a.raw; time sh -c "cat /tmp/a.raw > /dev/audio"' 60 "$LOG"
    node=$(tr -d '\r' < "$LOG" | grep -a -c 'audiocs0 at sbus0')
    drv=$node
fi
real=$(tr -d '\r' < "$LOG" | grep -a -o -E '^real +[0-9.]+|[0-9.]+ real' | tail -1 | grep -o -E '[0-9.]+')
cap_stop; restore_openbios
echo "node: $node, driver: $drv, 2 s of audio written in ${real:-?} s"
[ "${node:-0}" -ge 1 ] || { echo "FAIL: no CS4231 node or attach"; exit 1; }
awk -v t="${real:-0}" 'BEGIN { exit !(t >= 1.5 && t <= 4) }' || { echo "FAIL: playback took ${real:-?} s, not ~2 s"; exit 1; }
echo "PASS: $WHAT: the CS4231 attached, 2 s of audio played in $real s"
