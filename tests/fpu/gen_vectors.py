#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""gen_vectors.py -- write FPU test vectors from the fpref.py model.

    python3 tests/fpu/gen_vectors.py [--profile qemu|v8|viking]
                                     [--out DIR] [--seed N] [--random N]

Writes DIR/<op>.txt (default tests/fpu/vectors/) for every SPARC FPop in
fpref.OPS.  Each file starts with '#' comment lines; every other line is
one vector of five space-separated fields:

    rm a b result flags

  rm      FSR.RD rounding mode, one decimal digit: 0 nearest-even,
          1 toward zero, 2 toward +inf, 3 toward -inf
  a       rs1 operand (rs2 for one-operand FPops), hex, 8 digits for
          single and int32, 16 for double
  b       rs2 operand for two-operand FPops; all zeros for one-operand ones
  result  hex result: the rd value (8 or 16 digits); for fcmp/fcmpe the
          fcc code 0 '=', 1 '<', 2 '>', 3 unordered, as 1 hex digit
  flags   5 binary digits, FSR.cexc order: nv of uf dz nx

Every operand case is written once per rounding mode (4 consecutive
lines).  Output is deterministic for a given --seed.
"""

import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fpref  # noqa: E402
from fpref import F32, F64, I32  # noqa: E402

MAX_LINES = 50000


# --------------------------------------------------------------------------
# Value helpers

def mk(f, sign, ef, frac):
    return (f.sign if sign else 0) | (ef << f.mbits) | (frac & f.fmask)


def pow2(f, e, sign=0):
    """2^e in f (normal or subnormal), or None if out of range."""
    if e >= f.emin:
        if e > f.emax:
            return None
        return mk(f, sign, e + f.bias, 0)
    k = e - (f.emin - f.mbits)
    if k < 0:
        return None
    return (f.sign if sign else 0) | (1 << k)


def one(f):
    return pow2(f, 0)


def from_float(f, v):
    return fpref.to_bits(f, v)


def neg(f, x):
    return x ^ f.sign


def nans(f):
    q = f.inf | f.qbit
    return [f.default_nan, q, q | 0x5, neg(f, q | 0x3),
            f.inf | 1, f.inf | (f.qbit >> 1) | 0x7, neg(f, f.inf | 0x2),
            f.inf | f.fmask & ~f.qbit]


def specials(f, wide=False):
    """Signed special operands; wide=True adds more for unary ops."""
    pos = [0, f.inf,
           1, 2, 3, f.fmask, f.fmask - 1, f.qbit, f.qbit | 1,
           1 << f.mbits, (1 << f.mbits) | 1, (2 << f.mbits) - 1,
           f.maxf, f.maxf - 1, mk(f, 0, f.emask - 1, 0),
           one(f), one(f) + 1, one(f) - 1, pow2(f, 1), pow2(f, -1),
           from_float(f, 1.5), from_float(f, 3.0), from_float(f, 0.75),
           from_float(f, 10.0), from_float(f, 0.1), from_float(f, 7.0),
           from_float(f, 1.0 / 3.0)]
    if wide:
        for k in range(f.mbits):                   # every subnormal binade
            pos += [1 << k, (2 << k) - 1]
        for e in (f.emin, f.emin + 1, f.emax - 1, f.emax):
            pos += [pow2(f, e), pow2(f, e) + 1, pow2(f, e) - 1]
    out = []
    for x in pos:
        out += [x, neg(f, x)]
    return out + nans(f)


def rand_normal(f, rng, elo=None, ehi=None, sign=None):
    lo = 1 if elo is None else max(1, elo + f.bias)
    hi = f.emask - 1 if ehi is None else min(f.emask - 1, ehi + f.bias)
    lo, hi = min(lo, f.emask - 1), max(hi, 1)
    if hi < lo:
        lo = hi = (lo + hi) // 2
    s = rng.getrandbits(1) if sign is None else sign
    return mk(f, s, rng.randint(lo, hi), rng.getrandbits(f.mbits))


def rand_sub(f, rng):
    return (rng.getrandbits(1) << (f.width - 1)) | \
        rng.randint(1, f.fmask)


def exp_of(f, x):
    return ((x >> f.mbits) & f.emask) - f.bias


def rand_bits_sig(f, rng, nbits):
    """Random significand with exactly nbits significant bits, odd."""
    m = (1 << (nbits - 1)) | rng.getrandbits(max(nbits - 1, 0)) | 1
    return m


def from_sig(f, m, e, sign=0):
    """m * 2^e as bits, m < 2^p; None if not exactly representable."""
    while m and not m >> f.mbits and e > f.emin - f.mbits:
        m <<= 1
        e -= 1
    if m >> f.p:
        return None
    if m >> f.mbits:
        ef = e + f.mbits + f.bias
        if ef <= 0 or ef >= f.emask:
            return None
        return mk(f, sign, ef, m)
    if e != f.emin - f.mbits:
        return None
    return (f.sign if sign else 0) | m


# --------------------------------------------------------------------------
# Case generators: each returns a list of (a, b)

def cases_add(f, rng, n, sub=False):
    c = []
    sp = specials(f)
    c += [(a, b) for a in sp for b in sp]
    for _ in range(300):                           # exact halfway (and near)
        a = rand_normal(f, rng, -60, 60)
        ea = exp_of(f, a)
        h = pow2(f, ea - f.p)
        for b in (h, h + 1, h - 1, h | 0):
            if rng.getrandbits(1):
                b = neg(f, b)
            c.append((a, b))
        c.append((a | 1, h))                      # odd: tie rounds away
        c.append((a & ~1, h))                     # even: tie stays
    for _ in range(300):                           # cancellation
        a = rand_normal(f, rng)
        for k in (0, 1, 2, rng.randint(3, 1 << 20)):
            b = a + k if (a & f.fmask) + k <= f.fmask else a - k
            c.append((a, neg(f, b)) if not sub else (a, b))
        b = (a & f.sign) | ((((a >> f.mbits) & f.emask) - 1) << f.mbits) \
            | rng.getrandbits(f.mbits)
        if (a >> f.mbits) & f.emask > 1:
            c.append((a, neg(f, b)) if not sub else (a, b))
    for _ in range(200):                           # near minnormal -> subnormal
        a = rand_normal(f, rng, f.emin, f.emin + 1)
        b = rand_normal(f, rng, f.emin, f.emin + 1) | (a & f.sign)
        c.append((a, neg(f, b)) if not sub else (a, b))
        c.append((rand_sub(f, rng), rand_sub(f, rng)))
    mx = f.maxf
    hmax = pow2(f, f.emax - f.p)
    for b in (hmax, hmax + 1, hmax - 1, pow2(f, f.emax - f.mbits), mx,
              pow2(f, f.emax - 1)):
        c += [(mx, b), (neg(f, mx), neg(f, b)), (mx - 1, b)]
    for _ in range(200):                           # wide exponent gaps: sticky
        a = rand_normal(f, rng)
        b = rand_normal(f, rng, exp_of(f, a) - f.p - 8, exp_of(f, a) - 1)
        c.append((a, b))
    for i in range(n):                             # random
        a = rand_normal(f, rng)
        if i & 1:
            ea = exp_of(f, a)
            b = rand_normal(f, rng, ea - f.p - 3, ea + f.p + 3)
        else:
            b = rand_normal(f, rng)
        c.append((a, b))
    return c


def cases_mul(f, rng, n, out=None):
    c = []
    sp = specials(f)
    c += [(a, b) for a in sp for b in sp]
    cnt = 0
    while cnt < 400:                               # exact halfway products
        n1 = rng.randint(2, f.p - 1)
        m1 = rand_bits_sig(f, rng, n1)
        m2 = rand_bits_sig(f, rng, f.p + 1 - n1)
        if (m1 * m2).bit_length() != f.p + 1:
            continue
        e1 = rng.randint(-40, 40)
        a = from_sig(f, m1, e1 - n1 + 1, rng.getrandbits(1))
        b = from_sig(f, m2, -e1 - (f.p - n1), rng.getrandbits(1))
        if a is None or b is None:
            continue
        c.append((a, b))
        c.append((a, b + 1))                       # just above/below
        cnt += 1
    for k in range(f.p // 2 + 1, f.p + 2):         # tininess boundary
        a = (1 << f.mbits) | (1 << (f.mbits - k)) if k <= f.mbits else None
        b = from_float(f, 1.0 - 2.0 ** -k) if k <= f.p else None
        if a is not None and b is not None:
            c += [(a, b), (neg(f, a), b), (b, a)]
    for _ in range(300):                           # products around 2^emin
        a = rand_normal(f, rng, f.emin, f.emin + 3)
        b = rand_normal(f, rng, -4, -1)
        c.append((a, b))
        c.append((rand_sub(f, rng), rand_normal(f, rng, -3, 3)))
    for k in range(f.mbits):                       # subnormal halves
        x = (1 << k) | 1
        c += [(x, pow2(f, -1)), (x, pow2(f, -2)), (x | f.sign, pow2(f, -1))]
    for _ in range(300):                           # around overflow
        a = rand_normal(f, rng, 1, f.emax)
        ea = exp_of(f, a)
        b = rand_normal(f, rng, f.emax - ea - 1, f.emax - ea + 1)
        c.append((a, b))
    for _ in range(300):                           # deep underflow
        a = rand_normal(f, rng, f.emin - 1 - f.emin // 2, -1)
        ea = exp_of(f, a)
        b = rand_normal(f, rng, f.emin - ea - f.p - 2, f.emin - ea + 1)
        c.append((a, b))
    for i in range(n):
        if i % 3 == 0:
            c.append((rand_normal(f, rng), rand_normal(f, rng)))
        else:
            c.append((rand_normal(f, rng, f.emin // 2, f.emax // 2),
                      rand_normal(f, rng, f.emin // 2, f.emax // 2)))
    return c


def cases_fsmuld(rng, n):
    c = cases_mul(F32, rng, n)
    for _ in range(300):
        c.append((rand_sub(F32, rng), rand_sub(F32, rng)))
    return c


def cases_div(f, rng, n):
    c = []
    sp = specials(f)
    c += [(a, b) for a in sp for b in sp]
    cnt = 0
    while cnt < 400:                               # exact quotients
        mb = rand_bits_sig(f, rng, rng.randint(1, f.p // 2))
        mc = rand_bits_sig(f, rng, rng.randint(1, f.p // 2))
        eb = rng.randint(-60, 60)
        ec = rng.randint(-60, 60)
        a = from_sig(f, mb * mc, eb + ec, rng.getrandbits(1))
        b = from_sig(f, mb, eb, rng.getrandbits(1))
        if a is None or b is None:
            continue
        c.append((a, b))
        c.append((a + 1, b))
        c.append((a - 1, b))
        cnt += 1
    mx = f.maxf
    for b in (pow2(f, -1), from_float(f, 0.75), one(f) - 1, one(f) - 2,
              one(f)):
        c += [(mx, b), (neg(f, mx), b), (mx - 1, b)]
    mn = 1 << f.mbits
    for b in (pow2(f, 1), from_float(f, 3.0), one(f) + 1, pow2(f, f.mbits),
              pow2(f, f.p), pow2(f, f.p + 1), from_float(f, 1.5)):
        c += [(mn, b), (mn | 1, b), (1, b), (3, b), (f.fmask, b),
              (neg(f, mn), b)]
    for _ in range(300):                           # around under/overflow
        a = rand_normal(f, rng, f.emin, f.emin + 2)
        c.append((a, rand_normal(f, rng, 0, f.p + 2)))
        a = rand_normal(f, rng, f.emax - 2, f.emax)
        c.append((a, rand_normal(f, rng, -2, 0)))
        c.append((rand_sub(f, rng), rand_normal(f, rng, -4, 4)))
        c.append((rand_normal(f, rng, -4, 4), rand_sub(f, rng)))
    for i in range(n):
        if i % 3 == 0:
            c.append((rand_normal(f, rng), rand_normal(f, rng)))
        else:
            c.append((rand_normal(f, rng, -60, 60),
                      rand_normal(f, rng, -60, 60)))
    return c


def cases_cmp(f, rng, n):
    c = []
    sp = specials(f)
    c += [(a, b) for a in sp for b in sp]
    for i in range(n):
        a = rand_normal(f, rng)
        r = i % 4
        if r == 0:
            b = rand_normal(f, rng)
        elif r == 1:
            b = a
        elif r == 2:
            b = a + 1 if a & f.fmask != f.fmask else a - 1
        else:
            b = neg(f, a)
        c.append((a, b) if i & 4 else (b, a))
    return c


def cases_sqrt(f, rng, n):
    c = [(x, 0) for x in specials(f, wide=True)]
    for _ in range(600):                           # exact squares
        m = rand_bits_sig(f, rng, rng.randint(1, f.p // 2))
        e = rng.randint(f.emin // 2 - f.mbits // 2, f.emax // 2 - f.p)
        sq = from_sig(f, m * m, 2 * e)
        if sq is not None:
            c.append((sq, 0))
            c.append((sq + 1, 0))
            c.append((sq - 1, 0))
    for k in range(f.mbits):
        c.append(((1 << k) * 3, 0))
    for i in range(n):
        if i % 6 == 0:
            c.append((rand_sub(f, rng) & ~f.sign, 0))
        elif i % 6 == 1:
            c.append((rand_normal(f, rng) | f.sign, 0))
        else:
            c.append((rand_normal(f, rng, sign=0), 0))
    return c


def cases_unary(f, rng, n):
    c = [(x, 0) for x in specials(f, wide=True)]
    for i in range(n):
        c.append(((rand_sub(f, rng) if i % 5 == 0 else rand_normal(f, rng)),
                  0))
    return c


def cases_fdtos(rng, n):
    c = cases_unary(F64, rng, 0)
    s, d = F32, F64
    # f32 boundaries expressed as doubles
    for e in (s.emax, s.emax + 1, s.emin, s.emin - 1, s.emin - s.mbits,
              s.emin - s.mbits - 1, s.emin - s.mbits - 2, 0):
        x = pow2(d, e)
        c += [(x, 0), (x + 1, 0), (x - 1, 0), (neg(d, x), 0)]
    smax = fpref.f32_to_f64(s.maxf).bits
    hulp = 1 << (d.mbits - s.mbits - 1)            # half an f32 ulp
    for x in (smax, smax + hulp, smax + hulp - 1, smax + hulp + 1,
              smax + 2 * hulp):
        c += [(x, 0), (neg(d, x), 0)]
    for k in (s.p + 1, s.p + 2, s.p + 3):          # tininess at f32 minnormal
        x = fpref.to_bits(d, 2.0 ** s.emin * (1 - 2.0 ** -k))
        c += [(x, 0), (neg(d, x), 0)]
    for _ in range(600):                           # halfway and near
        f32 = rand_normal(s, rng, -40, 40)
        x = fpref.f32_to_f64(f32).bits
        c += [(x | hulp, 0), ((x | hulp) + 1, 0), ((x | hulp) - 1, 0)]
        sub = rand_sub(s, rng)
        x = fpref.f32_to_f64(sub).bits
        sh = pow2(d, s.emin - s.mbits - 1)         # half an f32 subnormal ulp
        c.append((fpref.add(d, x, sh | (x & d.sign)).bits, 0))
    for i in range(n):
        if i & 1:
            c.append((rand_normal(d, rng, s.emin - s.p - 2, s.emax + 2), 0))
        else:
            c.append((rand_normal(d, rng, -60, 60), 0))
    return c


def cases_fstod(rng, n):
    return cases_unary(F32, rng, n)


def cases_ftoi(f, rng, n):
    c = [(x, 0) for x in specials(f, wide=True)]
    vals = [2.0 ** 31, 2.0 ** 31 - 1, 2.0 ** 31 - 0.5, 2.0 ** 31 + 0.5,
            2.0 ** 31 - 128, 2.0 ** 31 + 256, 2.0 ** 32, 2.0 ** 40, 1e30,
            -2.0 ** 31, -2.0 ** 31 - 0.5, -2.0 ** 31 - 1, -2.0 ** 31 + 128,
            -2.0 ** 31 - 256, -2.0 ** 31 + 0.5, 0.5, 0.99, 1.0, 1.5, 2.5,
            2.7, 0.25, 1e-30, 16777215.0, 16777216.0, 8388607.5]
    for v in vals:
        for vv in (v, -v):
            try:
                x = fpref.to_bits(f, vv)
            except OverflowError:
                continue
            if fpref.to_fraction(f, x) == vv or f is F32:
                c.append((x, 0))
    for e in range(28, 34):
        for d in (-1, 0, 1):
            x = pow2(f, e)
            c += [(x + d, 0), (neg(f, x + d), 0)]
    for i in range(n):
        r = i % 3
        if r == 0:
            c.append((rand_normal(f, rng, -2, 31), 0))
        elif r == 1:
            c.append((rand_normal(f, rng, 29, 33), 0))
        else:
            c.append((rand_normal(f, rng, -8, 20), 0))
    return c


def cases_itof(f, rng, n):
    ints = [0, 1, 2, 3, 7, 0x7fffffff, 0x7ffffffe, 0x7fffff80, 0x7fffffc0,
            0x80000000, 0x80000001, 0xffffffff, 0xfffffff9]
    for k in range(20, 32):
        for d in (-3, -2, -1, 0, 1, 2, 3):
            v = (1 << k) + d
            if v < (1 << 31):
                ints += [v, (-v) & 0xffffffff]
    c = [(i, 0) for i in ints]
    for _ in range(300):                           # halfway for f32: bit k
        k = rng.randint(25, 30)                    # set, below it zeros
        m = rand_bits_sig(f, rng, 24) << 1 | 1     # 25 bits, odd -> tie
        v = m << (k - 24)
        if v < (1 << 31):
            c += [(v, 0), ((-v) & 0xffffffff, 0)]
    for i in range(n):
        if i & 1:
            c.append((rng.getrandbits(32), 0))
        else:
            c.append((rng.getrandbits(rng.randint(1, 31)) *
                      (1 if rng.getrandbits(1) else -1) & 0xffffffff, 0))
    return c


# --------------------------------------------------------------------------

def build_cases(op, rng, n):
    fa = fpref.OPS[op][0]
    if op in ("fadds", "faddd"):
        return cases_add(fa, rng, n)
    if op in ("fsubs", "fsubd"):
        return cases_add(fa, rng, n, sub=True)
    if op in ("fmuls", "fmuld"):
        return cases_mul(fa, rng, n)
    if op == "fsmuld":
        return cases_fsmuld(rng, n)
    if op in ("fdivs", "fdivd"):
        return cases_div(fa, rng, n)
    if op.startswith("fcmp"):
        return cases_cmp(fa, rng, n)
    if op.startswith("fsqrt"):
        return cases_sqrt(fa, rng, n)
    if op in ("fitos", "fitod"):
        return cases_itof(fpref.OPS[op][2], rng, n)
    if op in ("fstoi", "fdtoi"):
        return cases_ftoi(fa, rng, n)
    if op == "fdtos":
        return cases_fdtos(rng, n)
    if op == "fstod":
        return cases_fstod(rng, n)
    return cases_unary(fa, rng, n // 3)            # fmov/fneg/fabs


HEADER = """\
# {op}: SPARC V8 FPop test vectors from tests/fpu/fpref.py (profile {prof})
# One vector per line, five space-separated fields:
#   rm a b result flags
# rm     FSR.RD: 0 nearest-even, 1 toward zero, 2 toward +inf, 3 toward -inf
# a      rs1 operand ({wa} hex digits{ua})
# b      rs2 operand ({wb} hex digits{ub})
# result {res}
# flags  FSR.cexc as 5 binary digits: nv of uf dz nx (untrapped, TEM = 0)
# Each operand case appears once per rm, in rm order 0..3.
# Generated by tests/fpu/gen_vectors.py --seed {seed}; {n} vectors.
"""


def describe(t):
    if t is None:
        return "fcc"
    if t is I32:
        return "int32"
    return "binary32" if t is F32 else "binary64"


def write_op(op, outdir, rng, nrand, prof, seed):
    ta, tb, tr, _ = fpref.OPS[op]
    cases = build_cases(op, rng, nrand)
    for code, xop, rm, a, b, res, fl in fpref.T_FPU_EXPECTS:
        if xop == op:
            cases.append((a, b))
    seen = set()
    uniq = []
    for ab in cases:
        if ab not in seen:
            seen.add(ab)
            uniq.append(ab)
    wa = 8 if ta in (F32, I32) else 16
    unary = tb is None
    wb = wa if unary else (8 if tb is F32 else 16)
    wr = 1 if tr is None else (8 if tr in (F32, I32) else 16)
    if 4 * len(uniq) + 12 > MAX_LINES:
        raise SystemExit("%s: %d cases is too many" % (op, len(uniq)))
    lines = []
    for a, b in uniq:
        for rm in range(4):
            r = fpref.run(op, rm, a, b)
            lines.append("%d %0*x %0*x %0*x %s\n"
                         % (rm, wa, a, wb, b, wr, r.bits,
                            format(r.flags, "05b")))
    if unary:
        ub = ", always 0: one-operand FPop; a is the rs2 operand"
    else:
        ub = ", %s" % describe(tb)
    res = {None: "fcc, 1 hex digit: 0 =, 1 rs1<rs2, 2 rs1>rs2, 3 unordered",
           I32: "int32 rd, 8 hex digits",
           F32: "binary32 rd, 8 hex digits",
           F64: "binary64 rd (even/odd pair), 16 hex digits"}[tr]
    hdr = HEADER.format(op=op, prof=prof, wa=wa, ua=", " + describe(ta),
                        wb=wb, ub=ub, res=res, seed=seed, n=len(lines))
    with open(os.path.join(outdir, op + ".txt"), "w") as fh:
        fh.write(hdr)
        fh.writelines(lines)
    return len(uniq), len(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--out", default=os.path.join(here, "vectors"))
    ap.add_argument("--profile", default="qemu", choices=fpref.PROFILES)
    ap.add_argument("--seed", type=int, default=20261009)
    ap.add_argument("--random", type=int, default=3000,
                    help="random cases per op (each x4 rounding modes)")
    ap.add_argument("ops", nargs="*", help="subset of ops (default all)")
    args = ap.parse_args()
    fpref.set_profile(args.profile)
    os.makedirs(args.out, exist_ok=True)
    total = 0
    for op in (args.ops or sorted(fpref.OPS)):
        rng = random.Random("%d:%s" % (args.seed, op))
        nc, nl = write_op(op, args.out, rng, args.random, args.profile,
                          args.seed)
        total += nl
        print("%-7s %6d cases %7d vectors" % (op, nc, nl))
    print("total %d vectors in %s" % (total, args.out))


if __name__ == "__main__":
    main()
