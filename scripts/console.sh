#!/usr/bin/env bash
# Read the machine's serial console (ttya) off the MiSTer.
#   scripts/console.sh [--seconds N] [--out FILE] [--baud N]
# The core's UART is wired to the HPS UART, /dev/ttyS1 on the MiSTer. The
# core runs the line at a fixed 115200 8N1 whatever the OS programs into the
# ESCC (docs/impl-gaps/keyboard-mouse-serial.md A.2). "uartmode 0" first, so
# no pppd/agetty/midilink shares the tty.
set -u
. "$(dirname "$0")/common.sh"
: "${MISTER_HOST:?set MISTER_HOST in scripts/local.env}"
SECS=60; OUT=""; BAUD=115200
while [ $# -gt 0 ]; do
    case "$1" in
        --seconds) SECS="$2"; shift ;;
        --out) OUT="$2"; shift ;;
        --baud) BAUD="$2"; shift ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac; shift
done
CMD="uartmode 0 >/dev/null 2>&1; stty -F /dev/ttyS1 $BAUD raw -echo -hupcl; timeout $SECS cat /dev/ttyS1"
if [ -n "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")"
    ssh "${SSH_OPTS[@]}" "$DEV" "$CMD" | stdbuf -o0 tr -d '\r' | tee "$OUT"
else
    ssh "${SSH_OPTS[@]}" "$DEV" "$CMD" | stdbuf -o0 tr -d '\r'
fi
