#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""obp_nvram.py - OBP 2.25 NVRAM images (8 KB M48T08) for the Sun PROM.

  obp_nvram.py IN OUT [name=value ...]   edit IN's options, fix the checksum
  obp_nvram.py --new OUT [name=value ...]  a new image with the defaults
  obp_nvram.py --sv OUT.sv               the defaults as rtl/pkg/obp_nvram_pkg.sv

Sun's OBP keeps its options at fixed offsets of the NVRAM and checks them
with a one-byte checksum at offset 0; an image edited by hand without it, a
blank one, or one OpenBIOS formatted gets "Incorrect configuration checksum"
and then OBP sets every option to its default, sets diag-switch? to true on
top (so the next start runs the full POST, tests all of memory and boots
the diagnostic device, the network) and writes that back. The offsets and
the checksum come from the OBP 2.25 Forth dictionary (tools/romdis/obpforth.py
on your own PROM image; each option's header holds its offset and size);
the checksum is 0x38 (#fixed-params) ^ 0xf0 ^ the XOR of bytes 0x20..0x1cd7.

--new writes the options' defaults (the OpenBoot 2.x defaults, with
diag-switch? false and boot-device disk) and a good checksum, the rest
zero: the IDPROM (0x1fd8) and the clock (0x1ff8) are left blank, and the
core gives a blank IDPROM the machine's identity at its first load. The
core writes the same defaults into an empty NVRAM itself (no image in the
OSD's NVRAM slot, or a blank image file): --sv makes the table it uses.

Options:
  input-device=S, output-device=S   e.g. ttya, keyboard, screen
  boot-device=S, diag-device=S      e.g. disk, cdrom, net
  auto-boot?=true|false, diag-switch?=true|false
  selftest-#megs=N                  the memory the non-diag start tests
  0xOFF=0xBYTE                      any byte

Prints those options at the end. Never commit a Sun-written NVRAM image
(docs/VERILOG-PLAN.md 1.1).
"""
import sys

SIZE = 8192
CK_LO, CK_HI = 0x20, 0x1cd8         # the checksummed range
CK_SEED = 0x38 ^ 0xf0

# name: (offset, kind, size); kind s = a string (a length byte, then the
# text), f = a flag (0xff true), b = a byte, n = a 32-bit big-endian number
OPTIONS = {
    "diag-switch?":     (0x001, "f", 1),
    "boot-device":      (0x29f, "s", 0x102),
    "diag-device":      (0x423, "s", 0x102),
    "auto-boot?":       (0x5a8, "f", 1),
    "sbus-probe-list":  (0x5a9, "s", 0x0a),
    "scsi-initiator-id": (0x5b3, "b", 1),
    "selftest-#megs":   (0x5b4, "n", 4),
    "screen-#rows":     (0x5b8, "b", 1),
    "screen-#columns":  (0x5b9, "b", 1),
    "ttya-mode":        (0x5bc, "s", 0x12),
    "ttyb-mode":        (0x5ce, "s", 0x12),
    "ttya-ignore-cd":   (0x5e0, "f", 1),
    "ttyb-ignore-cd":   (0x5e2, "f", 1),
    "input-device":     (0x769, "s", 0x22),
    "output-device":    (0x78b, "s", 0x22),
    "tpe-link-test?":   (0x7ad, "f", 1),
}

# The defaults that are not zero (OpenBoot 2.x Command Reference), with
# boot-device "disk" rather than "disk net": with no disk the PROM stops at
# `ok` instead of waiting on the network. sbus-probe-list has no fixed
# default in the PROM: set-defaults stores "fe0123" when the IOMMU reports an
# implementation (ours does) and "f0123" otherwise; left empty, OBP probes
# no SBus slot, finds no TCX and prints "screen not found." on ttya.
DEFAULTS = {
    "boot-device": "disk",
    "diag-device": "net",
    "auto-boot?": "true",
    "sbus-probe-list": "fe0123",
    "scsi-initiator-id": "7",
    "selftest-#megs": "1",
    "screen-#rows": "34",
    "screen-#columns": "80",
    "ttya-mode": "9600,8,n,1,-",
    "ttyb-mode": "9600,8,n,1,-",
    "ttya-ignore-cd": "true",
    "ttyb-ignore-cd": "true",
    "input-device": "keyboard",
    "output-device": "screen",
    "tpe-link-test?": "true",
}

SHOWN = ("input-device", "output-device", "boot-device", "auto-boot?",
         "diag-switch?", "selftest-#megs")


def checksum(b):
    x = CK_SEED
    for i in range(CK_LO, CK_HI):
        x ^= b[i]
    return x


def put(b, k, v):
    if k.startswith("0x"):
        b[int(k, 16)] = int(v, 0)
        return
    if k not in OPTIONS:
        sys.exit(f"unknown option {k}")
    off, kind, size = OPTIONS[k]
    if kind == "s":
        if len(v) >= min(size, 256):
            sys.exit(f"{k}: at most {min(size, 256) - 1} characters")
        b[off:off + size] = bytes(size)
        b[off] = len(v)
        b[off + 1:off + 1 + len(v)] = v.encode()
    elif kind == "f":
        if v not in ("true", "false"):
            sys.exit(f"{k}: true or false")
        b[off] = 0xff if v == "true" else 0x00
    else:
        b[off:off + size] = int(v, 0).to_bytes(size, "big")


def get(b, k):
    off, kind, size = OPTIONS[k]
    if kind == "s":
        return b[off + 1:off + 1 + b[off]].decode(errors="replace")
    if kind == "f":
        return "true" if b[off] else "false"
    return str(int.from_bytes(b[off:off + size], "big"))


def defaults():
    b = bytearray(SIZE)
    for k, v in DEFAULTS.items():
        put(b, k, v)
    b[0] = checksum(b)
    return b


def write_sv(path):
    """The nonzero halfwords of the default image, as nvram_sd writes them:
    the halfword address (byte address / 2) and the halfword in Main's
    order (the even byte low)."""
    b = defaults()
    ent = [(a // 2, b[a] | b[a + 1] << 8) for a in range(0, CK_HI, 2) if b[a] or b[a + 1]]
    lines = [
        "// SPDX-License-Identifier: GPL-2.0-or-later",
        "//",
        "// obp_nvram_pkg: the Sun OBP 2.25's NVRAM defaults, which nvram_sd",
        "// writes into an empty NVRAM (no image, or a blank one) so that the PROM",
        "// finds a good configuration checksum: without it OBP sets diag-switch?",
        "// and tests all of memory at every start. GENERATED by",
        "// `tools/obp_nvram.py --sv rtl/pkg/obp_nvram_pkg.sv`: edit the tool.",
        "//",
        "// Entry k: {halfword address, halfword (the even byte in [7:0])}, the",
        "// image's nonzero halfwords below the IDPROM; the checksum is entry 0's",
        "// even byte.",
        "",
        "package obp_nvram_pkg;",
        "",
        f"  localparam int OBP_DFLT_N = {len(ent)};",
        "",
        "  function automatic logic [27:0] obp_dflt(input logic [$clog2(OBP_DFLT_N)-1:0] k);",
        "    case (k)",
    ]
    for i, (hw, v) in enumerate(ent):
        lines.append(f"      {i:>2}:      return {{12'h{hw:03x}, 16'h{v:04x}}};")
    lines += [
        "      default: return '0;",
        "    endcase",
        "  endfunction",
        "",
        "endpackage",
        "",
    ]
    if ent[0][0] != 0:
        sys.exit("the checksum halfword must be entry 0")
    open(path, "w").write("\n".join(lines))


def main():
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == "--sv":
        write_sv(a[1])
        return
    if len(a) < 2 or a[0] in ("-h", "--help"):
        sys.exit(__doc__)
    if a[0] == "--new":
        b = defaults()
    else:
        b = bytearray(open(a[0], "rb").read())
        if len(b) != SIZE:
            sys.exit("not an 8 KB NVRAM image")
        if b[0] != checksum(b):
            print("note: the input's configuration checksum is wrong", file=sys.stderr)
    for kv in a[2:]:
        k, v = kv.split("=", 1)
        put(b, k, v)
    b[0] = checksum(b)
    for k in SHOWN:
        print(f"{k}={get(b, k)}")
    open(a[1], "wb").write(b)


if __name__ == "__main__":
    main()
