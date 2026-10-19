#!/usr/bin/env python3
"""tcpsrv.py recv PORT OUT | send PORT FILE - one TCP connection, for the
guest's network tests: recv stores what arrives until EOF in OUT; send
writes FILE and closes. Prints the byte count, the seconds and cksum."""
import socket, subprocess, sys, time
mode, port, path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', port)); s.listen(1); s.settimeout(1800)
c, a = s.accept(); t0 = time.time(); n = 0
if mode == 'recv':
    with open(path, 'wb') as f:
        while True:
            b = c.recv(65536)
            if not b: break
            f.write(b); n += len(b)
else:
    with open(path, 'rb') as f:
        data = f.read()
    c.sendall(data); n = len(data)
    c.shutdown(socket.SHUT_WR)
    while c.recv(65536): pass
c.close(); dt = time.time() - t0
ck = subprocess.run(['cksum', path], capture_output=True, text=True).stdout.split()[:2]
print(f"{mode} {a[0]}: {n} bytes in {dt:.1f} s ({n / dt / 1024:.0f} KB/s), cksum {' '.join(ck)}", flush=True)
