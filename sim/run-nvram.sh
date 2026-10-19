#!/usr/bin/env bash
#
# run-nvram.sh [20] [--no-build] - the NVRAM image on the SD card
# (rtl/mister/nvram_sd.sv) in simulation: the CPU suite runs twice with an
# image in slot 3 (sim_main --nvram), both runs in parallel.
#
#   blank   8192 zero bytes. The built-in IDPROM, with a serial of its
#           own, replaces the blank one at the load, so the suite passes;
#           the IDPROM is written back to the file, and t_nvram's stores at
#           0x100, restored: the file is zeros but for a valid IDPROM
#           (format 1, the machine type, 08:00:20 + the hostid's serial).
#   random  random bytes and an IDPROM with a wrong checksum: t_idprom must
#           fail its check 3 and nothing else (the CPU sees the loaded
#           image, not the built-in one); the file is unchanged after the
#           write-back (load and write-back agree on the byte order).
# Both: 16 sector reads, at least one sector write.
set -uo pipefail
REV="${1:-20}"
case "$REV" in
    20) ROM=tests/cpu/out/ss20/cputest.rom;     TYPE=0x72 ;;
    *)  echo "usage: $0 [20] [--no-build]" >&2; exit 2 ;;
esac
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[ "${2:-}" = "--no-build" ] || sim/build.sh "$REV" > /dev/null || exit 1
python3 tests/cpu/build.py ss20 > /dev/null || exit 1
mkdir -p sim/out
O=sim/out/nvram-ss$REV
python3 - "$O" "$TYPE" <<'PY'
import random, sys
o, t = sys.argv[1], int(sys.argv[2], 0)
open(o + "-blank.nvr", "wb").write(bytes(8192))
random.seed(1)
b = bytearray(random.getrandbits(8) for _ in range(8192))
idp = [1, t, 8, 0, 0x20, 0xab, 0xcd, 0xef, 0, 0, 0, 0, 0xab, 0xcd, 0xef]
x = 0
for v in idp:
    x ^= v
idp.append(x ^ 0x5a)                       # a wrong checksum
b[0x1fd8:0x1fe8] = bytes(idp)
open(o + "-random.nvr", "wb").write(b)
open(o + "-random.orig", "wb").write(b)
PY
for k in blank random; do
    "sim/obj_ss$REV/Vsim_top" --rom "$ROM" --nvram "$O-$k.nvr" --stop "CPUTEST DONE" \
        --cycles 400M --quiet --log "$O-$k.log" 2> "$O-$k.err" &
done
wait
clean() { tr -d '\r' < "$1" | tr -cd '\11\12\40-\176' | grep -v '^$'; }
bad=0
fail() { echo "run-nvram ss$REV: $*"; bad=1; }
for k in blank random; do
    grep -q "CPUTEST DONE" "$O-$k.log" || { fail "$k: the run did not finish ($O-$k.err)"; continue; }
    grep -q "NVRAM image: 16 sector reads, [1-9]" "$O-$k.err" \
        || fail "$k: not 16 reads and some writes: $(grep 'NVRAM image' "$O-$k.err")"
done
clean "$O-blank.log" | grep -q "fail=0 " || fail "blank: failures: $(clean "$O-blank.log" | grep -B2 '^FAIL')"
R=$(python3 - "$O-blank.nvr" "$TYPE" <<'PY'
import sys
b, t = open(sys.argv[1], "rb").read(), int(sys.argv[2], 0)
i = b[0x1fd8:0x1fe8]
x = 0
for v in i:
    x ^= v
ok = (len(b) == 8192 and not any(b[:0x1fd8]) and not any(b[0x1fe8:0x1ff8])   # 0x1FF8-0x1FFF: the clock registers, in the image by design
      and i[0] == 1 and i[1] == t and i[2:5] == bytes([8, 0, 0x20])
      and i[5:8] == i[12:15] and x == 0)
print(("ok " if ok else "bad ") + i.hex())
PY
)
case "$R" in ok*) ;; *) fail "blank: the written-back IDPROM is wrong: $R" ;; esac
F=$(clean "$O-random.log" | grep '^FAIL')
[ "$F" = "FAIL chipset: NVRAM IDPROM format 1, machine type, checksum" ] \
    || fail "random: expected only t_idprom to fail, got: ${F:-nothing}"
clean "$O-random.log" | grep -B1 '^FAIL' | grep -q "check 00000003" \
    || fail "random: t_idprom did not fail its checksum check"
cmp -s "$O-random.nvr" "$O-random.orig" || fail "random: the image changed"
[ "$bad" = 0 ] && echo "run-nvram ss$REV: PASS (blank: $(clean "$O-blank.log" | grep 'CPUTEST DONE'), IDPROM ${R#ok }; $(grep 'NVRAM image' "$O-random.err" | sed 's/^\[sim\] //'))"
exit $bad
