"""SPARC V8 instruction decoder.

Covers the whole V8 instruction set, privileged instructions included
(rd/wr %psr %wim %tbr %asrN, lda/sta with an ASI, rett, flush, the
coprocessor ops) - the ones Capstone decodes badly or not at all, and the
ones a boot PROM is made of. Output follows the Sun assembler syntax that
the SPARC manuals use, with the usual synthetic forms (mov, cmp, tst, ret,
retl, set-style pairs are left to the caller).

decode(word, pc) -> Insn
"""

from dataclasses import dataclass, field

REGS = ([f"%g{i}" for i in range(8)] + [f"%o{i}" for i in range(8)] +
        [f"%l{i}" for i in range(8)] + [f"%i{i}" for i in range(8)])
REGS[14] = "%sp"
REGS[30] = "%fp"

ICC = ["n", "e", "le", "l", "leu", "cs", "neg", "vs",
       "a", "ne", "g", "ge", "gu", "cc", "pos", "vc"]
FCC = ["n", "ne", "lg", "ul", "l", "ug", "g", "u",
       "a", "e", "ue", "ge", "uge", "le", "ule", "o"]
CCC = ["n", "123", "12", "13", "1", "23", "2", "3",
       "a", "0", "03", "02", "023", "01", "013", "012"]

# op=2 arithmetic / logical / control
OP2 = {
    0x00: "add", 0x01: "and", 0x02: "or", 0x03: "xor", 0x04: "sub",
    0x05: "andn", 0x06: "orn", 0x07: "xnor", 0x08: "addx", 0x0a: "umul",
    0x0b: "smul", 0x0c: "subx", 0x0e: "udiv", 0x0f: "sdiv",
    0x10: "addcc", 0x11: "andcc", 0x12: "orcc", 0x13: "xorcc", 0x14: "subcc",
    0x15: "andncc", 0x16: "orncc", 0x17: "xnorcc", 0x18: "addxcc",
    0x1a: "umulcc", 0x1b: "smulcc", 0x1c: "subxcc", 0x1e: "udivcc",
    0x1f: "sdivcc",
    0x20: "taddcc", 0x21: "tsubcc", 0x22: "taddcctv", 0x23: "tsubcctv",
    0x24: "mulscc", 0x25: "sll", 0x26: "srl", 0x27: "sra",
    0x3c: "save", 0x3d: "restore",
}

# op=3 loads and stores: (mnemonic, kind) kind: i=int, f=fp, c=cp,
# fsr/csr/fq/cq special, a=alternate space
OP3 = {
    0x00: ("ld", "ld"), 0x01: ("ldub", "ld"), 0x02: ("lduh", "ld"),
    0x03: ("ldd", "ld"), 0x04: ("st", "st"), 0x05: ("stb", "st"),
    0x06: ("sth", "st"), 0x07: ("std", "st"), 0x09: ("ldsb", "ld"),
    0x0a: ("ldsh", "ld"), 0x0d: ("ldstub", "ld"), 0x0f: ("swap", "ld"),
    0x10: ("lda", "lda"), 0x11: ("lduba", "lda"), 0x12: ("lduha", "lda"),
    0x13: ("ldda", "lda"), 0x14: ("sta", "sta"), 0x15: ("stba", "sta"),
    0x16: ("stha", "sta"), 0x17: ("stda", "sta"), 0x19: ("ldsba", "lda"),
    0x1a: ("ldsha", "lda"), 0x1d: ("ldstuba", "lda"), 0x1f: ("swapa", "lda"),
    0x20: ("ld", "ldf"), 0x21: ("ld", "ldfsr"), 0x23: ("ldd", "ldf"),
    0x24: ("st", "stf"), 0x25: ("st", "stfsr"), 0x26: ("std", "stdfq"),
    0x27: ("std", "stf"),
    0x30: ("ld", "ldc"), 0x31: ("ld", "ldcsr"), 0x33: ("ldd", "ldc"),
    0x34: ("st", "stc"), 0x35: ("st", "stcsr"), 0x36: ("std", "stdcq"),
    0x37: ("std", "stc"),
}

FPOP1 = {
    0x001: "fmovs", 0x005: "fnegs", 0x009: "fabss",
    0x029: "fsqrts", 0x02a: "fsqrtd", 0x02b: "fsqrtq",
    0x041: "fadds", 0x042: "faddd", 0x043: "faddq",
    0x045: "fsubs", 0x046: "fsubd", 0x047: "fsubq",
    0x049: "fmuls", 0x04a: "fmuld", 0x04b: "fmulq",
    0x04d: "fdivs", 0x04e: "fdivd", 0x04f: "fdivq",
    0x069: "fsmuld", 0x06e: "fdmulq",
    0x0c4: "fitos", 0x0c6: "fdtos", 0x0c7: "fqtos",
    0x0c8: "fitod", 0x0c9: "fstod", 0x0cb: "fqtod",
    0x0cc: "fitoq", 0x0cd: "fstoq", 0x0ce: "fdtoq",
    0x0d1: "fstoi", 0x0d2: "fdtoi", 0x0d3: "fqtoi",
}
# unary FPop1s have no rs1
FPOP1_UNARY = {0x001, 0x005, 0x009, 0x029, 0x02a, 0x02b, 0x0c4, 0x0c6,
               0x0c7, 0x0c8, 0x0c9, 0x0cb, 0x0cc, 0x0cd, 0x0ce, 0x0d1,
               0x0d2, 0x0d3}
FPOP2 = {0x051: "fcmps", 0x052: "fcmpd", 0x053: "fcmpq",
         0x055: "fcmpes", 0x056: "fcmped", 0x057: "fcmpeq"}


@dataclass
class Insn:
    pc: int
    word: int
    mnemonic: str
    operands: str = ""
    valid: bool = True
    # control flow
    target: int | None = None      # branch / call destination, if static
    is_branch: bool = False        # Bicc/FBfcc/CBccc
    is_call: bool = False
    is_jmpl: bool = False          # indirect: jmpl / ret / retl / rett
    is_trap: bool = False          # Ticc
    conditional: bool = False
    annul: bool = False
    ends_flow: bool = False        # unconditional transfer (after delay slot)
    # memory / register info for annotators
    rd: int | None = None
    rs1: int | None = None
    rs2: int | None = None
    imm: int | None = None
    op3: int | None = None
    op: int | None = None
    asi: int | None = None
    mem: bool = False
    store: bool = False
    notes: list = field(default_factory=list)

    def text(self):
        return f"{self.mnemonic:<9} {self.operands}".rstrip()


def sext(v, bits):
    m = 1 << (bits - 1)
    return (v ^ m) - m


def hx(v):
    if v < 0:
        return f"-0x{-v:x}"
    return f"0x{v:x}" if v > 9 else f"{v}"


def _addr(rs1, i, simm, rs2):
    """[rs1 + rs2 / simm13] in Sun syntax."""
    r1 = REGS[rs1]
    if i:
        if rs1 == 0:
            return hx(simm)
        if simm == 0:
            return r1
        return f"{r1} + {hx(simm)}" if simm > 0 else f"{r1} - {hx(-simm)}"
    if rs2 == 0:
        return r1
    if rs1 == 0:
        return REGS[rs2]
    return f"{r1} + {REGS[rs2]}"


def _src2(i, simm, rs2):
    return hx(simm) if i else REGS[rs2]


def decode(word, pc):
    op = word >> 30
    ins = Insn(pc=pc, word=word, mnemonic=".word", operands=f"0x{word:08x}",
               valid=False, op=op)

    if op == 1:                                     # CALL
        disp = sext(word & 0x3fffffff, 30) << 2
        tgt = (pc + disp) & 0xffffffff
        ins.mnemonic, ins.operands, ins.valid = "call", f"0x{tgt:08x}", True
        ins.target, ins.is_call = tgt, True
        return ins

    rd = (word >> 25) & 0x1f
    if op == 0:
        op2 = (word >> 22) & 7
        if op2 == 4:                                # SETHI
            imm22 = word & 0x3fffff
            ins.valid, ins.rd, ins.imm = True, rd, imm22 << 10
            if rd == 0 and imm22 == 0:
                ins.mnemonic, ins.operands = "nop", ""
            else:
                ins.mnemonic = "sethi"
                ins.operands = f"%hi(0x{imm22 << 10:08x}), {REGS[rd]}"
            return ins
        if op2 == 0:                                # UNIMP
            ins.mnemonic, ins.operands = "unimp", hx(word & 0x3fffff)
            ins.valid = True
            return ins
        if op2 in (2, 6, 7):                        # Bicc FBfcc CBccc
            a = (word >> 29) & 1
            cond = (word >> 25) & 0xf
            disp = sext(word & 0x3fffff, 22) << 2
            tgt = (pc + disp) & 0xffffffff
            names = {2: ("b", ICC), 6: ("fb", FCC), 7: ("cb", CCC)}[op2]
            m = names[0] + names[1][cond]
            if a:
                m += ",a"
            ins.mnemonic, ins.operands, ins.valid = m, f"0x{tgt:08x}", True
            ins.target, ins.is_branch, ins.annul = tgt, True, bool(a)
            ins.conditional = cond not in (0, 8)
            # "ba" always transfers; "bn" never does
            ins.ends_flow = (cond == 8)
            if cond == 0:
                ins.target = None
            return ins
        return ins

    op3 = (word >> 19) & 0x3f
    rs1 = (word >> 14) & 0x1f
    i = (word >> 13) & 1
    rs2 = word & 0x1f
    simm = sext(word & 0x1fff, 13)
    asi = (word >> 5) & 0xff
    ins.rd, ins.rs1, ins.op3 = rd, rs1, op3
    ins.rs2 = None if i else rs2
    ins.imm = simm if i else None

    if op == 2:
        s2 = _src2(i, simm, rs2)
        if op3 in OP2:
            m = OP2[op3]
            ins.valid = True
            r1, rdn = REGS[rs1], REGS[rd]
            # synthetic forms
            if m == "or" and rs1 == 0:
                if not i and rs2 == 0:
                    ins.mnemonic, ins.operands = "clr", rdn
                else:
                    ins.mnemonic, ins.operands = "mov", f"{s2}, {rdn}"
                return ins
            if m == "subcc" and rd == 0:
                ins.mnemonic, ins.operands = "cmp", f"{r1}, {s2}"
                return ins
            if m == "orcc" and rd == 0 and rs1 == 0 and not i:
                ins.mnemonic, ins.operands = "tst", REGS[rs2]
                return ins
            if m == "orcc" and rd == 0 and i and simm == 0:
                ins.mnemonic, ins.operands = "tst", r1
                return ins
            if m in ("save", "restore") and rd == 0 and rs1 == 0 and \
                    not i and rs2 == 0:
                ins.mnemonic, ins.operands = m, ""
                return ins
            if m in ("sll", "srl", "sra") and i:
                s2 = str(simm & 0x1f)
                if simm & 0x1fe0:
                    ins.notes.append("reserved shift bits set")
            ins.mnemonic, ins.operands = m, f"{r1}, {s2}, {rdn}"
            return ins
        if op3 == 0x28:                             # rd %y / %asr / stbar
            ins.valid = True
            if rs1 == 0:
                ins.mnemonic, ins.operands = "rd", f"%y, {REGS[rd]}"
            elif rs1 == 15 and rd == 0:
                ins.mnemonic, ins.operands = "stbar", ""
            else:
                ins.mnemonic, ins.operands = "rd", f"%asr{rs1}, {REGS[rd]}"
            return ins
        if op3 in (0x29, 0x2a, 0x2b):
            sr = {0x29: "%psr", 0x2a: "%wim", 0x2b: "%tbr"}[op3]
            ins.mnemonic, ins.operands, ins.valid = "rd", \
                f"{sr}, {REGS[rd]}", True
            return ins
        if op3 in (0x30, 0x31, 0x32, 0x33):
            sr = {0x30: "%y" if rd == 0 else f"%asr{rd}", 0x31: "%psr",
                  0x32: "%wim", 0x33: "%tbr"}[op3]
            ins.valid = True
            if rs1 == 0:
                ins.mnemonic, ins.operands = "wr", f"{_src2(i, simm, rs2)}, {sr}"
            else:
                ins.mnemonic, ins.operands = "wr", \
                    f"{REGS[rs1]}, {_src2(i, simm, rs2)}, {sr}"
            return ins
        if op3 == 0x34:                             # FPop1
            opf = (word >> 5) & 0x1ff
            if opf in FPOP1:
                m = FPOP1[opf]
                ins.valid = True
                if opf in FPOP1_UNARY:
                    ins.mnemonic, ins.operands = m, f"%f{rs2}, %f{rd}"
                else:
                    ins.mnemonic, ins.operands = m, f"%f{rs1}, %f{rs2}, %f{rd}"
            else:
                ins.mnemonic, ins.operands = "fpop1", \
                    f"0x{opf:03x}, %f{rs1}, %f{rs2}, %f{rd}"
            return ins
        if op3 == 0x35:                             # FPop2
            opf = (word >> 5) & 0x1ff
            if opf in FPOP2:
                ins.mnemonic, ins.operands, ins.valid = FPOP2[opf], \
                    f"%f{rs1}, %f{rs2}", True
            else:
                ins.mnemonic, ins.operands = "fpop2", \
                    f"0x{opf:03x}, %f{rs1}, %f{rs2}, %f{rd}"
            return ins
        if op3 in (0x36, 0x37):                     # CPop1 CPop2
            opc = (word >> 5) & 0x1ff
            ins.mnemonic = "cpop1" if op3 == 0x36 else "cpop2"
            ins.operands = f"0x{opc:03x}, %c{rs1}, %c{rs2}, %c{rd}"
            ins.valid = True
            return ins
        if op3 == 0x38:                             # JMPL
            ins.valid, ins.is_jmpl, ins.ends_flow = True, True, True
            a = _addr(rs1, i, simm, rs2)
            if rd == 0 and i and simm == 8 and rs1 == 31:
                ins.mnemonic, ins.operands = "ret", ""
            elif rd == 0 and i and simm == 8 and rs1 == 15:
                ins.mnemonic, ins.operands = "retl", ""
            elif rd == 0:
                ins.mnemonic, ins.operands = "jmp", a
            elif rd == 15:
                ins.mnemonic, ins.operands = "call", a
                ins.ends_flow, ins.is_call = False, True
            else:
                ins.mnemonic, ins.operands = "jmpl", f"{a}, {REGS[rd]}"
            if rs1 == 0 and i:
                ins.target = simm & 0xffffffff
            return ins
        if op3 == 0x39:                             # RETT
            ins.mnemonic, ins.operands = "rett", _addr(rs1, i, simm, rs2)
            ins.valid, ins.is_jmpl, ins.ends_flow = True, True, True
            return ins
        if op3 == 0x3a:                             # Ticc
            cond = (word >> 25) & 0xf
            ins.mnemonic = "t" + ICC[cond]
            ins.operands = _addr(rs1, i, simm, rs2)
            ins.valid, ins.is_trap = True, True
            ins.conditional = cond not in (0, 8)
            return ins
        if op3 == 0x3b:                             # FLUSH (iflush)
            ins.mnemonic, ins.operands = "flush", _addr(rs1, i, simm, rs2)
            ins.valid = True
            return ins
        return ins

    # op == 3, memory
    if op3 not in OP3:
        return ins
    m, kind = OP3[op3]
    a = _addr(rs1, i, simm, rs2)
    ins.valid, ins.mem = True, True
    ins.store = kind.startswith("st") or m.startswith("st") or \
        m in ("ldstub", "ldstuba", "swap", "swapa")
    if kind == "ld":
        ins.mnemonic, ins.operands = m, f"[{a}], {REGS[rd]}"
    elif kind == "st":
        if rd == 0 and m in ("st", "stb", "sth"):
            ins.mnemonic = {"st": "clr", "stb": "clrb", "sth": "clrh"}[m]
            ins.operands = f"[{a}]"
        else:
            ins.mnemonic, ins.operands = m, f"{REGS[rd]}, [{a}]"
    elif kind in ("lda", "sta"):
        if i:   # alternate-space forms have no immediate in V8
            ins.valid = False
            ins.mnemonic, ins.operands = ".word", f"0x{word:08x}"
            return ins
        ins.asi = asi
        ins.mnemonic = m
        if kind == "lda":
            ins.operands = f"[{a}] 0x{asi:02x}, {REGS[rd]}"
        else:
            ins.operands = f"{REGS[rd]}, [{a}] 0x{asi:02x}"
    elif kind == "ldf":
        ins.mnemonic, ins.operands = m, f"[{a}], %f{rd}"
    elif kind == "stf":
        ins.mnemonic, ins.operands = m, f"%f{rd}, [{a}]"
    elif kind == "ldfsr":
        ins.mnemonic, ins.operands = m, f"[{a}], %fsr"
    elif kind == "stfsr":
        ins.mnemonic, ins.operands = m, f"%fsr, [{a}]"
    elif kind == "stdfq":
        ins.mnemonic, ins.operands = m, f"%fq, [{a}]"
    elif kind == "ldc":
        ins.mnemonic, ins.operands = m, f"[{a}], %c{rd}"
    elif kind == "stc":
        ins.mnemonic, ins.operands = m, f"%c{rd}, [{a}]"
    elif kind == "ldcsr":
        ins.mnemonic, ins.operands = m, f"[{a}], %csr"
    elif kind == "stcsr":
        ins.mnemonic, ins.operands = m, f"%csr, [{a}]"
    elif kind == "stdcq":
        ins.mnemonic, ins.operands = m, f"%cq, [{a}]"
    return ins


def has_delay_slot(ins):
    return ins.is_branch or ins.is_call or ins.is_jmpl


if __name__ == "__main__":
    import sys
    data = open(sys.argv[1], "rb").read()
    base = int(sys.argv[2], 16) if len(sys.argv) > 2 else 0
    start = int(sys.argv[3], 16) if len(sys.argv) > 3 else 0
    count = int(sys.argv[4], 16) if len(sys.argv) > 4 else 0x40
    for off in range(start, min(start + count, len(data)), 4):
        w = int.from_bytes(data[off:off + 4], "big")
        d = decode(w, base + off)
        print(f"{base + off:08x}: {w:08x}  {d.text()}")
