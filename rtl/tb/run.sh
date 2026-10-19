#!/usr/bin/env bash
# rtl/tb/run.sh [tb_name ...] - lint the RTL and run the block testbenches under
# Verilator. With no argument, every rtl/*/tb/tb_*.sv.
#
# Each testbench is self-checking (rtl/tb/tb_pkg.sv): it prints one PASS
# line and exits 0, or FAIL lines and exits non-zero. Builds go to
# rtl/tb/obj/ (gitignored).
set -u
here=$(cd "$(dirname "$0")" && pwd)
rtl=$(cd "$here/.." && pwd)
obj="$here/obj"
mkdir -p "$obj"

command -v verilator >/dev/null || { echo "verilator not found" >&2; exit 2; }

# The RTL, packages first.
pkgs=("$rtl"/pkg/*_pkg.sv)
srcs=$(ls "$rtl"/lib/*.sv "$rtl"/mister/*.sv "$rtl"/obio/*.sv "$rtl"/cpu/*.sv "$rtl"/video/*.sv "$rtl"/machine/*.sv "$rtl"/sun4m/*.sv 2>/dev/null)

fail=0
echo "== lint"
: > "$obj/lint.log"
# Each module as a top: -Wall, except that a package constant a module does
# not use is not a fault of the module.
for f in $srcs; do
  top=$(basename "$f" .sv)
  verilator --lint-only -Wall -Wno-UNUSEDPARAM --top-module "$top" "${pkgs[@]}" $srcs >> "$obj/lint.log" 2>&1 || fail=1
done
if grep -q '%Warning\|%Error' "$obj/lint.log"; then
  grep -v 'note: In instance' "$obj/lint.log"; fail=1
else
  echo "clean"
fi

cd "$rtl/.." || exit 2          # benches open their data files by repository-relative paths
if [ $# -gt 0 ]; then
  tbs="$*"
else
  tbs=$(ls "$rtl"/*/tb/tb_*.sv | xargs -n1 basename | sed 's/\.sv$//')
fi
for tb in $tbs; do
  echo "== $tb"
  d="$obj/$tb"
  src=$(ls "$rtl"/*/tb/"$tb".sv | head -1)
  # Benches with their own runner (rtl/mister/tb/run.sh, iverilog) name their
  # module differently; only self-named Verilator benches run from here.
  grep -q "^module $tb\b" "$src" || { echo "skipped: run by $(dirname "$src")/run.sh"; continue; }
  if ! verilator --binary --timing --timescale 1ns/1ps -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
        --top-module "$tb" --Mdir "$d" -o "V$tb" \
        "${pkgs[@]}" "$here/tb_pkg.sv" $srcs "$src" > "$d.build.log" 2>&1; then
    echo "build failed: see $d.build.log"
    grep -v 'note: In instance' "$d.build.log" | tail -25
    fail=1
    continue
  fi
  if "$d/V$tb" > "$d.log" 2>&1 && grep -q '^PASS' "$d.log"; then
    grep '^PASS' "$d.log"
  else
    grep -v '^\s*$' "$d.log" | tail -30
    fail=1
  fi
done
exit $fail
