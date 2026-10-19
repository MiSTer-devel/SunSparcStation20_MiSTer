#!/usr/bin/env python3
"""uinput_keys.py TOKEN... - runs on the MiSTer (root): a virtual keyboard
through /dev/uinput, which Main reads like any USB keyboard and turns into
the core's PS/2 keyboard. Unlike mrext's keyboard-raw call it can hold keys,
so chords (Right Alt + F1, Stop-A held across a reset) can be typed.

Tokens, with Linux key codes (input-event-codes.h):
  +N   key N down        -N   key N up        N   tap (down, then up)
  wS   wait S seconds (decimal)
e.g. Stop-A as the core maps it (Right Alt + F1, then A):
  uinput_keys.py +100 59 -100 30
Main needs about a second to pick up a new device: the script waits 2 s
after creating it, and 0.5 s before removing it.
"""
import fcntl, os, struct, sys, time

UI_SET_EVBIT, UI_SET_KEYBIT = 0x40045564, 0x40045565
UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502
EV_SYN, EV_KEY = 0, 1

fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
for k in range(1, 256):
    fcntl.ioctl(fd, UI_SET_KEYBIT, k)
# struct uinput_user_dev: name[80], input_id (4 x u16), ff_effects_max,
# absmax/absmin/absfuzz/absflat[64]
dev = struct.pack('80sHHHHi', b'sunkeys', 3, 0x1234, 0x5678, 1, 0) + bytes(4 * 64 * 4)
os.write(fd, dev)
fcntl.ioctl(fd, UI_DEV_CREATE)
time.sleep(2)

def ev(t, c, v):
    s, us = divmod(time.time(), 1)
    os.write(fd, struct.pack('llHHi', int(s), int(us * 1e6), t, c, v))

def key(c, v):
    ev(EV_KEY, c, v)
    ev(EV_SYN, 0, 0)
    time.sleep(0.08)

for tok in sys.argv[1:]:
    if tok.startswith('w'):
        time.sleep(float(tok[1:]))
    elif tok.startswith('+'):
        key(int(tok[1:]), 1)
    elif tok.startswith('-'):
        key(int(tok[1:]), 0)
    else:
        key(int(tok), 1)
        key(int(tok), 0)
time.sleep(0.5)
fcntl.ioctl(fd, UI_DEV_DESTROY)
os.close(fd)
