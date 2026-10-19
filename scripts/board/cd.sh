#!/usr/bin/env bash
# cd.sh openbios|obp [--obp FILE] [--cd IMAGE] [--rom FILE] [--secs N] [--log FILE]
#   - boot NetBSD's install CD (default netbsd11-cd.iso on the MiSTer) and
#   time it. Console on ttya, no disk. Last line: PASS or FAIL.
#
#   openbios  OpenBIOS (--rom FILE, default games/.../openbios.rom) at ok:
#             `boot cdrom:d`; the kernel's first line ("NetBSD 11.0
#             (INSTALL") must come within --secs (default 600; 113 s with
#             the caches on in go(), 2026-10-03)
#   obp       the Sun OBP (--obp FILE) with the NVRAM image ss20-obp.nvr
#             (no disk: auto-boot falls to ok): `boot cdrom` to the
#             installer's first question within --secs (default 1500; 899 s
#             in 2026-10: the OBP maps a client uncached without an
#             E-cache, PLAN.md E3)
set -u
. "$(dirname "$0")/../common.sh"
. scripts/board/lib.sh
WHAT=${1:-}; shift || true
OBP=""; CD=netbsd11-cd.iso; ROM=""; SECS=""; LOG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --obp) OBP=$2; shift ;;
        --cd) CD=$2; shift ;;
        --rom) ROM=$2; shift ;;
        --secs) SECS=$2; shift ;;
        --log) LOG=$2; shift ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac; shift
done
case "$WHAT" in
    openbios) : "${SECS:=600}" ;;
    obp) : "${SECS:=1500}"
         [ -f "$OBP" ] || { echo "obp needs --obp FILE (the Sun PROM image)"; exit 2; } ;;
    *) echo "usage: $0 openbios|obp [--obp FILE] [--cd IMAGE] [--rom FILE] [--secs N] [--log FILE]" >&2; exit 2 ;;
esac
: "${LOG:=sim/out/hw-20-cd-$WHAT.log}"
mkdir -p sim/out
if [ "$WHAT" = obp ]; then
    put_rom "$OBP" || exit 1
    scripts/mount.sh --hd0 "" --hd1 "" --cd "$CD" --nvram ss20-obp.nvr > /dev/null
else
    if [ -n "$ROM" ]; then put_rom "$ROM" || exit 1; else rsh "cp $G/openbios.rom $G/boot.rom"; fi
    scripts/mount.sh --hd0 "" --hd1 "" --cd "$CD" --nvram "" > /dev/null
fi
scripts/setopt.sh console=serial autoboot=off > /dev/null 2>&1
cap_stop; cap_start "$LOG" $((SECS + 600))
core_start
if [ "$WHAT" = obp ]; then
    tty_wait '^ok |ok $' 300 "$LOG" || { echo "FAIL: no ok prompt"; cap_stop; restore_openbios; exit 1; }
    sleep 3; t0=$(date +%s)
    TTY_DELAY=40000 tty_type 'boot cdrom\r'
    # the installer's first question (or a failure), after the boot command
    end='Installation medium|Terminal type|erase \^|sysinst|panic|Exception|Data Access'
else
    tty_wait '0 >' 120 "$LOG" || { echo "FAIL: no ok prompt"; cap_stop; restore_openbios; exit 1; }
    sleep 2; t0=$(date +%s)
    TTY_DELAY=60000 tty_type 'boot cdrom:d\r'
    end='NetBSD 11.0 .INSTALL|panic|Exception|Data Access'
fi
t=0; until sed -n '/boot cdrom/,$p' "$LOG" | grep -a -q -E "$end"; do
    sleep 1; t=$((t + 1)); [ $t -ge "$SECS" ] && break; done
dt=$(( $(date +%s) - t0 ))
cap_stop; restore_openbios
scripts/mount.sh --cd "" > /dev/null
if sed -n '/boot cdrom/,$p' "$LOG" | grep -a -q -E 'panic|Exception|Data Access'; then
    echo "FAIL: $WHAT: $(grep -a -m1 -E 'panic|Exception|Data Access' "$LOG")"; exit 1
elif [ $t -ge "$SECS" ]; then
    echo "FAIL: $WHAT: nothing after ${SECS}s; last line: $(tr -cd '\11\12\40-\176' < "$LOG" | grep -v '^ *$' | tail -1 | cut -c1-80)"; exit 1
fi
echo "PASS: $WHAT: boot cdrom ($CD) in ${dt}s"
