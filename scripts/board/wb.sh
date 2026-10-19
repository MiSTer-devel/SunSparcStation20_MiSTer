#!/usr/bin/env bash
# wb.sh [--log FILE] - Main's disk write buffer end to end: NetBSD (OpenBIOS,
# ttya, HD0 netbsd11.raw) writes 8 MB of random data (16 KB writes) and a
# copy of it in 7 KB writes, checksums both, reboots, and checksums them
# again, now read from the image. Last line: PASS or FAIL.
set -u
. "$(dirname "$0")/../common.sh"
. scripts/board/lib.sh
LOG=sim/out/hw-20-wb.log
[ "${1:-}" = --log ] && LOG=$2
mkdir -p sim/out
rsh "cp $G/openbios.rom $G/boot.rom"
scripts/mount.sh --hd0 netbsd11.raw --hd1 "" --cd "" --nvram "" > /dev/null
scripts/setopt.sh console=serial autoboot=on network=off > /dev/null 2>&1 || exit 1
cap_stop; cap_start "$LOG" 2400
core_start
login() { tty_wait "$1" 900 "$LOG" || { echo "FAIL: no login"; cap_stop; exit 1; }
          sleep 3; tty_type 'root\r'; sleep 10; }
login '^login:'
tty_run 'dd if=/dev/urandom of=/var/tmp/wb.dat bs=16k count=512' 300 "$LOG"
tty_run 'dd if=/var/tmp/wb.dat of=/var/tmp/wb2.dat bs=7k' 300 "$LOG"
tty_run 'cksum /var/tmp/wb.dat /var/tmp/wb2.dat; sync' 120 "$LOG"
n0=$(grep -a -c '^login:' "$LOG")
tty_type 'reboot\r'
for i in $(seq 1 180); do [ "$(grep -a -c '^login:' "$LOG")" -gt "$n0" ] && break; sleep 5; done
sleep 3; tty_type 'root\r'; sleep 10
tty_run 'cksum /var/tmp/wb.dat /var/tmp/wb2.dat' 120 "$LOG"
tty_run 'rm -f /var/tmp/wb.dat /var/tmp/wb2.dat; sync' 60 "$LOG"
tty_type 'halt\r'; sleep 20
cap_stop
scripts/setopt.sh network=eth0 > /dev/null 2>&1
S=$(tr -d '\r' < "$LOG" | grep -a -E '^[0-9]+ [0-9]+ /var/tmp/wb2?\.dat$')
echo "$S"
n=$(echo "$S" | grep -c .); u=$(echo "$S" | awk '{print $1, $2}' | sort -u | wc -l)
if [ "$n" -eq 4 ] && [ "$u" -eq 1 ]; then echo "PASS: 8 MB written in 16 KB and 7 KB blocks, the same checksum before and after a reboot"
else echo "FAIL: $n checksums, $u distinct"; exit 1; fi
