# Sourced by the board tests (scripts/board/*.sh): the MiSTer's files, the
# ttya capture, typing on ttya and waiting for output, starting the core.
# Source scripts/common.sh first (repository root, local.env, SSH_OPTS, DEV).
#
#   G                    the core's games folder on the MiSTer
#   rsh CMD...           run CMD on the MiSTer
#   core_start [REV]     load the revision's rbf (default SunSparcStation20)
#   put_rom FILE         FILE becomes boot.rom
#   restore_openbios     boot.rom = openbios.rom again, no NVRAM image
#   cap_start LOG SECS   capture ttya into LOG in the background
#   cap_stop             stop every capture (local and on the MiSTer)
#   tty_type TEXT        type TEXT on ttya one character at a time; \r is
#                        Enter; TTY_DELAY microseconds apart (default 20000;
#                        40000 at a PROM's ok prompt). No single quotes in
#                        TEXT (the ssh quoting): type programs through
#                        here-documents
#   tty_wait RE SECS LOG wait until LOG matches the extended regex RE;
#                        status 1 after SECS
#   tty_run CMD SECS LOG type CMD at a shell and wait for its end (a marker
#                        echoed after it); status 1 after SECS
#   host_ip              this machine's address on the MiSTer's network
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
G="/media/fat/games/$GAMES_DIR"

rsh() { ssh "${SSH_OPTS[@]}" "$DEV" "$@"; }

# The OSD's Load ROM (CONF_STR F0) is not remembered, so every start loads
# boot.rom, the ROM the tests set. Builds before the OSD standard remembered
# it (FC0, config/<core>.f0): a record left by one is removed first
# (KEEP_PROM=1 keeps it)
core_start() {
    [ "${KEEP_PROM:-0}" = 1 ] || rsh "rm -f /media/fat/config/$GAMES_DIR.f0"
    # through the OSD only (never /dev/MiSTer_cmd or mrext: the user's rule)
    scripts/board/osd_load.sh "${1:-SunSparcStation20}"
}

put_rom() { scp -q "${SSH_OPTS[@]}" "$1" "$DEV:$G/boot.rom"; }

restore_openbios() {
    rsh "cp $G/openbios.rom $G/boot.rom"
    scripts/mount.sh --nvram "" > /dev/null
}

cap_start() {
    rm -f "$1"
    (scripts/console.sh --seconds "$2" --out "$1" > /dev/null 2>&1 &)
    sleep 3
}

cap_stop() {
    local p
    # console[.]sh: the pattern must not match this shell's own command line
    for p in $(pgrep -f 'console[.]sh'); do kill "$p" 2>/dev/null; done
    # the MiSTer's busybox has no pkill; tty[S]1 for the same reason
    rsh "ps | awk '/cat \\/dev\\/tty[S]1/ {print \$1}' | xargs kill" 2>/dev/null
    true
}

tty_type() {
    local t=${1//\\r/$'\r'}
    rsh "sh -c 's=\"\$1\"; while [ -n \"\$s\" ]; do c=\${s%\"\${s#?}\"}; s=\${s#?}; printf %s \"\$c\" > /dev/ttyS1; usleep ${TTY_DELAY:-20000}; done' x '$t'"
}

tty_wait() {
    local re=$1 secs=$2 log=$3 t=0
    until grep -a -q -E "$re" "$log" 2>/dev/null; do
        sleep 1; t=$((t + 1))
        [ "$t" -ge "$secs" ] && return 1
    done
    return 0
}

# The marker X-""N prints X-N, which the echoed command line cannot match
tty_run() {
    local m="M$RANDOM"
    tty_type "$1; echo $m-\"\"END\r"
    tty_wait "^$m-END" "$2" "$3"
}

host_ip() {
    ip -4 route get "$MISTER_HOST" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p'
}
