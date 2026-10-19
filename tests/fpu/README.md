# FPU reference model and test vectors

An exact IEEE 754 model of the SPARC V8 FPops in binary32 and binary64
(`fpref.py`) and a generator of test vectors for the SystemVerilog FPU's
unit bench (`gen_vectors.py`). Pure Python 3, standard library only; no
code from SoftFloat or TestFloat (their documentation was read for test
strategy only).

## Run

```sh
python3 tests/fpu/fpref.py --selftest      # model self-check (~1 s)
python3 tests/fpu/gen_vectors.py           # -> tests/fpu/vectors/<op>.txt (~2 s)
python3 tests/fpu/gen_vectors.py --profile v8 --out /tmp/v8vec   # other conventions
python3 tests/fpu/gen_vectors.py fdivs fsqrtd                   # a subset
```

Options: `--seed N` (default 20261009; output is byte-identical for a given
seed and profile), `--random N` random cases per op (default 3000; each case
is written for all 4 rounding modes), `--profile qemu|v8|viking`.

The self-test checks every `EXPECT` of `tests/cpu/src/t_fpu.S`
(`fpref.T_FPU_EXPECTS`), the conventions below, identities (x + -0 = x,
x * 1 = x, x / 1 = x, commutativity, a - b = -(b - a) with the directed
modes mirrored, sqrt(c*c) = |c| for exact squares), and agreement with
Python's own double arithmetic (add, sub, mul, div, sqrt, compare, round
to nearest) and with `struct`'s float32 packing (fadds/fmuls where the
double result is exact, fitos, fitod, fstod, fdtos, fsmuld).

The model API: `fpref.add(F32, a, b, rm)` etc. returns `Result(bits,
flags)`; `fpref.run(op, rm, a, b)` takes a SPARC mnemonic from
`fpref.OPS`. `Result.tiny` gives the tininess, for a bench of trapped
underflow (UFM = 1 traps on tininess even when exact, V8 App. N.6).

## Vector format

`vectors/<op>.txt`, one file per instruction: `fadds faddd fsubs fsubd
fmuls fmuld fdivs fdivd fsmuld fsqrts fsqrtd fcmps fcmpd fcmpes fcmped
fitos fitod fstoi fdtoi fstod fdtos fmovs fmovd fnegs fnegd fabss fabsd`
(the `d` forms of fmov/fneg/fabs are V9/QEMU only, given for an FPU that
moves pairs). Lines starting with `#` are comments (the header repeats this
format). Every other line has five space-separated fields:

```
rm a b result flags
0 3f800000 40400000 3eaaaaab 00001
```

| field | meaning |
|---|---|
| `rm` | FSR.RD, one digit: 0 nearest-even, 1 toward zero, 2 toward +inf, 3 toward -inf |
| `a` | rs1 operand in hex; for one-operand FPops the rs2 operand. 8 digits for single and int32, 16 for double |
| `b` | rs2 operand in hex, same width as `a` for one-operand ops and all zeros there |
| `result` | rd in hex (8 or 16 digits; a double is the even/odd register pair, high word first); for fcmp/fcmpe the fcc code in one digit: 0 =, 1 rs1 < rs2, 2 rs1 > rs2, 3 unordered |
| `flags` | 5 binary digits in FSR.cexc order: nv of uf dz nx |

Flags are the untrapped results (TEM = 0): the cexc value, also or'd into
aexc. Each operand case is written 4 times, rm = 0..3 in order (F?TOi,
fcmp, fmov/fneg/fabs ignore rm, which the vectors show). A SystemVerilog
bench can read a line with `$fgets`, skip `#`, then
`$sscanf(line, "%d %h %h %h %b", rm, a, b, res, flags)`.

Per file, about 3,000 random cases plus the systematic ones, times 4:

| op | vectors | op | vectors |
|---|---|---|---|
| fadds / faddd | 41,516 / 41,560 | fitos / fitod | 13,968 / 13,988 |
| fsubs / fsubd | 41,540 / 41,520 | fstoi / fdtoi | 12,848 / 13,360 |
| fmuls / fmuld | 35,760 / 36,288 | fstod / fdtos | 12,624 / 22,856 |
| fdivs / fdivd | 37,060 / 37,060 | fsmuld | 36,960 |
| fsqrts / fsqrtd | 19,592 / 20,480 | fcmp(e)s / fcmp(e)d | 27,376 each |
| fmovs fnegs fabss | 4,624 each | fmovd fnegd fabsd | 5,088 each |

Systematic cases: all pairs of a signed special set (±0, ±inf, quiet and
signalling NaNs with payloads and both signs, the default NaN, min/max
subnormal, min normal and its neighbours, max normal, 1 and its neighbours,
small integers, 0.1, 1/3); for one-operand ops also every subnormal binade
(2^k and 2^(k+1)-1 for each k) and the neighbours of the extreme binades.
Then per op: exact halfway cases and their neighbours (add/sub: half an ulp
of a random operand, odd and even; mul: products of exactly p+1 bits; fdtos:
f32 value + half an f32 ulp, in normal and subnormal range; fitos: 25-bit
odd integers), cancellation (equal, 1-2 ulps apart, adjacent binades, near
the min normal), exponent gaps beyond p (sticky bit), overflow boundaries
(max + half an ulp, max * 2, max / 0.5, products and quotients at the
emax edge), underflow boundaries (products and quotients around 2^emin,
subnormal * 0.5 ties, deep underflow to 0 or the min subnormal, the
tininess-before/after cases minnormal*(1+2^-k)*(1-2^-k)), exact quotients
a = b*c, exact and near-exact squares for sqrt, division by ±0, int
conversions at and beyond the int32 range (±2^31, -2^31-0.5, 2^31-0.5,
2^31±256, 2^32...) and every `EXPECT` of `t_fpu.S`. A quotient or square
root can never fall exactly on a tie or in the tininess-ambiguous window
just below 2^emin, so those cases exist only for add/sub/mul/conversions.

## SPARC conventions

Sources: **[V8]** The SPARC Architecture Manual Version 8 (text extract
`sparcv8.txt`); **[QEMU]** `scratch/reference/emulators/qemu/target/sparc`
(`cpu.c`, `fop_helper.c`; the tree has no `fpu/` directory, so softfloat
itself could not be checked); **[VIK]** TMS390Z50 Viking (SuperSPARC) User
Documentation rev 2.00, §4.6.2. The default profile `qemu` follows QEMU,
which made the `t_fpu.S` expectations; `v8` follows the V8 recommendations
where they differ; `viking` the SuperSPARC notes.

**(a) Default NaN.** An invalid operation without a NaN operand returns
sign 0, exponent all ones, fraction all ones: `7fffffff` /
`7fffffffffffffff`. [V8] App. N.4 ("the sign is 0 to distinguish such
results from storage initialized to all '1' bits"); [QEMU] `cpu.c`
`set_float_default_nan_pattern(0b01111111)`. ([VIK] §4.6.2.2 says Viking
writes a fixed `7fc00000` for every NaN result; the double value is
illegible in our scan, the `viking` profile assumes `7ff8000000000000`.)

**(b) NaN propagation.** One NaN operand: that NaN with the quiet bit (the
fraction MSB) set; NV if it was signalling. Two NaNs: a signalling NaN wins
over a quiet one, and between two of the same kind rs2 wins ([V8] App. N.4
table: Q1,Q2 -> Q2; S1,Q2 -> QS1; Q1,S2 -> QS2; S1,S2 -> QS2). [QEMU]
`cpu.c` `float_2nan_prop_s_ba` ("Prefer SNaN over QNaN, order B then A").
Format conversions keep the sign and top fraction bits and set the quiet
bit ([V8] N.4 "NaN transformation"). FCMP: NV only for a signalling NaN,
FCMPE: NV for any NaN, fcc = 3 ([V8] N.4, §B.33, Table 4-5). FMOVs, FNEGs,
FABSs are bit operations with no exceptions, cexc cleared ([V8] §B.33 and
Ch. 5 "Floating-Point Operate"). FsMULd: [QEMU] `helper_fsmuld` converts
both operands to double before multiplying, so S1 * Q2 returns Q2 (both
quiet by then; NV still raised); `v8` gives QS1 per the N.4 table.

**(c) Underflow.** Untrapped underflow (UFM = 0) is raised only when the
result is tiny *and* inexact, always with NX ([V8] §4.4 FSR_underflow, App.
N.6; IEEE 754-1985 §7.4). Tininess: [V8] App. N.5/N.6 specify *before*
rounding; [VIK] §4.6.2.3 "Viking detects underflow after the rounding
operation"; [QEMU] target/sparc never calls `set_float_detect_tininess`,
so softfloat's default, *after* rounding, applies. Profile `qemu`
(default) and `viking`: after rounding; `v8`: before. They differ only when
the exact result lies within half an ulp below 2^emin and rounds up to the
min normal: `v8` gives UF NX, `qemu` NX (82 fmuls, 172 fmuld, 60 fsmuld
(NaN rule), 14 fdtos vectors differ). Overflow is after rounding, always
with NX; RN gives inf, RZ max, RP +inf/-max, RM -inf/+max.

**(d) Invalid operations.** inf - inf, 0 * inf, 0 / 0, inf / inf, sqrt of a
number < 0 (sqrt(-0) = -0, no flag) and the NaN cases of (b): NV with the
default NaN. x / 0 for finite x != 0: DZ, signed inf. F?TOi round toward
zero whatever RD ([V8] §B.33); out of range (NaN, inf, truncated value
outside int32): NV, `7fffffff` for sign 0 and `80000000` for sign 1 ([V8]
App. N.7). For a NaN, QEMU returns `7fffffff` whatever the sign (softfloat
`parts_float_to_sint`, from memory: not in the local tree), and that is the
default; `v8` uses the sign; [VIK] §4.6.2.1 says Viking writes 0
(`viking`). -2^31 - 0.5 truncates to -2^31: valid, NX.
