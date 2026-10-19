#!/usr/bin/env python3
"""check_imm.py FILE.S [cpp args...] - find SPARC immediates that do not fit.

The 13-bit signed immediate (simm13) of the ALU, shift, load/store, save
and jmpl forms holds -4096..4095. LLVM 18 and GNU as both encode a larger
value without a word, wrapped (add %l0, 4096, %o0 becomes add %l0, -4096):
ethtest's TX buffer at 0x1000 went to SCRATCH - 4096 that way. This runs
the C preprocessor over the source as build.py does, evaluates the constant
operands, and prints every one out of range. Exit status: the count.
"""
import re
import subprocess
import sys

OPS = ("add addcc addx addxcc sub subcc subx subxcc and andcc andn andncc "
       "or orcc orn orncc xor xorcc xnor xnorcc sll srl sra smul smulcc umul "
       "umulcc sdiv sdivcc udiv udivcc mulscc taddcc tsubcc taddcctv tsubcctv "
       "save restore cmp mov btst bset bclr btog wr jmpl "
       "ld ldub lduh ldsb ldsh ldd st stb sth std ldstub swap ldf lddf stf stdf "
       "ldfsr stfsr").split()
OPRE = re.compile(r"^\s*(?:[\w.$]+:\s*)*(" + "|".join(OPS) + r")\s+(.*)$")
EXPR = re.compile(r"^[-+~()0-9a-fA-FxX<>|&*/ ]+$")


def value(tok):
    tok = tok.strip()
    if not tok or "%" in tok or not EXPR.match(tok) or not re.search(r"\d", tok):
        return None
    try:
        return int(eval(tok.replace("/", "//"), {"__builtins__": {}}))
    except Exception:
        return None


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src, cpp_args = sys.argv[1], sys.argv[2:]
    out = subprocess.run(["cpp", "-P", "-x", "assembler-with-cpp", *cpp_args, src],
                         capture_output=True, text=True)
    if out.returncode:
        sys.stderr.write(out.stderr)
        sys.exit(1)
    bad = 0
    for stmt in out.stdout.replace(";", "\n").splitlines():
        stmt = stmt.split("!")[0]
        m = OPRE.match(stmt)
        if not m:
            continue
        op, args = m.group(1), m.group(2)
        # the operands, brackets kept together ([%o2 + 4096])
        parts = [p.strip(" []") for p in re.split(r",(?![^\[]*\])", args)]
        for p in parts:
            # [%reg + imm]: the immediate alone; any other operand whole
            terms = re.split(r"\s*\+\s*", p, maxsplit=1) if p.startswith("%") else [p]
            for t in terms:
                v = value(t)
                if v is not None and not -4096 <= v <= 4095:
                    print(f"{src}: {op} {args.strip()}: {v} does not fit 13 bits")
                    bad += 1
    sys.exit(min(bad, 125))


if __name__ == "__main__":
    main()
