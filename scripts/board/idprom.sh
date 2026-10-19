#!/usr/bin/env bash
# idprom.sh --obp FILE [--log FILE] - the machine's identity from the host:
# Main (support/sun, sun_idprom.cpp) sends an ID PROM made from the MiSTer's
# Ethernet address on ioctl index 64; the core takes its last three bytes as
# the serial of a blank NVRAM's IDPROM (rtl/mister/nvram_sd.sv). Last line: PASS or FAIL.
#
#   1. a blank NVRAM image under the Sun OBP: the banner shows 8:0:20 and the
#      MiSTer's eth0 bytes 3-5 (Ethernet address and Host ID 72xxxxxx), and
#      the image on the SD card holds that IDPROM afterwards
#   2. the same image again, with a boot1.rom carrying another address: the
#      image keeps its identity (a seed only fills a blank IDPROM); then
#      sun-idprom.sh reset blanks it, and the next load takes boot1.rom's
#   3. no NVRAM image, OpenBIOS: NetBSD's le0 has the MiSTer's address
#   4. an image with an identity of its own (ss20-obp.nvr): unchanged
#
# Needs Main's sun-family with the SPARCstation ID PROM (sun_enet_start sends
# it to both Sun cores). Uses tools/mister/sun-idprom.sh on the MiSTer (copied
# to /tmp) for boot1.rom and to read the image back.
set -u
. "$(dirname "$0")/../common.sh"
. scripts/board/lib.sh
OBP=""; LOG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --obp) OBP=$2; shift ;;
        --log) LOG=$2; shift ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac; shift
done
[ -f "$OBP" ] || { echo "usage: $0 --obp FILE (the Sun PROM image)"; exit 2; }
: "${LOG:=sim/out/hw-20-idprom}"
mkdir -p sim/out
B=idblank.nvr
fail() { echo "FAIL: $*"; cap_stop; rsh "rm -f $G/$B $G/boot1.rom"; restore_openbios; exit 1; }

scp -q "${SSH_OPTS[@]}" tools/mister/sun-idprom.sh "$DEV:/tmp/sun-idprom.sh" || exit 1
SID="bash /tmp/sun-idprom.sh"
mac=$(rsh 'cat /sys/class/net/eth0/address' | tr -d '\r')
m3=$(echo "$mac" | cut -d: -f4-6)                     # e.g. 61:56:f1
want_eth=$(echo "8:0:20:$m3" | sed 's/:0\([0-9a-f]\)/:\1/g')
want_hid="72$(echo "$m3" | tr -d ':')"
echo "MiSTer eth0 $mac: expect Ethernet address $want_eth, Host ID $want_hid"

banner() {   # the Ethernet address and Host ID the Sun OBP printed
    tr -d '\r' < "$1" | grep -a -o 'Ethernet address [0-9a-f:]*, Host ID: [0-9a-f]*' | tail -1
}
obp_boot() { # $1 log: boot the Sun OBP past its SBus probe (no disk). A
             # blank NVRAM sends the banner to the screen (output-device's
             # default), so the identity is checked in the image file
    cap_stop; cap_start "$1" 300
    core_start
    tty_wait 'at 3,0' 180 "$1" || fail "the OBP did not start ($1)"
    sleep 6                                            # nvram_sd: QUIET, then the write-back
}
image_id() { rsh "$SID" | grep "  $B:" | sed 's/^ *[^:]*: //'; }

# 1. a blank image
put_rom "$OBP" || exit 1
rsh "dd if=/dev/zero of=$G/$B bs=8192 count=1 2>/dev/null; rm -f $G/boot1.rom"
scripts/mount.sh --hd0 "" --hd1 "" --cd "" --nvram "$B" > /dev/null
scripts/setopt.sh console=serial > /dev/null 2>&1 || exit 1
obp_boot "$LOG-1.log"
i1=$(image_id); echo "1. blank image, after its first load: $i1"
echo "$i1" | grep -q "Ethernet 08:00:20:$m3, host ID $want_hid (checksum ok)" || fail "blank image: '$i1'"
curl -s -X POST "http://$MISTER_HOST:8182/api/screenshots" > /dev/null 2>&1 || true

# 2. the same image, another seed (boot1.rom): the identity stays
rsh "$SID make 08:00:20:ab:cd:ef" | sed 's/^/   /'
obp_boot "$LOG-2.log"
i2=$(image_id); echo "2. same image, seed ab:cd:ef: $i2"
[ "$i2" = "$i1" ] || fail "the stored identity changed: '$i2'"

# 2b. reset the image's identity: the next load takes boot1.rom's
rsh "$SID reset $B" | sed 's/^/   /'
obp_boot "$LOG-2b.log"
i2b=$(image_id); echo "2b. after reset, with boot1.rom: $i2b"
echo "$i2b" | grep -q "Ethernet 08:00:20:ab:cd:ef, host ID 72abcdef (checksum ok)" || fail "reset + boot1.rom: '$i2b'"
rsh "$SID remove" > /dev/null

# 4. an image with its own identity
scripts/mount.sh --nvram ss20-obp.nvr > /dev/null
cap_stop; cap_start "$LOG-4.log" 300
core_start
tty_wait 'Host ID' 180 "$LOG-4.log" || fail "no banner on ttya with ss20-obp.nvr"
b4=$(banner "$LOG-4.log"); echo "4. ss20-obp.nvr (console ttya): $b4"
echo "$b4" | grep -q "Ethernet address 8:0:20:12:34:56" || fail "ss20-obp.nvr lost its identity: '$b4'"
cap_stop
rsh "rm -f $G/$B"
restore_openbios

# 3. no image, OpenBIOS, NetBSD
scripts/mount.sh --hd0 netbsd11.raw --hd1 "" --cd "" --nvram "" > /dev/null
scripts/setopt.sh console=serial autoboot=on > /dev/null 2>&1 || exit 1
cap_start "$LOG-3.log" 900
core_start
tty_wait 'le0 at|login:' 600 "$LOG-3.log" || fail "NetBSD did not start"
tty_wait 'login:' 600 "$LOG-3.log"
cap_stop
l=$(tr -d '\r' < "$LOG-3.log" | grep -a 'le0 at' | grep -a -o 'address [0-9a-f:]*' | tail -1)
echo "3. no image, NetBSD: $l"
echo "$l" | grep -q "08:00:20:$m3" || fail "no image: '$l'"
restore_openbios

echo "PASS: the machine's identity comes from the MiSTer ($want_eth, $want_hid) and stays in its NVRAM image"
