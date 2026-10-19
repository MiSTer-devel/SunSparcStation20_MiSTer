#!/usr/bin/env bash
# sgprobe.sh [--obp FILE] [--disk NAME] [--log FILE] [-- SGPROBE_ARGS...]
# Boot an installed NeXTSTEP disk single-user on ttya (OpenBIOS, or the Sun
# OBP with --obp), make the root writable, type sgprobe in through uudecode
# and run it: BuildDisk's FindDisks scan through /dev/sg0 (targets 0-7, LUNs
# 0-7, INQUIRY), every result printed, then TEST UNIT READY, READ CAPACITY
# and INQUIRY on each device found. Leaves the machine at the single-user
# shell (halt it there before reloading the core). Use a copy of the disk:
# fsck may modify it. GPL-2.0-or-later.
set -u
cd "$(dirname "$0")/../.."
. scripts/common.sh; . scripts/board/lib.sh
OBP=""; DISK=ns33.img; LOG=sim/out/sgprobe.log
CD="NeXTSTEP 3.3 User (SPARC, PARISC).iso"
while [ $# -gt 0 ]; do
    case "$1" in
        --obp) OBP=$2; shift ;;
        --disk) DISK=$2; shift ;;
        --log) LOG=$2; shift ;;
        --) shift; break ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac; shift
done
tools/nextstep/build.sh sim/out/nextstep > /dev/null || exit 1
scp -q "${SSH_OPTS[@]}" sim/out/nextstep/sgprobe.uu tools/nextstep/ttysend.py "$DEV:/tmp/"
if [ -n "$OBP" ]; then
    put_rom "$OBP" || exit 1
    rsh "cp $G/ss20-obp.nvr $G/nextstep-test.nvr"
    scripts/mount.sh --hd0 "$DISK" --hd1 "" --cd "$CD" --nvram nextstep-test.nvr > /dev/null
    scripts/setopt.sh console=serial network=off > /dev/null 2>&1
else
    rsh "cp $G/openbios.rom $G/boot.rom"
    scripts/mount.sh --hd0 "$DISK" --hd1 "" --cd "$CD" --nvram "" > /dev/null
    scripts/setopt.sh console=serial autoboot=on network=off > /dev/null 2>&1
fi
cap_stop; cap_start "$LOG" 3600
core_start
tty_wait '^boot: ' 300 "$LOG" || { echo "no boot: prompt (see $LOG)"; exit 1; }
sleep 1; tty_type "-s\r"
tty_wait 'Singleuser boot' 400 "$LOG" || { echo "no single-user shell (see $LOG)"; exit 1; }
sleep 5
# fsck may have to set the clean flag ("must reboot without sync"): the
# probe only writes /tmp, which survives that
tty_run "fsck -y /dev/rsd0a" 300 "$LOG"
tty_run "cd /tmp" 20 "$LOG"
tty_type "cat > sgprobe.uu\r"; sleep 1
rsh "python3 /tmp/ttysend.py /tmp/sgprobe.uu 8 60"
sleep 1; tty_type $'\x04'; sleep 2
tty_run "uudecode sgprobe.uu; ls -l sgprobe" 60 "$LOG"
tty_run "./sgprobe $*" 300 "$LOG"
sed -n '/^open \/dev\/sg0/,/^done/p' "$LOG"
echo "at the single-user shell; log $LOG"
