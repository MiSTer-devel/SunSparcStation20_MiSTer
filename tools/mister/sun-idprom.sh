#!/bin/bash
# sun-idprom.sh - the SPARCstation core's machine identity (Ethernet address
# and host ID), run on the MiSTer. Copy it to /media/fat/Scripts to run it
# from the MiSTer's Scripts menu (which shows the identities), or run it
# over ssh with a command:
#
#   sun-idprom.sh                 show the identities: the one a blank NVRAM
#                                 image gets on this MiSTer, boot1.rom's, and
#                                 the one in every .nvr image of the folder
#   sun-idprom.sh make MAC        write boot1.rom: a blank NVRAM image then
#                                 gets 08:00:20 and MAC's last three bytes
#                                 (also the host ID: 72xxxxxx), instead of
#                                 this MiSTer's own
#   sun-idprom.sh make random     the same with three random bytes
#   sun-idprom.sh remove          delete boot1.rom (back to this MiSTer's
#                                 address)
#   sun-idprom.sh reset FILE.nvr  blank the image's IDPROM, so its next load
#                                 gives it a new identity (the rest of the
#                                 NVRAM, the firmware settings, is kept)
#
# How the core uses it: Main sends boot1.rom (else an ID PROM made from
# eth0's address) to the core at every load; the core uses it only for an
# NVRAM image whose IDPROM is blank, and writes the result back to the
# image, which keeps it from then on. Without an image, it is used at every
# start. The Sun-2 core reads the same file from its own folder.
#
# GPL-2.0-or-later.

DIR=${SS_DIR:-/media/fat/games/SunSparcStation}
ROM=$DIR/boot1.rom
IDOFF=8152                    # 0x1FD8: the IDPROM in an NVRAM image

die() { echo "$*" >&2; exit 1; }

# 16 bytes from offset $2 of file $1, as hex pairs
bytes() { dd if="$1" bs=1 skip="$2" count=16 2>/dev/null | od -An -v -tx1 | tr -s ' \n' ' '; }

# "01 72 08 00 20 ab cd ef ..." -> a description
describe() {
    set -- $1
    [ $# -ge 16 ] || { echo "(too short)"; return; }
    if [ "$1" != 01 ]; then echo "blank (gets a new identity at its next load)"; return; fi
    local x=0 i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do x=$(( x ^ 0x${!i} )); done
    local ok="checksum ok"; [ $x -eq $((0x${16})) ] || ok="BAD CHECKSUM"
    echo "Ethernet $3:$4:$5:$6:$7:$8, host ID ${2}${13}${14}${15} ($ok)"
}

# The 32-byte ID PROM for the address bytes $1 $2 $3 (hex) -> stdout
idprom() {
    local b=(01 72 08 00 20 "$1" "$2" "$3" 00 00 00 00 "$1" "$2" "$3") x=0 i
    for i in "${b[@]}"; do x=$(( x ^ 0x$i )); done
    b+=("$(printf %02x $x)")
    for i in $(seq 16); do b+=(ff); done
    printf '%s' "${b[@]}" | xxd -r -p
}

show() {
    local mac m
    mac=$(cat /sys/class/net/eth0/address 2>/dev/null)
    if [ -n "$mac" ]; then
        m=(${mac//:/ })
        echo "This MiSTer (eth0 $mac): a blank NVRAM image gets"
        echo "  Ethernet 08:00:20:${m[3]}:${m[4]}:${m[5]}, host ID 72${m[3]}${m[4]}${m[5]}"
    else
        echo "No eth0: without boot1.rom a blank image gets a random identity."
    fi
    if [ -f "$ROM" ]; then
        echo "boot1.rom (used instead of eth0): $(describe "$(bytes "$ROM" 0)")"
    else
        echo "No boot1.rom in $DIR."
    fi
    echo "NVRAM images in $DIR:"
    local f n=0
    for f in "$DIR"/*.nvr; do
        [ -f "$f" ] || continue
        n=$((n + 1))
        if [ "$(stat -c %s "$f")" != 8192 ]; then
            echo "  $(basename "$f"): not 8192 bytes, not an NVRAM image"
        else
            echo "  $(basename "$f"): $(describe "$(bytes "$f" $IDOFF)")"
        fi
    done
    [ $n -gt 0 ] || echo "  (none)"
}

case "${1:-show}" in
    show)
        show ;;
    make)
        a=${2:-}
        if [ "$a" = random ]; then
            set -- $(od -An -N3 -tx1 /dev/urandom)
        else
            [[ "$a" =~ ^([0-9a-fA-F]{1,2}:){5}[0-9a-fA-F]{1,2}$ ]] ||
                die "usage: $0 make MAC|random (MAC as 08:00:20:ab:cd:ef)"
            m=(${a//:/ })
            set -- "${m[3]}" "${m[4]}" "${m[5]}"
            [ "${m[0],,}:${m[1],,}:${m[2],,}" = 8:0:20 ] ||
            [ "${m[0],,}:${m[1],,}:${m[2],,}" = 08:00:20 ] ||
                echo "Note: the core keeps Sun's prefix 08:00:20; only the last three bytes are used."
        fi
        b=$(printf '%02x %02x %02x' 0x$1 0x$2 0x$3)
        idprom $b > "$ROM" || die "cannot write $ROM"
        echo "boot1.rom: $(describe "$(bytes "$ROM" 0)")"
        echo "Used by a blank NVRAM image at its next load (or by a core with no image)." ;;
    remove)
        rm -f "$ROM" && echo "boot1.rom removed: blank images get this MiSTer's address again." ;;
    reset)
        f=${2:-}
        [ -n "$f" ] || die "usage: $0 reset FILE.nvr"
        [ -f "$f" ] || f=$DIR/$f
        [ -f "$f" ] && [ "$(stat -c %s "$f")" = 8192 ] || die "$f: not an 8192-byte NVRAM image"
        echo "Before: $(describe "$(bytes "$f" $IDOFF)")"
        printf '\0' | dd of="$f" bs=1 seek=$IDOFF conv=notrunc 2>/dev/null || die "cannot write $f"
        sync
        echo "After:  $(describe "$(bytes "$f" $IDOFF)")"
        echo "If the core is running with this image, reload the core now (it would"
        echo "otherwise write its copy back over the change)." ;;
    *)
        sed -n '2,24p' "$0"; exit 2 ;;
esac
