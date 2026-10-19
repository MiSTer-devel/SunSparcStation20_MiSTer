#!/bin/sh
# build.sh [OUTDIR] - tools/nextstep/sgprobe.c -> OUTDIR/sgprobe, a NeXTSTEP
# 3.3 for SPARC executable (Mach-O MH_OBJECT like /usr/etc/scsilock, raw
# syscalls, no libraries), and OUTDIR/sgprobe.uu to type in on a NeXTSTEP
# shell through uudecode (tools/nextstep/sgprobe.sh). OUTDIR defaults to
# sim/out/nextstep. LLVM's clang compiles, tools/sparc_link.py links at VA 0,
# macho_wrap.py wraps. GPL-2.0-or-later.
set -e
R=$(cd "$(dirname "$0")/../.." && pwd)
O=${1:-$R/sim/out/nextstep}
mkdir -p "$O"
/usr/lib/llvm-18/bin/clang --target=sparc-unknown-elf -mcpu=v8 -Os -ffreestanding \
    -fno-builtin -fno-pic -fno-stack-protector -nostdlib \
    -c "$R/tools/nextstep/sgprobe.c" -o "$O/sgprobe.o"
python3 "$R/tools/sparc_link.py" "$O/sgprobe.o" -o "$O/sgprobe.bin" --base 0 --fill 0 \
    --order .text.start,.text,.rodata,.rodata.str1.1,.data --map "$O/sgprobe.map"
python3 "$R/tools/nextstep/macho_wrap.py" "$O/sgprobe.bin" "$O/sgprobe"
python3 - "$O/sgprobe" "$O/sgprobe.uu" <<'PY'
import binascii, sys
d = open(sys.argv[1], 'rb').read()
with open(sys.argv[2], 'w') as o:
    o.write('begin 755 sgprobe\n')
    for i in range(0, len(d), 45):
        o.write(binascii.b2a_uu(d[i:i + 45]).decode())
    o.write('`\nend\n')
PY
