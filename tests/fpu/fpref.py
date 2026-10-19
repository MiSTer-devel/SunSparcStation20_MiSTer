#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""fpref.py -- exact IEEE 754 reference model of the SPARC V8 FPops.

Pure Python, standard library only. Every finite operand is turned into an
exact rational (sign, num/den), the operation is done exactly, and the
exact result is rounded once to binary32 or binary64 in one of the four
IEEE rounding modes. Subnormal operands and results are exact. Each call
returns Result(bits, flags): the result bit pattern (for compares: the
fcc code; for F?TOi: the int32 bit pattern) and the five IEEE flags in
SPARC FSR.cexc order (V8 Figure 4-11):

    bit 4 NV invalid   bit 3 OF overflow   bit 2 UF underflow
    bit 1 DZ div-by-0  bit 0 NX inexact

The flags are the untrapped ones (all of FSR.TEM = 0): what lands in cexc
and is or'd into aexc.  Rounding modes use the FSR.RD encoding (V8 §4.4,
Table 4-4): 0 nearest-even, 1 toward zero, 2 toward +inf, 3 toward -inf.

Implemented operations (V8 Tables F-5/F-6, opf in docs/arch/iu-notes.md
§2.14): fadd, fsub, fmul, fdiv, fsqrt, fcmp, fcmpe (s and d), fitos,
fitod, fstoi, fdtoi, fstod, fdtos, fsmuld, fmovs/fnegs/fabss (and the d
forms, which V8 does not define but V9 and QEMU do).

SPARC conventions (sources: [V8] = The SPARC Architecture Manual Version 8,
text in the session scratchpad sparcv8.txt; [QEMU] = target/sparc in
scratch/reference/emulators/qemu; [VIK] = TMS390Z50 Viking User
Documentation rev 2.00 §4.6.2, the SS20's SuperSPARC):

(a) Default NaN.  An invalid operation with no NaN operand (0/0, inf/inf,
    0*inf, inf-inf, sqrt(<0), ...) returns the quiet NaN with sign 0,
    exponent all 1s, fraction all 1s: 0x7fffffff / 0x7fffffff_ffffffff.
    [V8] App. N.4 "Untrapped floating-point result in same format as
    operands"; [QEMU] cpu.c sparc_cpu_realizefn:
    set_float_default_nan_pattern(0b01111111) "sign bit clear, all frac
    bits set".

(b) NaN propagation.  [V8] App. N.4 table: one NaN operand -> that NaN
    with the quiet bit (MSB of the fraction) set; a signalling NaN raises
    NV.  Two NaNs: a signalling NaN wins over a quiet one; if both are of
    the same kind the rs2 (second source) NaN is returned.  In the rs1/rs2
    table: QNaN1 op QNaN2 -> QNaN2; SNaN1 op QNaN2 -> QSNaN1;
    QNaN1 op SNaN2 -> QSNaN2; SNaN1 op SNaN2 -> QSNaN2.  [QEMU] cpu.c sets
    set_float_2nan_prop_rule(float_2nan_prop_s_ba) "Prefer SNaN over QNaN,
    order B then A" (B = rs2), the same rule.  Format conversions keep the
    sign and the high fraction bits, set the quiet bit and raise NV for a
    signalling NaN ([V8] N.4 "NaN transformation").  FCMP raises NV only
    for a signalling NaN, FCMPE for any NaN; both give fcc 3 ([V8] N.4,
    §B.33 "Floating-point Compare", §4.4 Table 4-5).  fsmuld: [QEMU] fop_helper.c helper_fsmuld
    converts both operands to double first and then multiplies, so a
    signalling rs1 with a quiet rs2 returns rs2's NaN (both are quiet by
    then) where the V8 table would give QSNaN1; profile 'v8' uses the
    table.  FMOVs/FNEGs/FABSs only copy/flip/clear the sign bit, never
    raise anything, even for a signalling NaN ([V8] §B.33: "These
    instructions do not round"; Ch. 5 "Floating-Point Operate": "FABSs,
    FMOVs, and FNEGs can't generate IEEE exceptions, so clear cexc and
    leave aexc unchanged"; [QEMU] translate.c gen_op_fnegs etc. are bit ops).

(c) Underflow.  Untrapped (UFM = 0) underflow is flagged only when the
    result is tiny AND inexact ([V8] §4.4 FSR_underflow and App. N.6, IEEE
    754-1985 §7.4); nxc is then always set as well.  Tininess: [V8] App.
    N.5/N.6 says "tininess detected before rounding"; but [VIK] §4.6.2.3
    says "Viking detects underflow after the rounding operation", and
    [QEMU] target/sparc never calls set_float_detect_tininess, so softfloat
    keeps its default, after rounding.  The default profile ('qemu') is
    therefore AFTER rounding (rounded with unbounded exponent range, then
    compared with the smallest normal); profile 'v8' detects before.  The
    two differ only when the exact result lies just below 2^emin and
    rounds up to the smallest normal: 'v8' gives UF|NX, 'qemu' NX alone.
    For trapped underflow (UFM = 1), V8 N.6 traps on tininess even when
    exact; Result.tiny carries the tininess for that use.  Overflow is
    detected after rounding ([V8] N.6), always with NX.  The overflowed
    result: RN -> inf; RZ -> max finite; RP -> +inf or -max; RM -> -inf or
    +max (IEEE 754-1985 §7.3).

(d) Invalid operations: inf-inf (same-sign infinities subtracted), 0*inf,
    0/0, inf/inf, sqrt(x < 0) (not -0, which returns -0), compare with
    NaN as in (b), and F?TOi out of range: all NV, with the default NaN of
    (a) for the arithmetic ones.  x/0 for finite x != 0 raises DZ and
    returns a correctly signed infinity.

F?TOi ([V8] §B.33 "Convert Floating-point to Integer": "always
rounded toward zero (the RD field of the FSR register is ignored)"; App. N.7): always round toward zero,
whatever FSR.RD.  NX if the value was not an integer.  For NaN, inf, x >=
2^31 or x <= -2^31-1 (after truncation outside int32): NV and, per [V8]
N.7, 0x7fffffff when the sign bit is 0 and 0x80000000 when it is 1.  QEMU
(fpu/softfloat-parts.c.inc parts_float_to_sint, not in the local tree; from
memory) returns 0x7fffffff for every NaN whatever its sign and follows N.7
for infinities and overflow; the default profile does the same.  [VIK]
§4.6.2.1: Viking writes 0 for a NaN; profile 'viking'.

Profiles:  'qemu' (default) as above.  'v8': tininess before rounding,
NaN -> int by sign, fsmuld NaNs by the N.4 table.  'viking': as 'qemu'
but NaN -> int gives 0 and every NaN result is the fixed quiet NaN of
[VIK] §4.6.2.2 Table 4-4 (0x7fc00000; the double value is unreadable in
the scan and is assumed to be 0x7ff80000_00000000).

Usage:  python3 tests/fpu/fpref.py --selftest
"""

import math
import random
import struct
import sys
from fractions import Fraction

# --------------------------------------------------------------------------
# Formats, flags, rounding modes

NV, OF, UF, DZ, NX = 0x10, 0x08, 0x04, 0x02, 0x01
RN, RZ, RP, RM = 0, 1, 2, 3
RM_NAMES = {RN: "nearest", RZ: "zero", RP: "+inf", RM: "-inf"}


class Fmt:
    def __init__(self, name, ebits, mbits):
        self.name = name
        self.ebits = ebits
        self.mbits = mbits                    # stored fraction bits
        self.p = mbits + 1                    # precision
        self.bias = (1 << (ebits - 1)) - 1
        self.emin = 1 - self.bias             # exponent of smallest normal
        self.emax = self.bias
        self.width = 1 + ebits + mbits
        self.emask = (1 << ebits) - 1
        self.fmask = (1 << mbits) - 1
        self.sign = 1 << (self.width - 1)
        self.qbit = 1 << (mbits - 1)
        self.inf = self.emask << mbits
        self.maxf = ((self.emask - 1) << mbits) | self.fmask
        self.default_nan = self.inf | self.fmask        # (a): 0x7fffffff..
        self.hexw = self.width // 4


F32 = Fmt("s", 8, 23)
F64 = Fmt("d", 11, 52)


class Result(tuple):
    """(bits, flags); .tiny is the tininess for trapped underflow."""

    def __new__(cls, bits, flags, tiny=False):
        r = tuple.__new__(cls, (bits, flags))
        r.tiny = tiny
        return r

    bits = property(lambda s: s[0])
    flags = property(lambda s: s[1])


PROFILES = ("qemu", "v8", "viking")


class Config:
    profile = "qemu"


def set_profile(name):
    if name not in PROFILES:
        raise ValueError(name)
    Config.profile = name


def _tininess_after():
    return Config.profile in ("qemu", "viking")


# --------------------------------------------------------------------------
# Decoding

def is_nan(f, x):
    return (x >> f.mbits) & f.emask == f.emask and x & f.fmask != 0


def is_snan(f, x):
    return is_nan(f, x) and not x & f.qbit


def is_inf(f, x):
    return x & ~f.sign == f.inf


def is_zero(f, x):
    return x & ~f.sign == 0


def sign_of(f, x):
    return 1 if x & f.sign else 0


def decode(f, x):
    """Finite x -> (sign, m, e) with |x| = m * 2^e exactly."""
    s = sign_of(f, x)
    ef = (x >> f.mbits) & f.emask
    fr = x & f.fmask
    if ef == 0:
        return s, fr, f.emin - f.mbits
    return s, fr | (1 << f.mbits), ef - f.bias - f.mbits


def to_fraction(f, x):
    s, m, e = decode(f, x)
    v = Fraction(m) * (Fraction(2) ** e)
    return -v if s else v


# --------------------------------------------------------------------------
# Exact positive magnitudes.  Each provides ilog2() = floor(log2 v) and
# floor_scaled(k) = (floor(v * 2^k), exact?).

class Rat:
    __slots__ = ("n", "d")

    def __init__(self, n, d=1):
        assert n > 0 and d > 0
        self.n, self.d = n, d

    @staticmethod
    def dyadic(m, e):
        return Rat(m << e) if e >= 0 else Rat(m, 1 << -e)

    def ilog2(self):
        e = self.n.bit_length() - self.d.bit_length()
        if e >= 0:
            if self.n < (self.d << e):
                e -= 1
        elif (self.n << -e) < self.d:
            e -= 1
        return e

    def floor_scaled(self, k):
        if k >= 0:
            q, r = divmod(self.n << k, self.d)
        else:
            q, r = divmod(self.n, self.d << -k)
        return q, r == 0


class SqrtRat:
    """sqrt(n/d)."""
    __slots__ = ("r",)

    def __init__(self, rat):
        self.r = rat

    def ilog2(self):
        return self.r.ilog2() >> 1           # floor(E/2), see module notes

    def floor_scaled(self, k):
        q, exact = self.r.floor_scaled(2 * k)
        s = math.isqrt(q)
        return s, exact and s * s == q


def _round_int(n, half, sticky, sign, rm):
    """Round n + (remainder) given the guard bit and sticky; True if up."""
    if not half and not sticky:
        return n
    if rm == RN:
        up = half and (sticky or n & 1)
    elif rm == RZ:
        up = False
    elif rm == RP:
        up = not sign
    else:
        up = bool(sign)
    return n + 1 if up else n


def _round_at(v, k, sign, rm):
    """Round v*2^k to an integer; returns (n, inexact)."""
    t, ex = v.floor_scaled(k + 1)
    n, half = t >> 1, t & 1
    sticky = not ex
    return _round_int(n, half, sticky, sign, rm), bool(half or sticky)


def round_pack(f, sign, v, rm):
    """Round the exact nonzero magnitude v (sign given) into format f."""
    e = v.ilog2()
    eq = max(e, f.emin)                      # exponent of the quantum's binade
    k = f.mbits - eq                         # v * 2^k: integer = significand
    n, inexact = _round_at(v, k, sign, rm)
    if n >> f.p:                             # carry out to the next binade
        n >>= 1
        eq += 1
    flags = NX if inexact else 0
    sbit = f.sign if sign else 0
    # tininess
    if e >= f.emin:
        tiny = False
    elif not _tininess_after():
        tiny = True
    else:
        nu, _ = _round_at(v, f.mbits - e, sign, rm)   # unbounded exponent
        tiny = not (nu >> f.p and e + 1 >= f.emin)
    if tiny and inexact:
        flags |= UF
    if eq > f.emax:
        flags |= OF | NX
        if rm == RN or (rm == RP and not sign) or (rm == RM and sign):
            return Result(sbit | f.inf, flags)
        return Result(sbit | f.maxf, flags)
    if n == 0:
        return Result(sbit, flags, tiny)
    if n >> f.mbits:                         # normal
        bits = ((eq + f.bias) << f.mbits) | (n & f.fmask)
    else:                                    # subnormal (eq == emin)
        bits = n
    return Result(sbit | bits, flags, tiny)


def _exact_signed(f, sign, num, den, rm):
    """Round the exact value (-1)^sign * num/den (num >= 0)."""
    if num == 0:
        raise AssertionError("zero handled by caller")
    return round_pack(f, sign, Rat(num, den), rm)


# --------------------------------------------------------------------------
# NaN handling

def quiet(f, x):
    if Config.profile == "viking":
        return _viking_nan(f)
    return x | f.qbit


def _viking_nan(f):
    return 0x7fc00000 if f is F32 else 0x7ff8000000000000


def default_nan(f):
    if Config.profile == "viking":
        return _viking_nan(f)
    return f.default_nan


def nan1(f, a):
    """One-operand NaN result (a is a NaN)."""
    return Result(quiet(f, a), NV if is_snan(f, a) else 0)


def nan2(f, a, b):
    """Two-operand NaN rule (b) = rs2 preferred, SNaN preferred."""
    na, nb = is_nan(f, a), is_nan(f, b)
    sa, sb = is_snan(f, a), is_snan(f, b)
    fl = NV if (sa or sb) else 0
    if sb or (nb and not sa):
        pick = b
    else:
        pick = a
    return Result(quiet(f, pick), fl)


def nan_convert(src, dst, x):
    """[V8] N.4 NaN transformation between formats."""
    fl = NV if is_snan(src, x) else 0
    if Config.profile == "viking":
        return Result(_viking_nan(dst), fl)
    s = dst.sign if sign_of(src, x) else 0
    fr = x & src.fmask
    if dst.mbits >= src.mbits:
        fr <<= dst.mbits - src.mbits
    else:
        fr >>= src.mbits - dst.mbits
    return Result(s | dst.inf | dst.qbit | fr, fl)


# --------------------------------------------------------------------------
# Arithmetic

def _value(f, x):
    """Finite x -> (sign, num, den)."""
    s, m, e = decode(f, x)
    if e >= 0:
        return s, m << e, 1
    return s, m, 1 << -e


def add(f, a, b, rm=RN):
    if is_nan(f, a) or is_nan(f, b):
        return nan2(f, a, b)
    ia, ib = is_inf(f, a), is_inf(f, b)
    if ia or ib:
        if ia and ib and sign_of(f, a) != sign_of(f, b):
            return Result(default_nan(f), NV)
        return Result(a if ia else b, 0)
    sa, ma, ea = decode(f, a)
    sb, mb, eb = decode(f, b)
    e = min(ea, eb)
    va = (ma << (ea - e)) * (-1 if sa else 1)
    vb = (mb << (eb - e)) * (-1 if sb else 1)
    s = va + vb
    if s == 0:
        if ma == 0 and mb == 0 and sa == sb:
            return Result(f.sign if sa else 0, 0)
        return Result(f.sign if rm == RM else 0, 0)
    sign = 1 if s < 0 else 0
    return round_pack(f, sign, Rat.dyadic(abs(s), e), rm)


def sub(f, a, b, rm=RN):
    if is_nan(f, a) or is_nan(f, b):
        return nan2(f, a, b)
    return add(f, a, b ^ f.sign, rm)


def mul(f, a, b, rm=RN, out=None):
    """out: result format (for fsmuld); operands are in f."""
    o = out or f
    if is_nan(f, a) or is_nan(f, b):
        if o is f:
            return nan2(f, a, b)
        return _fsmuld_nan(f, o, a, b)
    sign = sign_of(f, a) ^ sign_of(f, b)
    sbit = o.sign if sign else 0
    ia, ib = is_inf(f, a), is_inf(f, b)
    za, zb = is_zero(f, a), is_zero(f, b)
    if ia or ib:
        if za or zb:
            return Result(default_nan(o), NV)
        return Result(sbit | o.inf, 0)
    if za or zb:
        return Result(sbit, 0)
    _, ma, ea = decode(f, a)
    _, mb, eb = decode(f, b)
    return round_pack(o, sign, Rat.dyadic(ma * mb, ea + eb), rm)


def _fsmuld_nan(f, o, a, b):
    if Config.profile == "v8":
        r = nan2(f, a, b)
        # nan2 quieted in f; convert the chosen NaN to o (flags from nan2)
        c = nan_convert(f, o, r.bits)
        return Result(c.bits, r.flags)
    # QEMU: convert each operand to double first, then the double NaN rule
    da = nan_convert(f, o, a) if is_nan(f, a) else fstod_bits(a)
    db = nan_convert(f, o, b) if is_nan(f, b) else fstod_bits(b)
    r = nan2(o, da.bits, db.bits)
    return Result(r.bits, da.flags | db.flags | r.flags)


def fstod_bits(x):
    return f32_to_f64(x, RN)


def div(f, a, b, rm=RN):
    if is_nan(f, a) or is_nan(f, b):
        return nan2(f, a, b)
    sign = sign_of(f, a) ^ sign_of(f, b)
    sbit = f.sign if sign else 0
    ia, ib = is_inf(f, a), is_inf(f, b)
    za, zb = is_zero(f, a), is_zero(f, b)
    if ia:
        if ib:
            return Result(default_nan(f), NV)
        return Result(sbit | f.inf, 0)
    if ib:
        return Result(sbit, 0)
    if zb:
        if za:
            return Result(default_nan(f), NV)
        return Result(sbit | f.inf, DZ)
    if za:
        return Result(sbit, 0)
    _, ma, ea = decode(f, a)
    _, mb, eb = decode(f, b)
    e = ea - eb
    n, d = ma, mb
    if e >= 0:
        n <<= e
    else:
        d <<= -e
    return round_pack(f, sign, Rat(n, d), rm)


def sqrt(f, a, rm=RN):
    if is_nan(f, a):
        return nan1(f, a)
    if is_zero(f, a):
        return Result(a, 0)                  # sqrt(-0) = -0
    if sign_of(f, a):
        return Result(default_nan(f), NV)
    if is_inf(f, a):
        return Result(a, 0)
    _, m, e = decode(f, a)
    return round_pack(f, 0, SqrtRat(Rat.dyadic(m, e)), rm)


def fcmp(f, a, b, signalling=False):
    """fcc: 0 =, 1 rs1 < rs2, 2 rs1 > rs2, 3 unordered ([V8] Table 4-5)."""
    if is_nan(f, a) or is_nan(f, b):
        nv = signalling or is_snan(f, a) or is_snan(f, b)
        return Result(3, NV if nv else 0)
    va, vb = _cmpval(f, a), _cmpval(f, b)
    return Result(0 if va == vb else (1 if va < vb else 2), 0)


def _cmpval(f, x):
    if is_inf(f, x):
        return -math.inf if sign_of(f, x) else math.inf
    return to_fraction(f, x)


def fcmpe(f, a, b):
    return fcmp(f, a, b, signalling=True)


def itof(f, i, rm=RN):
    i &= 0xffffffff
    v = i - (1 << 32) if i >> 31 else i
    if v == 0:
        return Result(0, 0)
    return round_pack(f, 1 if v < 0 else 0, Rat(abs(v)), rm)


def ftoi(f, a, rm=RN):
    """F?TOi: round toward zero regardless of rm."""
    if is_nan(f, a):
        if Config.profile == "viking":
            r = 0
        elif Config.profile == "v8":
            r = 0x80000000 if sign_of(f, a) else 0x7fffffff
        else:
            r = 0x7fffffff
        return Result(r, NV)
    neg = sign_of(f, a)
    if is_inf(f, a):
        return Result(0x80000000 if neg else 0x7fffffff, NV)
    if is_zero(f, a):
        return Result(0, 0)
    _, m, e = decode(f, a)
    if e >= 0:
        t, exact = m << e, True
    else:
        t, exact = m >> -e, (m & ((1 << -e) - 1)) == 0
    v = -t if neg else t
    if v > 0x7fffffff or v < -0x80000000:
        return Result(0x80000000 if neg else 0x7fffffff, NV)
    return Result(v & 0xffffffff, 0 if exact else NX)


def f32_to_f64(a, rm=RN):
    if is_nan(F32, a):
        return nan_convert(F32, F64, a)
    s = F64.sign if sign_of(F32, a) else 0
    if is_inf(F32, a):
        return Result(s | F64.inf, 0)
    if is_zero(F32, a):
        return Result(s, 0)
    _, m, e = decode(F32, a)
    return round_pack(F64, sign_of(F32, a), Rat.dyadic(m, e), rm)


def f64_to_f32(a, rm=RN):
    if is_nan(F64, a):
        return nan_convert(F64, F32, a)
    s = F32.sign if sign_of(F64, a) else 0
    if is_inf(F64, a):
        return Result(s | F32.inf, 0)
    if is_zero(F64, a):
        return Result(s, 0)
    _, m, e = decode(F64, a)
    return round_pack(F32, sign_of(F64, a), Rat.dyadic(m, e), rm)


def fsmuld(a, b, rm=RN):
    """f32 x f32 -> f64, always exact for numbers."""
    return mul(F32, a, b, rm, out=F64)


def fmov(f, a):
    return Result(a, 0)


def fneg(f, a):
    return Result(a ^ f.sign, 0)


def fabs(f, a):
    return Result(a & ~f.sign, 0)


# --------------------------------------------------------------------------
# Table of SPARC instructions -> (operand formats, result format, function).
# fn(rm, a, b) -> Result.  Integer operands/results are 32-bit patterns.

I32 = "i"


def _fmtw(t):
    return 8 if t in (F32, I32) else 16


OPS = {
    "fadds": (F32, F32, F32, lambda rm, a, b: add(F32, a, b, rm)),
    "faddd": (F64, F64, F64, lambda rm, a, b: add(F64, a, b, rm)),
    "fsubs": (F32, F32, F32, lambda rm, a, b: sub(F32, a, b, rm)),
    "fsubd": (F64, F64, F64, lambda rm, a, b: sub(F64, a, b, rm)),
    "fmuls": (F32, F32, F32, lambda rm, a, b: mul(F32, a, b, rm)),
    "fmuld": (F64, F64, F64, lambda rm, a, b: mul(F64, a, b, rm)),
    "fdivs": (F32, F32, F32, lambda rm, a, b: div(F32, a, b, rm)),
    "fdivd": (F64, F64, F64, lambda rm, a, b: div(F64, a, b, rm)),
    "fsmuld": (F32, F32, F64, lambda rm, a, b: fsmuld(a, b, rm)),
    "fcmps": (F32, F32, None, lambda rm, a, b: fcmp(F32, a, b)),
    "fcmpd": (F64, F64, None, lambda rm, a, b: fcmp(F64, a, b)),
    "fcmpes": (F32, F32, None, lambda rm, a, b: fcmpe(F32, a, b)),
    "fcmped": (F64, F64, None, lambda rm, a, b: fcmpe(F64, a, b)),
    "fsqrts": (F32, None, F32, lambda rm, a, b: sqrt(F32, a, rm)),
    "fsqrtd": (F64, None, F64, lambda rm, a, b: sqrt(F64, a, rm)),
    "fitos": (I32, None, F32, lambda rm, a, b: itof(F32, a, rm)),
    "fitod": (I32, None, F64, lambda rm, a, b: itof(F64, a, rm)),
    "fstoi": (F32, None, I32, lambda rm, a, b: ftoi(F32, a, rm)),
    "fdtoi": (F64, None, I32, lambda rm, a, b: ftoi(F64, a, rm)),
    "fstod": (F32, None, F64, lambda rm, a, b: f32_to_f64(a, rm)),
    "fdtos": (F64, None, F32, lambda rm, a, b: f64_to_f32(a, rm)),
    "fmovs": (F32, None, F32, lambda rm, a, b: fmov(F32, a)),
    "fmovd": (F64, None, F64, lambda rm, a, b: fmov(F64, a)),
    "fnegs": (F32, None, F32, lambda rm, a, b: fneg(F32, a)),
    "fnegd": (F64, None, F64, lambda rm, a, b: fneg(F64, a)),
    "fabss": (F32, None, F32, lambda rm, a, b: fabs(F32, a)),
    "fabsd": (F64, None, F64, lambda rm, a, b: fabs(F64, a)),
}


def run(op, rm, a, b=0):
    return OPS[op][3](rm, a, b)


# --------------------------------------------------------------------------
# Every EXPECT of tests/cpu/src/t_fpu.S, as (test.code, op, rm, a, b,
# result, flags or None).  Flags come from the t_fpu_fsr / t_fpu_underflow
# cexc checks where the test makes them; None = the test does not look.

T_FPU_EXPECTS = [
    ("single.1", "fadds", RN, 0x3f800000, 0x40000000, 0x40400000, 0),
    ("single.2", "fsubs", RN, 0x3f800000, 0x40000000, 0xbf800000, 0),
    ("single.3", "fmuls", RN, 0x3fc00000, 0x40000000, 0x40400000, 0),
    ("single.4", "fdivs", RN, 0x3f800000, 0x40400000, 0x3eaaaaab, NX),
    ("single.5", "fsqrts", RN, 0x40000000, 0, 0x3fb504f3, NX),
    ("single.6", "fnegs", RN, 0x3f800000, 0, 0xbf800000, 0),
    ("single.7", "fabss", RN, 0xbf800000, 0, 0x3f800000, 0),
    ("single.8", "fmovs", RN, 0x40400000, 0, 0x40400000, 0),
    ("double.1-2", "faddd", RN, 0x3ff0000000000000, 0x3cb0000000000000,
     0x3ff0000000000001, 0),
    ("double.3-4", "fdivd", RN, 0x3ff0000000000000, 0x4008000000000000,
     0x3fd5555555555555, NX),
    ("double.5-6", "fmuld", RN, 0x3fd5555555555555, 0x4008000000000000,
     0x3ff0000000000000, NX),
    ("double.7-8", "fsqrtd", RN, 0x4000000000000000, 0,
     0x3ff6a09e667f3bcd, NX),
    ("double.9", "fsubd", RN, 0x3ff0000000000000, 0x4000000000000000,
     0xbff0000000000000, 0),
    ("convert.1", "fitos", RN, 0xfffffff9, 0, 0xc0e00000, 0),
    ("convert.2-3", "fitod", RN, 0xfffffff9, 0, 0xc01c000000000000, 0),
    ("convert.4", "fstoi", RN, 0x402ccccd, 0, 0x00000002, NX),
    ("convert.5", "fdtoi", RN, 0xc00599999999999a, 0, 0xfffffffe, NX),
    ("convert.6-7", "fstod", RN, 0x3fc00000, 0, 0x3ff8000000000000, 0),
    ("convert.8", "fdtos", RN, 0x3fd5555555555555, 0, 0x3eaaaaab, NX),
    ("compare.1", "fcmps", RN, 0x3f800000, 0x40000000, 1, 0),
    ("compare.2", "fcmps", RN, 0x40000000, 0x3f800000, 2, 0),
    ("compare.3", "fcmps", RN, 0x3f800000, 0x3f800000, 0, 0),
    ("compare.4", "fcmps", RN, 0x3f800000, 0x7fc00000, 3, 0),
    ("fsr.1", "fdivs", RN, 0x3f800000, 0x40400000, 0x3eaaaaab, NX),
    ("fsr.2-3", "fdivs", RN, 0x3f800000, 0x00000000, 0x7f800000, DZ),
    ("fsr.4", "fdivs", RN, 0x00000000, 0x00000000, 0x7fffffff, NV),
    ("fsr.5", "fadds", RN, 0x3f800000, 0x3f800000, 0x40000000, 0),
    ("underflow.1-4,9-10", "fmuls", RN, 0x00800000, 0x00800000, 0, UF | NX),
    ("underflow.5-8,11-13", "fmuld", RN, 0x0010000000000000,
     0x0010000000000000, 0, UF | NX),
]
# fsr.4 in t_fpu.S checks the flags only; 0x7fffffff is convention (a).


# --------------------------------------------------------------------------
# Self-test

def _f2b(x):
    return struct.unpack("<Q", struct.pack("<d", x))[0]


def _b2f(b):
    return struct.unpack("<d", struct.pack("<Q", b))[0]


def _s2b(x):
    return struct.unpack("<I", struct.pack("<f", x))[0]


def _sb2f(b):
    return struct.unpack("<f", struct.pack("<I", b))[0]


def rand_normal(f, rng, emin=None, emax=None):
    lo = 1 if emin is None else emin + f.bias
    hi = f.emask - 1 if emax is None else emax + f.bias
    ef = rng.randint(max(1, lo), min(f.emask - 1, hi))
    return (rng.getrandbits(1) << (f.width - 1)) | (ef << f.mbits) | \
        rng.getrandbits(f.mbits)


def selftest(verbose=False):
    fails = []

    def check(name, got, want):
        if got != want:
            fails.append("%s: got %r want %r" % (name, got, want))

    def hx(r):
        return (hex(r[0]), r[1])

    # 1. t_fpu.S
    for code, op, rm, a, b, res, fl in T_FPU_EXPECTS:
        r = run(op, rm, a, b)
        check("t_fpu " + code, (hex(r.bits), r.flags if fl is not None
                                else None), (hex(res), fl))

    # 2. conventions (a)-(d)
    for f in (F32, F64):
        one, inf, z = to_bits(f, 1.0), f.inf, 0
        dn = f.default_nan
        check("inf-inf", hx(sub(f, inf, inf)), (hex(dn), NV))
        check("0*inf", hx(mul(f, z, inf)), (hex(dn), NV))
        check("inf/inf", hx(div(f, inf, inf)), (hex(dn), NV))
        check("sqrt(-1)", hx(sqrt(f, one | f.sign)), (hex(dn), NV))
        check("sqrt(-0)", hx(sqrt(f, f.sign)), (hex(f.sign), 0))
        q1, q2 = f.inf | f.qbit | 1, f.inf | f.qbit | 2
        s1, s2 = f.inf | 1, f.inf | 2
        check("Q1+Q2", hx(add(f, q1, q2)), (hex(q2), 0))
        check("S1+Q2", hx(add(f, s1, q2)), (hex(s1 | f.qbit), NV))
        check("Q1+S2", hx(add(f, q1, s2)), (hex(s2 | f.qbit), NV))
        check("S1+S2", hx(add(f, s1, s2)), (hex(s2 | f.qbit), NV))
        check("1+Q2", hx(add(f, one, q2)), (hex(q2), 0))
        check("Q1*1", hx(mul(f, q1, one)), (hex(q1), 0))
        check("fcmp Q", fcmp(f, one, q1), (3, 0))
        check("fcmp S", fcmp(f, one, s1), (3, NV))
        check("fcmpe Q", fcmpe(f, one, q1), (3, NV))
        check("fcmp -0 +0", fcmp(f, f.sign, 0), (0, 0))
        check("x-x RN", hx(sub(f, one, one, RN)), (hex(0), 0))
        check("x-x RM", hx(sub(f, one, one, RM)), (hex(f.sign), 0))
        check("1/0", hx(div(f, one, 0)), (hex(f.inf), DZ))
        check("-1/0", hx(div(f, one, f.sign)), (hex(f.inf | f.sign), DZ))
        # overflow results per mode
        mx = f.maxf
        check("ovf RN", hx(mul(f, mx, to_bits(f, 2.0), RN)),
              (hex(f.inf), OF | NX))
        check("ovf RZ", hx(mul(f, mx, to_bits(f, 2.0), RZ)),
              (hex(mx), OF | NX))
        check("ovf RM+", hx(mul(f, mx, to_bits(f, 2.0), RM)),
              (hex(mx), OF | NX))
        check("ovf RM-", hx(mul(f, mx | f.sign, to_bits(f, 2.0), RM)),
              (hex(f.inf | f.sign), OF | NX))
        # exact subnormal: no UF
        minsub = 1
        check("minsub*1", hx(mul(f, minsub, one)), (hex(1), 0))
        check("minsub*0.5", hx(mul(f, minsub, to_bits(f, 0.5))),
              (hex(0), UF | NX))
        check("3minsub*0.5", hx(mul(f, 3, to_bits(f, 0.5))),
              (hex(2), UF | NX))
        # tininess: minnormal*(1+2^-k)*(1-2^-k) rounds up to minnormal in RN
        k = f.p // 2 + 1
        a = (1 << f.mbits) | (1 << (f.mbits - k))      # minnormal(1+2^-k)
        b = to_bits(f, 1.0 - 2.0 ** -k)
        set_profile("v8")
        check("tiny-before", hx(mul(f, a, b)), (hex(1 << f.mbits), UF | NX))
        set_profile("qemu")
        check("tiny-after", hx(mul(f, a, b)), (hex(1 << f.mbits), NX))
        check("tiny-after RZ", hx(mul(f, a, b, RZ)),
              (hex(f.fmask), UF | NX))
    # F?TOi
    check("fstoi 2^31", ftoi(F32, 0x4f000000), (0x7fffffff, NV))
    check("fstoi -2^31", ftoi(F32, 0xcf000000), (0x80000000, 0))
    check("fstoi -2^31-256", ftoi(F32, 0xcf000001), (0x80000000, NV))
    check("fdtoi -2^31-0.5", ftoi(F64, _f2b(-2147483648.5)),
          (0x80000000, NX))
    check("fdtoi 2^31-0.5", ftoi(F64, _f2b(2147483647.5)), (0x7fffffff, NX))
    check("fdtoi -inf", ftoi(F64, F64.inf | F64.sign), (0x80000000, NV))
    check("fstoi -NaN qemu", ftoi(F32, 0xffc00000), (0x7fffffff, NV))
    check("fstoi -0.9", ftoi(F32, _s2b(-0.9)), (0, NX))
    check("fstod sNaN", hx(f32_to_f64(0xff800001)),
          (hex(0xfff8000020000000), NV))
    check("fdtos qNaN", hx(f64_to_f32(0x7ff8000020000001)),
          (hex(0x7fc00001), 0))
    check("fitos 2^24+1", hx(itof(F32, (1 << 24) + 1)), (hex(0x4b800000), NX))
    check("fitos 2^24+1 RP", hx(itof(F32, (1 << 24) + 1, RP)),
          (hex(0x4b800001), NX))
    check("fsmuld S1*Q2 qemu", hx(fsmuld(0x7f800001, 0x7fc00002)),
          (hex(0x7ff8000040000000), NV))
    set_profile("v8")
    check("fsmuld S1*Q2 v8", hx(fsmuld(0x7f800001, 0x7fc00002)),
          (hex(0x7ff8000020000000), NV))
    check("fstoi -NaN v8", ftoi(F32, 0xffc00000), (0x80000000, NV))
    set_profile("qemu")

    rng = random.Random(754)
    # 3. identities
    for f in (F32, F64):
        for _ in range(2000):
            x = rand_normal(f, rng)
            for rm in range(4):
                check("x+(-0)", add(f, x, f.sign, rm), (x, 0))
                check("x*1", mul(f, x, to_bits(f, 1.0), rm), (x, 0))
                check("x/1", div(f, x, to_bits(f, 1.0), rm), (x, 0))
            y = rand_normal(f, rng)
            for rm in range(4):
                check("a+b=b+a", add(f, x, y, rm), add(f, y, x, rm))
                check("a*b=b*a", mul(f, x, y, rm), mul(f, y, x, rm))
                mrm = rm if rm < 2 else 5 - rm
                check("a-b=-(b-a)", sub(f, x, y, rm).bits,
                      fneg(f, sub(f, y, x, mrm).bits).bits
                      if sub(f, x, y, rm).bits & ~f.sign else
                      sub(f, x, y, rm).bits)
            # exact squares: c with <= p/2 significant bits
            c = (x & ~f.fmask) | (x & (f.fmask & ~((1 << (f.mbits - f.p // 2
                                                          + 1)) - 1)))
            sq = mul(f, c, c, RN)
            if sq.flags == 0 and not is_inf(f, sq.bits):
                for rm in range(4):
                    check("sqrt(c*c)", sqrt(f, sq.bits, rm),
                          (c & ~f.sign, 0))
            # fneg/fabs
            check("neg", fneg(f, x).bits, x ^ f.sign)
    # 4. Python doubles (round to nearest)
    for _ in range(20000):
        a, b = rand_normal(F64, rng), rand_normal(F64, rng)
        if rng.random() < 0.5:
            b = rand_normal(F64, rng, -40 + (((a >> 52) & 0x7ff) - 1023),
                            40 + (((a >> 52) & 0x7ff) - 1023))
        x, y = _b2f(a), _b2f(b)
        check("py add", add(F64, a, b).bits, _f2b(x + y))
        check("py sub", sub(F64, a, b).bits, _f2b(x - y))
        try:
            check("py mul", mul(F64, a, b).bits, _f2b(x * y))
        except OverflowError:
            pass
        try:
            check("py div", div(F64, a, b).bits, _f2b(x / y))
        except (OverflowError, ZeroDivisionError):
            pass
        check("py sqrt", sqrt(F64, a & ~F64.sign).bits, _f2b(math.sqrt(abs(x))))
        check("py fcmpd", fcmp(F64, a, b).bits,
              0 if x == y else (1 if x < y else 2))
    # 5. float32 via struct: double results that are exact, then one rounding
    for _ in range(20000):
        a, b = rand_normal(F32, rng), rand_normal(F32, rng)
        x, y = _sb2f(a), _sb2f(b)
        for name, fn, pv in (("mul", mul, x * y), ("add", add, x + y)):
            if to_fraction(F64, _f2b(pv)) != _pyexact(name, x, y):
                continue
            try:
                want = _s2b(pv)
            except OverflowError:
                want = F32.inf | (F32.sign if pv < 0 else 0)
            check("struct f32 " + name, fn(F32, a, b).bits, want)
        i = rng.getrandbits(32)
        iv = i - (1 << 32) if i >> 31 else i
        check("struct fitos", itof(F32, i).bits, _s2b(float(iv)))
        check("struct fitod", itof(F64, i).bits, _f2b(float(iv)))
        check("struct fstod", f32_to_f64(a).bits, _f2b(x))
        d = rng.getrandbits(64) & ~(F64.emask << 52) | \
            (rng.randint(1023 - 160, 1023 + 160) << 52)
        dv = _b2f(d)
        try:
            want = _s2b(dv)
        except OverflowError:
            want = F32.inf | (F32.sign if dv < 0 else 0)
        check("struct fdtos", f64_to_f32(d).bits, want)
        check("struct fsmuld", fsmuld(a, b).bits, _f2b(x * y))

    if fails:
        for m in fails[:50]:
            print("FAIL", m)
        print("selftest: %d failures" % len(fails))
        return False
    print("selftest: PASS (%d t_fpu.S expects, conventions, identities, "
          "Python double and struct float32 cross-checks)"
          % len(T_FPU_EXPECTS))
    return True


def _pyexact(name, x, y):
    fx, fy = Fraction(x), Fraction(y)
    return fx * fy if name == "mul" else fx + fy


def to_bits(f, v):
    """Python float -> bits in f (v must be exact in f)."""
    if f is F64:
        return _f2b(v)
    return _s2b(v)


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(0 if selftest() else 1)
    print(__doc__)
