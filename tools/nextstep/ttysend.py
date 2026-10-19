#!/usr/bin/env python3
# ttysend.py FILE [CHAR_MS] [LINE_MS]: type FILE on ttya (/dev/ttyS1), one byte
# at a time; \n becomes \r (Enter). Runs on the MiSTer. GPL-2.0-or-later.
import sys, time, os
data = open(sys.argv[1], 'rb').read()
cms = float(sys.argv[2]) / 1000 if len(sys.argv) > 2 else 0.01
lms = float(sys.argv[3]) / 1000 if len(sys.argv) > 3 else 0.05
fd = os.open('/dev/ttyS1', os.O_WRONLY | os.O_NOCTTY)
for c in data:
    if c == 10: c = 13
    os.write(fd, bytes([c]))
    time.sleep(lms if c == 13 else cms)
os.close(fd)
