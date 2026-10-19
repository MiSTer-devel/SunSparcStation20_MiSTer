#!/usr/bin/env python3
# macho_wrap.py IMAGE OUT: a flat image linked at VA 0 -> a NeXTSTEP/SPARC Mach-O
# MH_OBJECT executable (the layout of /usr/etc/scsilock): one rwx segment at
# VA 0 holding everything, entry (pc) 0, no shared libraries; the buffers
# above the image are zero-filled up to 0x9000. GPL-2.0-or-later.
import struct, sys
img = open(sys.argv[1], 'rb').read()
img += b'\0' * ((-len(img)) % 8)
vsz = 0x9000                   # zero-filled up to 0x9000 (buffers at 0x8000)
assert len(img) < 0x8000
seg_cmd_size = 56 + 68           # one section
thread_size = 92
hdr = 28 + seg_cmd_size + thread_size
foff = (hdr + 7) & ~7
sect = struct.pack('>16s16s7I', b'__text', b'__TEXT', 0, len(img), foff, 2, 0, 0, 0) + b'\0' * 8
seg = struct.pack('>2I16s8I', 1, seg_cmd_size, b'', 0, vsz, foff, len(img), 7, 7, 1, 0) + sect
thr = struct.pack('>4I', 5, thread_size, 1, 19) + b'\0' * 76   # psr, pc 0, npc ...
mh = struct.pack('>7I', 0xfeedface, 14, 0, 1, 2, seg_cmd_size + thread_size, 1)
out = mh + seg + thr
out += b'\0' * (foff - len(out)) + img
open(sys.argv[2], 'wb').write(out)
