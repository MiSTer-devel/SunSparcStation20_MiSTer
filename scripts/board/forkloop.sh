#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# forkloop.sh [--core NAME] [--rom FILE] [--img IMAGE] [--tests "T..."]
#             [--hours H] [--stall SECS] [--log FILE] [--no-selftest]
# Hunts the intermittent freeze under fork-heavy load (docs/benchmarks/
# profile-20261014.md): NetBSD from the UnixBench image (as unixbench.sh),
# then UnixBench's TESTS (default "spawn shell8 execl") in an endless loop
# on the guest, each pass announced as PASS-N. The ttya capture must grow
# at least every SECS seconds (default 300; a test prints a result at least
# every ~70 s). When it stops:
#   - a "#HANG" line from the core's hang reporter (a build with
#     ss20_machine's HANG_DUMP = 1:
#     CPU 0 not committing, or spinning without traps) says the CPU itself
#     stopped (its words: rtl/lib/hang_dump.sv, cpu_module.sv dbg_w_o);
#   - else a BREAK on ttya enters NetBSD's DDB, and the script records
#     ps /w, ps /l, trace, show event, show uvmexp, show reg there.
# The machine is then left as it is (in DDB, or hung) for a closer look:
# `scripts/board/forkloop.sh --type 'CMD'` types more on ttya, the capture
# runs on to HOURS + 3 h. Exit 0 after HOURS with no freeze, 1 on a freeze.
#
# Before the loop, a self-test: a BREAK at the shell must reach DDB
# ("Stopped in") and `c` continue it (--no-selftest skips it).
set -u
. "$(dirname "$0")/../common.sh"
. scripts/board/lib.sh
CORE=SunSparcStation20; ROM=""; IMG=netbsd11-ub.raw; TESTS="spawn shell8 execl"
HOURS=4; STALL=300; LOG=sim/out/hw-forkloop.log; SELFTEST=1
brk() { rsh "python3 -c 'import os, termios; termios.tcsendbreak(os.open(\"/dev/ttyS1\", os.O_RDWR | os.O_NOCTTY), 0)'"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --core)  CORE=$2; shift ;;
        --rom)   ROM=$2; shift ;;
        --img)   IMG=$2; shift ;;
        --tests) TESTS=$2; shift ;;
        --hours) HOURS=$2; shift ;;
        --stall) STALL=$2; shift ;;
        --log)   LOG=$2; shift ;;
        --no-selftest) SELFTEST=0 ;;
        --type)  tty_type "$2"; exit 0 ;;
        --break) brk; exit 0 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac; shift
done
mkdir -p sim/out
log() { echo "$(date +%H:%M:%S) forkloop: $*"; }
size() { stat -c %s "$LOG" 2>/dev/null || stat -f %z "$LOG"; }
fail() { log "FAIL: $*"; cap_stop; restore_openbios; exit 2; }

if [ -n "$ROM" ]; then put_rom "$ROM" || exit 1; else rsh "cp $G/openbios.rom $G/boot.rom"; fi
scripts/mount.sh --hd0 "$IMG" --hd1 "" --cd "" --nvram "" > /dev/null
scripts/setopt.sh console=serial autoboot=on > /dev/null 2>&1 || exit 1
cap_stop; cap_start "$LOG" $(( HOURS * 3600 + 3 * 3600 ))
core_start "$CORE"
tty_wait '^login:' 1200 "$LOG" || fail "no login"
sleep 5; tty_type 'root\r'; sleep 15
tty_run 'uname -a' 60 "$LOG" || fail "no shell"

if [ "$SELFTEST" = 1 ]; then
    brk
    tty_wait 'Stopped in|db[{]?[0-9]*[}]?>' 30 "$LOG" || fail "a BREAK does not reach DDB (no 'Stopped in')"
    sleep 1; tty_type 'c\r'; sleep 2
    tty_run 'echo selftest' 60 "$LOG" || fail "no shell after DDB's c"
    log "self-test: BREAK -> DDB -> c works"
fi

tty_type "cd /root/ub; i=0; while :; do i=\$((i+1)); echo PASS-\"\"\$i; sh ub.sh run 1 $TESTS; done\r"
end=$(( $(date +%s) + HOURS * 3600 )); last=$(size); quiet=0
while [ "$(date +%s)" -lt "$end" ]; do
    sleep 10
    s=$(size)
    if [ "$s" != "$last" ]; then last=$s; quiet=0; else quiet=$((quiet + 10)); fi
    [ "$quiet" -ge "$STALL" ] && break
done
if [ "$quiet" -lt "$STALL" ]; then
    n=$(tr -d '\r' < "$LOG" | grep -a -c '^PASS-[0-9]')
    log "no freeze in $HOURS h ($n passes); stopping"
    tty_type '\003'; sleep 2; tty_type 'sync; halt\r'; sleep 20
    cap_stop; restore_openbios; exit 0
fi

n=$(tr -d '\r' < "$LOG" | grep -a -c '^PASS-[0-9]')
log "FREEZE: no output for $STALL s, in pass $n; last lines:"
tr -d '\r' < "$LOG" | grep -a -v '^\s*$' | tail -5
if grep -a -q '#HANG' "$LOG"; then
    log "the hang reporter fired:"; grep -a '#HANG' "$LOG" | tail -3
fi
log "BREAK"
brk
if tty_wait 'Stopped in|db[{]?[0-9]*[}]?>' 30 "$LOG"; then
    log "in DDB; recording"
    for c in 'set $lines = 0' 'ps /w' 'ps /l' 'trace' 'show event' 'show uvmexp' 'show reg'; do
        TTY_DELAY=30000 tty_type "$c\r"; sleep 8
    done
    log "done; the machine is left in DDB (forkloop.sh --type 'CMD\\r' for more)"
else
    log "no answer to the BREAK: the kernel is not taking the serial interrupt"
fi
tr -d '\r' < "$LOG" | grep -a -c '#HANG' | sed 's/^/hang lines: /'
exit 1
