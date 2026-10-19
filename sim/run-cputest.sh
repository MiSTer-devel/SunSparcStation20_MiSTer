#!/usr/bin/env bash
#
# run-cputest.sh [20] - the CPU test suite on the simulated machine, checked
# against the hardware baseline.
#
# The simulation must print exactly what the board printed
# (tests/cpu/expected/ss{5,20}-core-hw.log): same PASS/FAIL lines, same
# check values. A difference is either an RTL change (update the baseline
# from the board, not from here) or a simulation fault.
#
#   sim/run-cputest.sh 20 [--no-build]

set -uo pipefail

REV="${1:-20}"
case "$REV" in
    20) ROM=tests/cpu/out/ss20/cputest.rom;     EXP=tests/cpu/expected/ss20-core-hw.log ;;
    *)  echo "usage: $0 [20] [--no-build]" >&2; exit 2 ;;
esac
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[ "${2:-}" = "--no-build" ] || sim/build.sh "$REV" > /dev/null || exit 1
[ -f "$ROM" ] || python3 tests/cpu/build.py ss20 > /dev/null

mkdir -p sim/out
LOG="sim/out/cputest-ss$REV.log"
"sim/obj_ss$REV/Vsim_top" --rom "$ROM" --stop "CPUTEST DONE" --cycles 2G --quiet --log "$LOG"
rc=$?
[ "$rc" = 0 ] || { echo "run-cputest: the run did not finish (exit $rc); see $LOG"; exit 1; }

clean() { tr -d '\r' < "$1" | tr -cd '\11\12\40-\176' | grep -v '^$'; }
if diff <(clean "$EXP") <(clean "$LOG"); then
    echo "run-cputest ss$REV: matches the hardware baseline ($(grep -a 'CPUTEST DONE' "$LOG" | tr -d '\r'))"
else
    echo "run-cputest ss$REV: DIFFERS from $EXP"
    exit 1
fi
