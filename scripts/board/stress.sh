#!/usr/bin/env bash
# stress.sh [--obp FILE | --bios FILE] [--minutes N] [--one-cpu] [--log FILE] [OPTS...]
#   - Solaris 8 (HD0 sol8-ss20.img, console on ttya) under load: boot to
#   the login, log in, run three `find /usr | cksum` loops, and every minute
#   check that the shell answers, for N minutes (default 30; 30-40 is the
#   project's stress length). Under the Sun OBP (--obp FILE, NVRAM image
#   ss20-obp.nvr) by default all CPUs stay on; --one-cpu offlines 1 and 2.
#   --bios FILE boots that OpenBIOS image instead (no NVRAM image). OPTS are
#   setopt.sh options (e.g. l2tlb=on). Last line: PASS or FAIL.
set -u
. "$(dirname "$0")/../common.sh"
. scripts/board/lib.sh
OBP=""; BIOS=""; M=30; ONE=0; LOG=sim/out/hw-20-stress.log; OPTS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --obp) OBP=$2; shift ;;
        --bios) BIOS=$2; shift ;;
        --minutes) M=$2; shift ;;
        --one-cpu) ONE=1 ;;
        --log) LOG=$2; shift ;;
        *=*) OPTS+=("$1") ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac; shift
done
mkdir -p sim/out
if [ -n "$OBP" ]; then
    put_rom "$OBP" || exit 1
    scripts/mount.sh --hd0 sol8-ss20.img --nvram ss20-obp.nvr > /dev/null
elif [ -n "$BIOS" ]; then
    put_rom "$BIOS" || exit 1
    scripts/mount.sh --hd0 sol8-ss20.img --nvram "" > /dev/null
else
    rsh "cp $G/openbios.rom $G/boot.rom"
    scripts/mount.sh --hd0 sol8-ss20.img --nvram "" > /dev/null
fi
scripts/setopt.sh console=serial autoboot=on "${OPTS[@]}" > /dev/null 2>&1 || exit 1
cap_stop; cap_start "$LOG" $(( M * 60 + 1800 ))
core_start
t0=$(date +%s)
tty_wait 'console login:|panic\[' 1800 "$LOG" || { echo "FAIL: no login prompt"; cap_stop; restore_openbios; exit 1; }
grep -a -q 'panic\[' "$LOG" && { echo "FAIL: panic during the boot"; cap_stop; restore_openbios; exit 1; }
echo "login after $(( $(date +%s) - t0 ))s"
sleep 5; tty_type 'root\r'; sleep 15
[ "$ONE" = 1 ] && { tty_type 'psradm -f 1 2; psrinfo\r'; sleep 10; }
tty_type 'cd /; date; for i in 1 2 3; do (find /usr -type f -exec cksum {} \; > /dev/null 2>&1; echo STRESS-DONE-$i) & done\r'
sleep 15
pat='panic\[|panic: |uvm_fault|^db\{'
p0=$(grep -a -c -E "$pat" "$LOG"); miss=0; res=""
for i in $(seq 1 "$M"); do
    tag="W$i-$RANDOM"
    tty_type "ps -e | grep cksum | tail -1; echo $tag-\"\"OK\r"
    sleep 20
    if grep -a -q "^$tag-OK" "$LOG"; then
        miss=0
    else
        miss=$((miss + 1))
        echo "$(date +%H:%M:%S) minute $i: no answer"
        [ $miss -ge 2 ] && { res="FAIL: the shell stopped answering at minute $i"; break; }
    fi
    [ "$(grep -a -c -E "$pat" "$LOG")" -gt "$p0" ] && { res="FAIL: panic at minute $i"; break; }
    sleep 40
done
if [ -z "$res" ]; then
    tty_type 'sync; init 0\r'
    tty_wait 'Program terminated|ok ' 300 "$LOG"
fi
cap_stop; restore_openbios
echo "${res:-PASS: $M minutes of stress$([ "$ONE" = 1 ] && echo ', one CPU' || echo ', all CPUs')}"
[ -z "$res" ]
