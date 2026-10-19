#!/usr/bin/env python3
"""mkscsiimg.py OUT TAG [BLOCKS] - a disk image for tests/cpu/src/scsitest.S.

Block n (512 bytes, big-endian words): 'SCSI', TAG (up to 4 bytes, NUL
padded, e.g. HD0), n, then (n << 8 | k) ^ 0xa5a5a5a5 for k = 3..127.
BLOCKS defaults to 2048 (1 MB)."""
import struct, sys

def image(tag, blocks):
    t = struct.unpack(">I", tag.encode().ljust(4, b"\0")[:4])[0]
    out = bytearray()
    for n in range(blocks):
        w = [0x53435349, t, n] + [((n << 8) | k) ^ 0xa5a5a5a5 for k in range(3, 128)]
        out += struct.pack(">128I", *w)
    return bytes(out)

if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    open(sys.argv[1], "wb").write(image(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 2048))
