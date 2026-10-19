#!/usr/bin/env python3
"""Recursive-descent disassembler for sun4m boot PROMs.

    romdis.py CONFIG.json [-o listing.s] [--db analysis.json]

The config (JSON) names the ROM image and everything a human has learned
about it; the tool never needs the image to be in the repository:

{
  "rom":     "scratch/SparcStation/ss5.bin",   # relative to the repo root
  "profile": "ss5",                            # sun4m.PROFILES key
  "base":    "0x70000000",                     # link address of offset 0
  "trap_table": true,                          # seed the 256 trap vectors
  "trap_tables": {"0x70001000": "tt1"},        # more tables, label prefix
  "entries": {"0x70001000": "name", ...},      # extra code entry points
  "labels":  {"0x70001234": "name", ...},      # names for any address
  "comments":{"0x70001234": "text", ...},      # end-of-line comments
  "blocks":  {"0x70001234": "text", ...},      # comment block above
  "regions": [ {"start": "0x...", "end": "0x...", "type": "data|string|
               forth|fcode|pad|code", "name": "..."} ],
  "noreturn":["0x7000abcd"],                   # calls that never return
  "jumptables": [ {"at": "0x...", "count": N} ], # tables of code addrs
  "include": ["forth.json"],                   # merged configs (generated
                                               #  by other tools)
  "aliases": [ {"base": "0xffd00000",          # other addresses the image
                "size": "0x40000"} ]           #  runs at (MMU mappings);
}                                              #  optional "offset" into ROM,
                                               #  "flow": true = only for
                                               #  jump/call targets

Code is found by following control flow from the entries: branches, calls,
constant jmpl targets (sethi/or pairs are tracked), delay slots, annulled
branches. Everything not reached is emitted as data (strings detected),
with a hint when a stretch decodes cleanly and looks like unreached code.
"""

import argparse
import json
import os
import string
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sparcv8                                              # noqa: E402
import sun4m                                                # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PRINTABLE = set(bytes(string.printable, "ascii")) - set(b"\x0b\x0c")


def num(v):
    return int(v, 0) if isinstance(v, str) else int(v)


class Rom:
    def __init__(self, cfg):
        self.cfg = cfg
        path = cfg["rom"]
        if not os.path.isabs(path):
            path = os.path.join(REPO, path)
        self.data = open(path, "rb").read()
        self.base = num(cfg.get("base", 0))
        self.end = self.base + len(self.data)
        self.profile = cfg.get("profile", "ss5")
        self.kind = {}          # addr -> 'code' for decoded instructions
        self.insn = {}          # addr -> Insn
        self.labels = {num(k): v for k, v in cfg.get("labels", {}).items()}
        self.comments = {num(k): v for k, v in cfg.get("comments", {}).items()}
        self.blocks = {num(k): v for k, v in cfg.get("blocks", {}).items()}
        self.xrefs = {}         # target -> set((from, kind))
        self.notes = {}         # addr -> [auto annotations]
        self.regions = []
        for r in cfg.get("regions", []):
            self.regions.append((num(r["start"]), num(r["end"]),
                                 r["type"], r.get("name", "")))
        self.regions.sort()
        # optional region keys: "format": "w16" prints halfwords (token
        # threaded Forth, see obpforth.py); "banner": false drops the banner
        self.region_opt = {(num(r["start"]), num(r["end"])): r
                           for r in cfg.get("regions", [])}
        self.noreturn = {num(a) for a in cfg.get("noreturn", [])}
        # virtual windows onto the image: (vbase, size, rom address,
        # flow-only). A flow-only alias (e.g. a boot-mode fetch window at
        # 0) is applied to jump/call targets but not to data constants.
        self.aliases = [(num(x["base"]), num(x.get("size", len(self.data))),
                         self.base + num(x.get("offset", 0)),
                         bool(x.get("flow", False)))
                        for x in cfg.get("aliases", [])]
        self.funcs = set()
        self.strings = {}       # addr -> str, strings referenced by code

    # ------------------------------------------------------------ helpers
    def inrom(self, a):
        return self.base <= a < self.end

    def canon(self, a, flow=False):
        """Map an address in one of the configured aliases (for example the
        ROM's virtual mapping) to the ROM address it shows; others pass.
        flow=True also applies the flow-only aliases."""
        if self.inrom(a):
            return a
        for vb, sz, rb, fo in self.aliases:
            if vb <= a < vb + sz and (flow or not fo):
                return rb + (a - vb)
        return a

    def word(self, a):
        o = a - self.base
        return int.from_bytes(self.data[o:o + 4], "big")

    def region_at(self, a):
        for lo, hi, t, n in self.regions:
            if lo <= a < hi:
                return lo, hi, t, n
        return None

    def is_data_region(self, a):
        r = self.region_at(a)
        return r is not None and r[2] != "code"

    def xref(self, tgt, frm, kind):
        self.xrefs.setdefault(tgt, set()).add((frm, kind))

    def note(self, a, text):
        self.notes.setdefault(a, [])
        if text not in self.notes[a]:
            self.notes[a].append(text)

    def cstring(self, a, minlen=3):
        """NUL-terminated printable string at ROM address a, or None."""
        if not self.inrom(a):
            return None
        o = a - self.base
        e = o
        while e < len(self.data) and self.data[e] != 0 and \
                self.data[e] in PRINTABLE and e - o < 400:
            e += 1
        if e < len(self.data) and self.data[e] == 0 and e - o >= minlen:
            return self.data[o:e].decode("ascii")
        return None

    # ----------------------------------------------------------- analysis
    def analyse(self):
        work = []
        if self.cfg.get("trap_table", True):
            for tt in range(256):
                a = self.base + tt * 16
                work.append(a)
                self.labels.setdefault(a, f"trap_{tt:02x}")
        # further trap tables (a ROM may hold several copies, e.g. for
        # different %tbr settings): {"0x1000": "tt1"} labels tt1_XX
        for k, pfx in self.cfg.get("trap_tables", {}).items():
            for tt in range(256):
                a = num(k) + tt * 16
                work.append(a)
                self.labels.setdefault(a, f"{pfx}_{tt:02x}")
        late = []
        for k, v in self.cfg.get("entries", {}).items():
            a = num(k)
            if v:
                work.append(a)
                self.labels.setdefault(a, v)
            else:
                late.append(a)
        for jt in self.cfg.get("jumptables", []):
            at, n = num(jt["at"]), int(jt["count"])
            for i in range(n):
                t = self.canon(self.word(at + 4 * i), flow=True)
                if self.inrom(t):
                    work.append(t)
                    self.xref(t, at + 4 * i, "table")
        # anonymous entries (e.g. every pc of an execution trace) are walked
        # last, so the flow from the real entry points - which carries the
        # sethi/or constants - decodes each instruction first
        work = late[::-1] + work
        seen_entry = set()
        while work:
            a = work.pop()
            if a in seen_entry or not self.inrom(a):
                continue
            seen_entry.add(a)
            self.walk(a, work)

    def walk(self, a, work):
        regs = {0: 0}
        while self.inrom(a) and a not in self.kind:
            if self.is_data_region(a):
                self.note(a, "flow runs into a data region")
                return
            ins = sparcv8.decode(self.word(a), a)
            if not ins.valid:
                self.note(a, "flow reaches an invalid instruction")
                self.kind[a] = "bad"
                self.insn[a] = ins
                return
            self.kind[a] = "code"
            self.insn[a] = ins
            self.annotate(ins, regs)
            if sparcv8.has_delay_slot(ins):
                self.follow(ins, work, regs)
                ds = a + 4
                if not (ins.annul and not ins.conditional):   # ba,a / bn,a
                    if self.inrom(ds) and ds not in self.kind:
                        dsi = sparcv8.decode(self.word(ds), ds)
                        if dsi.valid:
                            self.kind[ds] = "code"
                            self.insn[ds] = dsi
                            # an annulled conditional branch runs its delay
                            # slot on the taken path only
                            self.annotate(dsi, dict(regs) if ins.annul
                                          else regs)
                if ins.ends_flow or (ins.is_call and
                                     ins.target in self.noreturn):
                    return
                if ins.is_call:
                    for r in list(regs):
                        if 1 <= r <= 15:
                            regs.pop(r, None)
                # conditional branch or call: execution goes on at pc+8
                a = ds + 4
                continue
            a += 4

    def follow(self, ins, work, regs):
        tgt = ins.target
        if ins.is_jmpl and tgt is None and ins.rs1 is not None:
            base = regs.get(ins.rs1)
            if base is not None:
                off = ins.imm if ins.imm is not None else \
                    regs.get(ins.rs2) if ins.rs2 is not None else None
                if off is not None:
                    tgt = (base + off) & 0xffffffff
        if ins.mnemonic in ("ret", "retl") or ins.mnemonic == "rett":
            return
        if tgt is None:
            if ins.is_jmpl:
                self.note(ins.pc, "indirect jump, target unknown")
            return
        kind = "call" if ins.is_call else "jmp" if ins.is_jmpl else "br"
        if not self.inrom(tgt) and self.inrom(self.canon(tgt, flow=True)):
            self.note(ins.pc, f"{kind} to 0x{tgt:08x} = ROM "
                      f"0x{self.canon(tgt, flow=True):08x}")
            tgt = self.canon(tgt, flow=True)
        if self.inrom(tgt):
            self.xref(tgt, ins.pc, kind)
            work.append(tgt)
            if kind == "call":
                self.funcs.add(tgt)
        else:
            self.note(ins.pc, f"{kind} to 0x{tgt:08x} (outside ROM)")

    def annotate(self, ins, regs):
        """Track constants through sethi/or/add/mov and describe memory
        accesses and interesting constants."""
        m = ins.mnemonic
        rd = ins.rd
        val = None
        if m == "sethi":
            val = ins.imm
        elif m in ("or", "add", "mov", "clr", "xor", "sub", "and",
                   "sll", "srl") and rd is not None:
            if m == "clr":
                val = 0
            else:
                s1 = regs.get(ins.rs1) if ins.rs1 is not None else None
                s2 = ins.imm if ins.imm is not None else \
                    regs.get(ins.rs2) if ins.rs2 is not None else None
                if m == "mov":
                    val = s2
                elif s1 is not None and s2 is not None:
                    val = {"or": s1 | s2, "add": s1 + s2, "xor": s1 ^ s2,
                           "sub": s1 - s2, "and": s1 & s2,
                           "sll": s1 << (s2 & 31),
                           "srl": s1 >> (s2 & 31)}.get(m)
                    if val is not None:
                        val &= 0xffffffff
        if m == "save" or m == "restore":
            # new window: ins <- outs (save) / outs <- ins (restore)
            new = {0: 0}
            for g in range(1, 8):
                if g in regs:
                    new[g] = regs[g]
            for i in range(8):
                src, dst = (8 + i, 24 + i) if m == "save" else (24 + i, 8 + i)
                if src in regs:
                    new[dst] = regs[src]
            regs.clear()
            regs.update(new)
            if rd:
                regs.pop(rd, None)
            return
        if rd is not None and not ins.mem and ins.op in (0, 2) and \
                m not in ("cmp", "tst", "wr", "nop", "stbar") and \
                not ins.is_branch:
            if rd != 0:
                if val is None:
                    regs.pop(rd, None)
                else:
                    regs[rd] = val
                    if m != "sethi":
                        self.const_note(ins.pc, val)
        if ins.mem:
            base = regs.get(ins.rs1) if ins.rs1 is not None else None
            off = ins.imm if ins.imm is not None else \
                regs.get(ins.rs2) if ins.rs2 is not None else None
            ea = (base + off) & 0xffffffff if base is not None and \
                off is not None else None
            if ins.asi is not None:
                self.note(ins.pc, sun4m.describe_asi_access(
                    self.profile, ins.asi, ea))
            elif ea is not None:
                self.addr_note(ins.pc, ea)
            if not ins.store and rd is not None and ins.op3 in \
                    (0x00, 0x01, 0x02, 0x09, 0x0a, 0x10, 0x11, 0x12, 0x19,
                     0x1a):
                regs.pop(rd, None)
            if ins.op3 in (0x03, 0x13):           # ldd: rd and rd+1
                regs.pop(rd, None)
                regs.pop(rd + 1, None)
        elif ins.op == 2 and ins.op3 in (0x28, 0x29, 0x2a, 0x2b) and rd:
            regs.pop(rd, None)

    def const_note(self, pc, v):
        c = self.canon(v)
        via = "" if c == v else f" = ROM 0x{c:08x}"
        s = self.cstring(c)
        if s is not None:
            self.strings[c] = s
            self.xref(c, pc, "str")
            self.note(pc, f"= 0x{v:08x}{via} \"{esc(s[:60])}\"")
            return
        if self.inrom(c) and c & 3 == 0 and c != self.base:
            self.note(pc, f"= 0x{v:08x}{via or ' (ROM)'}")
            self.xref(c, pc, "addr")
            return
        if v >= 0x10000:
            dev, off = sun4m.device(self.profile, v)
            if dev and dev != "RAM":
                self.note(pc, f"= 0x{v:08x} ({dev} +0x{off:x} if pa)")
            else:
                self.note(pc, f"= 0x{v:08x}")

    def addr_note(self, pc, ea):
        c = self.canon(ea)
        if self.inrom(c):
            via = "" if c == ea else f" = ROM 0x{c:08x}"
            s = self.cstring(c)
            if s is not None:
                self.note(pc, f"[0x{ea:08x}]{via} \"{esc(s[:40])}\"")
            else:
                self.note(pc, f"[0x{ea:08x}]{via or ' (ROM)'}")
            self.xref(c, pc, "load")
            return
        dev, off = sun4m.device(self.profile, ea)
        if dev and dev != "RAM":
            self.note(pc, f"[0x{ea:08x}] {dev} +0x{off:x} (if MMU off)")
        else:
            self.note(pc, f"[0x{ea:08x}]")

    # ------------------------------------------------------------- output
    def name(self, a):
        if a in self.labels:
            return self.labels[a]
        if a in self.funcs:
            return f"sub_{a:08x}"
        if a in self.xrefs and any(k in ("br", "jmp", "table", "call")
                                   for _, k in self.xrefs[a]):
            return f"L_{a:08x}"
        return None

    def operand_text(self, ins):
        t = ins.text()
        if ins.target is not None and (ins.is_branch or ins.is_call):
            n = self.name(ins.target)
            if n:
                t = t.replace(f"0x{ins.target:08x}", n)
        return t

    def emit(self, out):
        w = out.write
        cfg = self.cfg
        w(f"! {cfg.get('title', 'ROM listing')}\n")
        w(f"! image: {os.path.basename(cfg['rom'])}  size 0x{len(self.data):x}"
          f"  base 0x{self.base:08x}  profile {self.profile}\n")
        w("! generated by tools/romdis/romdis.py - do not edit by hand;\n")
        w("! add names and comments to the config and regenerate.\n\n")
        a = self.base
        cur_region = None
        while a < self.end:
            r = self.region_at(a)
            if r != cur_region:
                if r and self.region_opt.get((r[0], r[1]), {}).get(
                        "banner", True):
                    w(f"\n!{'=' * 70}\n! region {r[2]}: {r[3]} "
                      f"0x{r[0]:08x}-0x{r[1]:08x}\n!{'=' * 70}\n")
                cur_region = r
            if a in self.blocks:
                w("\n")
                for line in self.blocks[a].splitlines():
                    w(f"! {line}\n")
            n = self.name(a)
            if n:
                xr = sorted(self.xrefs.get(a, ()))
                xs = " ".join(f"{f:08x}{k[0]}" for f, k in xr[:8])
                if len(xr) > 8:
                    xs += f" (+{len(xr) - 8})"
                w(f"\n{n}:" + (f"{'':<{max(1, 40 - len(n))}}! xref {xs}"
                                if xs else "") + "\n")
            k = self.kind.get(a)
            if k in ("code", "bad"):
                ins = self.insn[a]
                c = []
                if a in self.comments:
                    c.append(self.comments[a])
                c += self.notes.get(a, [])
                c += ins.notes
                line = f"{a:08x}: {ins.word:08x}  {self.operand_text(ins)}"
                if c:
                    line = f"{line:<64} ! " + "; ".join(c)
                w(line + "\n")
                a += 4
                continue
            a = self.emit_data(out, a, r)

    def emit_data(self, out, a, region):
        """Emit one data item starting at a; return the next address."""
        w = out.write
        s = self.cstring(a, minlen=4)
        if s is not None and (region is None or region[2] in
                              ("data", "string")):
            ln = len(s) + 1
            w(f"{a:08x}: {'.asciz':<9} \"{esc(s)}\"")
            if a in self.comments:
                w(f"  ! {self.comments[a]}")
            w("\n")
            return a + ln
        if region is not None and self.region_opt.get(
                (region[0], region[1]), {}).get("format") == "w16":
            return self.emit_w16(out, a, region)
        # up to 4 words per line, stopping at the next label/code/region
        # boundary, the next string or the end
        o = a - self.base
        words = []
        b = a
        while b < self.end and len(words) < 4:
            if b != a and (self.name(b) or self.kind.get(b) or
                           b in self.blocks or self.region_at(b) != region):
                break
            if b != a and self.cstring(b, minlen=4) is not None and \
                    (region is None or region[2] in ("data", "string")):
                break
            if b & 3 or b + 4 > self.end:
                words.append(("b", self.data[b - self.base]))
                b += 1
                if b & 3 == 0:
                    break
                continue
            words.append(("w", self.word(b)))
            b += 4
        txt = " ".join(f"0x{v:08x}" if t == "w" else f"0x{v:02x}"
                       for t, v in words)
        raw = self.data[o:b - self.base]
        asc = "".join(chr(c) if 32 <= c < 127 else "." for c in raw)
        d = ".word" if all(t == "w" for t, _ in words) else ".byte"
        line = f"{a:08x}: {d:<9} {txt}"
        c = []
        if a in self.comments:
            c.append(self.comments[a])
        if region is None and all(t == "w" for t, _ in words) and \
                all(sparcv8.decode(v, 0).valid for _, v in words) and \
                any(v not in (0, 0xffffffff) for _, v in words):
            c.append("unreached; " + " / ".join(
                sparcv8.decode(v, a + 4 * i).text()
                for i, (_, v) in enumerate(words)))
        line = f"{line:<64} ! {asc}" + (" ; " + "; ".join(c) if c else "")
        w(line + "\n")
        return b

    def emit_w16(self, out, a, region):
        """Up to 8 halfwords per line (a "w16" region: 16-bit Forth
        tokens); an odd start gets a single .byte."""
        b = a
        vals = []
        if a & 1:
            vals.append(("b", self.data[a - self.base]))
            b += 1
        else:
            while b + 2 <= self.end and len(vals) < 8:
                if b != a and (self.name(b) or self.kind.get(b) or
                               b in self.blocks or b in self.comments or
                               self.region_at(b) != region):
                    break
                vals.append(("h", int.from_bytes(
                    self.data[b - self.base:b - self.base + 2], "big")))
                b += 2
            if not vals:
                vals.append(("b", self.data[a - self.base]))
                b = a + 1
        txt = " ".join(f"0x{v:04x}" if t == "h" else f"0x{v:02x}"
                       for t, v in vals)
        raw = self.data[a - self.base:b - self.base]
        asc = "".join(chr(c) if 32 <= c < 127 else "." for c in raw)
        d = ".half" if vals[0][0] == "h" else ".byte"
        line = f"{a:08x}: {d:<9} {txt}"
        line = f"{line:<64} ! {asc}"
        if a in self.comments:
            line += " ; " + self.comments[a]
        out.write(line + "\n")
        return b

    def db(self):
        return {
            "base": self.base, "size": len(self.data),
            "code_bytes": 4 * sum(1 for k in self.kind.values()
                                  if k == "code"),
            "functions": sorted(f"0x{f:08x}" for f in self.funcs),
            "labels": {f"0x{a:08x}": self.name(a) for a in sorted(
                set(self.labels) | self.funcs | set(self.xrefs))
                if self.name(a)},
            "strings": {f"0x{a:08x}": s for a, s in sorted(
                self.strings.items())},
            "xrefs": {f"0x{t:08x}": sorted(f"0x{f:08x}:{k}" for f, k in v)
                      for t, v in sorted(self.xrefs.items())},
            "notes": {f"0x{a:08x}": v for a, v in sorted(self.notes.items())},
        }


def load_config(path):
    """Read a config and merge its "include" files (paths relative to the
    config). Dict keys merge (the including file wins), lists concatenate.
    An include that does not exist yet is skipped, so a config can name a
    generated file (for example forth.json) before it has been produced."""
    cfg = json.load(open(path))
    here = os.path.dirname(os.path.abspath(path))
    for inc in cfg.get("include", []):
        p = os.path.join(here, inc)
        if not os.path.exists(p):
            print(f"note: include {inc} not found, skipped", file=sys.stderr)
            continue
        sub = load_config(p)
        for k, v in sub.items():
            if k in ("rom", "profile", "base", "title", "include"):
                continue
            if isinstance(v, dict):
                merged = dict(v)
                merged.update(cfg.get(k, {}))
                cfg[k] = merged
            elif isinstance(v, list):
                cfg[k] = cfg.get(k, []) + v
            else:
                cfg.setdefault(k, v)
    return cfg


def esc(s):
    return s.replace("\\", "\\\\").replace("\"", "\\\"").replace(
        "\n", "\\n").replace("\t", "\\t").replace("\r", "\\r")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("config")
    ap.add_argument("-o", "--out", help="listing file (default stdout)")
    ap.add_argument("--db", help="write the analysis as JSON")
    ap.add_argument("--stats", action="store_true")
    args = ap.parse_args()
    cfg = load_config(args.config)
    rom = Rom(cfg)
    rom.analyse()
    out = open(args.out, "w") if args.out else sys.stdout
    rom.emit(out)
    if args.db:
        json.dump(rom.db(), open(args.db, "w"), indent=1)
    if args.stats or args.out:
        code = sum(1 for k in rom.kind.values() if k == "code")
        print(f"{os.path.basename(cfg['rom'])}: {code} instructions "
              f"({4 * code} bytes, {100 * 4 * code / len(rom.data):.1f}% of "
              f"image), {len(rom.funcs)} functions, "
              f"{len(rom.strings)} referenced strings", file=sys.stderr)


if __name__ == "__main__":
    main()
