#!/usr/bin/env python3
"""Generate the integer ALU test vectors (src/gen/alu_vec.S) from a
reference model of SPARC V8 semantics (The SPARC Architecture Manual,
Version 8, sections B.8-B.20: add/sub with carry, tagged arithmetic, logic,
shifts, multiply step, 32x32->64 multiply, 64/32 divide with overflow).

Each vector calls a stub that sets Y and the carry, executes ONE
instruction and returns; the runner (src/t_alu.S) then compares the result
register, the icc and Y. Rows (8 words):

    stub, a, b, y_in, c_in, exp_result, flags, exp_y
    flags: bits 3:0  expected icc NZVC
           bit  10   the instruction must trap; tt in bits 23:16
                     (the destination register and the icc stay as the
                     stub prelude left them)

Stub prelude: `wr %o2, %y` (three nops of write delay), then
`subcc %g0, %o3, %g0`, which leaves C = (c_in != 0), N = C, Z = !C, V = 0
- so N^V, the multiply-step input, equals c_in as well.

Also writes out/alu_vectors.txt: one line per row, for looking up a
failing check code: code = 0x100000 + row * 16 + {0 result, 1 icc, 2 Y,
3 trap}.
"""

import os
import random
import sys

M = 0xffffffff
HERE = os.path.dirname(os.path.abspath(__file__))


def s32(x):
    x &= M
    return x - (1 << 32) if x >> 31 else x


def nz(r):
    return (8 if r >> 31 else 0) | (4 if r == 0 else 0)


def add_flags(a, b, r):
    v = ((a & b & ~r) | (~a & ~b & r)) >> 31 & 1
    c = ((a & b) | (~r & (a | b))) >> 31 & 1
    return v, c


def sub_flags(a, b, r):
    v = ((a & ~b & ~r) | (~a & b & r)) >> 31 & 1
    c = ((~a & b) | (~(a ^ b) & r)) >> 31 & 1
    return v, c


def model(op, a, b, y, cin):
    """-> (result, icc, y_out, trap_tt or None). icc_in is the prelude's:
    C = cin, N = cin, Z = !cin, V = 0."""
    icc_in = (9 if cin else 4)
    cc = op.endswith("cc")
    base = op[:-2] if cc and op not in ("taddcc", "tsubcc") else op
    r, v, c, yo, trap = None, 0, 0, y, None
    if op in ("taddcc", "tsubcc", "taddcctv", "tsubcctv"):
        cc = True
        if op.startswith("tadd"):
            r = (a + b) & M
            v, c = add_flags(a, b, r)
        else:
            r = (a - b) & M
            v, c = sub_flags(a, b, r)
        if (a | b) & 3:
            v = 1
        if op.endswith("tv") and v:
            return a, icc_in, y, 0x0a
    elif base == "add":
        r = (a + b) & M
        v, c = add_flags(a, b, r)
    elif base == "addx":
        r = (a + b + cin) & M
        v, c = add_flags(a, b, r)
    elif base == "sub":
        r = (a - b) & M
        v, c = sub_flags(a, b, r)
    elif base == "subx":
        r = (a - b - cin) & M
        v, c = sub_flags(a, b, r)
    elif base == "and":
        r = a & b
    elif base == "andn":
        r = a & ~b & M
    elif base == "or":
        r = a | b
    elif base == "orn":
        r = (a | ~b) & M
    elif base == "xor":
        r = a ^ b
    elif base == "xnor":
        r = ~(a ^ b) & M
    elif base == "sll":
        r = (a << (b & 31)) & M
    elif base == "srl":
        r = a >> (b & 31)
    elif base == "sra":
        r = (s32(a) >> (b & 31)) & M
    elif base == "umul":
        p = a * b
        r, yo = p & M, (p >> 32) & M
    elif base == "smul":
        p = s32(a) * s32(b)
        r, yo = p & M, (p >> 32) & M
    elif base == "udiv":
        if b == 0:
            return a, icc_in, y, 0x2a
        q = ((y << 32) | a) // b
        r, v = (M, 1) if q > M else (q, 0)
    elif base == "sdiv":
        if b == 0:
            return a, icc_in, y, 0x2a
        n = (y << 32) | a
        if n >> 63:
            n -= 1 << 64
        d = s32(b)
        q = abs(n) // abs(d)
        if (n < 0) != (d < 0):
            q = -q
        if q > 0x7fffffff:
            r, v = 0x7fffffff, 1
        elif q < -0x80000000:
            r, v = 0x80000000, 1
        else:
            r, v = q & M, 0
    elif op == "mulscc":
        cc = True
        n_xor_v = cin                   # see the prelude
        op1 = (n_xor_v << 31) | (a >> 1)
        op2 = b if y & 1 else 0
        r = (op1 + op2) & M
        v, c = add_flags(op1, op2, r)
        yo = ((a & 1) << 31) | (y >> 1)
    else:
        raise ValueError(op)
    if base in ("udiv", "sdiv", "umul", "smul", "and", "andn", "or", "orn",
                "xor", "xnor") and cc:
        c = 0
        if base in ("umul", "smul"):
            v = 0
        if base in ("and", "andn", "or", "orn", "xor", "xnor"):
            v = 0
    icc = (nz(r) | (v << 1) | c) if cc else icc_in
    return r, icc, yo, trap


REG_OPS = ["add", "addcc", "addx", "addxcc", "sub", "subcc", "subx",
           "subxcc", "and", "andcc", "andn", "andncc", "or", "orcc", "orn",
           "orncc", "xor", "xorcc", "xnor", "xnorcc", "sll", "srl", "sra",
           "umul", "umulcc", "smul", "smulcc", "udiv", "udivcc", "sdiv",
           "sdivcc", "mulscc", "taddcc", "tsubcc", "taddcctv", "tsubcctv"]
# immediate forms: (op, simm13) - the b column holds the immediate
IMM_OPS = [("add", -4096), ("add", 4095), ("addcc", -1), ("addcc", 1),
           ("subcc", 1), ("subcc", -4096), ("addxcc", 0), ("subxcc", 0),
           ("and", 0xfff), ("andcc", -2), ("or", -1), ("orcc", 0),
           ("xor", -1), ("xnorcc", 0), ("sll", 31), ("sll", 1),
           ("srl", 31), ("srl", 1), ("sra", 31), ("sra", 4),
           ("umul", 3), ("smul", -3), ("udiv", 3), ("sdiv", -2),
           ("mulscc", 0), ("taddcc", 1), ("tsubcc", 4)]

EDGE = [0, 1, 2, 3, 4, 0x7fffffff, 0x80000000, 0x80000001, 0xfffffffe,
        M, 0x55555555, 0xaaaaaaaa, 0x0000ffff, 0xffff0000, 0x12345678,
        0xfedcba98]
SHIFTS = [0, 1, 2, 15, 16, 31, 32, 33, 63, 0xffffffe1]


def vectors(op, rng):
    out = []
    if op in ("sll", "srl", "sra"):
        for a in [1, 0x80000000, M, 0x12345678, 0x7fffffff, 0xaaaaaaaa]:
            for b in SHIFTS:
                out.append((a, b, 0, 0))
        return out
    if op in ("udiv", "udivcc", "sdiv", "sdivcc"):
        for a in EDGE:
            for b in [1, 2, 3, 7, 0x10000, M, 0x80000000, 0x7fffffff]:
                sign = M if (op.startswith("s") and a >> 31) else 0
                out.append((a, b, sign, 0))
        # large dividends, overflow, divide by zero
        out += [(0, 1, 1, 0), (0, 2, 1, 0), (M, M, M - 1, 0),
                (0x80000000, M, M, 0), (0, 1, 0x80000000, 0),
                (1, 0, 0, 0), (0x12345678, 0x1000, 0x00000fff, 0),
                (0xffffffff, 0x10000, 0xffff, 0), (5, 0x10000, 0x10000, 0)]
        for _ in range(12):
            a, b = rng.getrandbits(32), rng.getrandbits(32) | 1
            y = rng.getrandbits(32) % (b if not op.startswith("s") else 1)
            if op.startswith("s"):
                y = M if a >> 31 else 0
            out.append((a, b, y, 0))
        return out
    if op == "mulscc":
        for _ in range(24):
            out.append((rng.getrandbits(32), rng.getrandbits(32),
                        rng.getrandbits(32), rng.getrandbits(1)))
        out += [(0, 5, 1, 0), (1, 5, 0, 1), (M, M, M, 1), (2, 0x80000000,
                                                          1, 0)]
        return out
    picks = [0, 1, 0x7fffffff, 0x80000000, M, 0x55555555, 3, 0xfffffffe,
             0x12345678]
    for a in picks:
        for b in picks:
            out.append((a, b, 0x5a5a5a5a, 0))
    for _ in range(8):
        out.append((rng.getrandbits(32), rng.getrandbits(32),
                    rng.getrandbits(32), rng.getrandbits(1)))
    if op.startswith(("addx", "subx")):
        out += [(M, 0, 0, 1), (0x7fffffff, 0, 0, 1), (0, 0, 0, 1),
                (0x80000000, 0, 0, 1), (0, M, 0, 1)]
    return out


def main():
    rng = random.Random(0x5a4d)
    os.makedirs(os.path.join(HERE, "src", "gen"), exist_ok=True)
    os.makedirs(os.path.join(HERE, "out"), exist_ok=True)
    stubs, rows, doc = [], [], []

    def stub(name, insn):
        stubs.append(f"{name}:\n\twr %o2, %g0, %y\n\tnop\n\tnop\n\tnop\n"
                     f"\tsubcc %g0, %o3, %g0\n\t{insn}\n\tretl\n\tnop\n")

    for op in REG_OPS:
        name = f"alu_s_{op}"
        stub(name, f"{op} %o0, %o1, %o0")
        for a, b, y, cin in vectors(op, rng):
            rows.append((name, op, a, b, y, cin, *model(op, a, b, y, cin)))
    for op, imm in IMM_OPS:
        name = f"alu_i_{op}_{'m' if imm < 0 else ''}{abs(imm)}"
        stub(name, f"{op} %o0, {imm}, %o0")
        b = imm & M
        for a in [0, 1, 0x7fffffff, 0x80000000, M, 0x12345678, 3, 0x1000]:
            for y, cin in [(0, 0), (0xa5a5a5a5, 1)]:
                if op in ("udiv", "sdiv"):
                    y = 0 if op == "udiv" else (M if a >> 31 else 0)
                rows.append((name, f"{op} imm {imm}", a, b, y, cin,
                             *model(op, a, b if op not in ("sll", "srl",
                                                          "sra") else imm,
                                    y, cin)))

    p = os.path.join(HERE, "src", "gen", "alu_vec.S")
    with open(p, "w") as f:
        f.write("/* generated by tests/cpu/gen_alu.py - do not edit */\n")
        f.write("\t.section .text\n\t.align 4\n")
        f.write("".join(stubs))
        f.write("\t.section .rodata\n\t.align 4\n\t.globl alu_vec\n"
                "alu_vec:\n")
        for i, (stub_name, op, a, b, y, cin, r, icc, yo, trap) in \
                enumerate(rows):
            flags = icc | ((0x400 | (trap << 16)) if trap is not None else 0)
            f.write(f"\t.word {stub_name}, 0x{a:08x}, 0x{b:08x}, 0x{y:08x}, "
                    f"{cin}, 0x{r:08x}, 0x{flags:08x}, 0x{yo:08x}"
                    f"  /* {i}: {op} */\n")
            doc.append(f"row {i:5d} code 0x{0x100000 + i * 16:06x}: {op:18s}"
                       f" a={a:08x} b={b:08x} y={y:08x} c={cin} -> "
                       f"r={r:08x} icc={icc:x} y={yo:08x}"
                       + (f" trap 0x{trap:02x}" if trap is not None else ""))
        f.write("\t.globl alu_vec_end\nalu_vec_end:\n")
    # branch / Ticc condition table: for icc = 0..15 (NZVC), a 16-bit
    # mask of the conditions that are true (bit k = condition code k)
    conds = [
        lambda n, z, v, c: 0,                       # n  (never)
        lambda n, z, v, c: z,                       # e
        lambda n, z, v, c: z | (n ^ v),             # le
        lambda n, z, v, c: n ^ v,                   # l
        lambda n, z, v, c: c | z,                   # leu
        lambda n, z, v, c: c,                       # cs
        lambda n, z, v, c: n,                       # neg
        lambda n, z, v, c: v,                       # vs
        lambda n, z, v, c: 1,                       # a  (always)
        lambda n, z, v, c: 1 - z,                   # ne
        lambda n, z, v, c: 1 - (z | (n ^ v)),       # g
        lambda n, z, v, c: 1 - (n ^ v),             # ge
        lambda n, z, v, c: 1 - (c | z),             # gu
        lambda n, z, v, c: 1 - c,                   # cc
        lambda n, z, v, c: 1 - n,                   # pos
        lambda n, z, v, c: 1 - v,                   # vc
    ]
    with open(os.path.join(HERE, "src", "gen", "cond_tab.S"), "w") as f:
        f.write("/* generated by tests/cpu/gen_alu.py - do not edit */\n"
                "\t.section .rodata\n\t.align 4\n\t.globl cond_tab\n"
                "cond_tab:  /* per icc NZVC 0..15: mask of true conditions"
                " */\n")
        for icc in range(16):
            n, z, v, c = icc >> 3 & 1, icc >> 2 & 1, icc >> 1 & 1, icc & 1
            m = sum(conds[k](n, z, v, c) << k for k in range(16))
            f.write(f"\t.word 0x{m:04x}\t/* icc {icc:04b} */\n")

    open(os.path.join(HERE, "out", "alu_vectors.txt"), "w").write(
        "\n".join(doc) + "\n")
    print(f"{len(rows)} ALU vectors, {len(stubs)} stubs -> {p}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
