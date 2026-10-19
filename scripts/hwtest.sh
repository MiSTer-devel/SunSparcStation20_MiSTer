#!/usr/bin/env bash
# hwtest.sh 20 TEST... - regression runs on the MiSTer, logged and checked.
#
# Tests (run in the order given):
#   cpu      the CPU suite as boot.rom (tests/cpu/out/<target>/cputest.rom);
#            the output must equal tests/cpu/expected/ss{5,20}-core-hw.log
#            (--record overwrites that baseline instead)
#   netbsd   OpenBIOS, console on ttya, HD0 = netbsd11.raw: wait for
#            'login:', log in as root, run a command, check its output
#   solaris  OpenBIOS, console on ttya, HD0 = sol8-ss20.img (its /dev links name the SS20's ESP
#            path, docs/disk-images.md; target 3): wait for
#            'console login:', log in as root, run a command, check its output
#   solaris-obp  the Sun PROM (--obp FILE, here; Sun's image is never in the
#            repo) with the NVRAM image --nvram NAME (default ss20-obp.nvr in
#            games/SunSparcStation/), HD0 = sol8-ss20.img: as solaris, plus
#            psrinfo, then 'init 0' so the disk is clean. The NVRAM image
#            must already hold diag-switch? false, auto-boot? true,
#            boot-device disk, input-device and output-device ttya (set them
#            once at the PROM's ok prompt: they are saved, TOD-6)
#   post     the Sun PROM's diagnostic POST (--obp FILE): a copy of the
#            NVRAM image (--nvram NAME, default ss20-obp.nvr) with byte 1,
#            diag-switch?, set to 0xff, as games/SunSparcStation/post.nvr;
#            wait for "Power-On SelfTest PASSED" on ttya (or FAILED, or the
#            OBP's "ttya initialized": OBP 2.25 on the SS20 prints no PASSED
#            banner, so that with no ERROR line is a pass). The POST runs its
#            list on each CPU; the log has the tests' names and any ERROR
#            lines
#   brk      a BREAK on ttya: tests/cpu/out/<target>/brktest.rom as boot.rom;
#            when it prints "BRK?", a BREAK (tcsendbreak on the MiSTer's
#            /dev/ttyS1, 0.25-0.5 s); the output must equal
#            tests/cpu/expected/ss{5,20}-brk-hw.log (--record writes it)
#   wdog     the watchdog reset: tests/cpu/out/<target>/wdtest.rom as
#            boot.rom puts CPU 0 in error mode (a trap with ET = 0); the
#            machine must come back through a watchdog reset (memory kept,
#            SFSR EM, system status WD) and print PASS (cpu.md IU-1)
#   kbd      the keyboard: tests/cpu/out/<target>/kbdtest.rom as boot.rom;
#            when it prints "KBD?", keys are typed on a virtual keyboard on
#            the MiSTer (scripts/board/uinput_keys.py: A, Stop-A, Right Alt
#            + Q, Help, Pause, Print Screen, F1), then at "RST?" Stop and A
#            are held across the keyboard's reset; the Sun codes the ROM
#            prints must equal tests/cpu/expected/ss{5,20}-kbd-hw.log
#            (--record writes it)
#   scsi     the SCSI path: tests/cpu/out/<target>/scsitest.rom as boot.rom
#            with two images of known content (tests/cpu/mkscsiimg.py, copied
#            to games/SunSparcStation/scsi-hd{0,1}.img) at HD0 (t3) and HD1
#            (t1), and the CD drive (t6) empty; the output must equal
#            tests/cpu/expected/ss{5,20}-scsi-hw.log (--record writes it), and
#            HD0 must be unchanged afterwards (the write test restores it).
#            HD0 = the OS image again and HD1 empty afterwards
#
# The longer board tests are scripts in scripts/board/ (each usable alone),
# run from here by name (SS20; the rbf, OpenBIOS and the NVRAM image as
# above; Main from sun-family for the network):
#   net-netbsd       NetBSD on the LAN (DHCP, ping both ways)
#   net-solaris      Solaris on the LAN, TCP both ways (scripts/board/net.sh)
#   net-solaris-obp  the same under the Sun PROM (--obp)
#   obp-testnet      the Sun PROM's `test net` and `boot net` (--obp)
#   wb               Main's disk write buffer: NetBSD writes 8 MB, reboots,
#                    checksums (scripts/board/wb.sh)
#   speed            Solaris: boot time and timed jobs (scripts/board/speed.sh;
#                    --l2tlb on|off there)
#   boottime         Solaris's boot by phase (scripts/board/boottime.sh)
#   audio-solaris    the SS20 audio card (CS4231 in slot 3): the driver attaches
#   audio-netbsd     and 2 s of /dev/audio play in ~2 s (scripts/board/audio.sh)
#   audio-solaris-obp  the same under the Sun OBP (--obp)
#   audio-obp        the Sun OBP builds SUNW,CS4231@3 from its FCode and names
#                    slot e dbri-absent (--obp)
#   cdaudio          CD audio under NetBSD: cdplay plays, pauses, resumes the
#                    audio tracks of cddatest.cue (tools/mkcdda.py; Main
#                    sun-family-ss20-scsi; scripts/board/cdaudio.sh)
#   nextstep         NeXTSTEP 3.3 from ns33.img to loginwindow, still running
#                    2 min later, under OpenBIOS (scripts/board/nextstep.sh;
#                    --bios FILE for another image)
#   nextstep-obp     the same under the Sun OBP (--obp)
#   nextstep-install NeXTSTEP 3.3 installed from its CD onto a blank disk
#                    (nsi-test.img, recreated), under OpenBIOS: the text
#                    phase on ttya, Configure.app and BuildDisk in the GUI,
#                    ~2.5 h (scripts/board/nextstep-install.sh; not in all)
#   nextstep-install-obp  the same under the Sun OBP (--obp)
#   hotplug          a CD attached and swapped, a disk attached, through the
#                    OSD while Solaris runs (scripts/board/hotplug.sh)
#   idprom-obp       the machine's identity from the MiSTer's Ethernet address
#                    (blank, kept, reset, boot1.rom, no image; --obp;
#                    scripts/board/idprom.sh)
#   cd               OpenBIOS boots NetBSD's install CD to its kernel
#                    (scripts/board/cd.sh; --bios FILE for another image)
#   cd-obp           the Sun PROM boots it to the installer (--obp)
#   stress           Solaris under load for --minutes N (default 30), under
#                    the Sun PROM if --obp is given (scripts/board/stress.sh)
#   all              cpu scsi brk kbd wdog netbsd solaris net-netbsd net-solaris cd
#                    nextstep,
#                    and with --obp also solaris-obp post net-solaris-obp
#                    obp-testnet idprom-obp audio-obp cd-obp nextstep-obp (not
#                    stress)
# --obp defaults to SUN_OBP from scripts/local.env.
#
#   scripts/hwtest.sh 5 cpu netbsd
#   scripts/hwtest.sh 5 --bios bios/build/boot.rom netbsd   (a new OpenBIOS)
#   scripts/hwtest.sh 20 --obp scratch/ss20-obp225.rom solaris-obp
#   scripts/hwtest.sh 20 --obp scratch/ss20-obp225.rom post
#
# The rbf must already be on the MiSTer (deploy.sh --no-launch). Logs go to
# sim/out/hw-<rev>-<test>.log. One capture at a time: a second reader on
# /dev/ttyS1 steals bytes from the first. Exit status: the number of tests
# that failed.
set -u
. "$(dirname "$0")/common.sh"
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
REV=$(rev_of "${1:-}") || exit 2; shift
RECORD=0
BIOS=""
OBP="${SUN_OBP:-}"
NVRAM=ss20-obp.nvr
MINUTES=30
TESTS=()
while [ $# -gt 0 ]; do
    a=$1; shift
    case "$a" in
        --record) RECORD=1 ;;
        --bios) BIOS=$1; shift ;;
        --obp) OBP=$1; shift ;;
        --nvram) NVRAM=$1; shift ;;
        --minutes) MINUTES=$1; shift ;;
        cpu|netbsd|solaris|solaris-obp|scsi|post|brk|kbd|wdog) TESTS+=("$a") ;;
        net-netbsd|net-solaris|net-solaris-obp|obp-testnet|idprom-obp|hotplug|wb|speed|boottime|audio-solaris|audio-solaris-obp|audio-netbsd|audio-obp|cd|cd-obp|cdaudio|nextstep|nextstep-obp|nextstep-install|nextstep-install-obp|stress) TESTS+=("$a") ;;
        all) TESTS+=(cpu scsi brk kbd wdog netbsd solaris net-netbsd net-solaris cd nextstep)
             [ -n "$OBP" ] && TESTS+=(solaris-obp post net-solaris-obp obp-testnet idprom-obp audio-obp cd-obp nextstep-obp) ;;
        *) echo "unknown argument $a" >&2; exit 2 ;;
    esac
done
[ ${#TESTS[@]} -gt 0 ] || { echo "usage: $0 20 [--record] [--bios FILE] [--obp FILE] [--nvram NAME] [--minutes N] TEST... (see the header)" >&2; exit 2; }
T=ss20; EXP=tests/cpu/expected/ss20-core-hw.log; OSIMG=sol8-ss20.img
G="/media/fat/games/$GAMES_DIR"
mkdir -p sim/out
rsh() { ssh "${SSH_OPTS[@]}" "$DEV" "$@"; }
clean() { tr -d '\r' < "$1" | tr -cd '\11\12\40-\176' | grep -v '^$'; }
# A test ROM's output from its first line on: the capture starts before the
# core is reloaded, so the previous machine's last output can precede it
romlog() { clean "$1" | sed -n '/^CPUTEST /,$p'; }

# Capture ttya for up to $2 seconds into $1 while launching the core; stop
# early when the log matches $3 (an extended regex).
run_capture() {
    local log=$1 secs=$2 until=$3
    scripts/console.sh --seconds "$secs" --out "$log" > /dev/null 2>&1 &
    local cp=$!
    sleep 3
    # boot.rom is the ROM under test: remove a Boot PROM record left by a
    # build before the OSD standard (FC0; Load ROM is F0, not remembered)
    rsh "rm -f /media/fat/config/$GAMES_DIR.f0"
    # through the OSD only (never /dev/MiSTer_cmd or mrext: the user's rule)
    scripts/board/osd_load.sh "$REV" >&2
    local t=0
    while kill -0 $cp 2>/dev/null; do
        if grep -a -q -E "$until" "$log" 2>/dev/null; then break; fi
        sleep 2; t=$((t + 2))
    done
    echo $cp
}
stop_capture() {   # the local ssh, and the remote cat it started
    kill "$1" 2>/dev/null
    # The MiSTer's busybox has no pkill. tty[S]1: a pattern that the awk
    # command line itself does not match.
    rsh "ps | awk '/cat \\/dev\\/tty[S]1/ {print \$1}' | xargs kill" 2>/dev/null
    wait "$1" 2>/dev/null
}
# Type on ttya; printf turns \r into Enter. No single quotes in $1.
type_tty() { rsh "printf '$1' > /dev/ttyS1"; }

FAILED=0
for t in "${TESTS[@]}"; do
    log="sim/out/hw-${REV#SunSparcStation}-$t.log"
    case "$t" in
    cpu)
        # always the current suite (a stale ROM once ran an old t_mmu_l2)
        python3 tests/cpu/build.py "$T" > /dev/null || exit 1
        rsh "cp $G/boot.rom /tmp/boot.rom.hwtest"
        scp -q "${SSH_OPTS[@]}" "tests/cpu/out/$T/cputest.rom" "$DEV:$G/boot.rom" || exit 1
        cp=$(run_capture "$log" 90 'CPUTEST DONE')
        sleep 2; stop_capture "$cp"
        rsh "cp /tmp/boot.rom.hwtest $G/boot.rom"
        if [ "$RECORD" = 1 ]; then
            romlog "$log" > "$EXP"; log "cpu: baseline recorded: $(grep 'CPUTEST DONE' "$EXP")"
        elif diff <(romlog "$EXP") <(romlog "$log") > "$log.diff"; then
            log "cpu: PASS, identical to $EXP ($(clean "$log" | grep 'CPUTEST DONE'))"
        else
            log "cpu: FAIL, differs from $EXP (diff in $log.diff; $(clean "$log" | grep 'CPUTEST DONE' || echo 'no CPUTEST DONE'))"
            FAILED=$((FAILED + 1))
        fi
        ;;
    scsi)
        sexp=tests/cpu/expected/${T%-core}-scsi-hw.log
        python3 tests/cpu/build.py "$T" --main=scsitest > /dev/null || exit 1
        for n in 0 1; do
            python3 tests/cpu/mkscsiimg.py "sim/out/scsi-hd$n.img" "HD$n" || exit 1
            scp -q "${SSH_OPTS[@]}" "sim/out/scsi-hd$n.img" "$DEV:$G/scsi-hd$n.img" || exit 1
        done
        rsh "cp $G/boot.rom /tmp/boot.rom.hwtest"
        scp -q "${SSH_OPTS[@]}" "tests/cpu/out/$T/scsitest.rom" "$DEV:$G/boot.rom" || exit 1
        scripts/mount.sh --hd0 scsi-hd0.img --hd1 scsi-hd1.img --cd "" > /dev/null
        scripts/setopt.sh console=serial > /dev/null
        cp=$(run_capture "$log" 120 'CPUTEST DONE')
        sleep 2; stop_capture "$cp"
        rsh "cp /tmp/boot.rom.hwtest $G/boot.rom"
        scripts/mount.sh --hd0 "$OSIMG" --hd1 "" > /dev/null
        scripts/setopt.sh console=serial > /dev/null
        same=$( [ "$(rsh "md5sum < $G/scsi-hd0.img" | cut -c1-32)" = "$(md5sum < sim/out/scsi-hd0.img | cut -c1-32)" ] && echo yes || echo no)
        if [ "$RECORD" = 1 ]; then
            romlog "$log" > "$sexp"; log "scsi: baseline recorded: $(grep 'CPUTEST DONE' "$sexp"); HD0 unchanged: $same"
        elif [ "$same" = yes ] && diff <(romlog "$sexp") <(romlog "$log") > "$log.diff"; then
            log "scsi: PASS, identical to $sexp ($(clean "$log" | grep 'CPUTEST DONE'))"
        else
            log "scsi: FAIL (HD0 unchanged: $same; diff in $log.diff; $(clean "$log" | grep 'CPUTEST DONE' || echo 'no CPUTEST DONE'))"
            FAILED=$((FAILED + 1))
        fi
        ;;
    net-netbsd|net-solaris|net-solaris-obp|obp-testnet|idprom-obp|hotplug|wb|speed|boottime|audio-solaris|audio-solaris-obp|audio-netbsd|audio-obp|cd|cd-obp|cdaudio|nextstep|nextstep-obp|nextstep-install|nextstep-install-obp|stress)
        case "$t" in
            cdaudio)      args=(scripts/board/cdaudio.sh) ;;
            idprom-obp)   args=(scripts/board/idprom.sh) ;;
            hotplug)      args=(scripts/board/hotplug.sh) ;;
            audio-*)      args=(scripts/board/audio.sh "${t#audio-}") ;;
            wb)           args=(scripts/board/wb.sh) ;;
            speed)        args=(scripts/board/speed.sh) ;;
            boottime)     args=(scripts/board/boottime.sh solaris) ;;
            net-*|obp-*)  args=(scripts/board/net.sh "${t#net-}") ;;
            cd)           args=(scripts/board/cd.sh openbios); [ -n "$BIOS" ] && args+=(--rom "$BIOS") ;;
            cd-obp)       args=(scripts/board/cd.sh obp) ;;
            nextstep)     args=(scripts/board/nextstep.sh); [ -n "$BIOS" ] && args+=(--rom "$BIOS") ;;
            nextstep-obp) args=(scripts/board/nextstep.sh) ;;
            nextstep-install) args=(scripts/board/nextstep-install.sh --disk nsi-test.img --fresh)
                          [ -n "$BIOS" ] && args+=(--rom "$BIOS") ;;
            nextstep-install-obp) args=(scripts/board/nextstep-install.sh --disk nsi-test.img --fresh) ;;
            stress)       args=(scripts/board/stress.sh --minutes "$MINUTES") ;;
        esac
        case "$t" in
            *obp*) [ -f "$OBP" ] || { log "$t needs --obp FILE (the Sun PROM image)"; exit 2; }
                   args+=(--obp "$OBP") ;;
            stress) [ -f "$OBP" ] && args+=(--obp "$OBP") ;;
        esac
        args+=(--log "$log")
        r=$("${args[@]}" 2>&1 | tee "$log.out" | tail -1)
        case "$r" in
            PASS*) log "$t: $r" ;;
            *) log "$t: ${r:-FAIL (no result)}"; FAILED=$((FAILED + 1)) ;;
        esac
        ;;
    kbd)
        kexp=tests/cpu/expected/${T%-core}-kbd-hw.log
        python3 tests/cpu/build.py "$T" --main=kbdtest > /dev/null || exit 1
        scp -q "${SSH_OPTS[@]}" scripts/board/uinput_keys.py "$DEV:/tmp/uinput_keys.py" || exit 1
        rsh "cp $G/boot.rom /tmp/boot.rom.hwtest"
        scp -q "${SSH_OPTS[@]}" "tests/cpu/out/$T/kbdtest.rom" "$DEV:$G/boot.rom" || exit 1
        scripts/setopt.sh console=serial > /dev/null
        cp=$(run_capture "$log" 60 'KBD[?]')
        # Linux key codes: A 30, Right Alt 100, F1 59, Q 16, F11 87, Pause
        # 119, Print Screen (SysRq) 99
        rsh "python3 /tmp/uinput_keys.py 30 w0.3 +100 +59 -100 30 -59 w0.3 +100 16 -100 w0.3 +100 87 -100 w0.3 119 w0.3 99 w0.3 59"
        t=0; while [ $t -lt 30 ] && ! grep -a -q 'RST[?]' "$log"; do sleep 1; t=$((t + 1)); done
        rsh "python3 /tmp/uinput_keys.py +100 +59 +30 w6 -30 -59 -100"
        t=0; while [ $t -lt 30 ] && ! grep -a -q 'CPUTEST DONE' "$log"; do sleep 1; t=$((t + 1)); done
        sleep 2; stop_capture "$cp"
        rsh "cp /tmp/boot.rom.hwtest $G/boot.rom"
        if [ "$RECORD" = 1 ]; then
            romlog "$log" > "$kexp"; log "kbd: baseline recorded: $(grep 'CPUTEST DONE' "$kexp")"
        elif diff <(romlog "$kexp") <(romlog "$log") > "$log.diff"; then
            log "kbd: PASS, identical to $kexp"
        else
            log "kbd: FAIL, differs from $kexp (diff in $log.diff)"
            FAILED=$((FAILED + 1))
        fi
        ;;
    brk)
        bexp=tests/cpu/expected/${T%-core}-brk-hw.log
        python3 tests/cpu/build.py "$T" --main=brktest > /dev/null || exit 1
        rsh "cp $G/boot.rom /tmp/boot.rom.hwtest"
        scp -q "${SSH_OPTS[@]}" "tests/cpu/out/$T/brktest.rom" "$DEV:$G/boot.rom" || exit 1
        scripts/setopt.sh console=serial > /dev/null
        cp=$(run_capture "$log" 60 'BRK[?]')
        rsh "python3 -c 'import os, termios; termios.tcsendbreak(os.open(\"/dev/ttyS1\", os.O_RDWR | os.O_NOCTTY), 0)'"
        t=0; while [ $t -lt 30 ] && ! grep -a -q 'CPUTEST DONE' "$log"; do sleep 1; t=$((t + 1)); done
        sleep 2; stop_capture "$cp"
        rsh "cp /tmp/boot.rom.hwtest $G/boot.rom"
        if [ "$RECORD" = 1 ]; then
            romlog "$log" > "$bexp"; log "brk: baseline recorded: $(grep 'CPUTEST DONE' "$bexp")"
        elif diff <(romlog "$bexp") <(romlog "$log") > "$log.diff"; then
            log "brk: PASS, identical to $bexp ($(clean "$log" | grep 'CPUTEST DONE'))"
        else
            log "brk: FAIL, differs from $bexp (diff in $log.diff; $(clean "$log" | grep 'CPUTEST DONE' || echo 'no CPUTEST DONE'))"
            FAILED=$((FAILED + 1))
        fi
        ;;
    wdog)
        python3 tests/cpu/build.py "$T" --main=wdtest > /dev/null || exit 1
        rsh "cp $G/boot.rom /tmp/boot.rom.hwtest"
        scp -q "${SSH_OPTS[@]}" "tests/cpu/out/$T/wdtest.rom" "$DEV:$G/boot.rom" || exit 1
        scripts/setopt.sh console=serial > /dev/null
        cp=$(run_capture "$log" 60 'CPUTEST DONE|ran on')
        sleep 2; stop_capture "$cp"
        rsh "cp /tmp/boot.rom.hwtest $G/boot.rom"
        if clean "$log" | grep -q '^PASS wdog' && clean "$log" | grep -q 'CPUTEST DONE pass=1 fail=0'; then
            log "wdog: PASS ($(clean "$log" | grep -c '^CPUTEST ss') banners: error mode came back as a watchdog reset)"
        else
            log "wdog: FAIL ($(clean "$log" | tail -2 | tr '\n' ' '))"
            FAILED=$((FAILED + 1))
        fi
        ;;
    post)
        [ -f "$OBP" ] || { log "post needs --obp FILE (the Sun PROM image)"; exit 2; }
        rsh "test -s $G/$NVRAM" || { log "no $G/$NVRAM on the MiSTer"; exit 2; }
        rsh "cp $G/$NVRAM $G/post.nvr && printf '\\377' | dd of=$G/post.nvr bs=1 seek=1 conv=notrunc 2> /dev/null" || exit 1
        scp -q "${SSH_OPTS[@]}" "$OBP" "$DEV:$G/boot.rom" || exit 1
        scripts/mount.sh --nvram post.nvr > /dev/null
        scripts/setopt.sh console=serial > /dev/null
        cp=$(run_capture "$log" 900 'Power-On SelfTest (PASSED|FAILED)|ttya initialized')
        sleep 30; stop_capture "$cp"       # (the probing, then ok)
        rsh "cp $G/openbios.rom $G/boot.rom"
        scripts/mount.sh --nvram "" > /dev/null
        r=$(clean "$log" | grep -a -m1 -o -E 'Power-On SelfTest (PASSED|FAILED).*' || true)
        # OBP 2.25 on the SS20 prints no PASSED banner: a POST that ends in
        # "ttya initialized" with no ERROR line passed
        ne=$(clean "$log" | grep -a -c 'ERROR')
        [ -z "$r" ] && [ "$ne" = 0 ] && clean "$log" | grep -a -q 'ttya initialized' \
            && r="PASSED: no ERROR lines, then $(clean "$log" | grep -a -c '^Probing') Probing lines$(clean "$log" | grep -a -q 'ok' && echo ', ok')"
        case "$r" in
        *PASSED*) log "post: PASS ($r)" ;;
        *) log "post: FAIL (${r:-no result after 900 s}; $(clean "$log" | grep -a -c 'ERROR') ERROR lines; first: $(clean "$log" | grep -a -m1 -A2 'ERROR' | tr -s ' ' | tr '\n' ' '))"
           FAILED=$((FAILED + 1)) ;;
        esac
        ;;
    netbsd|solaris|solaris-obp)
        if [ "$t" = netbsd ]; then img=netbsd11.raw; want='login:'; secs=900
        elif [ "$t" = solaris ]; then want='console login:'; secs=1800
            if [ "$REV" = SunSparcStation20 ]; then img=sol8-ss20.img; else img=sol8.img; fi
        else img=sol8-ss20.img; want='console login:'; secs=1800; fi
        if [ "$t" = solaris-obp ]; then
            [ -f "$OBP" ] || { log "solaris-obp needs --obp FILE (the Sun PROM image)"; exit 2; }
            rsh "test -s $G/$NVRAM" || { log "no $G/$NVRAM on the MiSTer"; exit 2; }
            scp -q "${SSH_OPTS[@]}" "$OBP" "$DEV:$G/boot.rom" || exit 1
            scripts/mount.sh --nvram "$NVRAM" > /dev/null
        else
            # OpenBIOS formats any NVRAM image it does not recognise: run it
            # with the slot empty, so a saved Sun PROM image survives.
            scripts/mount.sh --nvram "" > /dev/null
            if [ -n "$BIOS" ]; then
                scp -q "${SSH_OPTS[@]}" "$BIOS" "$DEV:$G/boot.rom" || exit 1
            else
                rsh "cp $G/openbios.rom $G/boot.rom"
            fi
        fi
        scripts/setopt.sh console=serial > /dev/null
        scripts/mount.sh --hd0 "$img" > /dev/null
        cp=$(run_capture "$log" "$secs" "$want")
        if ! grep -a -q "$want" "$log"; then
            stop_capture "$cp"
            log "$t: FAIL, no '$want' after ${secs}s; last line: $(clean "$log" | tail -1)"
            FAILED=$((FAILED + 1)); continue
        fi
        # Log in and run a command; the marker X-""42 prints X-42, which
        # the echoed command line cannot match (any shell, Bourne included).
        sleep 2; type_tty 'root\r'; sleep 8
        type_tty 'uname -sr; echo X-""42\r'; sleep 8
        if [ "$t" = solaris-obp ]; then
            type_tty 'psrinfo\r'; sleep 5
            type_tty 'sync; init 0\r'; sleep 90
            rsh "cp $G/openbios.rom $G/boot.rom"
        fi
        stop_capture "$cp"
        if clean "$log" | grep -q '^X-42$'; then
            log "$t: PASS, login and shell on ttya ($(clean "$log" | grep -a -m1 -E '^(NetBSD|SunOS) [0-9]' || true))$([ "$t" = solaris-obp ] && echo "; $(clean "$log" | grep -a -c 'on-line') CPUs on-line")"
        else
            log "$t: FAIL, '$want' seen but the shell did not answer"
            FAILED=$((FAILED + 1))
        fi
        ;;
    esac
done
exit $FAILED
