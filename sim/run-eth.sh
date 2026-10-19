#!/usr/bin/env bash
#
# run-eth.sh [20] [--no-build] - the Ethernet path in simulation: the
# ethtest ROM (tests/cpu/src/ethtest.S) with --eth-loop, where the
# simulation plays Main's side of the frame mailbox (rtl/mister/eth_hps.sv)
# and sends every transmitted frame back. Prints the test lines and the
# frames the mailbox carried; exit 0 when the run finishes.
set -uo pipefail
REV="${1:-20}"
case "$REV" in
    20) T=ss20 ;;
    *)  echo "usage: $0 [20] [--no-build]" >&2; exit 2 ;;
esac
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[ "${2:-}" = "--no-build" ] || sim/build.sh "$REV" > /dev/null || exit 1
python3 tests/cpu/build.py "$T" --main=ethtest -DETH_POLLS=5000 > /dev/null || exit 1
ROM=tests/cpu/out/$T/ethtest.rom
mkdir -p sim/out
O=sim/out/eth-ss$REV
"sim/obj_ss$REV/Vsim_top" --rom "$ROM" --eth-loop --stop "CPUTEST DONE" \
    --cycles 100M --quiet --log "$O.log" 2> "$O.err"
tr -d '\r' < "$O.log" | tr -cd '\11\12\40-\176' | grep -v '^$' | grep -v '^CPUTEST ss'
grep -E '^\[eth\]|^\[sim\]' "$O.err"
