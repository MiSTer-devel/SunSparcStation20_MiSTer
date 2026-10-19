#!/usr/bin/env bash
# sim/cpu/run.sh [--all] [--qemu] [+plusargs...] - the CPU module (IU, FPU,
# SRMMU, caches) against the CPU test suite. Builds the phase-3 subset of
# tests/cpu as a boot ROM (src/main_cpu.S: everything but the chipset, MSI
# and SMP tests; --all: the whole suite), runs it on the cpu_sim harness
# under Verilator and compares the result lines with QEMU's. --qemu
# (re)generates the QEMU reference, tests/cpu/expected/ss20-cpu-qemu.log.
# --bench=NAME builds and runs tests/cpu/src/NAME.S (tlbbench, bmbench) and
# prints its numbers; no comparison.
# --wd builds and runs tests/cpu/src/wdtest.S instead (error mode → the
# watchdog reset → second boot), passing when it prints PASS and CPUTEST
# DONE; it has no QEMU reference (QEMU has no watchdog).
# Plusargs (+lat=N +gaps +trace +dmem +mem +from= +to=) go to the binary.
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
obj="$here/obj"
main=main_cpu; ALL=0; QEMU=0; WD=0; PLUS=""; RESNOOP=128
for a in "$@"; do
  case "$a" in
    --all) ALL=1; main=main ;;
    --qemu) QEMU=1 ;;
    --wd) WD=1; main=wdtest; PLUS="$PLUS +wd" ;;
    --bench=*) WD=2; main="${a#--bench=}" ;;
    +noresnoop) RESNOOP=0 ;;
    +resnoop=*) RESNOOP="${a#+resnoop=}" ;;   # the delayed second DMA snoop off (t_dma_poll with +dmalag must then fail)
    +*) PLUS="$PLUS $a" ;;
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
ref="tests/cpu/expected/ss20-cpu-qemu.log"
if [ "$WD" = 0 ] && { [ "$QEMU" = 1 ] || [ ! -f "$ref" ]; }; then
  command -v qemu-system-sparc >/dev/null || { echo "qemu-system-sparc not found" >&2; exit 1; }
  timeout 120 qemu-system-sparc -M SS-20 -cpu TI-SuperSparc-60 -m 128 -bios "$rom" -nographic \
      -serial mon:stdio -monitor none -display none </dev/null 2>/dev/null \
    | tr -d '\r' | sed -u '/CPUTEST DONE/q' > "$ref" || true
  echo "qemu reference: $ref ($(grep -c . "$ref") lines)"
fi
srcs="rtl/pkg/iobus_pkg.sv rtl/pkg/sun4m_pkg.sv rtl/pkg/cpu_pkg.sv rtl/pkg/fpu_pkg.sv rtl/pkg/mem_pkg.sv rtl/pkg/mmu_pkg.sv rtl/lib/*.sv rtl/cpu/*.sv sim/cpu/snoop_queue.sv rtl/obio/escc.sv rtl/obio/escc_chan.sv rtl/obio/slavio_misc.sv rtl/obio/slavio_timer.sv sim/cpu/cpu_sim.sv"
# one build directory per parameter set: Verilator does not rebuild for a -G change alone
if ! verilator --binary --timing --timescale 1ns/1ps -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
      -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-PROCASSINIT --top-module cpu_sim --Mdir "$obj/build-r$RESNOOP" -o Vcpu_sim \
      -GROM="\"$obj/rom.hex\"" -GRESNOOP=$RESNOOP $srcs > "$obj/build.log" 2>&1; then
  echo "build failed: see $obj/build.log"; grep -E '%Error|%Warning' "$obj/build.log" | head -20; exit 1
fi
"$obj/build-r$RESNOOP/Vcpu_sim" $PLUS | tr -d '\r' | tee "$obj/run.log" | tail -3
if [ "$WD" = 2 ]; then
  grep -E 'passes|cycles|PASS|FAIL|DONE' "$obj/run.log"; exit 0
fi
if [ "$WD" = 1 ]; then
  if grep -q '^PASS wdog' "$obj/run.log" && grep -q 'CPUTEST DONE' "$obj/run.log" && ! grep -q 'ran on' "$obj/run.log"; then
    echo "cpu_sim: wdtest PASS (error mode came back as a watchdog reset)"; exit 0
  else
    echo "cpu_sim: wdtest FAILED"; grep -E '^(PASS|FAIL)|WD|check|ran on' "$obj/run.log" | head; exit 1
  fi
fi
# Compare the result lines: the core must FAIL nothing, and must not SKIP a
# test QEMU passes (except the SS5-only t_mmu_swift tests). Where QEMU
# fails or skips (its deviations, tests/cpu/README.md and
# docs/arch/mmu-notes.md §7.3) the core only has to pass.
python3 - "$ref" "$obj/run.log" <<'PY'
import re, sys
def results(path):
    out = []
    for line in open(path, errors='replace'):
        m = re.match(r'^(PASS|FAIL|SKIP) (.*)$', line.rstrip())
        if m: out.append((m.group(2), m.group(1)))
    return out
ref = dict(results(sys.argv[1])); ours = results(sys.argv[2])
errors = []
for name, st in ours:
    if st == 'FAIL': errors.append('FAIL  ' + name)
    elif st == 'SKIP' and ref.get(name) == 'PASS' and not name.startswith('mmu-swift') and 'swift' not in name:
        errors.append('SKIP  ' + name + '  (QEMU passes)')
missing = [n for n in ref if n not in dict(ours)]
for n in missing: errors.append('MISSING  ' + n)
npass = sum(1 for _, s in ours if s == 'PASS'); nskip = sum(1 for _, s in ours if s == 'SKIP')
better = [n for n, s in ours if s == 'PASS' and ref.get(n) in ('FAIL', 'SKIP')]
if errors:
    print('cpu_sim: PROBLEMS:'); print('\n'.join('  ' + e for e in errors)); sys.exit(1)
print('cpu_sim: no failures (%d PASS, %d SKIP); passes where QEMU does not: %d' % (npass, nskip, len(better)))
PY
