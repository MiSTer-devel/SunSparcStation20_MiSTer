#!/usr/bin/env bash
#
# mk-openbios-nvram.sh OUT.nvr - an 8192-byte NVRAM image in OpenBIOS's own
# format (a "system" partition and a "free" partition), dumped from QEMU's
# SS-20 at machine start (its board code formats the M48T08 for OpenBIOS),
# with the IDPROM and the clock bytes blanked so the core's nvram_sd puts
# its built-in IDPROM in.
#
# Why: OpenBIOS formats any NVRAM it does not recognise ("nvram error
# detected, zapping pram") and then runs (set-defaults), whose undefined
# NVRAM hook makes (undefined-defer) scan RAM backwards for a word name —
# minutes on the board, an hour in simulation, and the defaults may not
# apply (no autoboot). With this image OpenBIOS finds valid partitions and
# boots at once. Use it as sim_main's --nvram (a copy: it is written back)
# or mount it on the MiSTer for the OpenBIOS tests.
set -euo pipefail
OUT="${1:?usage: $0 OUT.nvr}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
command -v qemu-system-sparc >/dev/null || { echo "qemu-system-sparc not found" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
# QMP over stdio: pmemsave of the SS-20's NVRAM (36-bit PA 0xF_F120_0000) after
# the firmware has run a moment; the HMP parser wants a relative file name.
(sleep 8; printf '{"execute":"qmp_capabilities"}\n'; sleep 1
 printf '{"execute":"human-monitor-command","arguments":{"command-line":"pmemsave 0xff1200000 8192 nvram.bin"}}\n'
 sleep 2; printf '{"execute":"quit"}\n') |
  timeout 60 qemu-system-sparc -M SS-20 -m 128 -display none -qmp stdio -serial none -boot c > /dev/null 2>&1 || true
[ -s nvram.bin ] || { echo "no NVRAM dump from QEMU" >&2; exit 1; }
python3 - nvram.bin "$OUT" <<'PY'
import sys
b = bytearray(open(sys.argv[1], "rb").read())
assert len(b) == 8192 and b[0] == 0x70, "not an OpenBIOS-format NVRAM (no system partition)"
off = 0
while off < 0x1fd8:
    sig, ln = b[off], (b[off + 2] << 8) | b[off + 3]
    if ln == 0:
        break
    print(f"partition @{off:04x}: sig={sig:02x} len={ln * 16} name={bytes(b[off + 4:off + 16]).rstrip(b'\0').decode()}")
    off += ln * 16
# This repo's OpenBIOS (drivers/obio.c) keeps 0x1f50-0x1fd7 for a one-shot
# reboot command and wants the partition walk to end exactly at 0x1f50:
# shorten the last (free) partition to end there and fix its checksum
# (packages/nvram.c nvpart_checksum: a byte sum with an end-around carry).
END = 0x1f50
VARS = b"boot-device=disk\0auto-boot?=true\0output-device=ttya\0input-device=ttya\0\0"
def checksum(h):
    v = h[0]
    for i in range(2, 16):
        v += h[i]
        if v > 255:
            v = (v - 256 + 1) & 0xff
    return v
off = 0
while True:
    ln = (b[off + 2] << 8) | b[off + 3]
    if off + ln * 16 >= END or b[off + ln * 16] == 0:
        break
    off += ln * 16
assert b[off] == 0x7f, "the last partition is not the free one"
# QEMU 11 leaves the system partition empty: give it the variables the
# board tests rely on, growing it to hold them (16-byte units), and move
# the free partition up behind it
sysoff = 0
assert b[sysoff] == 0x70
sysdata = sysoff + 16
need = (16 + len(VARS) + 15) // 16
b[sysdata:sysoff + need * 16] = VARS + bytes(need * 16 - 16 - len(VARS))
b[sysoff + 2], b[sysoff + 3] = need >> 8, need & 0xff
b[sysoff + 1] = checksum(b[sysoff:sysoff + 16])
off = sysoff + need * 16
b[off:off + 16] = bytes([0x7f, 0, 0, 0]) + b"free" + bytes(8)
newlen = (END - off) // 16
b[off + 2], b[off + 3] = newlen >> 8, newlen & 0xff
b[off + 1] = checksum(b[off:off + 16])
b[END:0x1fd8] = bytes(0x1fd8 - END)   # the reboot-command area
b[0x1fd8:0x1fe8] = bytes(16)         # the IDPROM: blank, for the core's built-in one
b[0x1ff8:0x2000] = bytes(8)          # the clock registers
print(f"free partition @{off:04x} now {newlen * 16} bytes, ends at {END:#x}; checksum {b[off + 1]:02x}")
open(sys.argv[2], "wb").write(bytes(b))
print("wrote", sys.argv[2])
PY
