#!/usr/bin/env python3
"""uinput_mouse.py TOKEN... - runs on the MiSTer (root): a virtual mouse
through /dev/uinput, which Main reads like any USB mouse and turns into the
core's Sun mouse (as uinput_keys.py does for the keyboard).

Tokens:
  mDX,DY   move by DX, DY counts (split into steps of at most 8, 10 ms
           apart, so the guest's acceleration stays low)
  sN       steps of at most N counts from here on (NeXTSTEP accelerates
           steps of 8, so 8-count paths do not repeat; with s1 or s2 a
           move maps to the screen linearly)
  c        left click          r   right click
  +l -l    left button down / up (drags)
  wS       wait S seconds (decimal)
e.g. uinput_mouse.py m-400,-400 m100,50 c
Main rescans /dev/input when a node appears, but a mouse's eventN node
comes before its mouseN node (the one Main reads), so that rescan misses it:
a second, dummy device is created and removed after the mouse to make Main
rescan once the mouseN node exists. Then 2 s for Main to settle, and 0.5 s
before removing the mouse.

Solaris: its `ms` STREAMS module discards the first 48 packets after the
mouse is opened (X's start; the baud-rate detection settling), so start a
session with a warm-up of at least 48 packets (e.g. m-400,-400 = 50 steps
of 8) before moves that matter.
"""
import fcntl, os, struct, sys, time

UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_RELBIT = 0x40045564, 0x40045565, 0x40045566
UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502
EV_SYN, EV_KEY, EV_REL = 0, 1, 2
REL_X, REL_Y = 0, 1
BTN_LEFT, BTN_RIGHT, BTN_MIDDLE = 0x110, 0x111, 0x112

fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_REL)
for b in (BTN_LEFT, BTN_RIGHT, BTN_MIDDLE):
    fcntl.ioctl(fd, UI_SET_KEYBIT, b)
fcntl.ioctl(fd, UI_SET_RELBIT, REL_X)
fcntl.ioctl(fd, UI_SET_RELBIT, REL_Y)
dev = struct.pack('80sHHHHi', b'sunmouse', 3, 0x1234, 0x5679, 1, 0) + bytes(4 * 64 * 4)
os.write(fd, dev)
fcntl.ioctl(fd, UI_DEV_CREATE)
time.sleep(1)
dummy = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(dummy, UI_SET_EVBIT, EV_KEY)
fcntl.ioctl(dummy, UI_SET_KEYBIT, 1)
os.write(dummy, struct.pack('80sHHHHi', b'rescan', 3, 0x1234, 0x567a, 1, 0) + bytes(4 * 64 * 4))
fcntl.ioctl(dummy, UI_DEV_CREATE)
time.sleep(1)
fcntl.ioctl(dummy, UI_DEV_DESTROY)
os.close(dummy)
time.sleep(2)


def ev(t, c, v):
    os.write(fd, struct.pack('llHHi', 0, 0, t, c, v))


def syn():
    ev(EV_SYN, 0, 0)


STEP = 8


def move(dx, dy):
    while dx or dy:
        sx = max(-STEP, min(STEP, dx))
        sy = max(-STEP, min(STEP, dy))
        if sx:
            ev(EV_REL, REL_X, sx)
        if sy:
            ev(EV_REL, REL_Y, sy)
        syn()
        dx -= sx
        dy -= sy
        time.sleep(0.01)


def button(b, v):
    ev(EV_KEY, b, v)
    syn()
    time.sleep(0.1)


for tok in sys.argv[1:]:
    if tok.startswith('m'):
        x, y = tok[1:].split(',')
        move(int(x), int(y))
    elif tok.startswith('s'):
        STEP = int(tok[1:])
    elif tok == 'c':
        button(BTN_LEFT, 1)
        button(BTN_LEFT, 0)
    elif tok == 'r':
        button(BTN_RIGHT, 1)
        button(BTN_RIGHT, 0)
    elif tok == '+l':
        button(BTN_LEFT, 1)
    elif tok == '-l':
        button(BTN_LEFT, 0)
    elif tok.startswith('w'):
        time.sleep(float(tok[1:]))
    else:
        sys.exit(f'uinput_mouse: bad token {tok!r}')
    time.sleep(0.05)

time.sleep(0.5)
fcntl.ioctl(fd, UI_DEV_DESTROY)
os.close(fd)
