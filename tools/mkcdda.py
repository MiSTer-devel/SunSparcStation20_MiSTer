#!/usr/bin/env python3
"""mkcdda.py DIR - a test disc for CD audio (PLAN S2): DIR/cddatest.cue with
a data track (cddatest-data.iso, 300 sectors of 2048 bytes with an ISO 9660
volume descriptor at 16, labelled CDDATEST) and two audio tracks of 10 s in
cddatest-audio.bin: a 440 Hz tone (track 2), then 880 Hz left and 660 Hz
right (track 3). Copy the three files to games/SunSparcStation on the
MiSTer (scripts/board/cdaudio.sh plays it under NetBSD).
"""
import math
import os
import struct
import sys


def tone(fl, fr, secs):
    out = bytearray()
    for i in range(44100 * secs):
        l = int(12000 * math.sin(2 * math.pi * fl * i / 44100))
        r = int(12000 * math.sin(2 * math.pi * fr * i / 44100))
        out += struct.pack('<hh', l, r)
    while len(out) % 2352:
        out += b'\0'
    return out


def main(d):
    os.makedirs(d, exist_ok=True)
    data = bytearray(300 * 2048)
    pvd = bytearray(2048)
    pvd[0] = 1
    pvd[1:6] = b'CD001'
    pvd[6] = 1
    pvd[40:72] = b'CDDATEST'.ljust(32)
    data[16 * 2048:17 * 2048] = pvd
    term = bytearray(2048)
    term[0] = 255
    term[1:6] = b'CD001'
    term[6] = 1
    data[17 * 2048:18 * 2048] = term
    with open(os.path.join(d, 'cddatest-data.iso'), 'wb') as f:
        f.write(data)
    t2 = tone(440, 440, 10)
    t3 = tone(880, 660, 10)
    with open(os.path.join(d, 'cddatest-audio.bin'), 'wb') as f:
        f.write(t2 + t3)
    f2 = len(t2) // 2352
    with open(os.path.join(d, 'cddatest.cue'), 'w') as f:
        f.write('FILE "cddatest-data.iso" BINARY\n'
                '  TRACK 01 MODE1/2048\n'
                '    INDEX 01 00:00:00\n'
                'FILE "cddatest-audio.bin" BINARY\n'
                '  TRACK 02 AUDIO\n'
                '    INDEX 01 00:00:00\n'
                '  TRACK 03 AUDIO\n'
                f'    INDEX 01 {f2 // 4500:02d}:{f2 // 75 % 60:02d}:{f2 % 75:02d}\n')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
