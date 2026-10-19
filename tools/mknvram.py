#!/usr/bin/env python3
"""mknvram.py OUT - an 8192-byte NVRAM image already formatted for OpenBIOS.

OpenBIOS keeps its settings in OpenFirmware partitions (bios/openbios,
packages/nvram.c): a "common" system partition of 0xc10 bytes at 0, then a
free partition up to the reboot-command area (0x1f50). A blank image is
formatted at the first boot; this one starts formatted, with every variable
at its default (OpenBIOS stores only the ones that differ). The IDPROM
(0x1fd8) and the clock (0x1ff8) are left zero: the core gives a blank
IDPROM the machine's identity at its first load (README, NVRAM).

The Sun PROMs use their own format: a Sun OBP formats this image for itself
the first time a setting changes, as it does a blank one.
"""
import sys

SIZE = 8192
OB_END = 0x1f50          # NVRAM_REBOOT_OFF: the end of OpenBIOS's partitions
SYSTEM = 0xc10           # DEF_SYSTEM_SIZE


def checksum(hdr):
    """nvpart_checksum: byte 0 plus bytes 2-15, with end-around carry."""
    v = hdr[0]
    for i in range(2, 16):
        v += hdr[i]
        if v > 255:
            v = (v - 256 + 1) & 0xff
    return v


def part(sig, name, size):
    h = bytearray(16)
    h[0] = sig
    h[2] = (size // 16) >> 8 & 0xff
    h[3] = (size // 16) & 0xff
    h[4:4 + len(name)] = name
    h[1] = checksum(h)
    return h


def image():
    b = bytearray(SIZE)
    b[0:16] = part(0x70, b'common', SYSTEM)
    b[SYSTEM:SYSTEM + 16] = part(0x7f, b'777777777777', OB_END - SYSTEM)
    return b


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with open(sys.argv[1], 'wb') as f:
        f.write(image())
