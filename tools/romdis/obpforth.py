#!/usr/bin/env python3
"""Walk and decompile the Forth dictionary of a Sun OpenBoot 2.x boot PROM.

    obpforth.py docs/rom-disassembly/ss5-obp/romdis.json
                [--dict forth-dictionary.txt] [--json forth.json]
                [--nodes forth-nodes.txt] [--va-base 0xffd00000]

The argument is the ROM's romdis config (for "rom", "base", "title" and the
regions it already classifies); outputs default to the config's folder:
forth-dictionary.txt (every word, decompiled), forth-nodes.txt (the device
tree built into the image) and forth.json (regions / entries / labels /
blocks / comments that romdis.py merges through its "include"). A
qemu-trace.json next to the config (executed ROM addresses) is used to make
sure no executed code is left inside a Forth data region.

Format (see docs/rom-disassembly/OBP-FORTH-FORMAT.md for the long version)
---------------------------------------------------------------------------
OBP 2.x is Bradley Forthware's Forthmacs, metacompiled into a ROM image that
runs in place (the ROM is mapped at VA 0xffd00000; RAM continues the
dictionary above the ROM image). It is *token threaded with 16-bit tokens*:

  token t  <->  code field address  cfa = origin + t * S

origin is the start of the kernel (a "ba,a cold" at its first word), S is the
token scale: 4 on ss5.bin (95/03), 16 on the SS20 OBP 2.25 (95/09) and on
ss5-170.bin. Registers: %g2 origin, %g3 user pointer "up" (the user area
starts with a copy of NEXT, so "jmp %g3" is NEXT), %g4 top of stack, %g5 IP,
%g6 return stack pointer, %g7 data stack pointer (grows down), %l1 W (cfa of
the word being executed). NEXT (copied into the user area at up = 0xffef0000):

    lduh [%g5],%l1; sll %l1,log2 S,%l1; add %l1,%g2,%l1   ! W = cfa
    lduh [%l1],%l0; sll %l0,log2 S,%l0; jmp %l0+%g2       ! cf is a token too
    add  %g5,2,%g5

Header (all fields big-endian, cfa aligned to S):

    [0 pad][name bytes][count][link:16][cf:16 at cfa][parameter field...]
    count = 0x80 | 0x40 immediate | 0x20 alias | length (1..31)
    link  = token of the previous word of the same vocabulary (0 = end);
            each vocabulary is one list, its head token lives in the user area
    headerless words are just [cf:16][parameter field] at an S-aligned cfa.

The code field is a token of the machine code that runs the word. The kernel
prologue right after origin holds the shared handlers; the tool finds them by
signature: docolon (IP = cfa+2), docreate (push cfa+2), dovariable (push
aligned cfa+2), douser (push up+w), dovalue (fetch up+w), dodefer (execute the
token at up+w), doconstant (32-bit in two halfwords), do2constant, dodoes (the
target of the "call" a does> clause compiles) and, S=16 only, docode (token 1:
"jmp %l1+4"). A code word's machine code starts at cfa+4: on S=4 its cf is its
own token + 1, on S=16 it is 1 (docode). An alias header's "cf" is the token
of the word it aliases. A does> child's cf is the token of the "call dodoes;
sub %g7,4,%g7" pair the defining word compiled (at an S-aligned address after
"(does>)"); the tokens of the does> clause follow those two instructions.

Colon bodies are 16-bit tokens ending with "unnest" (`exit` is a separate
token). Inline operands: (lit) 32 bits, (dlit) 64, (wlit) 16 (pushes w-1),
branch ?branch (loop) (+loop) (do) (?do) (of) (endof) a signed 16-bit offset
from the offset's own address, (') (is) compile a token, (") (.") (abort")
("s) a counted string padded to even length with at least one NUL,
(does>) / (;code) switch to machine code at the next S-aligned address.

Method (details in OBP-FORTH-FORMAT.md, "How the tool decompiles"): header
candidates are trusted only on a link chain whose head is stored in the user
area image or used as a token; everything reachable from them is parsed;
the gaps between known words are then decoded (headerless words, `actions`
tables, C entry stubs, code fragments, FCode tables), overlaps resolved, and
the machine code in the dictionary handed to romdis.py as entries.
"""

import argparse
import bisect
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sparcv8                                              # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# machine-code signatures of the code-field handlers in the kernel prologue
# (None matches any word; the shift amounts differ with the token scale)
SIGS = [
    ("docolon", [0x8c21a004, 0xca200006, 0x81c0e000, 0x8a046002]),
    ("docreate", [0x8e21e004, 0xc8200007, 0x81c0e000, 0x88046002]),
    ("dovariable", [0x8e21e004, 0xc8200007, 0x88046002, 0x88012003,
                    0x81c0e000, 0x88292003]),
    ("douser", [0x8e21e004, 0xc8200007, 0xe0146002, 0x81c0e000,
                0x88040003]),
    ("dovalue", [0x8e21e004, 0xc8200007, 0xe0146002, 0x81c0e000,
                 0xc8040003]),
    ("dodefer", [0xe0146002, 0xe2140003, None, 0xa2044002, 0xe0146000,
                 None, 0x81c40002]),
    ("doconstant", [0x8e21e004, 0xc8200007, 0xc8146002, 0x89292010,
                    0xe0146004, 0x81c0e000, 0x88040004]),
    ("do2constant", [0x8e21e004, 0x8e21e004, 0xc821e004, 0xc8146002,
                     0xc831e000]),
    ("dodoes", [0xc8200007, 0x88046002, 0x8c21a004, 0xca200006,
                0x81c0e000, 0x8a03e008]),
    ("docode", [0x81c46004, 0x01000000]),
]
KIND_OF = {"docolon": "colon", "docreate": "create",
           "dovariable": "variable", "douser": "user", "dovalue": "value",
           "dodefer": "defer", "doconstant": "constant",
           "do2constant": "2constant", "docode": "code"}
# NEXT: lduh [%g5],%l1; sll %l1,N,%l1; add %l1,%g2,%l1; lduh [%l1],%l0;
#       sll %l0,N,%l0; jmp %l0+%g2; add %g5,2,%g5
NEXT_SIG = [0xe2116000, None, 0xa2044002, 0xe0146000, None, 0x81c40002,
            0x8a016002]

# words that take inline operands (by name; the same in every OBP 2.x)
INLINE = {
    "(lit)": "lit32", "(dlit)": "lit64", "(wlit)": "wlit",
    "branch": "br", "?branch": "br", "(loop)": "br", "(+loop)": "br",
    "(do)": "br", "(?do)": "br", "(of)": "br", "(endof)": "br",
    "(')": "tok", "(is)": "tok", "compile": "tok",
    "(\")": "str", "(.\")": "str", "(abort\")": "str", "(\"s)": "str",
    "(does>)": "does", "(;code)": "code",
}
# defining words whose children's parameter field is machine code
CODE_DEFINERS = {"label", "acf-label"}

SYM = {"!": "store", "@": "fetch", "+": "plus", "-": "minus", "*": "star",
       "/": "slash", "<": "lt", ">": "gt", "=": "eq", "?": "q", ".": "dot",
       ",": "comma", "\"": "quote", "'": "tick", "(": "p", ")": "",
       "[": "lb", "]": "rb", "#": "num", "$": "str", "%": "pct",
       "&": "amp", ":": "colon", ";": "semi", "\\": "bs", "^": "caret",
       "~": "tilde", "|": "bar", "{": "lc", "}": "rc", "`": "bq"}


def ident(name):
    """A valid assembler identifier for a Forth name."""
    out = []
    for i, c in enumerate(name):
        if c.isalnum() or c == "_":
            out.append(c)
        elif c == "-" and 0 < i < len(name) - 1 and \
                name[i - 1].isalnum() and name[i + 1].isalnum():
            out.append("_")
        else:
            s = SYM.get(c, f"x{ord(c):02x}")
            if s:
                out.append(f"_{s}_")
    s = re.sub("_+", "_", "".join(out)).strip("_")
    return s or "anon"


def fmt_num(v, bits=32):
    """Literal as OBP would read it back: small decimals, else hex."""
    v &= (1 << bits) - 1
    if v == (1 << bits) - 1:
        return "-1"
    if v < 10:
        return str(v)
    return f"0x{v:x}"


class Word:
    __slots__ = ("cfa", "tok", "name", "flags", "link", "cf", "kind",
                 "end", "hdr", "items", "info", "code", "vocab", "err",
                 "definer", "refs")

    def __init__(self, cfa, tok):
        self.cfa, self.tok = cfa, tok
        self.name = None
        self.flags = 0
        self.link = None
        self.cf = None
        self.kind = None
        self.end = None         # file offset after the parameter field
        self.hdr = None         # file offset of the first name byte
        self.items = []         # colon: decompiled items
        self.info = {}
        self.code = []          # [(start, end)] machine code spans
        self.vocab = None
        self.err = None
        self.definer = None
        self.refs = set()


class Forth:
    def __init__(self, data, base, va_base=0xffd00000, known_code=()):
        self.d = data
        self.base = base
        self.va_base = va_base
        # file offsets known to hold executed machine code (the cold entry,
        # a QEMU trace, ...): they must end up in code spans
        self.known_code = set(known_code)
        self.detect()
        self.known_code.add(self.cold)

    # ---------------------------------------------------------------- bytes
    def u16(self, o):
        return int.from_bytes(self.d[o:o + 2], "big")

    def s16(self, o):
        v = self.u16(o)
        return v - 0x10000 if v & 0x8000 else v

    def u32(self, o):
        return int.from_bytes(self.d[o:o + 4], "big")

    def rom(self, o):
        """listing (romdis) address of file offset o"""
        return self.base + o

    def va(self, o):
        return self.va_base + o

    def cfa_of(self, t):
        return self.origin + t * self.S

    def tok_of(self, cfa):
        return (cfa - self.origin) // self.S

    def align(self, o, n):
        return (o + n - 1) & ~(n - 1)

    def match(self, o, sig):
        if o < 0 or o + 4 * len(sig) > len(self.d):
            return False
        return all(s is None or self.u32(o + 4 * i) == s
                   for i, s in enumerate(sig))

    # ------------------------------------------------------------ detection
    def detect(self):
        d = self.d
        colon = None
        for o in range(0, len(d) - 16, 4):
            if self.match(o, SIGS[0][1]):
                colon = o
                break
        if colon is None:
            raise SystemExit("no docolon signature: not an OBP 2.x image?")
        # origin: the "ba,a cold" a few words before docolon
        for o in range(colon - 4, colon - 0x40, -4):
            if self.u32(o) >> 22 == 0x0c2:           # ba,a disp22
                self.origin = o
                break
        else:
            raise SystemExit("kernel origin not found")
        # scale from dodefer's shift count
        self.S = None
        for o in range(self.origin, self.origin + 0x200, 4):
            if self.match(o, SIGS[5][1]):
                self.S = 1 << (self.u32(o + 20) & 31)
                break
        if self.S not in (2, 4, 8, 16):
            raise SystemExit("token scale not found")
        # the handlers of the prologue
        self.handler = {}           # token -> handler name
        self.handler_at = {}        # file offset -> handler name
        o = self.origin
        first_hdr = self.find_first_header()
        self.first_hdr = first_hdr
        while o < first_hdr:
            for name, sig in SIGS:
                if self.match(o, sig) and (o - self.origin) % self.S == 0 \
                        and name not in self.handler.values():
                    t = self.tok_of(o)
                    self.handler[t] = name
                    self.handler_at[o] = name
                    break
            o += 4
        if "dodoes" in self.handler.values():
            self.dodoes = next(a for a, n in self.handler_at.items()
                               if n == "dodoes")
        else:
            self.dodoes = None
        self.cold = self.origin + 4 * sparcv8.sext(
            self.u32(self.origin) & 0x3fffff, 22)
        # user area image: the ROM copy of NEXT after the dictionary
        self.user = None
        for o in range(len(d) - 32, first_hdr, -4):
            if self.match(o, NEXT_SIG) and self.u32(o + 28) == 0:
                self.user = o
                break
        self.docode_tok = next((t for t, n in self.handler.items()
                                if n == "docode"), None)

    def find_first_header(self):
        """cfa of "(lit)", the first word of every OBP 2.x kernel"""
        m = self.d.find(b"(lit)\x85", self.origin)
        if m < 0:
            raise SystemExit("(lit) header not found")
        return m        # file offset of the name

    # --------------------------------------------------------------- headers
    def scan_headers(self):
        """Every S-aligned position that looks like a header."""
        cands = {}
        d = self.d
        end = self.user or len(d)
        for cfa in range(self.first_hdr + 6, end, self.S):
            if (cfa - self.origin) % self.S:
                cfa += self.S - (cfa - self.origin) % self.S
            c = d[cfa - 3]
            if not c & 0x80:
                continue
            n = c & 0x1f
            if n == 0:
                continue
            nm = d[cfa - 3 - n:cfa - 3]
            if not all(0x21 <= b < 0x80 for b in nm):
                continue
            link = self.u16(cfa - 2)
            t = self.tok_of(cfa)
            if link >= t:
                continue
            cands[cfa] = (nm.decode("latin-1"), c & 0x60, link, cfa - 3 - n)
        return cands

    # ------------------------------------------------------------ code spans
    def code_extent(self, start, limit):
        """End (exclusive) of a machine-code routine starting at start: the
        first unconditional transfer (plus delay slot) that no forward
        branch jumps over."""
        a, far = start, start
        while a < limit:
            ins = sparcv8.decode(self.u32(a), a)
            if not ins.valid:
                return a
            if ins.is_branch and ins.target is not None and \
                    start <= ins.target < limit:
                far = max(far, ins.target)
            if ins.ends_flow:
                e = a + (4 if ins.annul and ins.is_branch else 8)
                if far < e:
                    return min(e, limit)
                a = e
                continue
            a += 4
        return limit

    def is_call_dodoes(self, o):
        if self.dodoes is None or o + 8 > len(self.d):
            return False
        w = self.u32(o)
        if w >> 30 != 1:
            return False
        tgt = (o + ((w & 0x3fffffff) << 2)) & 0xffffffff
        return tgt == self.dodoes

    # ------------------------------------------------------------- the walk
    def run(self):
        self.cands = self.scan_headers()
        self.inline = {}
        for cfa, (nm, fl, link, hs) in sorted(self.cands.items()):
            if nm in INLINE and not fl & 0x20:
                self.inline.setdefault(self.tok_of(cfa), INLINE[nm])
        self.unnest = next((self.tok_of(c) for c, v in sorted(
            self.cands.items()) if v[0] == "unnest"), None)
        self.hdrs = {}              # validated headers: cfa -> cands entry
        self.succ = {}              # cfa -> the header that links to it
        self.head_of = {}           # cfa -> user offset of its chain head
        self.code_targets = set()   # legitimate ;code handler entries
        self.ip_ops = {}            # handler offset -> (bytes, is_token)
        self.extra = set()          # headerless words found by the sweep
        self.words = {}
        self.frags = {}
        self.nodes = []
        self.banned = set()         # candidates that overlap decoded code
        self.ram_refs = {}          # RAM token -> words using it
        self.specials = {}          # actions tables, C entry stubs
        self.ram_start = self.align(self.user_limit(), 4) \
            if self.user is not None else len(self.d)
        self.claim_user_heads()
        self.find_fcode_tables()
        for rnd in range(12):
            self.names = {self.tok_of(c): v[0] for c, v in self.hdrs.items()}
            self.parse_all()
            if self.prune():
                self.names = {self.tok_of(c): v[0]
                              for c, v in self.hdrs.items()}
                self.parse_all()
            grew = self.claim_referenced()
            n, nx = len(self.code_targets), len(self.extra)
            self.seed_nodes()
            self.update_code_targets()
            self.discover()
            self.update_code_targets()
            self.carve_search()
            if not grew and len(self.code_targets) == n and \
                    len(self.extra) == nx:
                break
        self.prune()
        self.finalize()
        self.carve()
        self.names = {self.tok_of(c): v[0] for c, v in self.hdrs.items()}
        self.rejected = {c: v for c, v in self.cands.items()
                         if c not in self.hdrs}
        self.vocabularies()
        return self

    def in_dict(self, o):
        return self.first_hdr <= o < (self.user or len(self.d))

    # headers are only trusted when they belong to a link chain whose head
    # is stored somewhere (a vocabulary or device node in the user area, or
    # a token some decoded word uses); each header has at most one
    # successor, so a candidate linking to an already claimed header is a
    # coincidence in data
    def find_fcode_tables(self):
        """The byte-code interpreter's token tables: one page per FCode
        high byte, 256 16-bit tokens + a 32-byte "immediate" bitmap
        (0x220 bytes), page 0 starting [end0][ferror x15]. The tokens
        they hold are word starts even when nothing else refers to them
        (the FCode primitives b(lit), b(:) ... are headerless)."""
        self.fcode_pages = []
        tok = {v[0]: self.tok_of(c) for c, v in self.cands.items()
               if v[0] in ("end0", "ferror")}
        if len(tok) < 2:
            return
        sig = tok["end0"].to_bytes(2, "big") + \
            tok["ferror"].to_bytes(2, "big") * 15
        o = self.d.find(sig, self.first_hdr)
        if o < 0 or o & 1:
            return
        # pages follow each other while their entries are word tokens
        p = o
        while p + 0x220 <= len(self.d):
            ts = [self.u16(p + 2 * i) for i in range(256)]
            good = sum(1 for t in ts if self.in_dict(self.cfa_of(t)))
            if good < 200 or ts[0] not in (tok["end0"], tok["ferror"]):
                break
            self.fcode_pages.append(p)
            p += 0x220
        for p in self.fcode_pages:
            for i in range(256):
                c = self.cfa_of(self.u16(p + 2 * i))
                if self.in_dict(c) and c not in self.hdrs:
                    self.extra.add(c)
        w = Word(o, None)
        w.kind = "fcode-table"
        w.hdr = o
        w.end = o + 0x220 * len(self.fcode_pages)
        w.info["pages"] = list(self.fcode_pages)
        self.specials[o] = w

    # ---------------------------------------------------- device nodes
    # A device node built into the dictionary is a vocabulary (its methods)
    # followed, at the next S-aligned cfa at or after cfa+8, by a second
    # vocabulary word (its properties). Its user-area record at the
    # methods offset M: M+0 methods head, M+2 first child, M+4 next peer,
    # M+6 token of the properties vocabulary, M+8 and M+0xc two cells,
    # M+0x10 a token, M+0x12 properties head. A property word is a child
    # of the property `actions` word: pfa = [offset:32][length:16], the
    # value lies at pfa - offset (compiled before the header).
    def voc_does_token(self):
        for w in self.words.values():
            if w.name == "vocabulary" and w.kind == "colon" and \
                    w.info.get("does_at"):
                return self.tok_of(w.info["does_at"][0])
        return None

    def node_props_cfa(self, cfa, vt):
        c = self.align(cfa + 8, self.S)
        c += (-(c - self.origin)) % self.S
        return c if self.u16(c) == vt else None

    def seed_nodes(self):
        """Walk the static device tree (child / peer links in the user
        image) from the root node and make every node and property
        vocabulary a known word."""
        self.nodes = []
        vt = self.voc_does_token()
        if vt is None or self.user is None:
            return
        root = next((w for w in self.words.values()
                     if w.name == "root-node" and w.kind == "does"), None)
        if root is None:
            return
        seen = set()

        def walk(c, parent, depth):
            while c and c not in seen and len(seen) < 500:
                if not self.in_dict(c) or self.u16(c) != vt:
                    return
                seen.add(c)
                m = self.u16(c + 2)
                rec = self.user + m
                pt = self.u16(rec + 6)
                pc = self.cfa_of(pt) if pt and \
                    self.u16(self.cfa_of(pt)) == vt else \
                    self.node_props_cfa(c, vt)
                self.nodes.append((c, parent, depth, m, pc))
                for x in (c, pc):
                    if x is not None and x not in self.hdrs:
                        self.extra.add(x)
                child = self.u16(rec + 2)
                if child:
                    walk(self.cfa_of(child), c, depth + 1)
                peer = self.u16(rec + 4)
                c = self.cfa_of(peer) if peer else 0

        walk(root.cfa, None, 0)

    def node_props(self, pc):
        """[(name, value bytes, property word)] of a node, oldest first."""
        if pc is None:
            return []
        off = self.u16(pc + 2)
        t = self.u16(self.user + off)
        out, n = [], 0
        while t and n < 200:
            c = self.cfa_of(t)
            w = self.words.get(c)
            if w is None or w.name is None:
                break
            pf = c + 2
            o = self.u32(pf)
            ln = self.u16(pf + 4)
            if w.kind == "does" and w.info["does"] == self.prop_does():
                val = self.d[pf - o:pf - o + ln] if 0 < o < 0x10000 \
                    else b""
            else:
                val = None              # computed when read
            out.append((w.name, val, w))
            t = w.link or 0
            n += 1
        return out[::-1]

    def prop_does(self):
        """does> address of the static property words (the definer of
        most "name" properties)."""
        if getattr(self, "_prop_does", None) is None:
            from collections import Counter
            c = Counter(w.info["does"] for w in self.words.values()
                        if w.kind == "does" and w.name == "name")
            self._prop_does = c.most_common(1)[0][0] if c else -1
        return self._prop_does

    def node_methods(self, c):
        m = self.u16(c + 2)
        t = self.u16(self.user + m)
        out, n = [], 0
        while t and n < 500:
            w = self.words.get(self.cfa_of(t))
            if w is None:
                break
            out.append(w.name or self.disp(t))
            t = w.link or 0
            n += 1
        return out[::-1]

    def fmt_prop(self, name, v):
        """A property value the way .attributes would show it."""
        if not v:
            return ""
        txt = v.rstrip(b"\0")
        parts = txt.split(b"\0")
        if v.endswith(b"\0") and txt and all(
                p and all(32 <= c < 127 for c in p) for p in parts):
            return " | ".join(x.decode() for x in parts)
        if len(v) % 4 == 0:
            cells = [int.from_bytes(v[i:i + 4], "big")
                     for i in range(0, len(v), 4)]
            per = 3 if name in ("reg", "available") else \
                5 if name == "ranges" else 2 if name == "intr" else 8
            rows = [" ".join(f"{x:08x}" for x in cells[i:i + per])
                    for i in range(0, len(cells), per)]
            return " / ".join(rows)
        return " ".join(f"{c:02x}" for c in v)

    def node_paths(self):
        """{node cfa: path, props vocabulary cfa: path} of the static
        device tree."""
        path, out = {}, {}
        for c, parent, depth, m, pc in self.nodes:
            pv = {n: v for n, v, w in self.node_props(pc) if v is not None}
            nm = pv.get("name", b"").rstrip(b"\0").decode("latin-1")
            ua = ""
            if len(pv.get("reg", b"")) >= 8:
                r = pv["reg"]
                ua = f"@{int.from_bytes(r[0:4], 'big'):x}," \
                     f"{int.from_bytes(r[4:8], 'big'):x}"
            vn = self.words[c].name if c in self.words else None
            if parent is None:
                p = "/"
            else:
                p = path[parent].rstrip("/") + "/" + (nm or vn or "?") + ua
            path[c] = p
            out[c] = p
            if pc is not None:
                out[pc] = p
        return out

    def nodes_report(self, title):
        L = [f"# Static device tree: {title}",
             "# generated by tools/romdis/obpforth.py - do not edit.",
             "# The device nodes that exist in the ROM dictionary image "
             "itself, walked through",
             "# their records in the user area image (child / peer "
             "links). Nodes and properties",
             "# the ROM adds while it runs (cpu, SBus devices from FCode, "
             "root name / model /",
             "# idprom, \"address\", memory \"reg\", ...) are not here; "
             "see device-tree.md.",
             "# Each node: path, node (methods vocabulary) VA and ROM "
             "address, user record offset;",
             "# then methods (oldest first) and properties "
             "(name = value, oldest first).", ""]
        paths = self.node_paths()
        for c, parent, depth, m, pc in self.nodes:
            props = self.node_props(pc)
            vn = self.words[c].name if c in self.words and \
                self.words[c].name else None
            p = paths[c]
            L.append(f"{p}")
            L.append(f"    node {self.va(c):08x} (ROM {self.rom(c):08x})"
                     + (f" = vocabulary {vn}" if vn else "") +
                     f", user record up+0x{m:x}")
            ms = self.node_methods(c)
            if ms:
                L.append("    methods: " + " ".join(ms))
            for n, v, w in props:
                if v is None:
                    d = w.definer
                    dn = (d.name or self.disp(d.tok)) if d is not None \
                        and d.tok is not None else "?"
                    txt = f"(computed: {w.kind} of {dn})"
                else:
                    txt = self.fmt_prop(n, v)
                L.append(f"    {n:<22} {txt}   [{self.rom(w.cfa):08x}]")
            L.append("")
        return "\n".join(L) + "\n"

    def fcode_name(self, n):
        """ROM word for FCode number n (None if not in the tables)."""
        pg, i = n >> 8, n & 0xff
        if pg >= len(self.fcode_pages):
            return None
        t = self.u16(self.fcode_pages[pg] + 2 * i)
        imm = self.d[self.fcode_pages[pg] + 0x200 + i // 8] >> (i % 8) & 1
        return t, imm

    def claim_chain(self, c, uoff=None):
        got = 0
        while c in self.cands and c not in self.hdrs and \
                c not in self.banned:
            nm, fl, link, hs = self.cands[c]
            if not self.plausible(c):
                break
            lc = self.cfa_of(link) if link else None
            if lc is not None and self.succ.get(lc, c) != c:
                break
            self.hdrs[c] = self.cands[c]
            if uoff is not None:
                self.head_of.setdefault(c, uoff)
            got += 1
            if lc is None:
                break
            self.succ[lc] = c
            c = lc
        return got

    def chain_len(self, c):
        n, seen = 0, set()
        while c in self.cands and c not in seen and n < 5000:
            seen.add(c)
            n += 1
            link = self.cands[c][2]
            if not link:
                break
            c = self.cfa_of(link)
        return n

    def claim_user_heads(self):
        if self.user is None:
            return
        heads = []
        for o in range(self.user, self.user_limit(), 2):
            c = self.cfa_of(self.u16(o))
            if c in self.cands:
                heads.append((self.chain_len(c), c, o - self.user))
        for n, c, uoff in sorted(heads, reverse=True):
            self.claim_chain(c, uoff)

    def claim_referenced(self):
        """Claim the chains of candidates used as tokens, and continue
        chains that stopped at a candidate not plausible at the time."""
        grew = 0
        for c in sorted(self.referenced):
            if c in self.cands and c not in self.hdrs:
                grew += self.claim_chain(c)
        for h in sorted(self.hdrs):
            link = self.hdrs[h][2]
            lc = self.cfa_of(link) if link else None
            if lc in self.cands and lc not in self.hdrs and \
                    self.succ.get(lc) == h:
                grew += self.claim_chain(lc, self.head_of.get(h))
        return grew

    def user_limit(self):
        o = self.user
        while o < len(self.d) - 16 and self.d[o:o + 16] != b"\xff" * 16:
            o += 16
        return o

    def plausible(self, cfa):
        nm, fl, link, hs = self.cands[cfa]
        cf = self.u16(cfa)
        if fl & 0x20:                   # alias: of a word, or a RAM token
            c = self.cfa_of(cf)
            return self.valid_token(cf) or c >= self.ram_start
        return self.cf_kind(cfa, cf) is not None

    def valid_token(self, t):
        c = self.cfa_of(t)
        if not self.in_dict(c):
            return False
        if c in self.words:
            return True
        return self.cf_kind(c, self.u16(c)) is not None

    def cf_kind(self, cfa, cf):
        """What a code field value makes of the word at cfa (or None)."""
        t = self.tok_of(cfa)
        if cf in self.handler:
            return KIND_OF.get(self.handler[cf])
        if self.S == 4 and cf == t + 1:
            return "code"
        tgt = self.cfa_of(cf)
        if not (self.first_hdr <= tgt < (self.user or len(self.d))):
            return None
        if self.is_call_dodoes(tgt):
            return "does"
        if tgt >= cfa or tgt & 3:
            return None
        if tgt in self.code_targets or self.handler_like(tgt):
            return ";code"
        return None

    def handler_like(self, o):
        """Machine code that works on W (%l1) and ends in NEXT: a code
        field routine laid down without a header (a ;code fragment)."""
        if self.owner(o) is not None:
            return False
        uses_w = False
        for i in range(24):
            a = o + 4 * i
            ins = sparcv8.decode(self.u32(a), a)
            if not ins.valid or self.u32(a) == 0:
                return False
            if (ins.rs1 == 17 or ins.rs2 == 17) and i < 8:
                uses_w = True
            if ins.ends_flow:
                return uses_w and ins.is_jmpl
        return False

    def colon_like(self, o):
        """A code field routine that runs a token body at W+2."""
        for i in range(16):
            w = self.u32(o + 4 * i)
            if w == 0x8a046002:                 # add %l1,2,%g5
                return True
            if w == 0x81c0e000 and i > 0 and \
                    self.u32(o + 4 * i + 4) == 0x8a046002:
                return True
            ins = sparcv8.decode(w, o + 4 * i)
            if not ins.valid:
                return False
        return False

    def ip_operand(self, o):
        """(bytes, is_token) a code routine at o takes from the caller's
        instruction stream: the "add %g5,imm,%g5" on its straight path up
        to NEXT; is_token if the operand is scaled and added to origin."""
        n, tok, loaded = 0, False, False
        for i in range(40):
            a = o + 4 * i
            w = self.u32(a)
            ins = sparcv8.decode(w, a)
            if not ins.valid:
                return 0, False
            m = ins.mnemonic
            if ins.mem and not ins.store and ins.rs1 == 5:
                loaded = True
            if m == "add" and ins.rd == 5 and ins.rs1 == 5 and \
                    ins.imm is not None:
                n += ins.imm
            elif ins.rd == 5 and not ins.store and not ins.is_branch and \
                    m not in ("cmp", "tst"):
                # IP reloaded (an action handler entering a colon body
                # after taking its operand), or not an operand user
                return (n, tok) if n and loaded else (0, False)
            if m == "sll" and ins.imm == self.S.bit_length() - 1 and loaded:
                tok = True
            if ins.ends_flow:
                if ins.is_jmpl and ins.rs1 == 3:
                    nx = sparcv8.decode(self.u32(a + 4), a + 4)
                    if nx.mnemonic == "add" and nx.rd == 5 and \
                            nx.rs1 == 5 and nx.imm is not None:
                        n += nx.imm
                    return (n, tok) if loaded else (0, False)
                return 0, False
        return 0, False

    def update_code_targets(self):
        for w in self.words.values():
            for c in w.info.get("code_at", []):
                self.code_targets.add(c)
            if w.kind == "does" and w.code:
                self.code_targets.add(w.code[0][0])

    def name_of(self, t):
        n = self.names.get(t)
        if n is not None:
            return n
        return f"({self.va(self.cfa_of(t)):08x})"

    def parse_all(self):
        self.words = {}
        self.referenced = {}
        self._sorted = None
        work = sorted(set(self.hdrs) | self.extra, reverse=True)
        self.frags = {}
        self.words.update(self.specials)
        for x in self.specials.values():
            for t in x.refs:
                work.append(self.cfa_of(t))
        while work:
            cfa = work.pop()
            if cfa in self.words:
                continue
            w = self.parse(cfa)
            if w is None:
                continue
            self.words[cfa] = w
            for t in w.refs:
                c = self.cfa_of(t)
                self.referenced.setdefault(c, set()).add(cfa)
                if c not in self.words and self.in_dict(c):
                    work.append(c)
        self.user_refs()
        self.definers()

    def definers(self):
        """does> / ;code children: find the defining word; children of
        `label`-like definers hold machine code in their body."""
        self._sorted = None
        for w in self.words.values():
            if w.kind not in ("does", ";code"):
                continue
            tgt = w.info["does"] if w.kind == "does" else w.info["code"]
            d = self.owner(tgt) or self.code_owner(tgt)
            w.definer = d
            if w.kind == "does" and d is not None and \
                    d.name in CODE_DEFINERS:
                # the code starts at the next aligned non-zero word
                s = self.align(w.cfa + 2, 4)
                while self.u32(s) == 0 and s < self.align(w.cfa + 2, self.S):
                    s += 4
                w.code = [(s, self.code_extent(s, len(self.d)))]
            elif w.kind == ";code" and not w.items and \
                    self.colon_like(w.info["code"]):
                # an "action" word: a colon body run by its own handler
                self.decompile(w, w.cfa + 2)

    def parse(self, cfa):
        if not self.in_dict(cfa) or (cfa - self.origin) % self.S:
            return None
        t = self.tok_of(cfa)
        w = Word(cfa, t)
        h = self.hdrs.get(cfa)
        cf = self.u16(cfa)
        w.cf = cf
        if h:
            w.name, w.flags, w.link, w.hdr = h
            if w.flags & 0x20:
                w.kind = "alias"
                w.end = cfa + 2
                w.refs.add(cf)
                return w
        k = self.cf_kind(cfa, cf)
        if k is None:
            return None
        w.kind = k
        pf = cfa + 2
        if k == "colon":
            self.decompile(w, pf)
        elif k in ("user", "value", "defer"):
            w.info["uoff"] = self.u16(pf)
            w.end = pf + 2
        elif k == "constant":
            w.info["value"] = self.u32(pf)
            w.end = pf + 4
        elif k == "2constant":
            w.info["value"] = (self.u32(pf), self.u32(pf + 4))
            w.end = pf + 8
        elif k == "code":
            body = cfa + 4
            e = self.code_extent(body, len(self.d))
            w.code.append((body, e))
            w.end = e
        elif k == "does":
            w.info["does"] = self.cfa_of(cf)
            w.refs.add(cf)
        elif k == ";code":
            w.info["code"] = self.cfa_of(cf)
            w.refs.add(cf)
        # create / variable / does / ;code: the length is known only when
        # the next word is (sweep() fills w.end)
        return w

    def operand_of(self, t):
        """Inline operand kind of token t in a colon body."""
        k = self.inline.get(t)
        if k is not None:
            return k, 0
        c = self.cfa_of(t)
        cf = self.u16(c)
        if cf in self.handler:
            return None, 0
        tgt = c + 4 if (self.S == 4 and cf == t + 1) or \
            cf == self.docode_tok else self.cfa_of(cf)
        if tgt not in self.ip_ops:
            self.ip_ops[tgt] = self.ip_operand(tgt)
        n, tok = self.ip_ops[tgt]
        if n == 2 and tok:
            return "tok", 0
        if n:
            return "data", n
        return None, 0

    def decompile(self, w, a):
        items = []
        far = a
        limit = self.user or len(self.d)
        while True:
            if a + 2 > limit:
                w.err = "runs off the dictionary"
                break
            t = self.u16(a)
            c = self.cfa_of(t)
            if self.ram_start <= c:
                # a word the ROM expects at a fixed place in RAM (created
                # at run time above the ROM image)
                items.append((a, "call", t, None))
                self.ram_refs.setdefault(t, set()).add(w.cfa)
                a += 2
                continue
            if not (self.origin <= c < limit):
                w.err = f"bad token 0x{t:04x} at {self.rom(a):08x}"
                break
            if t not in self.handler and not self.valid_token(t):
                w.err = f"not a word: token 0x{t:04x} at {self.rom(a):08x}"
                break
            w.refs.add(t)
            k, n = self.operand_of(t)
            if k == "lit32":
                items.append((a, "lit", t, self.u32(a + 2)))
                a += 6
            elif k == "lit64":
                items.append((a, "dlit", t, (self.u32(a + 2),
                                             self.u32(a + 6))))
                a += 10
            elif k == "wlit":
                items.append((a, "lit", t, (self.u16(a + 2) - 1)
                              & 0xffffffff))
                a += 4
            elif k == "br":
                tgt = a + 2 + self.s16(a + 2)
                items.append((a, "br", t, tgt))
                far = max(far, tgt)
                a += 4
            elif k == "tok":
                x = self.u16(a + 2)
                items.append((a, "tok", t, x))
                if self.valid_token(x):
                    w.refs.add(x)
                a += 4
            elif k == "data":
                items.append((a, "data", t, self.d[a + 2:a + 2 + n]))
                a += 2 + n
            elif k == "str":
                n = self.d[a + 2]
                s = self.d[a + 3:a + 3 + n]
                items.append((a, "str", t, s))
                a = (a + n + 5) & ~1
            elif k == "does":
                items.append((a, "call", t, None))
                c = self.align(a + 2, max(4, self.S))
                if not self.is_call_dodoes(c):
                    w.err = f"(does>) without call dodoes at " \
                        f"{self.rom(c):08x}"
                    a = a + 2
                    break
                items.append((c, "does", None, c))
                w.code.append((c, c + 8))
                w.info.setdefault("does_at", []).append(c)
                a = c + 8
                far = a
            elif k == "code":
                items.append((a, "call", t, None))
                c = self.align(a + 2, max(4, self.S))
                e = self.code_extent(c, limit)
                items.append((c, ";code", None, (c, e)))
                w.code.append((c, e))
                w.info.setdefault("code_at", []).append(c)
                a = e
                break
            elif t == self.unnest and a >= far:
                items.append((a, "end", t, None))
                a += 2
                break
            else:
                items.append((a, "call", t, None))
                a += 2
        w.items = items
        w.end = a

    def user_refs(self):
        """Defer defaults in the user image are tokens: follow them."""
        if self.user is None:
            return
        more = []
        for w in list(self.words.values()):
            if w.kind == "defer":
                t = self.u16(self.user + w.info["uoff"])
                w.info["init"] = t
                if self.valid_token(t):
                    more.append(self.cfa_of(t))
            elif w.kind in ("user", "value"):
                w.info["init"] = self.u32(self.user + w.info["uoff"])
        while more:
            cfa = more.pop()
            if cfa in self.words:
                continue
            w = self.parse(cfa)
            if w is None:
                continue
            self.words[cfa] = w
            self.referenced.setdefault(cfa, set()).add("user")
            for t in w.refs:
                c = self.cfa_of(t)
                if c not in self.words and self.in_dict(c):
                    more.append(c)

    def start_of(self, w):
        return w.hdr if w.hdr is not None else w.cfa

    def discover(self):
        """Walk the dictionary in address order and try to decode what
        lies in the gaps between known words: header candidates (whose
        chain is then claimed) and headerless words at aligned positions."""
        limit = self.user or len(self.d)
        changed = True
        while changed:
            changed = False
            self._sorted = None
            self.find_frags()
            starts = self.starts()
            found = []
            for i, (st, kind, key) in enumerate(starts):
                j = i + 1
                nxt = starts[j][0] if j < len(starts) else limit
                end = self.extent(kind, key, nxt)
                if end is None or end >= nxt:
                    continue
                if all(b == 0 for b in self.d[end:nxt]):
                    continue
                # the next start that is not a code fragment: a word found
                # here may own the fragments before it (its ;code part)
                while j < len(starts) and starts[j][1] == "frag":
                    j += 1
                hard = starts[j][0] if j < len(starts) else limit
                p = end + (-(end - self.origin)) % self.S
                while p < nxt + 0x40:
                    if p in self.cands and p not in self.hdrs and \
                            self.cands[p][3] >= end and \
                            self.claim_chain(p):
                        self.names[self.tok_of(p)] = self.cands[p][0]
                    if p >= nxt:
                        break
                    x = self.special(end, p, hard)
                    if x is not None:
                        found.append(x)
                        break
                    x = self.parse(p)
                    if x is not None and not x.err and \
                            (x.end is None or x.end <= hard or
                             x.hdr is not None):
                        found.append(x)
                        break
                    p += self.S
            for x in found:
                if x.cfa not in self.words:
                    self.words[x.cfa] = x
                    if x.kind in ("actions", "c-entry"):
                        self.specials[x.cfa] = x
                    else:
                        self.extra.add(x.cfa)
                    self.referenced.setdefault(x.cfa, set()).add("sweep")
                    self.add_refs(x)
                    changed = True
            if changed:
                self._sorted = None
                self.definers()
                self.update_code_targets()

    def prune(self):
        """Resolve overlaps: a word found only by the gap sweep, or a
        header whose name lies inside a cleanly decoded colon body, loses
        against the word it overlaps."""
        fixed = {"colon", "constant", "2constant", "user", "value",
                 "defer", "alias"}
        removed = 0
        order = sorted(self.words.values(), key=self.start_of)
        prev = None
        for i, x in enumerate(order):
            nxt = order[i + 1] if i + 1 < len(order) else None
            clash_prev = prev is not None and prev.kind in fixed and \
                not prev.err and prev.end is not None and \
                self.start_of(x) < prev.end
            clash_next = nxt is not None and x.end is not None and \
                x.kind in fixed and x.end > self.start_of(nxt) and \
                x.cfa in self.extra
            if clash_prev and x.cfa in self.extra and \
                    x.cfa not in self.hdrs:
                self.extra.discard(x.cfa)
                removed += 1
                continue
            if clash_next:
                self.extra.discard(x.cfa)
                removed += 1
                continue
            if clash_prev and x.cfa in self.hdrs and \
                    (x.cfa not in self.succ or len(x.name or "") < 4) and \
                    (x.cfa not in self.head_of or len(x.name or "") < 3):
                self.unclaim(x.cfa)
                removed += 1
                continue
            prev = x
        return removed

    def unclaim(self, c):
        self.banned.add(c)
        self.hdrs.pop(c, None)
        for k in [k for k, v in self.succ.items() if v == c]:
            del self.succ[k]
        link = self.cands[c][2]
        if link and self.succ.get(self.cfa_of(link)) == c:
            del self.succ[self.cfa_of(link)]

    def special(self, lo, p, hi):
        """Structures in the dictionary that are not words:
        actions  [action tokens, newest first][count:32][call dodoes]
                 [sub %g7,4,%g7][does> tokens ... unnest]  (Forthmacs
                 `actions`: the children's cf points at the call; action
                 n>0 is found by counting back from it)
        c-entry  save %sp,-N,%sp; call <enter-forth>; nop; tokens...
                 (C-callable stubs that run a few tokens and return)"""
        for q in range(p, min(p + self.S, hi), 4):
            if self.is_call_dodoes(q) and self.u32(q + 4) == 0x8e21e004 \
                    and (q - self.origin) % self.S == 0:
                n = self.u32(q - 4)
                st = q - 4 - 2 * (n - 1)
                if not 1 <= n <= 32 or st < lo:
                    continue
                acts = [self.u16(q - 4 - 2 * i) for i in range(1, n)]
                if not all(self.valid_token(t) for t in acts):
                    continue
                w = Word(q, self.tok_of(q))
                w.kind = "actions"
                w.hdr = st
                w.info["actions"] = acts
                w.code = [(q, q + 8)]
                w.refs |= set(acts)
                self.decompile(w, q + 8)
                if w.err:
                    continue
                return w
        for q in range(self.align(max(lo, p - self.S + 4), 4),
                       min(p + self.S, hi), 4):
            if self.u32(q) >> 13 == 0x9de3bfa0 >> 13 and \
                    self.u32(q + 4) >> 30 == 1 and \
                    self.u32(q + 8) == 0x01000000 and q + 14 <= hi:
                break
        else:
            return None
        if True:
            w = Word(q, self.tok_of(q) if (q - self.origin) % self.S == 0
                     else None)
            w.kind = "c-entry"
            w.code = [(q, q + 12)]
            tgt = (q + 4 + ((self.u32(q + 4) & 0x3fffffff) << 2)) \
                & 0xffffffff
            w.info["enter"] = tgt
            a = q + 12
            items = []
            while a + 2 <= hi and len(items) < 16:
                t = self.u16(a)
                if not self.valid_token(t):
                    break
                items.append((a, "call", t, None))
                w.refs.add(t)
                a += 2
                if self.returns_to_c(t):
                    break
            if not items:
                return None
            w.items = items
            w.end = a
            return w
        return None

    def returns_to_c(self, t):
        c = self.cfa_of(t)
        cf = self.u16(c)
        if not ((self.S == 4 and cf == t + 1) or cf == self.docode_tok):
            return False
        for i in range(24):
            ins = sparcv8.decode(self.u32(c + 4 + 4 * i), 0)
            if ins.mnemonic in ("ret", "retl"):
                return True
            if not ins.valid:
                return False
        return False

    def in_code(self, o):
        w = self.owner(o)
        if w is not None and any(a <= o < b for a, b in w.code):
            return True
        return any(a <= o < (b or a + 4) for a, b in self.frags.items())

    def carve_search(self):
        """Known code inside a data-like word: look for the code word it
        belongs to (a word nothing in the dictionary refers to, e.g. a
        trap handler) just before it."""
        found = 0
        self._sorted = None
        for o in sorted(self.known_code):
            if not self.in_dict(o) or self.in_code(o):
                continue
            cf = self.sorted_cfas()
            i = bisect.bisect_right(cf, o) - 1
            w = self.words[cf[i]] if i >= 0 else None
            if w is None or w.kind not in ("create", "variable", "does",
                                           ";code", "actions") or \
                    (w.end is not None and o >= w.end):
                continue
            p = o - (o - self.origin) % self.S
            while p > w.cfa and p > o - 0x80:
                x = self.parse(p)
                if x is not None and not x.err and x.code and \
                        x.code[0][0] <= o and x.kind in ("code", "colon"):
                    self.extra.add(p)
                    found += 1
                    break
                p -= self.S
        return found

    def carve(self):
        """Known code still inside a data-like body: a code island there."""
        self._sorted = None
        for o in sorted(self.known_code):
            if not self.in_dict(o) or self.in_code(o):
                continue
            w = self.owner(o)
            if w is None:
                continue
            s = o
            # start at the body when the island begins right after the cf
            b = self.align(w.cfa + 2, 4)
            if b <= o < b + 16 and all(
                    self.u32(a) and sparcv8.decode(self.u32(a), a).valid
                    for a in range(b, o, 4)):
                s = b
            e = self.code_extent(s, w.end)
            w.code.append((s, max(e, o + 4)))
            w.code.sort()
            w.info.setdefault("islands", []).append(s)

    def code_owner(self, t):
        """The word whose machine code span holds t, if any."""
        cf = self.sorted_cfas()
        i = bisect.bisect_right(cf, t) - 1
        while i >= 0 and cf[i] > t - 0x400:
            w = self.words[cf[i]]
            if any(a <= t < b for a, b in w.code):
                return w
            i -= 1
        return None

    def find_frags(self):
        """;code targets that no word contains are code fragments."""
        self.frags = {t: e for t, e in self.frags.items()
                      if self.owner(t) is None and
                      self.code_owner(t) is None}
        for w in list(self.words.values()):
            if w.kind == ";code":
                t = w.info["code"]
                if t not in self.frags and self.owner(t) is None and \
                        self.code_owner(t) is None:
                    self.frags[t] = None

    def finalize(self):
        """Give words of unknown length their extent, clip machine code at
        the next word, and list what could not be decoded."""
        limit = self.user or len(self.d)
        self._sorted = None
        self.find_frags()
        starts = self.starts()
        self.gaps = []
        for i, (st, kind, key) in enumerate(starts):
            nxt = starts[i + 1][0] if i + 1 < len(starts) else limit
            if kind == "frag":
                e = self.code_extent(key, nxt)
                self.frags[key] = e
                end = e
            else:
                w = self.words[key]
                if w.end is None or (w.kind in ("create", "variable", "does",
                                                ";code") and not w.items):
                    w.end = nxt
                if w.kind == "code":
                    s = w.code[0][0]
                    w.code = [(s, self.code_extent(s, nxt))]
                    w.end = w.code[0][1]
                elif w.kind == "does" and w.code:
                    s = w.code[0][0]
                    w.code = [(s, self.code_extent(s, nxt))]
                elif w.kind == "colon" and w.info.get("code_at"):
                    c = w.info["code_at"][-1]
                    e = self.code_extent(c, nxt)
                    w.code = [x for x in w.code if x[0] != c] + [(c, e)]
                    w.items = [it if it[1] != ";code" or it[0] != c else
                               (c, ";code", None, (c, e)) for it in w.items]
                    w.end = e
                elif w.end > nxt:
                    w.err = f"overlaps the next word at {self.rom(nxt):08x}"
                end = w.end
            codey = kind == "frag" or (self.words[key].code and
                                       self.words[key].code[-1][1] == end)
            if end < nxt and any(self.d[end:nxt]) and codey:
                e2 = self.code_tail(end, nxt)
                if e2 is not None:
                    # more machine code after the routine's last exit
                    # (reached by a branch): part of the same code
                    if kind == "frag":
                        self.frags[key] = e2
                    else:
                        w = self.words[key]
                        s0, _ = w.code[-1]
                        w.code[-1] = (s0, e2)
                        w.end = max(w.end, e2)
                        w.info["tail"] = (end, e2)
                    end = e2
            if end < nxt and any(self.d[end:nxt]):
                self.gaps.append((end, nxt))
        self._sorted = None

    def code_tail(self, end, nxt):
        """If [end, nxt) is machine code (trailing zero padding aside),
        return where it ends."""
        e = nxt
        while e > end and self.d[e - 1] == 0:
            e -= 1
        e = self.align(e, 4)
        if end & 3 or e <= end or e > nxt:
            return None
        for a in range(end, e, 4):
            w = self.u32(a)
            if w == 0 or not sparcv8.decode(w, a).valid:
                return None
        return e

    def starts(self):
        """Sorted (start offset, kind, key) of words and code fragments."""
        s = [(self.start_of(w), "word", c) for c, w in self.words.items()]
        s += [(o, "frag", o) for o in self.frags]
        s.sort()
        return s

    def extent(self, kind, key, nxt):
        if kind == "frag":
            return self.code_extent(key, nxt)
        w = self.words[key]
        if w.kind in ("create", "variable", "does", ";code") and \
                not w.items:
            return None
        if w.kind == "code":
            return self.code_extent(w.code[0][0], nxt)
        if w.kind == "colon" and w.info.get("code_at"):
            return self.code_extent(w.info["code_at"][-1], nxt)
        return w.end

    def add_refs(self, x):
        more = [x]
        while more:
            x = more.pop()
            for t in x.refs:
                c = self.cfa_of(t)
                if c not in self.words and self.in_dict(c):
                    y = self.parse(c)
                    if y is not None:
                        self.words[c] = y
                        self.referenced.setdefault(c, set()).add(x.cfa)
                        more.append(y)

    def vocabularies(self):
        """Vocabulary membership from the link chains. A vocabulary child
        (does> of `vocabulary`) holds the user offset of its thread head;
        other chain heads in the user area belong to device nodes."""
        self.vocs = {}
        voc_does = set()
        for w in self.words.values():
            if w.name == "vocabulary" and w.kind == "colon":
                voc_does |= set(w.info.get("does_at", []))
        byoff = {}
        for w in sorted(self.words.values(), key=lambda x: x.cfa):
            if w.kind == "does" and w.info["does"] in voc_does:
                off = self.u16(w.cfa + 2)
                vname = w.name or self.name_of(w.tok)
                self.vocs[vname] = (w, off, self.u16(self.user + off))
                byoff[off] = vname
        # device node vocabularies are named after their path
        paths = self.node_paths() if self.nodes else {}
        pcs = {pc for c, parent, depth, m, pc in self.nodes}
        for vname, (w, off, head) in list(self.vocs.items()):
            if w.cfa in paths:
                nn = paths[w.cfa] + (" props" if w.cfa in pcs else "")
                byoff[off] = nn
        # walk the vocabularies first, then every other chain whose head is
        # in the user area (device nodes: their property / method lists)
        self.chains = {}            # user offset -> [cfa, ...] newest first
        offs = sorted(byoff) + [o - self.user for o in
                                range(self.user, self.user_limit(), 2)
                                if o - self.user not in byoff]
        for off in offs:
            c = self.cfa_of(self.u16(self.user + off))
            if c not in self.hdrs or self.words.get(c) is None or \
                    self.words[c].vocab is not None:
                continue
            chain = []
            while c in self.words and len(chain) < 5000:
                chain.append(c)
                link = self.words[c].link
                if not link:
                    break
                c = self.cfa_of(link)
            vn = byoff.get(off, f"node@up+0x{off:x}")
            if vn.startswith("node@") and not all(
                    self.words[c].vocab is None for c in chain):
                continue            # a pointer into a vocabulary (last...)
            self.chains[off] = chain
            for c in chain:
                if self.words[c].vocab is None:
                    self.words[c].vocab = vn
        self.definers()

    def owner(self, o):
        """The word whose body contains file offset o."""
        cf = self.sorted_cfas()
        i = bisect.bisect_right(cf, o) - 1
        if i < 0:
            return None
        w = self.words[cf[i]]
        if w.end is not None and o < w.end:
            return w
        return None

    def sorted_cfas(self):
        if getattr(self, "_sorted", None) is None or \
                len(self._sorted) != len(self.words):
            self._sorted = sorted(self.words)
        return self._sorted

    # --------------------------------------------------------------- output
    def disp(self, t):
        return self.name_of(t)

    def colon_text(self, w, width=96):
        """Decompiled body: linear, with local labels for branch targets."""
        targets = sorted({it[3] for it in w.items if it[1] == "br"})
        lab = {a: f"L{i + 1}" for i, a in enumerate(targets)}
        lines, cur = [], []

        def flush():
            if cur:
                lines.append(" ".join(cur))
                cur.clear()

        for it in w.items:
            a, kind, t, x = it
            if a in lab:
                flush()
                cur.append(f"{lab[a]}:")
            if kind == "call":
                h = self.hdrs.get(self.cfa_of(t))
                imm = h is not None and h[1] & 0x40 and not h[1] & 0x20
                cur.append(("[compile] " if imm else "") + self.disp(t))
                if self.names.get(t) in ("exit",):
                    flush()
            elif kind == "lit":
                cur.append(fmt_num(x))
            elif kind == "dlit":
                cur.append(f"{fmt_num(x[1])} {fmt_num(x[0])} (dlit)")
            elif kind == "br":
                nm = self.disp(t)
                cur.append(f"{nm} {lab.get(x, f'?{self.rom(x):08x}')}")
                if nm == "branch":
                    flush()
            elif kind == "tok":
                nm = self.disp(t)
                tn = self.disp(x) if self.valid_token(x) else f"0x{x:04x}?"
                cur.append({"(')": "[']"}.get(nm, nm) + " " + tn)
            elif kind == "str":
                nm = self.disp(t)
                s = x.decode("latin-1")
                s = "".join(ch if 32 <= ord(ch) < 127 else
                            f"\\x{ord(ch):02x}" for ch in s)
                pre = {"(.\")": ".\"", "(abort\")": "abort\"",
                       "(\")": "\"", "(\"s)": "p\""}.get(nm, nm)
                cur.append(f"{pre} {s}\"")
            elif kind == "does":
                flush()
                cur.append(f"[{self.rom(a):08x}: call dodoes] does-body:")
            elif kind == ";code":
                flush()
                cur.append(f"[machine code {self.rom(x[0]):08x}.."
                           f"{self.rom(x[1]):08x}]")
            elif kind == "end":
                cur.append(";")
        flush()
        # wrap
        out = []
        for ln in lines:
            ind = ""
            while len(ln) > width:
                cut = ln.rfind(" ", 0, width)
                if cut <= 0:
                    break
                out.append(ind + ln[:cut])
                ln = ln[cut + 1:]
                ind = "    "
            out.append(ind + ln)
        return out

    def hexdump(self, o, e, maxb=64):
        b = self.d[o:min(e, o + maxb)]
        s = " ".join(f"{b[i:i + 2].hex()}" for i in range(0, len(b), 2))
        asc = "".join(chr(c) if 32 <= c < 127 else "." for c in b)
        more = f" ...(+{e - o - maxb})" if e - o > maxb else ""
        return f"{s}{more}  |{asc}|"

    def disasm(self, s, e, maxn=48, indent="        "):
        out = []
        for i, a in enumerate(range(s, e, 4)):
            if i >= maxn:
                out.append(f"{indent}... ({(e - a) // 4} more instructions,"
                           " see listing.s)")
                break
            ins = sparcv8.decode(self.u32(a), self.rom(a))
            out.append(f"{indent}{self.rom(a):08x}: {self.u32(a):08x}  "
                       f"{ins.text()}")
        return out

    def describe(self, w):
        """(kind column, one-line summary, extra lines)"""
        k = w.kind
        extra = []
        summ = ""
        if k == "colon":
            extra = self.colon_text(w)
            for (s, e) in w.code:
                if e - s > 8:
                    extra.append(f"    ;code machine code:")
                    extra += self.disasm(s, e)
        elif k == "code":
            s, e = w.code[0]
            summ = f"machine code {self.rom(s):08x}..{self.rom(e):08x}"
            extra = self.disasm(s, e)
        elif k == "constant":
            summ = f"= {fmt_num(w.info['value'])}"
        elif k == "2constant":
            v = w.info["value"]
            summ = f"= {fmt_num(v[0])} {fmt_num(v[1])}"
        elif k in ("user", "value", "defer"):
            u = w.info["uoff"]
            summ = f"up+0x{u:x}"
            if "init" in w.info:
                if k == "defer":
                    summ += f"  initially -> {self.disp(w.info['init'])}" \
                        if self.valid_token(w.info["init"]) else \
                        f"  initially 0x{w.info['init']:04x}"
                else:
                    summ += f"  initial {fmt_num(w.info['init'])}"
        elif k == "alias":
            summ = f"-> {self.disp(w.cf)}"
        elif k == "actions":
            acts = w.info["actions"]
            summ = (f"{len(acts) + 1} actions; children's cf -> call dodoes "
                    f"at {self.rom(w.cfa):08x}; action 0 = the does> body")
            extra = [f"action {i + 1}: {self.disp(t)}"
                     for i, t in enumerate(acts)]
            extra += ["does> body:"] + self.colon_text(w)
        elif k == "fcode-table":
            pages = w.info["pages"]
            summ = (f"FCode token tables: {len(pages)} pages (FCode "
                    f"0x000-0x{len(pages) * 0x100 - 1:03x}), 256 tokens + "
                    f"32-byte immediate bitmap each")
            extra = []
            for pg in range(len(pages)):
                row = []
                for i in range(256):
                    t, imm = self.fcode_name(pg * 256 + i)
                    nm = self.disp(t)
                    if nm == "ferror" or t == 0:
                        continue
                    row.append(f"{pg * 256 + i:03x}={nm}" + ("*" if imm
                                                           else ""))
                line = ""
                for x in row:
                    if len(line) + len(x) > 100:
                        extra.append(line)
                        line = ""
                    line += x + " "
                if line:
                    extra.append(line)
            extra.append("(* = executed while compiling; unlisted numbers "
                         "map to ferror)")
        elif k == "c-entry":
            summ = (f"C-callable stub: save; call "
                    f"{self.rom(w.info['enter']):08x}; nop; then tokens:")
            extra = self.colon_text(w)
        elif k in ("create", "variable", "does", ";code"):
            pf = w.cfa + 2
            if k == "variable":
                pf = self.align(pf, 4)
            if k == "does":
                dn = w.definer.name if w.definer and w.definer.name else \
                    (self.disp(w.definer.tok) if w.definer else "?")
                summ = f"does> of {dn}"
                if w.definer and w.definer.name in CODE_DEFINERS:
                    s = self.align(pf, 4)
                    e = self.code_extent(s, w.end)
                    w.code = [(s, e)]
                    extra = self.disasm(s, e)
                    return k, summ, extra
            elif k == ";code":
                d = w.definer
                dn = d.name if d is not None and d.name else \
                    self.disp(d.tok) if d is not None and d.tok is not None \
                    else "a code fragment"
                summ = f";code of {dn} (code {self.rom(w.info['code']):08x})"
                if w.items:
                    return k, summ + ", token body:", self.colon_text(w)
            n = w.end - pf
            summ += (" " if summ else "") + f"{n} bytes"
            if n > 0:
                extra = ["    " + self.hexdump(pf, w.end)]
            for a, b in w.code:
                if a in w.info.get("islands", ()):
                    extra.append(f"    machine code in the body (executed):"
                                 f" {self.rom(a):08x}..{self.rom(b):08x}")
                    extra += self.disasm(a, b)
        return k, summ, extra

    def label(self, w):
        if w.name:
            return ident(w.name)
        return f"{self.va(w.cfa):08x}"

    def report(self, title):
        ws = [self.words[c] for c in sorted(self.words)]
        # give every word its extras once (describe() fills code spans of
        # label children)
        desc = {w.cfa: self.describe(w) for w in ws}
        cnt = {}
        for w in ws:
            cnt[w.kind] = cnt.get(w.kind, 0) + 1
        named = sum(1 for w in ws if w.name)
        L = []
        L.append(f"# Forth dictionary: {title}")
        L.append("# generated by tools/romdis/obpforth.py - do not edit;"
                 " see ../OBP-FORTH-FORMAT.md")
        L.append(f"# origin: file 0x{self.origin:x} = ROM "
                 f"0x{self.rom(self.origin):08x} = VA "
                 f"0x{self.va(self.origin):08x};  token = (cfa - origin) / "
                 f"{self.S};  cold start 0x{self.rom(self.cold):08x}")
        if self.user is not None:
            L.append(f"# user area image (starts with NEXT): ROM "
                     f"0x{self.rom(self.user):08x}, copied to up at cold")
        L.append("# handlers: " + ", ".join(
            f"{n}=tok 0x{t:x} ({self.rom(self.cfa_of(t)):08x})"
            for t, n in sorted(self.handler.items())))
        L.append(f"# words: {len(ws)} ({named} with headers, "
                 f"{len(ws) - named} headerless); by kind: " +
                 ", ".join(f"{k} {v}" for k, v in sorted(cnt.items())))
        span = (self.user or len(self.d)) - self.first_hdr
        gb = sum(e - s for s, e in self.gaps)
        code = sum(e - s for w in ws for s, e in w.code) + \
            sum((e or s) - s for s, e in self.frags.items())
        L.append(f"# dictionary 0x{self.rom(self.first_hdr):08x}.."
                 f"0x{self.rom(self.user or len(self.d)):08x} ({span} bytes):"
                 f" machine code {code} bytes, undecoded gaps {len(self.gaps)}"
                 f" ({gb} bytes, {100.0 * gb / span:.2f}%), everything else "
                 f"headers / tokens / data / padding")
        L.append(f"# header candidates rejected: {len(self.rejected)} "
                 f"(name-like bytes in data, not on any link chain)")
        if self.ram_refs:
            L.append(f"# tokens of RAM words (above the ROM image, created at "
                     f"run time) used by ROM code: {len(self.ram_refs)}")
        if self.vocs:
            L.append("# vocabularies (user offset of the thread head): " +
                     ", ".join(f"{n} up+0x{o:x}" for n, (w, o, h) in
                               sorted(self.vocs.items())))
        L.append("#")
        L.append("# Each entry: ROM address of the code field (listing.s"
                 " address), token, VA the ROM")
        L.append("# runs at, kind, flags (I immediate, A alias), "
                 "[vocabulary] name, summary. Headerless")
        L.append("# words are named (VA) like the ROM's own `see`. Colon "
                 "bodies are listed linearly;")
        L.append("# Ln: marks a branch target, `?branch Ln` / `branch Ln` "
                 "jump to it; (do)/(?do) Ln")
        L.append("# is the loop exit, (of) Ln the next case.")
        L.append("")
        gaps = dict(self.gaps)
        for w in ws:
            k, summ, extra = desc[w.cfa]
            fl = ("I" if w.flags & 0x40 else "") + \
                ("A" if w.flags & 0x20 else "")
            nm = w.name if w.name is not None else \
                self.disp(w.tok) if w.tok is not None else \
                f"({self.va(w.cfa):08x})"
            voc = f"[{w.vocab}] " if w.vocab and w.vocab != "forth" else ""
            tk = f"{w.tok:04x}" if w.tok is not None else "----"
            L.append(f"{self.rom(w.cfa):08x} {tk} "
                     f"{self.va(w.cfa):08x} {k:<9} {fl:<2} {voc}{nm}"
                     + (f"   {summ}" if summ else ""))
            if w.err:
                L.append(f"    !! {w.err.strip()}")
            for x in extra:
                L.append("    " + x if not x.startswith("    ") else x)
            if w.end in gaps:
                s, e = w.end, gaps[w.end]
                L.append(f"{self.rom(s):08x} ---- {self.va(s):08x} "
                         f"UNDECODED {e - s} bytes")
                for o in range(s, e, 32):
                    L.append("    " + self.hexdump(o, min(e, o + 32), 32))
        return "\n".join(L) + "\n"

    def romdis_json(self, title):
        """regions / entries / labels / blocks for romdis."""
        ws = [self.words[c] for c in sorted(self.words)]
        for w in ws:
            if w.kind == "does":
                self.describe(w)        # fills code spans of label children
        entries, labels, blocks, comments = {}, {}, {}, {}
        used = {}

        def uniq(s):
            n = used.get(s, 0)
            used[s] = n + 1
            return s if n == 0 else f"{s}_{n + 1}"

        # kernel prologue handlers
        for o, n in sorted(self.handler_at.items()):
            entries[f"0x{self.rom(o):08x}"] = uniq(f"fw_{n}")
        entries[f"0x{self.rom(self.cold):08x}"] = uniq("fw_cold")
        entries[f"0x{self.rom(self.origin):08x}"] = uniq("fw_origin")
        if self.user is not None:
            entries[f"0x{self.rom(self.user):08x}"] = uniq("fw_next_image")
            comments[f"0x{self.rom(self.user):08x}"] = (
                "NEXT; the user area image starts here and is copied to "
                "up (0xffef0000) at cold start")
        code_spans = []
        for o, e in sorted(self.frags.items()):
            code_spans.append((o, e or o + 4))
            entries[f"0x{self.rom(o):08x}"] = uniq(f"fw_code_{self.va(o):08x}")
            users = sorted(self.label(w) for w in ws if w.kind == ";code"
                           and w.info.get("code") == o)
            comments[f"0x{self.rom(o):08x}"] = (
                "code field routine of " + ", ".join(users[:6]) +
                (" ..." if len(users) > 6 else "")) if users else \
                "code field routine (headerless)"
        for w in ws:
            base = self.label(w)
            lab = uniq("f_" + base)
            labels[f"0x{self.rom(w.cfa):08x}"] = lab
            for i, (s, e) in enumerate(w.code):
                code_spans.append((s, e))
                if w.kind == "colon":
                    nm = uniq(f"fw_{base}_does" if (s, e) in [
                        (c, c + 8) for c in w.info.get("does_at", [])]
                        else f"fw_{base}_code")
                else:
                    nm = uniq(f"fw_{base}")
                entries[f"0x{self.rom(s):08x}"] = nm
            nm = w.name if w.name is not None else \
                self.disp(w.tok) if w.tok is not None else \
                f"({self.va(w.cfa):08x})"
            k = w.kind
            tk = f"token 0x{w.tok:04x}, " if w.tok is not None else ""
            txt = f"{k} {nm}  ({tk}VA {self.va(w.cfa):08x})"
            if w.kind == "colon":
                body = self.colon_text(w, width=90)
                if len(body) > 12:
                    body = body[:12] + ["... (see forth-dictionary.txt)"]
                txt += "\n" + "\n".join("  " + b for b in body)
            else:
                _, summ, _ = self.describe(w)
                if summ:
                    txt += "  " + summ
            blocks[f"0x{self.rom(self.start_of(w)):08x}"] = txt
        # regions: the dictionary minus machine code
        start = self.first_hdr
        limit = self.user or len(self.d)
        regions = []
        code_spans.sort()
        o = start
        for s, e in code_spans:
            if s > o:
                regions.append((o, s))
            o = max(o, e)
        if o < limit:
            regions.append((o, limit))
        reg = [{"start": f"0x{self.rom(s):08x}", "end": f"0x{self.rom(e):08x}",
                "type": "forth", "format": "w16",
                "name": "Forth dictionary (see forth-dictionary.txt)"}
               for s, e in regions if e > s]
        for r in reg[1:]:
            r["banner"] = False
        # NEXT and the token dispatch inside machine code
        for s, e in code_spans:
            for a in range(s, e, 4):
                w = self.u32(a)
                k = f"0x{self.rom(a):08x}"
                if w == 0x81c0e000 and k not in comments:
                    comments[k] = "NEXT (jmp up: the user area starts " \
                        "with NEXT)"
                elif w == 0x81c40002 and k not in comments:
                    comments[k] = "execute: jmp origin + cf*S"
        if self.user is not None:
            ue = self.user_end()
            reg.append({"start": f"0x{self.rom(self.user + 32):08x}",
                        "end": f"0x{self.rom(ue):08x}", "type": "data",
                        "name": "Forth user area image (initial values)"})
        return {
            "comment": "generated by tools/romdis/obpforth.py - do not edit",
            "regions": reg, "entries": entries, "labels": labels,
            "blocks": blocks, "comments": comments,
        }

    def user_end(self):
        e = self.user
        mx = 0
        for w in self.words.values():
            if w.kind in ("user", "value", "defer"):
                mx = max(mx, w.info["uoff"] + 4)
        e = self.user + mx
        # extend over trailing non-fill data
        o = e
        while o < len(self.d) and self.d[o] != 0xff:
            o += 1
        return self.align(o, 4) if o - e < 0x1000 else e


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("config", help="the ROM's romdis.json")
    ap.add_argument("--dict", help="forth-dictionary.txt output")
    ap.add_argument("--json", help="forth.json output")
    ap.add_argument("--nodes", help="forth-nodes.txt output (static "
                    "device tree)")
    ap.add_argument("--va-base", default="0xffd00000",
                    help="VA the ROM image is mapped at (default 0xffd00000)")
    args = ap.parse_args()
    cfg = json.load(open(args.config))
    here = os.path.dirname(os.path.abspath(args.config))
    rom = cfg["rom"]
    if not os.path.isabs(rom):
        rom = os.path.join(REPO, rom)
    data = open(rom, "rb").read()
    base = int(cfg.get("base", "0"), 0)
    known = set()
    tr = os.path.join(here, "qemu-trace.json")
    if os.path.exists(tr):
        for k in json.load(open(tr)).get("entries", {}):
            o = int(k, 0) - base
            if 0 <= o < len(data):
                known.add(o)
    f = Forth(data, base, int(args.va_base, 0), known_code=known).run()
    title = cfg.get("title", os.path.basename(rom))
    out = args.dict or os.path.join(here, "forth-dictionary.txt")
    open(out, "w").write(f.report(title))
    if f.nodes:
        nf = args.nodes or os.path.join(here, "forth-nodes.txt")
        open(nf, "w").write(f.nodes_report(title))
    js = args.json or os.path.join(here, "forth.json")
    rj = f.romdis_json(title)
    # the FCode images (detokenized by detok.py) are data for romdis
    import detok
    import re as _re
    dt = detok.Detok(f)
    for o, h in dt.find():
        items = dt.decode(o, h)[0]
        nm = _re.sub(r"[^A-Za-z0-9_.-]+", "_", dt.title(items) or "image")
        a = f"0x{f.rom(o):08x}"
        rj["regions"].append({"start": a, "end": f"0x{f.rom(o + h[3]):08x}",
                              "type": "fcode",
                              "name": f"FCode image {nm} (see fcode-"
                                      f"{f.rom(o):08x}-{nm}.txt)"})
        rj["labels"][a] = f"fcode_{ident(nm)}"
    # leave alone what the machine-code config already classifies: drop
    # or clip our regions that overlap one of its regions
    theirs = sorted((int(r["start"], 0), int(r["end"], 0))
                    for r in cfg.get("regions", []))
    keep = []
    for r in rj["regions"]:
        a, b = int(r["start"], 0), int(r["end"], 0)
        for lo, hi in theirs:
            if lo < b and a < hi:
                if lo <= a and b <= hi:
                    a = b                       # covered: drop
                elif lo <= a:
                    a = hi
                else:
                    b = min(b, lo)
        if a < b:
            r["start"], r["end"] = f"0x{a:08x}", f"0x{b:08x}"
            keep.append(r)
    rj["regions"] = keep
    json.dump(rj, open(js, "w"), indent=1)
    ws = f.words.values()
    print(f"{os.path.basename(rom)}: origin 0x{f.origin:x} scale {f.S}, "
          f"{len(f.words)} words ({sum(1 for w in ws if w.name)} named), "
          f"{len(f.rejected)} header candidates rejected, "
          f"{len(f.gaps)} gaps ({sum(e - s for s, e in f.gaps)} bytes)",
          file=sys.stderr)


if __name__ == "__main__":
    main()
