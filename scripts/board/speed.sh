#!/usr/bin/env bash
# speed.sh [--l2tlb on|off] [--log FILE] - Solaris 8 (OpenBIOS, ttya, HD0
# sol8-ss20.img): the boot to login and a few timed jobs (a raw disk read,
# a disk write, bc, a ksh loop, reading /usr/lib), as a performance record;
# with --l2tlb, the OSD's L2TLB option set for the run (PLAN A2/N1: its
# default). Prints the times; last line PASS when every job finished.
set -u
. "$(dirname "$0")/../common.sh"
. scripts/board/lib.sh
LOG=sim/out/hw-20-speed.log; L2=""
while [ $# -gt 0 ]; do
    case "$1" in
        --l2tlb) L2=$2; shift ;;
        --log) LOG=$2; shift ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac; shift
done
mkdir -p sim/out
rsh "cp $G/openbios.rom $G/boot.rom"
scripts/mount.sh --hd0 sol8-ss20.img --hd1 "" --cd "" --nvram "" > /dev/null
scripts/setopt.sh console=serial autoboot=on ${L2:+l2tlb=$L2} > /dev/null 2>&1 || exit 1
cap_stop; cap_start "$LOG" 3000
t0=$(date +%s); core_start
tty_wait 'console login:|panic\[' 1200 "$LOG" || { echo "FAIL: no login"; cap_stop; exit 1; }
echo "boot to login: $(( $(date +%s) - t0 )) s${L2:+ (L2TLB $L2)}"
sleep 5; tty_type 'root\r'; sleep 20
ok=1
# job NAME TIMEOUT CMD: timex's real/user/sys, then NAME (no single quotes:
# tty_type sends the text through ssh in them)
job() { local n=$1 t=$2; shift 2; tty_run "$*; echo $n" "$t" "$LOG" || ok=0; }
job rawread 900 'timex dd if=/dev/rdsk/c1t3d0s2 of=/dev/null bs=64k count=160'
job write 900 'timex dd if=/dev/zero of=/var/tmp/speed.dat bs=64k count=80; sync'
tty_run 'rm -f /var/tmp/speed.dat' 120 "$LOG"
job bc 1200 'echo "scale=400; 4*a(1)" | timex bc -l > /dev/null'
job ksh 1200 'timex /usr/bin/ksh -c "i=0; while [ \$i -lt 100000 ]; do i=\$((i+1)); done"'
job readlibs 900 'timex cat /usr/lib/*.so* > /dev/null'
tty_type 'sync; init 0\r'
tty_wait 'ok |Program terminated' 300 "$LOG"
cap_stop
[ -n "$L2" ] && scripts/setopt.sh l2tlb=off > /dev/null 2>&1
tr -d '\r' < "$LOG" | grep -a -E '^real|^(rawread|write|bc|ksh|readlibs)$' | paste - - | awk '{printf "%-9s %s s\n", $3, $2}'
[ $ok = 1 ] && echo "PASS: every job finished" || { echo "FAIL: a job timed out"; exit 1; }
