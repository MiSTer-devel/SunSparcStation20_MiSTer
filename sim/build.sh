#!/usr/bin/env bash
#
# build.sh [20] [--trace] - build the Verilator model of the machine.
#
# Verilates sim_top.sv around rtl/machine/ss20_machine.sv with the harness
# (sim_main.cpp) into sim/obj_ss20/Vsim_top (sim/obj_ss20_trace/ with
# --trace, which adds VCD waveform support and costs build time). The RTL is
# the same SystemVerilog Quartus builds: files.qip lists it, and this script
# takes the list from there, so the two cannot drift apart.
# SIM_OBJ=dir builds elsewhere, e.g. while a run still uses the usual model.
# SIM_NCPU=n builds the machine with n CPU modules (default 2, as the core).
# SIM_JOBS=n compiles with n jobs (default 0: all cores; use 2 on a shared box).

set -euo pipefail

REV=20
TRACE=0
for a in "$@"; do
    case "$a" in
        20|ss20) ;;
        --trace) TRACE=1 ;;
        *) echo "usage: $0 [20] [--trace]" >&2; exit 2 ;;
    esac
done
SYSFREQ=55000000                 # clk_sys on the board (rtl/pll.v)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OBJ="$ROOT/sim/obj_ss$REV"
[ "$TRACE" = 1 ] && OBJ="${OBJ}_trace"
[ -n "${SIM_OBJ:-}" ] && OBJ="$ROOT/sim/$SIM_OBJ"

# The machine's sources: files.qip's SystemVerilog under rtl/, in order
# (packages first), without the MiSTer top.
SRCS=()
while read -r f; do SRCS+=("$f"); done \
    < <(sed -n 's/^set_global_assignment -name SYSTEMVERILOG_FILE \(rtl\/.*\.sv\)$/\1/p' "$ROOT/files.qip")
[ "${#SRCS[@]}" -gt 0 ] || { echo "no rtl/ sources in files.qip" >&2; exit 1; }

VFLAGS=(
    --cc --exe --build -j "${SIM_JOBS:-0}"
    --top-module sim_top
    -O3 --x-assign fast --x-initial fast --noassert
    -Wno-fatal -Wno-lint -Wno-style
    -CFLAGS "-O2 -DSIM_SYSFREQ=$SYSFREQ"
    -MAKEFLAGS "OPT_FAST=-O2 OPT_SLOW=-O1"
    -Mdir "$OBJ"
)
[ "$TRACE" = 1 ] && VFLAGS+=(--trace)
# SIM_NCPU=n: n CPU modules (ss20_machine NCPU; default 2)
[ -n "${SIM_NCPU:-}" ] && VFLAGS+=(-GNCPU="$SIM_NCPU")

cd "$ROOT"
time verilator "${VFLAGS[@]}" "${SRCS[@]}" sim/sdram_chip.sv sim/sim_top.sv sim/sim_main.cpp
echo "built $OBJ/Vsim_top"
