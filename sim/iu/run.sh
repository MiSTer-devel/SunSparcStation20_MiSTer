#!/usr/bin/env bash
# sim/iu/run.sh [--all] [--qemu] - the integer unit against the CPU test suite.
# Builds the phase-1 subset of tests/cpu as a boot ROM (src/main_iu.S;
# --all: the whole suite), runs it on the IU harness under Verilator and
# compares the result lines with QEMU's. --qemu (re)generates the QEMU
# reference, tests/cpu/expected/ss20-iu-qemu.log (qemu-system-sparc 11).
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
obj="$here/obj"
main=main_iu; ALL=0; QEMU=0
for a in "$@"; do
  case "$a" in
    --all) ALL=1; main=main ;;
    --qemu) QEMU=1 ;;
    *) echo "unknown argument $a" >&2; exit 2 ;;
  esac
done
mkdir -p "$obj"
cd "$root" || exit 1
# On macOS: Apple's cpp cannot take the suite's preprocessor flags and Apple's
# clang has no SPARC target; use Homebrew's LLVM (build.py reads $LLVM) and a
# cpp that is "clang -E".
if [ "$(uname)" = Darwin ]; then
  for d in /opt/homebrew/opt/llvm/bin /opt/homebrew/opt/llvm@18/bin; do
    [ -x "$d/clang" ] && { export LLVM="$d"; break; }
  done
  mkdir -p "$obj/bin"
  printf '#!/bin/sh\nexec "%s/clang" -E "$@"\n' "${LLVM:-/usr/bin}" > "$obj/bin/cpp"
  chmod +x "$obj/bin/cpp"
  export PATH="$obj/bin:${LLVM:+$LLVM:}$PATH"     # build.py falls back to "clang" on PATH
fi
rom="tests/cpu/out/ss20/$([ "$main" = main ] && echo cputest || echo "$main").rom"
python3 tests/cpu/build.py ss20 --main="$main" > /dev/null || exit 1
python3 - "$rom" "$obj/rom.hex" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
data += b'\0' * ((-len(data)) % 4)
with open(sys.argv[2], 'w') as f:
    for i in range(0, len(data), 4):
        f.write('%08x\n' % int.from_bytes(data[i:i+4], 'big'))
PY
ref="tests/cpu/expected/ss20-iu-qemu.log"
if [ "$QEMU" = 1 ] || [ ! -f "$ref" ]; then
  command -v qemu-system-sparc >/dev/null || { echo "qemu-system-sparc not found" >&2; exit 1; }
  timeout 120 qemu-system-sparc -M SS-20 -cpu TI-SuperSparc-60 -m 128 -bios "$rom" -nographic \
      -serial mon:stdio -monitor none -display none </dev/null 2>/dev/null \
    | tr -d '\r' | sed -u '/CPUTEST DONE/q' > "$ref" || true
  echo "qemu reference: $ref ($(grep -c . "$ref") lines)"
fi
srcs="rtl/pkg/iobus_pkg.sv rtl/pkg/sun4m_pkg.sv rtl/pkg/cpu_pkg.sv rtl/pkg/fpu_pkg.sv rtl/pkg/mem_pkg.sv rtl/pkg/mmu_pkg.sv rtl/lib/*.sv rtl/cpu/*.sv rtl/obio/escc.sv rtl/obio/escc_chan.sv sim/iu/iu_sim.sv"
if ! verilator --binary --timing --timescale 1ns/1ps -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
      -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-PROCASSINIT --top-module iu_sim --Mdir "$obj/build" -o Viu_sim \
      -GROM="\"$obj/rom.hex\"" $srcs > "$obj/build.log" 2>&1; then
  echo "build failed: see $obj/build.log"; grep -E '%Error|%Warning' "$obj/build.log" | head -20; exit 1
fi
"$obj/build/Viu_sim" | tr -d '\r' | tee "$obj/run.log" | tail -3
# Compare the result lines (PASS/FAIL/SKIP), leaving out the CPUTEST DONE
# totals, and with QEMU's known deviations from V8 (tests/cpu/README.md) taken as PASS
# in the reference: the core must be right where QEMU is wrong.
QEMU_DEVIATIONS='rett with traps enabled|TBR.tt holds the last trap type|reserved ASRs read %y'
filt() { grep -a -E '^(PASS|FAIL|SKIP)' "$1"; }
reffilt() { filt "$1" | sed -E "s/^FAIL (.*($QEMU_DEVIATIONS))/PASS \\1/"; }
if diff <(reffilt "$ref") <(filt "$obj/run.log") > "$obj/diff.txt"; then
  echo "iu_sim: result lines match QEMU with its deviations corrected ($(grep -c '^PASS' "$obj/run.log") PASS, $(grep -c '^SKIP' "$obj/run.log") SKIP)"
else
  echo "iu_sim: DIFFERS from QEMU:"; head -40 "$obj/diff.txt"; exit 1
fi
