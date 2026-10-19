#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# unixbench.sh [--core NAME] [--rom FILE] [--img IMAGE] [--copies N]
#              [--nvram FILE] [--tests "T..."] [--log FILE] - UnixBench's System Benchmarks
# Index on the board: NetBSD from IMAGE (default netbsd11-ub.raw, a NetBSD 11
# image with /root/ub holding UnixBench's programs built by
# tools/unixbench/ub.sh) at HD0, the console on ttya, then
# `sh ub.sh run N [TESTS]` and a clean halt. The score is computed from the
# capture by tools/unixbench/ubscore.py (index 10.0 = a SPARCstation 20-61).
#
#   --core NAME   the rbf core_start loads (default SunSparcStation20; e.g. an
#                 older release copied under another name)
#   --rom FILE    a boot ROM for this run (default: the board's openbios.rom)
#   --copies N    parallel copies (UnixBench -c N), default 1
#   --nvram NAME  an NVRAM image in the games folder (with --rom = Sun's
#                 PROM: ss20-obp.nvr, its console on ttya); default none
#
# A full single-copy run takes 25-60 minutes.
set -u
. "$(dirname "$0")/../common.sh"
. scripts/board/lib.sh
CORE=SunSparcStation20; ROM=""; IMG=netbsd11-ub.raw; COPIES=1; TESTS=""; LOG=""; NVR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --core)   CORE=$2; shift ;;
        --rom)    ROM=$2; shift ;;
        --img)    IMG=$2; shift ;;
        --copies) COPIES=$2; shift ;;
        --nvram)  NVR=$2; shift ;;
        --tests)  TESTS=$2; shift ;;
        --log)    LOG=$2; shift ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac; shift
done
: "${LOG:=sim/out/hw-unixbench-$CORE-c$COPIES.log}"
mkdir -p sim/out
fail() { echo "FAIL: $*"; cap_stop; restore_openbios; exit 1; }

if [ -n "$ROM" ]; then put_rom "$ROM" || exit 1; else rsh "cp $G/openbios.rom $G/boot.rom"; fi
scripts/mount.sh --hd0 "$IMG" --hd1 "" --cd "" --nvram "$NVR" > /dev/null
scripts/setopt.sh console=serial autoboot=on > /dev/null 2>&1 || exit 1
cap_stop; cap_start "$LOG" 10800
core_start "$CORE"
tty_wait '^login:' 1200 "$LOG" || fail "no login"
sleep 5; tty_type 'root\r'; sleep 15
tty_run "cd /root/ub && sh ub.sh run $COPIES $TESTS" 9000 "$LOG" || fail "the run did not finish"
tty_type 'sync; halt\r'
tty_wait 'halted|Program terminated|ok $' 300 "$LOG" || echo "(no halt message)"
sleep 3; cap_stop; restore_openbios
python3 tools/unixbench/ubscore.py "$LOG"
n=$(tr -d '\r' < "$LOG" | grep -a -c '^UB|')
[ "$n" -gt 0 ] && grep -a -q 'UB-DONE' "$LOG" && { echo "PASS: unixbench on $CORE, $COPIES copies ($n results; $LOG)"; exit 0; }
echo "FAIL: no results"; exit 1
