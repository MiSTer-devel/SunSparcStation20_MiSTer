#!/usr/bin/env python3
"""Minimal static linker for one big-endian ELF32 SPARC object.

    sparc_link.py in.o -o out.bin --base 0x70000000 [--size 0x40000]
                  [--map out.map] [--order .text,.rodata,.testtab]

LLVM assembles SPARC V8 (clang --target=sparc / llvm-mc -triple=sparc) but
has no 32-bit SPARC linker, and no sparc-elf binutils is installed. A boot
image built from a single translation unit only needs its sections placed
one after another from --base and its relocations applied, which is what
this does. Supported relocations: R_SPARC_8/16/32, DISP8/16/32, WDISP30,
WDISP22, HI22, 22, 13, LO10, UA32. Undefined symbols are an error.

Allocated PROGBITS sections go into the image in --order first, then in
file order; NOBITS (.bss) sections are an error - a ROM has no .bss, keep
variables at fixed RAM addresses instead.
"""

import argparse
import struct
import sys

R = {1: "8", 2: "16", 3: "32", 4: "DISP8", 5: "DISP16", 6: "DISP32",
     7: "WDISP30", 8: "WDISP22", 9: "HI22", 10: "22", 11: "13", 12: "LO10",
     23: "UA32"}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("obj")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--base", default="0")
    ap.add_argument("--size", default=None, help="pad image to this size")
    ap.add_argument("--fill", default="0xff")
    ap.add_argument("--map")
    ap.add_argument("--order", default=".text,.rodata,.data,.testtab")
    a = ap.parse_args()
    base = int(a.base, 0)
    d = open(a.obj, "rb").read()
    if d[:4] != b"\x7fELF" or d[4] != 1 or d[5] != 2:
        sys.exit("not a big-endian ELF32 object")
    (e_type, e_machine, _, _, _, e_shoff, _, _, _, _, e_shentsize, e_shnum,
     e_shstrndx) = struct.unpack(">HHIIIIIHHHHHH", d[16:52])
    if e_machine not in (2, 18):
        sys.exit(f"e_machine {e_machine} is not SPARC")
    sh = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        sh.append(struct.unpack(">IIIIIIIIII", d[o:o + 40]))
    shstr = sh[e_shstrndx]
    names = d[shstr[4]:shstr[4] + shstr[5]]

    def nm(off, tab=names):
        return tab[off:tab.index(b"\0", off)].decode()

    SHF_ALLOC, SHT_PROGBITS, SHT_NOBITS, SHT_RELA, SHT_SYMTAB = 2, 1, 8, 4, 2
    order = a.order.split(",")
    alloc = [i for i, s in enumerate(sh) if s[2] & SHF_ALLOC]
    for i in alloc:
        if sh[i][1] == SHT_NOBITS:
            sys.exit(f"section {nm(sh[i][0])} is NOBITS; a ROM has no .bss")
    alloc.sort(key=lambda i: (order.index(nm(sh[i][0]))
                              if nm(sh[i][0]) in order else len(order), i))
    addr = {}
    cur = base
    image = bytearray()
    for i in alloc:
        al = max(sh[i][8], 1)
        pad = (-cur) % al
        image += b"\0" * pad
        cur += pad
        addr[i] = cur
        image += d[sh[i][4]:sh[i][4] + sh[i][5]]
        cur += sh[i][5]

    symtab = [s for s in sh if s[1] == SHT_SYMTAB][0]
    strtab = sh[symtab[6]]
    strs = d[strtab[4]:strtab[4] + strtab[5]]
    syms = []
    for k in range(symtab[5] // 16):
        o = symtab[4] + 16 * k
        st_name, st_value, st_size, st_info, st_other, st_shndx = \
            struct.unpack(">IIIBBH", d[o:o + 16])
        name = nm(st_name, strs) if st_name else ""
        if st_shndx in addr:
            v = addr[st_shndx] + st_value
        elif st_shndx == 0xfff1:                      # SHN_ABS
            v = st_value
        elif st_shndx == 0:
            v = None
        else:
            v = None
        syms.append((name, v, st_shndx, st_info))

    for s in sh:
        if s[1] != SHT_RELA or s[7] not in addr:
            continue
        tgt = s[7]
        for k in range(s[5] // 12):
            o = s[4] + 12 * k
            r_off, r_info, r_add = struct.unpack(">IIi", d[o:o + 12])
            sym, typ = r_info >> 8, r_info & 0xff
            name, S, shndx, _ = syms[sym]
            if S is None:
                sys.exit(f"undefined symbol {name!r}")
            P = addr[tgt] + r_off
            io = P - base
            V = (S + r_add) & 0xffffffff
            t = R.get(typ)
            if t is None:
                sys.exit(f"unsupported relocation type {typ} at 0x{P:08x}")

            def put(n, val, mask):
                w = int.from_bytes(image[io:io + n], "big")
                w = (w & ~mask) | (val & mask)
                image[io:io + n] = w.to_bytes(n, "big")

            if t in ("32", "UA32"):
                put(4, V, 0xffffffff)
            elif t == "16":
                put(2, V, 0xffff)
            elif t == "8":
                put(1, V, 0xff)
            elif t == "DISP32":
                put(4, V - P, 0xffffffff)
            elif t == "DISP16":
                put(2, V - P, 0xffff)
            elif t == "DISP8":
                put(1, V - P, 0xff)
            elif t == "WDISP30":
                put(4, (V - P) >> 2, 0x3fffffff)
            elif t == "WDISP22":
                diff = ((V - P + (1 << 31)) % (1 << 32)) - (1 << 31)
                if not -(1 << 23) <= diff < (1 << 23):
                    sys.exit(f"WDISP22 out of range at 0x{P:08x}")
                put(4, diff >> 2, 0x3fffff)
            elif t == "HI22":
                put(4, V >> 10, 0x3fffff)
            elif t == "22":
                put(4, V, 0x3fffff)
            elif t == "13":
                put(4, V, 0x1fff)
            elif t == "LO10":
                put(4, V & 0x3ff, 0x3ff)

    if a.size:
        size = int(a.size, 0)
        if len(image) > size:
            sys.exit(f"image is 0x{len(image):x} bytes, over --size")
        image += bytes([int(a.fill, 0)]) * (size - len(image))
    open(a.out, "wb").write(image)
    if a.map:
        with open(a.map, "w") as m:
            for i in alloc:
                m.write(f"{addr[i]:08x} {sh[i][5]:8x} {nm(sh[i][0])}\n")
            for name, v, shndx, info in sorted(
                    (s for s in syms if s[1] is not None and s[0]),
                    key=lambda s: s[1]):
                m.write(f"{v:08x} {name}\n")


if __name__ == "__main__":
    main()
