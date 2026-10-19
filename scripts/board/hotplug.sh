#!/usr/bin/env bash
# hotplug.sh [--log FILE] - images attached and swapped through the OSD while
# Solaris 8 runs (OpenBIOS, HD0 sol8-ss20.img). The OSD is driven with
# scripts/board/uinput_keys.py (a keyboard Main reads): F12, Down to the
# slot, Enter, letters that filter the file list, Enter. Last line: PASS or
# FAIL.
#
#   CD (slot 2, target 6, Solaris c1t6d0; vold stopped so the raw device is
#   free; the drive powers up with 512-byte blocks, as Solaris reads CDs):
#     empty: the open fails
#     netbsd11-cd.iso attached: slice 0's sector 16 is the ISO's volume
#       descriptor ("CD001", "NetBSD")
#     swapped to the NeXTSTEP CD: Solaris re-reads the medium (the NetBSD
#       CD's Sun label is gone)
#     swapped back: the NetBSD CD's label and volume descriptor again
#   Disk 1 (slot 1, target 1): attached sol8.img; after devfsadm Solaris has
#     c1t1d0, reads its VTOC, mounts its root read-only (/etc/release)
#
# Needs on the MiSTer: sol8-ss20.img, sol8.img, netbsd11-cd.iso and
# "NeXTSTEP 3.3 User (SPARC, PARISC).iso" in games/SunSparcStation.
set -u
. "$(dirname "$0")/../common.sh"
. scripts/board/lib.sh
LOG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --log) LOG=$2; shift ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac; shift
done
: "${LOG:=sim/out/hw-20-hotplug.log}"
mkdir -p sim/out
fail() { echo "FAIL: $*"; cap_stop; scripts/mount.sh --hd1 "" --cd "" > /dev/null;
         scripts/setopt.sh > /dev/null 2>&1; exit 1; }
keys() { rsh "python3 /tmp/uinput_keys.py $*"; sleep 3; }
# the OSD: F12, n x Down (0 = Disk 0), Enter, the filter's key codes, Enter
osd_mount() { local d=$1; shift
    local downs=""; for _ in $(seq 1 "$d"); do downs="$downs 108 w0.5"; done
    local typed=""; for k in "$@"; do typed="$typed $k w0.4"; done
    keys 88 w1.5 $downs 28 w2 $typed w1 28 w2; }
slot() { rsh "tr -d '\\0' < /media/fat/config/SunSparcStation.s$1" | head -c 200; }
run() { tty_run "$1" "${2:-60}" "$LOG"; }
out() { tr -d '\r' < "$LOG" | tr -cd '\11\12\40-\176' | sed -n "/$1/,\$p"; }
vd='dd if=/dev/rdsk/c1t6d0s0 of=/tmp/vd bs=2048 skip=16 count=1; od -c /tmp/vd | head -1; echo VD-""DONE'

rsh "cp $G/openbios.rom $G/boot.rom"
scripts/mount.sh --hd0 sol8-ss20.img --hd1 "" --cd "" --nvram "" > /dev/null
scripts/setopt.sh console=serial autoboot=on > /dev/null 2>&1 || exit 1
scp -q "${SSH_OPTS[@]}" scripts/board/uinput_keys.py "$DEV:/tmp/uinput_keys.py" || exit 1
cap_stop; cap_start "$LOG" 2400
core_start
tty_wait 'console login:' 900 "$LOG" || fail "no login"
sleep 5; tty_type 'root\r'; sleep 15
run '/etc/init.d/volmgt stop; sleep 3' 60

# CD: empty
run 'dd if=/dev/rdsk/c1t6d0s0 of=/dev/null bs=2048 count=1 2>&1 | head -1; echo EMPTY-""DONE'
e=$(out 'EMPTY-""DONE' | grep -a -m1 'dd:')
echo "CD empty: $e"
[ -n "$e" ] || fail "the empty drive read"

# CD: the NetBSD CD (filter "net": netbsd11-cd as .chd, .cue or .iso, the
# same disc; the .chd and .cue go through Main's sun_cdrom translation)
NBISO="49 18 20"
osd_mount 2 $NBISO
s=$(slot 2); echo "slot 2: $s"
run "$vd"
a=$(out 'VD-""DONE' | grep -a -m1 '^0000000')
echo "CD NetBSD: $a"
echo "$a" | grep -q 'C   D   0   0   1' && echo "$a" | grep -q 'N   e   t   B   S   D' || fail "NetBSD CD: '$a'"

# CD: swapped to NeXTSTEP (filter "nex")
osd_mount 2 49 18 45
s=$(slot 2); echo "slot 2: $s"
echo "$s" | grep -q NeXTSTEP || fail "the OSD did not attach the NeXTSTEP CD"
run 'prtvtoc /dev/rdsk/c1t6d0s2 2>&1 | grep -c "711040"; echo LBL-""DONE'
n=$(out 'LBL-""DONE' | grep -a -m1 -E '^[0-9]+$')
echo "CD NeXTSTEP: NetBSD label lines left: $n"
[ "$n" = 0 ] || fail "Solaris kept the NetBSD CD's label after the swap"

# CD: back to NetBSD
osd_mount 2 $NBISO
run "$vd"
a=$(out 'VD-""DONE' | grep -a '^0000000' | tail -1)
echo "CD NetBSD again: $a"
echo "$a" | grep -q 'N   e   t   B   S   D' || fail "NetBSD CD after the swap back: '$a'"

# Disk 1: sol8.img (filter "sol8.")
osd_mount 1 31 24 38 9 52
s=$(slot 1); echo "slot 1: $s"
echo "$s" | grep -q 'sol8.img' || fail "the OSD did not attach sol8.img"
run 'devfsadm -c disk; prtvtoc /dev/rdsk/c1t1d0s2 | grep -c "^ *[0-9]"; echo VT-""DONE' 240
v=$(out 'VT-""DONE' | grep -a -m1 -E '^[0-9]+$')
echo "Disk 1: $v partitions"
[ "${v:-0}" -ge 3 ] || fail "no VTOC on the hot-plugged disk"
run 'mount -F ufs -o ro /dev/dsk/c1t1d0s0 /mnt && head -1 /mnt/etc/release; umount /mnt; echo RL-""DONE' 120
r=$(out 'RL-""DONE' | grep -a -m1 'Solaris')
echo "Disk 1 root: $r"
[ -n "$r" ] || fail "the hot-plugged disk's root did not mount"

tty_type 'sync; init 0\r'
tty_wait 'ok |Program terminated' 300 "$LOG"
cap_stop
scripts/mount.sh --hd1 "" --cd "" > /dev/null
scripts/setopt.sh > /dev/null 2>&1
echo "PASS: CD attached, swapped twice and read under Solaris; a disk attached at target 1 found, its VTOC read and its root mounted"
