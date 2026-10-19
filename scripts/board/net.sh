#!/usr/bin/env bash
# net.sh netbsd|solaris|solaris-obp|obp-testnet [--obp FILE] [--mode MODE] [--log FILE]
#   - the network through the Ethernet mailbox and Main's sun_enet, OSD
#   Network MODE (default eth0). Console on ttya. Last line: PASS or FAIL.
#
#   netbsd       OpenBIOS (games/.../openbios.rom), HD0 netbsd11.raw: log in,
#                DHCP on le0 (dhcpcd), ping the gateway, ping the guest from
#                here
#   (netbsd and solaris also ping with 8000- and 16000-byte datagrams both
#   ways: 6 and 11 fragments, which arrive together and must all fit the
#   RX ring; the guest's IP reassembly must lose none)
#   solaris      OpenBIOS, HD0 sol8-ss20.img: log in, DHCP on le1 (the
#                image's path_to_inst comes from QEMU), ping the gateway and
#                the guest, then TCP both ways with Perl's IO::Socket
#                against scripts/board/tcpsrv.py here: the guest sends
#                /usr/lib/libc.so.1 and receives 4 MB of random bytes; both
#                cksums must agree on the two sides
#   solaris-obp  the same under the Sun OBP (--obp FILE, the PROM image,
#                never in the repository) with the NVRAM image ss20-obp.nvr
#                on the MiSTer (auto-boot? true, boot-device disk, console
#                ttya: hwtest.sh's solaris-obp needs the same)
#   obp-testnet  the Sun OBP, no disk (auto-boot falls to ok): `test net`
#                (the le driver's internal and external loopback tests, AUI
#                and TP) must succeed, and `boot net` must send frames (the
#                mailbox's TX count grows; nothing answers its RARP)
#
# The machine running this must be reachable from the guest (TCP ports
# 5001/5002). Needs Main's sun-family (support/sun) on the MiSTer.
set -u
. "$(dirname "$0")/../common.sh"
. scripts/board/lib.sh
WHAT=${1:-}; shift || true
OBP=""; MODE=eth0; LOG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --obp) OBP=$2; shift ;;
        --mode) MODE=$2; shift ;;
        --log) LOG=$2; shift ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac; shift
done
case "$WHAT" in netbsd|solaris|solaris-obp|obp-testnet) ;;
    *) echo "usage: $0 netbsd|solaris|solaris-obp|obp-testnet [--obp FILE] [--mode MODE] [--log FILE]" >&2; exit 2 ;;
esac
: "${LOG:=sim/out/hw-20-net-$WHAT.log}"
mkdir -p sim/out
fail() { echo "FAIL: $*"; cap_stop; restore_openbios; exit 1; }

case "$WHAT" in
    solaris-obp|obp-testnet)
        [ -f "$OBP" ] || { echo "$WHAT needs --obp FILE (the Sun PROM image)"; exit 2; }
        rsh "test -s $G/ss20-obp.nvr" || { echo "no $G/ss20-obp.nvr on the MiSTer"; exit 2; }
        put_rom "$OBP" || exit 1
        NVR=ss20-obp.nvr ;;
    *)  rsh "cp $G/openbios.rom $G/boot.rom"; NVR="" ;;
esac
case "$WHAT" in
    netbsd)      HD0=netbsd11.raw ;;
    obp-testnet) HD0="" ;;
    *)           HD0=sol8-ss20.img ;;
esac
scripts/mount.sh --hd0 "$HD0" --hd1 "" --cd "" --nvram "$NVR" > /dev/null
scripts/setopt.sh console=serial autoboot=on network="$MODE" > /dev/null 2>&1 || exit 1
cap_stop; cap_start "$LOG" 2400
core_start

if [ "$WHAT" = obp-testnet ]; then
    tty_wait '^ok |ok $' 300 "$LOG" || fail "no ok prompt"
    sleep 3
    txc() { rsh 'devmem 0x1FF00010 32'; }
    tx0=$(txc)
    TTY_DELAY=40000 tty_type 'test net\r'; sleep 25
    TTY_DELAY=40000 tty_type 'boot net\r'; sleep 30
    tx1=$(txc)
    rsh "printf '\\003' > /dev/ttyS1"              # stop the boot
    sleep 2; cap_stop; restore_openbios
    t=$(sed -n '/test net/,$p' "$LOG")
    # four loopback tests (internal and external, AUI and TP)
    if [ "$(echo "$t" | grep -a -c 'test -- succeeded')" -ge 4 ] && ! echo "$t" | grep -a -q -i 'failed'; then
        echo "PASS: test net's loopback tests succeeded; mailbox TX $tx0 -> $tx1"
        [ "$tx0" != "$tx1" ] || { echo "FAIL: boot net sent nothing"; exit 1; }
        exit 0
    fi
    echo "$t" | head -20
    echo "FAIL: test net"; exit 1
fi

if [ "$WHAT" = netbsd ]; then
    IF=le0; want='login:'
else
    IF=le1; want='console login:'
fi
GW=$(ip -4 route | sed -n 's/^default via \([0-9.]*\).*/\1/p' | head -1)
tty_wait "$want" 1200 "$LOG" || fail "no '$want'"
sleep 5; tty_type 'root\r'; sleep 20
if [ "$WHAT" = netbsd ]; then
    tty_run 'ifconfig le0 up; dhcpcd -w -t 40 le0 > /tmp/dh.log 2>&1; tail -3 /tmp/dh.log' 120 "$LOG"
    tty_run 'ifconfig le0 | grep inet' 60 "$LOG"
    tty_run "ping -c 4 $GW" 60 "$LOG"
else
    tty_run "ifconfig $IF plumb; ifconfig $IF dhcp start" 120 "$LOG"
    tty_run "ifconfig $IF" 30 "$LOG"
fi
IP=$(grep -a -o -E 'inet [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$LOG" | grep -v 'inet 127\.' | tail -1 | cut -d' ' -f2)
[ -n "$IP" ] || fail "no address from DHCP"
echo "guest address $IP"
if [ "$WHAT" != netbsd ]; then
    tty_run "ping $GW" 30 "$LOG"
fi
ping -c 4 "$IP" > /tmp/net-ping.$$ 2>&1; pr=$(tail -2 /tmp/net-ping.$$ | head -1); rm -f /tmp/net-ping.$$
echo "ping from here: $pr"
echo "$pr" | grep -q ' 0% packet loss' || fail "the guest does not answer pings"

# Fragmented datagrams both ways (the RX ring takes a burst of 11)
HOST=$(host_ip)
[ -n "$HOST" ] || fail "cannot tell this machine's address"
for sz in 8000 16000; do
    ping -c 4 -s $sz "$IP" > /tmp/net-ping.$$ 2>&1; pr=$(tail -2 /tmp/net-ping.$$ | head -1); rm -f /tmp/net-ping.$$
    echo "ping -s $sz from here: $pr"
    echo "$pr" | grep -q ' 0% packet loss' || fail "$sz-byte pings from here lost"
done
if [ "$WHAT" = netbsd ]; then
    tty_run "ping -c 4 -s 8000 $HOST; ping -c 4 -s 16000 $HOST" 60 "$LOG"
    tty_run 'netstat -s -p ip | grep -i fragment' 30 "$LOG"
    gp=$(grep -a -E 'packets transmitted' "$LOG" | tail -2)
    fr=$(grep -a -E '[0-9]+ fragments? dropped after timeout' "$LOG" | tail -1 | awk '{print $1}')
else
    tty_run "ping -s $HOST 8000 4; ping -s $HOST 16000 4" 60 "$LOG"
    tty_run 'netstat -s -P ip | grep -i reasm' 30 "$LOG"
    gp=$(grep -a -E 'packets transmitted' "$LOG" | tail -2)
    fr=$(grep -a -o -E 'ipReasmFails *= *[0-9]+' "$LOG" | tail -1 | grep -o -E '[0-9]+$')
fi
echo "large pings from the guest: $(echo $gp)"
[ "$(echo "$gp" | grep -c -E ' 0(\.0)?% packet loss')" = 2 ] || fail "large pings from the guest lost"
echo "reassembly failures in the guest: ${fr:-?}"
[ "$fr" = 0 ] || fail "the guest lost fragments (${fr:-no count})"

if [ "$WHAT" = netbsd ]; then
    tty_run 'netstat -i' 60 "$LOG"
    cap_stop; restore_openbios
    echo "PASS: NetBSD on the LAN at $IP (DHCP, ping both ways, 16000-byte pings)"
    exit 0
fi

# TCP both ways: two Perl programs, typed through here-documents
put() { tty_type "cat > $1 <<\\E\r"; sleep 1; shift
        for l in "$@"; do tty_type "$l\r"; sleep 1; done; tty_type 'E\r'; sleep 2; }
put /tmp/tx.pl 'use IO::Socket;' \
    "\$s = IO::Socket::INET->new(PeerAddr => \"$HOST\", PeerPort => \$ARGV[0]) or die \"connect\";" \
    'open(F, $ARGV[1]) or die "open";' \
    'while (read(F, $b, 8192)) { print $s $b; }' \
    'close $s;'
put /tmp/rx.pl 'use IO::Socket;' \
    "\$s = IO::Socket::INET->new(PeerAddr => \"$HOST\", PeerPort => \$ARGV[0]) or die \"connect\";" \
    'open(F, ">$ARGV[1]") or die "open";' \
    'while (sysread($s, $b, 8192)) { print F $b; }' \
    'close F;'
T=sim/out/net-tcp.$$
head -c 4194304 /dev/urandom > "$T.4m"
# guest -> here
timeout 400 python3 scripts/board/tcpsrv.py recv 5001 "$T.rx" > "$T.rxlog" 2>&1 &
sleep 1
tty_run 'timex perl /tmp/tx.pl 5001 /usr/lib/libc.so.1' 300 "$LOG"
tty_run 'cksum /usr/lib/libc.so.1' 30 "$LOG"
wait
# here -> guest
timeout 400 python3 scripts/board/tcpsrv.py send 5002 "$T.4m" > "$T.txlog" 2>&1 &
sleep 1
tty_run 'timex perl /tmp/rx.pl 5002 /tmp/rx.bin' 300 "$LOG"
tty_run 'cksum /tmp/rx.bin; rm -f /tmp/rx.bin' 30 "$LOG"
wait
tty_run 'netstat -i' 30 "$LOG"
tty_type 'sync; init 0\r'
tty_wait 'Program terminated|ok ' 300 "$LOG"
cap_stop; restore_openbios
rx=$(cat "$T.rxlog"); tx=$(cat "$T.txlog")
echo "guest -> here: $rx"
echo "here -> guest: $tx"
# the cksum lines the guest printed: libc's, then rx.bin's
g_libc=$(grep -a -E '^[0-9]+ +[0-9]+ +/usr/lib/libc.so.1' "$LOG" | tail -1 | awk '{print $1, $2}')
g_rx=$(grep -a -E '^[0-9]+ +[0-9]+ +/tmp/rx.bin' "$LOG" | tail -1 | awk '{print $1, $2}')
h_rx=$(cksum < "$T.rx" 2>/dev/null | awk '{print $1, $2}')
h_4m=$(cksum < "$T.4m" | awk '{print $1, $2}')
rm -f "$T".*
if [ -n "$g_libc" ] && [ "$g_libc" = "$h_rx" ] && [ "$g_rx" = "$h_4m" ]; then
    echo "PASS: Solaris on the LAN at $IP, TCP both ways (cksums $g_libc, $g_rx)"
    exit 0
fi
echo "FAIL: TCP (guest libc $g_libc, received here $h_rx; sent here $h_4m, guest got $g_rx)"
exit 1
