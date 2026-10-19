#!/usr/bin/env python3
"""Find and detokenize the FCode images embedded in a Sun OBP 2.x PROM.

    detok.py docs/rom-disassembly/ss5-obp/romdis.json [--out-dir DIR]

Writes one fcode-<ROM address>-<first name>.txt per image into the
config's folder (or DIR). FCode names come from the ROM's own byte-code
token tables (found by obpforth.py), so they are the OBP 2.x names
(attribute, xdrint, ...), with the IEEE 1275 names for the headerless
b(...) primitives.

FCode (IEEE 1275 / OBP 2.x): an image starts with start0/1/2/4 (0xf0-0xf3)
or version1 (0xfd), then format:8, checksum:16 (sum of the bytes after the
8-byte header), length:32 (header included). Tokens are one byte
(0x10-0xff) or two (0x01-0x0f prefix byte + byte); 0x00 is end0, 0xff end1.
Inline operands: b(lit) 32 bits; b(') and b(to) an FCode number; b(") a
counted string; new-token an FCode number; named-token / external-token a
counted name then an FCode number; bbranch b?branch b(loop) b(+loop) b(do)
b(?do) b(of) b(endof) an offset, 16-bit after offset16 (implied by
start0..4) and 8-bit in version1 images, counted from the offset's first
byte. The 32 bytes following each 256-entry page of the ROM table are a
bitmap of the FCodes that execute while compiling.
"""

import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import obpforth                                             # noqa: E402

REPO = obpforth.REPO

# IEEE 1275 names of the FCodes whose ROM words are headerless
STD = {
    0x00: "end0", 0x10: "b(lit)", 0x11: "b(')", 0x12: "b(\")",
    0x13: "bbranch", 0x14: "b?branch", 0x15: "b(loop)", 0x16: "b(+loop)",
    0x17: "b(do)", 0x18: "b(?do)", 0x1b: "b(leave)", 0x1c: "b(of)",
    0xb1: "b(<mark)", 0xb2: "b(>resolve)", 0xb3: "set-token-table",
    0xb4: "set-table", 0xb5: "new-token", 0xb6: "named-token",
    0xb7: "b(:)", 0xb8: "b(value)", 0xb9: "b(variable)",
    0xba: "b(constant)", 0xbb: "b(create)", 0xbc: "b(defer)",
    0xbd: "b(buffer:)", 0xbe: "b(field)", 0xbf: "b(code)", 0xc0: "instance",
    0xc2: "b(;)", 0xc3: "b(to)", 0xc4: "b(case)", 0xc5: "b(endcase)",
    0xc6: "b(endof)", 0xca: "external-token", 0xcc: "offset16",
    0xf0: "start0", 0xf1: "start1", 0xf2: "start2", 0xf3: "start4",
    0xfd: "version1", 0xff: "end1",
}
BRANCH = {0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x1c, 0xc6}
DEFINERS = {0xb7: ":", 0xb8: "value", 0xb9: "variable", 0xba: "constant",
            0xbb: "create", 0xbc: "defer", 0xbd: "buffer:", 0xbe: "field"}


class Detok:
    def __init__(self, forth):
        self.f = forth
        self.d = forth.d

    def rom_name(self, n):
        if n in STD:
            return STD[n]
        r = self.f.fcode_name(n)
        if r is None:
            return None
        t, imm = r
        nm = self.f.names.get(t)
        if nm is None:
            return f"({self.f.va(self.f.cfa_of(t)):08x})"
        return nm

    def header(self, o):
        """(start byte, format, checksum, length) if o holds a plausible
        FCode image header."""
        d = self.d
        if o + 8 > len(d) or d[o] not in (0xf0, 0xf1, 0xf2, 0xf3, 0xfd):
            return None
        fmt, ck = d[o + 1], int.from_bytes(d[o + 2:o + 4], "big")
        ln = int.from_bytes(d[o + 4:o + 8], "big")
        if not 16 <= ln <= len(d) - o or fmt > 0x10:
            return None
        return d[o], fmt, ck, ln

    def find(self):
        """Images whose token stream decodes cleanly up to end0 close to
        the length the header states."""
        out = []
        o = 0
        while o < len(self.d) - 8:
            h = self.header(o)
            if h is not None:
                r = self.decode(o, h, probe=True)
                if r is not None:
                    out.append((o, h))
                    o += h[3]
                    continue
            o += 1
        return out

    def fnum(self, p):
        b = self.d[p]
        if 0x01 <= b <= 0x0f:
            return (b << 8) | self.d[p + 1], 2
        return b, 1

    def decode(self, o, h, probe=False):
        start, fmt, ck, ln = h
        d = self.d
        end = o + ln
        off16 = start != 0xfd
        p = o + 8
        items = []          # (offset, kind, text/obj)
        names = {}          # fcode# -> name defined by the image
        bad = 0
        while p < end:
            at = p
            n, w = self.fnum(p)
            p += w
            if n == 0x00:
                items.append((at, "end", "end0"))
                break
            if n == 0xff:
                items.append((at, "end", "end1"))
                break
            nm = names.get(n) or self.rom_name(n)
            if nm is None or nm == "ferror":
                bad += 1
                nm = f"ferror(0x{n:03x})"
                if probe and bad > 2:
                    return None
            if n == 0x10:
                v = int.from_bytes(d[p:p + 4], "big")
                p += 4
                items.append((at, "lit", v))
            elif n in (0x11, 0xc3):
                x, w2 = self.fnum(p)
                p += w2
                tn = names.get(x) or self.rom_name(x) or f"0x{x:x}"
                items.append((at, "tok", ("[']" if n == 0x11 else "to",
                                          tn)))
            elif n == 0x12:
                c = d[p]
                s = d[p + 1:p + 1 + c]
                p += 1 + c
                items.append((at, "str", s))
            elif n in BRANCH:
                if off16:
                    v = int.from_bytes(d[p:p + 2], "big", signed=True)
                    q = p
                    p += 2
                else:
                    v = int.from_bytes(d[p:p + 1], "big", signed=True)
                    q = p
                    p += 1
                items.append((at, "br", (nm, q + v)))
            elif n == 0xb5:
                x, w2 = self.fnum(p)
                p += w2
                names[x] = f"t{x:03x}"
                items.append((at, "new", (None, x)))
            elif n in (0xb6, 0xca):
                c = d[p]
                s = d[p + 1:p + 1 + c].decode("latin-1")
                p += 1 + c
                x, w2 = self.fnum(p)
                p += w2
                names[x] = s
                items.append((at, "new", (s, x, n == 0xca)))
            elif n == 0xcc:
                off16 = True
                items.append((at, "call", nm))
            elif n in DEFINERS:
                items.append((at, "def", DEFINERS[n]))
            elif n == 0xc2:
                items.append((at, "semi", ";"))
            else:
                items.append((at, "call", nm))
        else:
            if probe:
                return None
        if probe:
            last = items[-1][0] if items else o
            if not items or items[-1][1] != "end" or last < end - 16 or \
                    len(items) < 8:
                return None
        return items, names, p, bad

    def text(self, o, h, width=100):
        start, fmt, ck, ln = h
        items, names, stop, bad = self.decode(o, h)
        calc = sum(self.d[o + 8:o + ln]) & 0xffff
        rom = self.f.rom(o)
        L = [f"\\ FCode image at ROM 0x{rom:08x} (file 0x{o:x}), "
             f"{ln} (0x{ln:x}) bytes: {STD.get(start, hex(start))}, "
             f"format 0x{fmt:02x}, checksum 0x{ck:04x} "
             f"(sum of bytes 8..len = 0x{calc:04x}"
             f"{', matches' if calc == ck else ', differs'})",
             "\\ generated by tools/romdis/detok.py - do not edit. "
             "Names from the ROM's byte-code tables.",
             f"\\ decoding stopped at +0x{stop - o:x}"
             + (f"; {bad} unknown FCode numbers" if bad else ""),
             "\\ Each paragraph starts with the byte offset in the image. "
             "Ln: marks a branch target;",
             "\\ b?branch Ln / bbranch Ln / b(do) Ln (loop exit) jump to it. "
             "tNNN = headerless token NNN.",
             ""]
        targets = sorted({x[1] for a, k, x in items if k == "br"})
        lab = {a: f"L{i + 1}" for i, a in enumerate(targets)}
        cur = []
        lines = []

        def flush():
            if cur:
                lines.append(cur[:])
                cur.clear()

        skip = set()
        for i, (a, k, x) in enumerate(items):
            if i in skip:
                continue
            if k == "new":
                nm = f"t{x[1]:03x}" if x[0] is None else x[0]
                pre = "external " if x[0] is not None and x[2] else ""
                tag = "" if x[0] is None else f" (0x{x[1]:03x})"
                nx = items[i + 1] if i + 1 < len(items) else None
                if nx is not None and nx[1] == "def":
                    skip.add(i + 1)
                    if nx[2] == ":":
                        flush()
                        cur.append((a, f"{pre}: {nm}{tag}"))
                    else:
                        cur.append((a, f"{pre}{nx[2]} {nm}{tag}"))
                        flush()
                else:
                    cur.append((a, f"{pre}new-token {nm}{tag}"))
                continue
            if a in lab:
                cur.append((a, f"{lab[a]}:"))
            if k == "lit":
                cur.append((a, f"0x{x:x}" if x > 9 and x != 0xffffffff
                            else "-1" if x == 0xffffffff else str(x)))
            elif k == "tok":
                cur.append((a, f"{x[0]} {x[1]}"))
            elif k == "str":
                t = "".join(chr(c) if 32 <= c < 127 else f"\\x{c:02x}"
                            for c in x)
                cur.append((a, f"\" {t}\""))
            elif k == "br":
                cur.append((a, f"{x[0]} {lab.get(x[1], hex(x[1]))}"))
            elif k == "def":
                cur.append((a, x))
            elif k == "semi":
                cur.append((a, ";"))
                flush()
            elif k == "end":
                flush()
                cur.append((a, x))
                flush()
            else:
                cur.append((a, x))
        flush()
        for grp in lines:
            toks = [t for a, t in grp if t]
            if not toks:
                continue
            a0 = grp[0][0] - o
            prefix = f"{a0:5x}: "
            ln_ = prefix
            for t in toks:
                if len(ln_) + len(t) + 1 > width and ln_.strip():
                    L.append(ln_.rstrip())
                    ln_ = " " * len(prefix)
                ln_ += t + " "
            L.append(ln_.rstrip())
        return "\n".join(L) + "\n", items, names

    def title(self, items):
        """The first string an image makes its "name" property from."""
        prev = None
        for a, k, x in items:
            if k == "str":
                if x == b"name" and prev is not None:
                    return prev.decode("latin-1")
                prev = x
            elif k == "call" and x in ("name", "device-name") and \
                    prev is not None:
                return prev.decode("latin-1")
        for a, k, x in items:            # else the first named word
            if k == "new" and x[0]:
                return x[0]
        return None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("config")
    ap.add_argument("--out-dir")
    args = ap.parse_args()
    cfg = json.load(open(args.config))
    here = args.out_dir or os.path.dirname(os.path.abspath(args.config))
    rom = cfg["rom"]
    if not os.path.isabs(rom):
        rom = os.path.join(REPO, rom)
    data = open(rom, "rb").read()
    base = int(cfg.get("base", "0"), 0)
    f = obpforth.Forth(data, base).run()
    dt = Detok(f)
    found = dt.find()
    for o, h in found:
        txt, items, names = dt.text(o, h)
        t = dt.title(items) or "image"
        safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", t)
        fn = os.path.join(here, f"fcode-{f.rom(o):08x}-{safe}.txt")
        open(fn, "w").write(txt)
        print(f"{os.path.basename(fn)}: {h[3]} bytes, {len(items)} tokens, "
              f"{len(names)} tokens defined", file=sys.stderr)
    if not found:
        print("no FCode images found", file=sys.stderr)


if __name__ == "__main__":
    main()
