#!/usr/bin/env bash
#
# run-obp.sh ROM [--diag] [--nvram FILE] [Vsim_top options...] - Sun's OBP
# 2.25 (the user's SS20 boot PROM image, never in the repository) on the
# simulated machine, its console on ttya, to the `ok` prompt.
#
# The NVRAM: OBP keeps its options in a Sun-format image with a checksum
# (tools/obp_nvram.py). Without --nvram, sim/out/obp.nvr is made once by
# tools/obp_nvram.py --new (OBP's defaults, the ones the core writes into
# an empty NVRAM) with input-device and output-device ttya and auto-boot?
# false. The run uses a copy (the simulation writes the image back). --diag sets diag-switch? (the POST runs, its
# messages on ttya; ss20_memctl slows boot-mode PROM reads to the real
# EPROM's pace, which its counter/timer test needs).
#
#   sim/run-obp.sh scratch/obp.rom --ram 64 --cycles 2G
#   sim/run-obp.sh scratch/obp.rom --ram 64 --hd0 disk.img --send 'ok =>boot disk\r' --stop login:
#
# The model must be built (sim/build.sh). Prefer --ram 64: OBP clears all of
# memory at every start. Without a --stop of its own the run ends at `ok`.
set -euo pipefail
ROM="${1:?usage: $0 ROM [--diag] [--nvram FILE] [Vsim_top options...]}"
shift
DIAG=0
NV=""
STOP=1
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --diag)  DIAG=1 ;;
        --nvram) NV="$2"; shift ;;
        --stop)  STOP=0; ARGS+=("$1") ;;
        *)       ARGS+=("$1") ;;
    esac
    shift
done
[ "$STOP" = 1 ] && ARGS+=(--stop "ok ")
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="$ROOT/sim/obj_ss20/Vsim_top"
OUT="$ROOT/sim/out"
mkdir -p "$OUT"
if [ -z "$NV" ]; then
    NV="$OUT/obp.nvr"
    [ -f "$NV" ] || python3 "$ROOT/tools/obp_nvram.py" --new "$NV" \
        input-device=ttya output-device=ttya 'auto-boot?=false' > /dev/null
fi
RUN="$OUT/obp-run.nvr"
if [ "$DIAG" = 1 ]; then
    python3 "$ROOT/tools/obp_nvram.py" "$NV" "$RUN" 'diag-switch?=true' > /dev/null
else
    python3 "$ROOT/tools/obp_nvram.py" "$NV" "$RUN" 'diag-switch?=false' > /dev/null
fi
exec "$SIM" --rom "$ROM" --nvram "$RUN" "${ARGS[@]}"
