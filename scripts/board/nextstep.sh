#!/usr/bin/env bash
# nextstep.sh [--obp FILE | --rom FILE] [--l2tlb on|off] [--disk IMAGE]
# [--cd IMAGE] [--log FILE] - NeXTSTEP 3.3 for SPARC (PLAN N1) from its
# disk, under the Sun OBP with --obp, else under OpenBIOS (the board's
# openbios.rom, or --rom FILE). --l2tlb sets the OSD's L2TLB option for the
# run; it acts only where the PROM sets MCNTL bit 6 (OpenBIOS does, the Sun
# OBP does not).
#
# The disk is a NeXTSTEP 3.3 installation (HD0, default ns33.img in the
# games folder; docs/disk-images.md says how it was made), the CD its
# installation CD: until the installation is finished in the GUI, the
# installer's /etc/fstab mounts it (/NEXTSTEP_INSTALL), and fsck stops
# the boot without it ("Can't read label on /dev/rsd1a"). Under the Sun
# OBP the NVRAM is a fresh copy of ss20-obp.nvr (console on ttya, every
# other variable at its default: sbus-probe-list fe0123, so slot e's node is
# probed); under OpenBIOS there is no NVRAM image and the OSD auto-boots.
# The network is off. Steps:
#   - the boot reaches rc's "Reboot complete" (TMR-8: the delay loop
#     calibrates against the user timer; DEC-4: sbus_config names every
#     SBus node; Ctrl-C on ttya skips the network configuration panel);
#   - loginwindow starts;
#   - the Workspace logs in ("Workspace[n]: logged in" on ttya, about 10 s
#     later under either PROM): rc, loginwindow and the Workspace's start
#     all ran, so the machine kept running (ESP-7, CPU 0 spinning on the
#     SCSI completion's interlock, never got here). Until 2026-10-17 this
#     step read CPU 0's PC with tools/debugarm/pcdump, which cannot be
#     built (clean room).
# With the console on ttya NeXTSTEP attaches no mouse (consconfig): for
# the GUI, use a copy of ss20-obp-video.nvr instead.
# Last line: PASS or FAIL.
set -u
. "$(dirname "$0")/../common.sh"
. scripts/board/lib.sh
OBP=""; ROM=""; L2=""; DISK=ns33.img; CD="NeXTSTEP 3.3 User (SPARC, PARISC).iso"
LOG=sim/out/hw-20-nextstep.log
while [ $# -gt 0 ]; do
    case "$1" in
        --obp) OBP=$2; shift ;;
        --rom) ROM=$2; shift ;;
        --l2tlb) L2=$2; shift ;;
        --disk) DISK=$2; shift ;;
        --cd) CD=$2; shift ;;
        --log) LOG=$2; shift ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac; shift
done
[ -z "$OBP" ] || [ -f "$OBP" ] || { echo "no $OBP"; exit 2; }
[ -z "$ROM" ] || [ -f "$ROM" ] || { echo "no $ROM"; exit 2; }
rsh "test -f $G/$DISK" || { echo "FAIL: no $G/$DISK on the MiSTer"; exit 1; }
mkdir -p sim/out
fail() { echo "FAIL: $*"; cap_stop; restore_openbios; scripts/setopt.sh console=serial > /dev/null 2>&1; exit 1; }

if [ -n "$OBP" ]; then
    put_rom "$OBP" || exit 1
    rsh "cp $G/ss20-obp.nvr $G/nextstep-test.nvr" || exit 1
    scripts/mount.sh --hd0 "$DISK" --hd1 "" --cd "$CD" --nvram nextstep-test.nvr > /dev/null
    scripts/setopt.sh console=serial network=off ${L2:+l2tlb=$L2} > /dev/null 2>&1 || exit 1
else
    if [ -n "$ROM" ]; then put_rom "$ROM" || exit 1; else rsh "cp $G/openbios.rom $G/boot.rom"; fi
    scripts/mount.sh --hd0 "$DISK" --hd1 "" --cd "$CD" --nvram "" > /dev/null
    scripts/setopt.sh console=serial autoboot=on network=off ${L2:+l2tlb=$L2} > /dev/null 2>&1 || exit 1
fi
cap_stop; cap_start "$LOG" 1800
core_start
# Under OpenBIOS nothing passes -v: without it the kernel prints nothing on
# ttya after the loader, so answer the loader's prompt
[ -n "$OBP" ] || { tty_wait 'boot: ' 300 "$LOG" && tty_type '-v\r'; }
# Every run ends with the core reloaded under NeXTSTEP, so the root is
# unclean at the next: fsck fixes it and reboots once ("Root fixed")
drv='Setting tape block size for /dev/nrst1'
tty_wait "$drv|panic|BAD TRAP|RUN fsck|Root fixed" 600 "$LOG" || fail "no driver configuration (see $LOG)"
if grep -a -q 'Root fixed' "$LOG"; then
    t=0
    until sed -n '/Root fixed/,$p' "$LOG" | grep -a -q -E "$drv|panic|BAD TRAP|RUN fsck"; do
        sleep 2; t=$((t + 2))
        [ "$t" -ge 600 ] && fail "no driver configuration after fsck's reboot (see $LOG)"
    done
fi
grep -a -q 'RUN fsck' "$LOG" && fail "fsck stopped the boot (see $LOG)"
grep -a -q -E 'panic|BAD TRAP' "$LOG" && fail "kernel panic (see $LOG)"
# The network configuration panel is on the screen: "No response from
# network configuration server", Ctrl-C on the console (ttya) skips it
for try in 1 2 3; do
    sleep 60; tty_type $'\x03'
    tty_wait 'Reboot complete' 120 "$LOG" && break
done
grep -a -q 'Reboot complete' "$LOG" || fail "rc did not finish (see $LOG)"
tty_wait 'loginwindow' 120 "$LOG" || fail "no loginwindow (see $LOG)"
tty_wait 'Workspace\[[0-9]+\]: logged in' 180 "$LOG" || fail "loginwindow started but the Workspace did not log in (see $LOG)"
cap_stop
restore_openbios; scripts/setopt.sh console=serial > /dev/null 2>&1
echo "PASS: NeXTSTEP booted to loginwindow and the Workspace logged in${L2:+ (OSD L2TLB $L2)}"
