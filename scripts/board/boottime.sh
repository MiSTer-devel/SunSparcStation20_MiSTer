#!/usr/bin/env bash
# boottime.sh [solaris|netbsd] [--log FILE] - an OS's boot from disk under
# OpenBIOS (ttya), timed by phase: the serial capture is timestamped (each
# chunk '@<epoch> ...') and scripts/board/bootphases.py prints when each
# milestone came (OpenBIOS start, Trying disk, the kernel, the login).
# PLAN E1. Last line: PASS with the time to the login prompt.
set -u
. "$(dirname "$0")/../common.sh"
. scripts/board/lib.sh
OS=${1:-solaris}; shift || true
LOG=sim/out/hw-20-boottime-$OS.ts
[ "${1:-}" = --log ] && LOG=$2
case "$OS" in solaris) HD0=sol8-ss20.img ;; netbsd) HD0=netbsd11.raw ;;
    *) echo "usage: $0 [solaris|netbsd] [--log FILE]" >&2; exit 2 ;; esac
mkdir -p sim/out
rsh "cp $G/openbios.rom $G/boot.rom"
scripts/mount.sh --hd0 "$HD0" --hd1 "" --cd "" --nvram "" > /dev/null
scripts/setopt.sh console=serial autoboot=on > /dev/null 2>&1 || exit 1
cap_stop; rm -f "$LOG"
CMD="uartmode 0 >/dev/null 2>&1; stty -F /dev/ttyS1 115200 raw -echo -hupcl; timeout 900 cat /dev/ttyS1"
(ssh "${SSH_OPTS[@]}" "$DEV" "$CMD" | python3 -u -c '
import sys, time, os
out = open(sys.argv[1], "w")
while True:
    b = os.read(0, 4096)
    if not b: break
    out.write("@%.1f " % time.time() + b.decode("latin-1").replace("\r", "")); out.flush()
' "$LOG" > /dev/null 2>&1 &)
sleep 3; core_start
for i in $(seq 1 180); do grep -a -q 'login:' "$LOG" 2>/dev/null && break; sleep 5; done
sleep 2; cap_stop
python3 scripts/board/bootphases.py "$LOG"
t=$(python3 scripts/board/bootphases.py "$LOG" | grep 'login:' | tail -1 | awk '{print $1}')
[ -n "$t" ] && echo "PASS: $OS at its login in $t s" || { echo "FAIL: no login"; exit 1; }
