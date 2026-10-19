#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""qcon.py SOCKET [send:TEXT | wait:REGEX[:SECONDS]]... - drive a QEMU
serial console exposed as a Unix socket (-chardev socket,...,server=on): each
send types TEXT (\\r for Enter) a character at a time, each wait reads until
REGEX matches the output (default 600 s; exit 1 on a time-out). Everything
read is echoed to stdout."""
import re
import socket
import sys
import time

s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.settimeout(0.5)
buf = ""


def read_some():
    global buf
    try:
        d = s.recv(4096).decode("latin-1")
    except socket.timeout:
        return
    sys.stdout.write(d)
    sys.stdout.flush()
    buf += d


for a in sys.argv[2:]:
    kind, _, arg = a.partition(":")
    if kind == "send":
        for ch in arg.replace("\\r", "\r"):
            s.send(ch.encode("latin-1"))
            time.sleep(0.02)
            read_some()
        buf = ""
    elif kind == "wait":
        m = re.match(r"(.*?)(?::(\d+))?$", arg, re.S)
        pat, tmo = m.group(1), int(m.group(2) or 600)
        end = time.time() + tmo
        while not re.search(pat, buf):
            if time.time() > end:
                sys.stdout.write(f"\n[qcon] time-out waiting for {pat!r}\n")
                sys.exit(1)
            read_some()
        buf = ""
