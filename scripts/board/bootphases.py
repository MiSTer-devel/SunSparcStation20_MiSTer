#!/usr/bin/env python3
"""bootphases.py LOG.ts - times of the Solaris/NetBSD boot milestones in a
timestamped capture (scratch/tscap.sh: each chunk prefixed '@<epoch> ')."""
import re, sys

MARKS = ["OpenBIOS start", "Trying disk", "Jumping to entry point", "SunOS Release",
         "NetBSD 11", "root on", "Hostname:", "Configuring devices", "The system is ready",
         "console login:", "login:"]
t0 = None
seen = set()
text = open(sys.argv[1], errors="replace").read()
for m in re.finditer(r"@(\d+\.\d+) ([^@]*)", text, re.S):
    t, chunk = float(m.group(1)), m.group(2)
    if t0 is None:
        t0 = t
    for k in MARKS:
        if k in chunk and k not in seen:
            seen.add(k)
            print(f"{t - t0:7.1f} s  {k}")
