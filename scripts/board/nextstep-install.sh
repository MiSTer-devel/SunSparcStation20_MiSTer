#!/usr/bin/env bash
# nextstep-install.sh [--obp FILE | --rom FILE] [--disk NAME] [--cd IMAGE]
#                     [--log FILE] [--keep | --fresh]
# NeXTSTEP 3.3 for SPARC installed from its CD onto a blank 2000 MB disk
# (PLAN N1), under the Sun OBP with --obp, else under OpenBIOS (the
# board's openbios.rom, or --rom FILE); docs/disk-images.md describes the
# same steps by hand.
#
#   phase 1  ttya console: boot cdrom; English (1), prepare (1), install on
#            the 2000 MB disk (1), start (1); ~10 min of copying; Return
#            restarts from the disk; at the loader's boot: prompt -s, and
#            the single-user shell halts the machine (a clean stop: a core
#            reload under a running NeXTSTEP loses its last writes)
#   phase 2  screen console (the GUI needs it: with ttya NeXTSTEP attaches
#            no mouse): Ctrl-C skips the network panel; loginwindow logs in
#            "me" and runs Configure.app (Return saves its defaults) and,
#            after Configure's restart, BuildDisk in Install mode (loginwindow
#            writes "BuildDisk Install Yes" in me's defaults); Return installs
#            the packages from the CD and Return restarts
#   then     Restart; Ctrl-C again; the Welcome panel (English, USA) and its
#            confirmation: Return, Return; the Workspace; Log Out (Command-Q)
#            and Power Off (the mouse), a clean stop; the MiSTer menu
#   check    /private/adm/BuildDisk.custom on the disk (BuildDisk writes it
#            when done; loginwindow then starts Workspace instead) and the
#            receipts in /NextLibrary/Receipts (14 with every package)
#
# The disk (default ns33-new.img in the games folder) is created blank; an
# existing one is refused unless --keep (resume at phase 2) or --fresh (it
# is deleted first: for a test image, never a disk worth keeping). Keys go through
# a uinput keyboard (scripts/board/uinput_keys.py), the screen comes from the
# user's OBS (scripts/board/osd.sh shot) into sim/out/osd-nsi-*.png. The
# network is off. Last line: PASS or FAIL.
set -u
. "$(dirname "$0")/../common.sh"
. scripts/board/lib.sh
OBP=""; ROM=""; DISK=ns33-new.img; CD="NeXTSTEP 3.3 User (SPARC, PARISC).iso"
LOG=sim/out/hw-20-nextstep-install.log; KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --obp) OBP=$2; shift ;;
        --rom) ROM=$2; shift ;;
        --disk) DISK=$2; shift ;;
        --cd) CD=$2; shift ;;
        --log) LOG=$2; shift ;;
        --keep) KEEP=1 ;;
        --fresh) KEEP=2 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac; shift
done
[ -z "$OBP" ] || [ -f "$OBP" ] || { echo "no $OBP"; exit 2; }
[ -z "$ROM" ] || [ -f "$ROM" ] || { echo "no $ROM"; exit 2; }
mkdir -p sim/out
fail() { echo "FAIL: $*"; cap_stop; restore_openbios; scripts/setopt.sh console=serial autoboot=on > /dev/null 2>&1; exit 1; }
keys() { rsh "python3 /tmp/uinput_keys.py $*"; }
shot() { scripts/board/osd.sh shot "nsi-$1" > /dev/null 2>&1; }
for f in scripts/board/uinput_keys.py scripts/board/uinput_mouse.py tools/ufsread.py; do
    rsh "test -f /tmp/${f##*/}" || scp -q "${SSH_OPTS[@]}" "$f" "$DEV:/tmp/${f##*/}"
done

# The PROM and its console: ttya for phase 1, the screen for phase 2
prom() {   # prom serial|video
    if [ -n "$OBP" ]; then
        put_rom "$OBP" || exit 1
        local nv=ss20-obp.nvr; [ "$1" = video ] && nv=ss20-obp-video.nvr
        rsh "cp $G/$nv $G/nextstep-test.nvr" || exit 1
        scripts/mount.sh --hd0 "$DISK" --hd1 "" --cd "$CD" --nvram nextstep-test.nvr > /dev/null
        scripts/setopt.sh console=serial autoboot=$([ "$1" = serial ] && echo off || echo on) network=off > /dev/null 2>&1
    else
        if [ -n "$ROM" ]; then put_rom "$ROM" || exit 1; else rsh "cp $G/openbios.rom $G/boot.rom"; fi
        scripts/mount.sh --hd0 "$DISK" --hd1 "" --cd "$CD" --nvram "" > /dev/null
        if [ "$1" = serial ]; then
            scripts/setopt.sh console=serial autoboot=off network=off > /dev/null 2>&1
        else
            scripts/setopt.sh console=video autoboot=on network=off > /dev/null 2>&1
        fi
    fi
}

# Wait for the ttya log to show RE after the Nth occurrence of MARK
after() {   # after MARK N RE SECS
    local t=0
    until LC_ALL=C awk -v m="$1" -v n="$2" 'index($0, m) {c++} c >= n' "$LOG" | grep -a -q -E "$3"; do
        sleep 2; t=$((t + 2)); [ "$t" -ge "$4" ] && return 1
    done
    return 0    # (an until loop's status is its body's last command's)
}

if [ "$KEEP" != 1 ]; then
    [ "$KEEP" = 2 ] && rsh "rm -f $G/$DISK"
    rsh "test -e $G/$DISK" && { echo "FAIL: $G/$DISK exists (--keep resumes at phase 2)"; exit 1; }
    rsh "truncate -s 2097152000 $G/$DISK" || exit 1
    # ---- phase 1, ttya
    prom serial
    cap_stop; cap_start "$LOG" 5400
    core_start
    if [ -n "$OBP" ]; then
        tty_wait '^ok |ok $' 300 "$LOG" || fail "no ok prompt"
        sleep 3; TTY_DELAY=40000 tty_type 'boot cdrom\r'
    else
        tty_wait '0 >' 120 "$LOG" || fail "no OpenBIOS prompt"
        sleep 2; TTY_DELAY=60000 tty_type 'boot cdrom\r'
    fi
    for q in 'Type 1 to use the English' 'Type 1 to prepare to install' \
             'Type 1 to install NEXTSTEP on this disk' 'Type 1 to start installing'; do
        tty_wait "$q" 600 "$LOG" || fail "phase 1: no \"$q\" (see $LOG)"
        sleep 2; tty_type '1\r'
    done
    tty_wait 'Press Return to restart' 3600 "$LOG" || fail "phase 1: the copy did not finish (see $LOG)"
    sleep 2; tty_type '\r'
    # Auto boot is off for phase 1: the PROM may stop at its prompt
    after 'Press Return to restart' 1 '^boot: |ok $|0 >' 600 || fail "phase 1: no restart (see $LOG)"
    if ! after 'Press Return to restart' 1 '^boot: ' 1; then
        sleep 2; TTY_DELAY=60000 tty_type 'boot disk\r'
        after 'Press Return to restart' 1 '^boot: ' 600 || fail "phase 1: no restart from the disk (see $LOG)"
    fi
    sleep 1; tty_type '-s\r'
    after 'Press Return to restart' 1 'Singleuser boot' 600 || fail "phase 1: no single-user shell (see $LOG)"
    sleep 5; tty_type 'halt\r'
    after 'Press Return to restart' 1 'safe to turn off|halted' 120 || fail "phase 1: halt (see $LOG)"
    sleep 15
    cap_stop
    echo "phase 1 done: $(grep -a -c . "$LOG") lines in $LOG"
fi

# ---- phase 2, the screen
# Wait until the screen shows one of STATES (scripts/board/nsscreen.py)
screen() {   # screen SECS NAME STATE...
    local secs=$1 name=$2 t=0; shift 2
    while :; do
        shot "$name"
        python3 scripts/board/nsscreen.py "sim/out/osd-nsi-$name.png" "$@" > /dev/null && return 0
        t=$((t + 10)); [ "$t" -ge "$secs" ] && return 1
        sleep 8
    done
}
prom video
core_start
screen 600 net netpanel || fail "phase 2: no network panel (sim/out/osd-nsi-net.png)"
keys +29 46 -29                                   # Ctrl-C: no network
screen 600 cfg configure install || fail "phase 2: neither Configure.app nor BuildDisk (sim/out/osd-nsi-cfg.png)"
if python3 scripts/board/nsscreen.py sim/out/osd-nsi-cfg.png configure > /dev/null; then
    # Save, at the bottom right of "Summary of Devices": the pointer from the
    # top left corner in 2-count steps, which NeXTSTEP does not accelerate
    # (~0.5 screen pixels a count, a few pixels' spread); a miss clicks the
    # window's background, so try a little above and below too
    ok=0
    for d in "1203,910" "0,-12" "0,24"; do
        if [ "$d" = 1203,910 ]; then rsh "python3 /tmp/uinput_mouse.py m-3000,-3000 s2 m$d c"
        else rsh "python3 /tmp/uinput_mouse.py s2 m$d c"; fi
        screen 90 ins install && { ok=1; break; }
    done
    [ "$ok" = 1 ] || fail "phase 2: Save did not lead to BuildDisk (sim/out/osd-nsi-ins.png)"
fi
python3 scripts/board/nsscreen.py sim/out/osd-nsi-ins.png install > /dev/null 2>&1 ||
    screen 300 ins install nodisks || fail "phase 2: no BuildDisk (sim/out/osd-nsi-ins.png)"
python3 scripts/board/nsscreen.py sim/out/osd-nsi-ins.png nodisks > /dev/null &&
    fail "phase 2: BuildDisk in its normal mode: \"No disks that you can build\" (me's defaults lack BuildDisk Install)"
keys 28                                           # Install
echo "phase 2: installing the packages from $(date +%T)"
screen 14400 done done || fail "phase 2: BuildDisk did not finish (sim/out/osd-nsi-done.png)"
echo "phase 2: done at $(date +%T)"
keys 28                                           # Restart
screen 900 net2 netpanel || fail "phase 2: no restart (sim/out/osd-nsi-net2.png)"
keys +29 46 -29
screen 600 wel welcome || fail "phase 2: no Welcome panel (sim/out/osd-nsi-wel.png)"
keys 28                                           # English, USA
screen 120 conf confirm || fail "phase 2: no confirmation (sim/out/osd-nsi-conf.png)"
keys 28
screen 600 ws workspace || fail "phase 2: no Workspace (sim/out/osd-nsi-ws.png)"
# A clean stop: Log Out (Command-Q; Left Windows is Command), Power Off
sleep 30
keys +125 16 -125
screen 120 lo logout || fail "no Log Out panel (sim/out/osd-nsi-lo.png)"
ok=0
for d in "1050,651" "0,-12" "0,24"; do       # Power Off, as Save above
    if [ "$d" = 1050,651 ]; then rsh "python3 /tmp/uinput_mouse.py m-3000,-3000 s2 m$d c"
    else rsh "python3 /tmp/uinput_mouse.py s2 m$d c"; fi
    screen 120 off nspanel && { ok=1; break; }
done
[ "$ok" = 1 ] || fail "no shutdown (sim/out/osd-nsi-off.png)"
sleep 10
# (the disk is read below while the core is stopped: load the menu core
# through the OSD by hand; never /dev/MiSTer_cmd, the user's rule)
echo "nextstep-install: load the Menu core through the OSD now, then press Enter" >&2; read -r _
rsh "python3 /tmp/ufsread.py $G/$DISK ls /private/adm --offset 0x28000" | grep -q 'BuildDisk.custom' ||
    fail "no /private/adm/BuildDisk.custom on $DISK"
n=$(rsh "python3 /tmp/ufsread.py $G/$DISK ls /NextLibrary/Receipts --offset 0x28000" | grep -c '\.pkg$')
restore_openbios; scripts/setopt.sh console=serial autoboot=on > /dev/null 2>&1
echo "PASS: NeXTSTEP installed on $DISK ($([ -n "$OBP" ] && echo "Sun OBP" || echo OpenBIOS)): BuildDisk.custom, $n package receipts, shut down"
