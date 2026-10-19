# SPARC V8 integer unit: reference digest for the SS20 core

Facts gathered for the design of the phase 1 integer unit (IU) of the
SuperSPARC-compatible CPU ([VERILOG-PLAN.md](../VERILOG-PLAN.md) §2, §3
phase 1). Each fact names its source. The digest gives no design advice.
Where the sources disagree, it says so and gives each side.

## Sources and how they are cited

| Short name | Document | Where |
|---|---|---|
| **V8** | *The SPARC Architecture Manual, Version 8* | `scratch/reference/cpu/sparcv8.pdf`. Cited by section/table. Where a line number is given, it refers to a `pdftotext` extraction (`sparcv8.txt`, 14094 lines), which is not in the repository |
| **Viking** | *The Viking Microprocessor (TI TMS390Z50) User Documentation*, Sun 800-4510-02, Rev 2.00, Nov 1990 | `scratch/reference/cpu/800-4510-02_…pdf`. Cited by section/table. The PDF is a scan, and its OCR text (used here) has some garbled characters |
| **SS-II** | *SuperSPARC II Addendum* (STP1021), Rev 1.3, Dec 1994 | `scratch/reference/text/STP1021UG.txt:line` |
| **Sun-4M** | *Sun-4M System Architecture* | `scratch/reference/text/Sun4M_SystemArchitecture_edited2.txt:line` |
| **QEMU** | QEMU `target/sparc/` | `scratch/reference/emulators/qemu/target/sparc/<file>:line` |
| **tests** | the project's CPU suite | `tests/cpu/…:line` |
| **PLAN** | `docs/VERILOG-PLAN.md` | § |

The request asked for "Chapter 5 instruction definitions" and "Appendix B
encodings". In this edition of V8, Chapter 5 is the overview (formats,
categories, delayed control transfers). The per-instruction definitions,
with their trap lists, are in **Appendix B**. The opcode maps are in
**Appendix F** (Tables F-1..F-7). The ISP pseudo-code, which gives the exact
order of checks, is in **Appendix C**. Implementation characteristics are in
**Appendix L**, and the suggested ASIs are in **Appendix I**.

The text extraction of V8 shows "−" as `<` and "≥" as `*`. This digest
gives the correct symbols.

---

## 1. Registers

### 1.1 r registers and windows

- **NWINDOWS = 8.** Sources: PLAN §3 phase 1; QEMU `cpu.c:488`
  (`TI-SuperSparc-60`: `.nwindows = 8`); test `t_wim_bits` expects 8 (`tests/cpu/src/t_window.S:96-99`).
  V8 allows 2..32 (V8 §4.1).
- **Total r registers:** 8 globals + NWINDOWS × 16 = 136 for 8 windows
  (V8 §4.1).
- **Window addressing** (V8 Table 4-1):

  | Name | r address | Note |
  |---|---|---|
  | `%g0-%g7` (global[0..7]) | r[0]-r[7] | shared by all windows |
  | `%o0-%o7` (out[0..7]) | r[8]-r[15] | = the ins of window CWP−1 |
  | `%l0-%l7` (local[0..7]) | r[16]-r[23] | private to the window |
  | `%i0-%i7` (in[0..7]) | r[24]-r[31] | = the outs of window CWP+1 |

- **Overlap rule (V8 §4.1 "Overlapping of Windows"):** r[o] (8 ≤ o ≤ 15)
  is the same register as r[o+16] after CWP is decremented by 1 (mod
  NWINDOWS). r[i] (24 ≤ i ≤ 31) is the same register as r[i−16] after
  CWP is incremented by 1. The outs of window 0 are the ins of window
  NWINDOWS−1. Windows are numbered contiguously 0..NWINDOWS−1.
- **CWP arithmetic is modulo NWINDOWS.** SAVE and traps decrement CWP;
  RESTORE and RETT increment it (V8 §4.1, §4.2 PSR_cwp).
- **r[0]** reads as 0 when used as rs1, rs2, or as rd of a store. A write
  to r[0] is discarded (V8 §4.1 "Special r Registers"). Tests: `t_sethi`
  checks 8-9 (`mov 5,%g0`, `add %g0,7,%g0` leave %g0 = 0;
  `tests/cpu/src/t_alu.S:82-88`).
- **CALL** writes its own address to r[15]. **A trap** writes PC and nPC
  to r[17] and r[18] (%l1, %l2) of the **new** window (V8 §4.1).
- **Doubleword register operands** use even/odd pairs. "An attempt to
  execute a doubleword load or store instruction that refers to a
  misaligned (odd) destination register number may cause an
  illegal_instruction trap" (V8 §4.1, §B.1, §B.4). QEMU traps
  illegal_instruction on LDD/STD with odd rd (`translate.c:4459-4466`,
  `:4476-4483`: decode returns false, which becomes `TT_ILL_INSN` at
  `translate.c:5749-5751`).
- **LDD with rd = 0 modifies only r[1]** (V8 §B.1). Test `t_ldd_std`
  checks 5-6: `ldd [..], %g0` leaves %g0 = 0, %g1 = the odd word
  (`tests/cpu/src/t_ldst.S:77-82`).
- **Locals and outs** are not guaranteed after a RESTORE followed by a
  SAVE with traps enabled. With traps disabled they remain valid
  (V8 §4.1 Programming Note).
- **Register file contents after reset:** uninitialized (Viking Table 4-1;
  the PROMs pass POST results in %g1-%g7 because the register file is not
  reset).

### 1.2 PSR (Processor State Register)

Layout (V8 Figure 4-3). Reset column: V8 guarantees only ET and S after a
reset trap (V8 §7.4 "Reset Trap", §7.6 "reset").

| Bits | Field | Behaviour | Value on SuperSPARC / after reset |
|---|---|---|---|
| 31:28 | impl | hardwired; WRPSR does not change it (V8 §4.2, §L.1) | **4** (TI) (V8 Table L-2; QEMU `cpu.c:480` `iu_version 0x40000000`; Viking §4.4.3) |
| 27:24 | ver | implementation-dependent, "must not be implemented as a general-purpose read/write field" (V8 §L.1) | **0** (QEMU `cpu.c:480`; Viking §4.4.3). SS-II Table A-51 gives the byte "PSR VER = 0x40" for SuperSPARC 3.x/4.x/5.x (`STP1021UG.txt:2346-2352`) |
| 23 | n | icc negative | QEMU reset 0 (`cpu.c:46` memset) |
| 22 | z | icc zero | " |
| 21 | v | icc overflow | " |
| 20 | c | icc carry (add carry-out of bit 31; sub borrow into bit 31) (V8 §4.2) | " |
| 19:14 | reserved | read as 0 (V8 §4.2) | 0 |
| 13 | EC | coprocessor enable. With no coprocessor, "should always read as 0 and writes to it should be ignored" (V8 §4.2). **Viking: a WRPSR that tries to set EC traps illegal_instruction** (Viking §4.4.3, §4.13.4.7). QEMU ignores the bit; it is not stored and reads 0 (`win_helper.c:57-62`, `:83-92`) | 0 (Viking Table 4-1: EC=0) |
| 12 | EF | FPU enable. Reads 0 and ignores writes if no FPU (V8 §4.2) | QEMU 0. The suite detects an FPU by "PSR.EF sticks" (`tests/cpu/src/runtime.S:104-117`) |
| 11:8 | PIL | interrupt level; the processor accepts IRL > PIL, or IRL = 15 (V8 §4.2, §7.3) | QEMU 0 |
| 7 | S | supervisor | **1** (V8 §7.4; Viking Table 4-1; QEMU `cpu.c:62`) |
| 6 | PS | S at the time of the most recent trap | QEMU 1 (`cpu.c:63`); V8 says nothing about it |
| 5 | ET | enable traps. A trap clears it | **0** (V8 §7.4; Viking Table 4-1; QEMU `cpu.c:61`) |
| 4:0 | CWP | current window | Viking: uninitialized (Table 4-1). QEMU 0 (`cpu.c:47`) |

- The PSR is modified by SAVE, RESTORE, Ticc, RETT, traps, every
  icc-setting instruction, and WRPSR (V8 §4.2).
- **RDPSR / WRPSR are privileged** (V8 §B.28, §B.29).
- **WRPSR writes `r[rs1] xor operand2`** (V8 §B.29).
- **WRPSR with result CWP ≥ NWINDOWS → illegal_instruction, and the PSR is
  not written** (V8 §B.29; ISP V8 §C.9 "Write State Register",
  `sparcv8.txt:8432-8475`; QEMU `win_helper.c:165-175`). Test
  `t_wrpsr_cwp` (`tests/cpu/src/t_iu2.S:182-197`; IU-5).
- **The PSR seen by the suite at start-up** (after `wr %g0, S|PS|PIL, %psr`
  and some code) is printed as `psr=40400fc0` in every SS20 log: impl 4,
  ver 0, Z = 1, EF = 0, PIL = 15, S = 1, PS = 1, ET = 0, CWP = 0
  (`tests/cpu/expected/ss20-qemu.log:1`, `ss20-core-hw.log:1`;
  `runtime.S:49`, `:83`).
- `t_psr_fields`: flipping impl/ver with WRPSR leaves them unchanged.
  PIL 15 → 5 → 15 is writable, and icc is writable through WRPSR
  (`tests/cpu/src/t_psr.S:5-25`).

### 1.3 WIM (Window Invalid Mask)

- One bit per implemented window. WIM[n] corresponds to CWP = n (V8 §4.2).
- SAVE, RESTORE and RETT trap (overflow/underflow) when the **new** CWP
  has WIM[new_CWP] = 1 (V8 §4.2, §B.20, §B.26).
- **Bits for unimplemented windows read as 0, and writes to them are
  ignored.** WRWIM with all ones followed by RDWIM gives exactly the
  implemented windows (V8 §4.2). QEMU masks the written value to
  `nwindows` bits (`translate.c:3456-3462`). The suite counts NWINDOWS
  this way (`runtime.S:84-97`: `wr %g0,-1,%wim; rd %wim` and count the
  ones).
- RDWIM / WRWIM are privileged. WRWIM writes `r[rs1] xor operand2`
  (V8 §B.28, §B.29).
- Reset: Viking: uninitialized (Table 4-1). QEMU: `wim = 1` (`cpu.c:49`).
  The suite writes 0 and then 2 (`runtime.S:51`, `:98`).

### 1.4 TBR (Trap Base Register)

- Fields (V8 Figure 4-6): **TBA = bits 31:12** (written by WRTBR),
  **tt = bits 11:4** (written by hardware on a trap, keeps its value until
  the next trap), **bits 3:0 = 0**.
- **"The WRTBR instruction does not affect the tt field"** (V8 §4.2). The
  ISP writes only `TBR<31:12> ← result<31:12>` (V8 §C.9,
  `sparcv8.txt:8471-8475`). Test `t_tbr` check 4: `wr %l2|0xff0, %tbr`
  leaves tt as it was (`tests/cpu/src/t_psr.S:27-44`). QEMU differs
  (README deviation 3: `do_wrtba` moves the whole value,
  `translate.c:3536-3539`).
- RDTBR and WRTBR are privileged (V8 §B.28, §B.29).
- A reset trap does **not** write tt. After power-up, tt is undefined
  (V8 §7.4 "Reset Trap"). In error mode, tt is written only when the trap
  comes from a RETT executed with ET = 0 (V8 §7.4 "Error Mode"; Viking
  §4.13.2).
- Trap vector = TBR itself: `TBA<31:12> | tt<11:4> | 0000`. Each trap-table
  entry holds 4 instructions (16 bytes) (V8 §7.4).

### 1.5 Y register

- 32 bits. It holds the high word of UMUL/SMUL(cc) products, the
  multiplier/product shift of MULScc, and the high word of the
  UDIV/SDIV(cc) dividend (V8 §4.2).
- RDY (not privileged) and WRY (not privileged; writes
  `r[rs1] xor operand2`) (V8 §B.28, §B.29). Test `t_y_register`: the
  xor semantics (`tests/cpu/src/t_alu.S:91-107`).
- **Divides and Y.** V8 says "software should assume that the contents of
  the Y register are not preserved by the divide instructions". Its
  implementation note *recommends* storing the remainder in Y (V8 §B.19).
  **The acceptance model keeps Y unchanged across UDIV/SDIV(cc), including
  the trapping case.** In `gen_alu.py:model()`, `yo = y` and no divide
  branch changes it (`tests/cpu/gen_alu.py:61`, `:110-130`), and
  `t_alu_vectors` compares Y (code `…+2`, `t_alu.S:44-47`). QEMU never
  writes Y on a divide (`helper.c:85-131`).

### 1.6 Ancillary State Registers (ASRs)

- V8: ASR 1-15 are reserved for the architecture, and ASR 16-31 are
  implementation-dependent (V8 §4.2). `op3 = 0x28` with `rs1 = 0` is RDY;
  with `rs1 ≠ 0` it is RDASR. `op3 = 0x30` with `rd = 0` is WRY; with
  `rd ≠ 0` it is WRASR (V8 §B.28, §B.29).
- **RDASR with rs1 = 15 and rd = 0 is STBAR.** RDASR with rs1 = 15 and
  rd ≠ 0 is reserved. RDASR with rs1 in 1..14 "produces undefined results,
  but does not cause an illegal_instruction trap" (V8 §B.28). WRASR with
  rd in 1..15 produces undefined results. "WRASR in new implementations
  must not write the Y register" (V8 §B.29).
- For ASR 16-31, the implementation decides privilege, the illegal_instruction
  trap and the meaning of the other fields (V8 §B.28, §B.29).
- **Pre-1991 implementations:** "None … implements any user or privileged
  ancillary state registers. A WRASR … acts as a WRY instruction; the rd
  field is ignored." "All five implementations treat … STBAR as a RDY with
  rd = 0" (V8 §L.3).
- **Viking (SuperSPARC) documented ASR encodings:** STBAR =
  `RDASR 0x0f, %g0` = `0x8143c000` (Viking §4.4.5). SIGM (signal
  emulation) = `RDASR 0x1f, %g0` = `0x8147c000`, which runs as a NOP unless
  the JTAG-only MCMD.INITM bit is set (Viking §4.4.6). The Viking document
  does not say what other RDASR/WRASR encodings do (see "Not established").
- **What the acceptance test requires (`t_rdasr`,
  `tests/cpu/src/t_iu2.S:199-233`; IU-6):** `rd %asr1`
  (`0xa1404000`), `rd %asr2` (`0xa3408000`) and `rd %asr15, %l2`
  (`0xa543c000`, rd ≠ 0) all **read Y** and do not trap.
  `wr %l4, %g0, %asr1` (`0x83850000`) **does not change Y** and does not
  trap. CASA (`0xe5e40171`, op3 0x3c) → **illegal_instruction**, and memory
  is unchanged. The test's comment cites the microSPARC-I/II manuals ("every
  ASR read acts as RDY and every ASR write as a NOP"), and OpenSSL's
  `wr %g0,%y; rd %asr2` V8/V9 probe (NetBSD `syslogd`/`login` get SIGILL
  if it traps).
- QEMU: RDASR with any rs1 except 15 reads Y (`insns.decode:113-130`,
  `RDY_v7`). ASR17 is LEON-only. Every `rs1 = 15` encoding is STBAR,
  whatever rd is, and bit 13 is ignored. Solaris 8 executes `0x8143e008`
  during boot (`insns.decode:111-120`). WRASR (`rd ≠ 0`) is a NOP with no
  privilege check (`insns.decode:150-157`, `translate.c:3711`). QEMU
  deviation 7 in the README: `rd %asr15` with rd ≠ 0 does not write rd.

### 1.7 PC / nPC

- PC = address of the instruction being executed. nPC = address of the
  next instruction, assuming no trap (V8 §4.2).
- Without a trap: PC ← nPC, nPC ← nPC + 4 (overflow ignored). A control
  transfer writes its target into nPC (V8 §5.1).
- During the delay instruction of a DCTI, PC points to the delay
  instruction and nPC to the CTI's target (V8 §4.2).

### 1.8 IU deferred-trap queue

- Optional. Its contents are implementation-dependent (V8 §4.2). "None of
  the existing implementations uses an Integer Deferred-Trap Queue"
  (V8 §L.3). No IU queue is described in the Viking document.

---

## 2. Instruction set

### 2.1 Formats and fields (V8 §5.2, Figure 5-1)

| Format | op (31:30) | Layout |
|---|---|---|
| 1 | 01 | CALL: `disp30` (29:0) |
| 2 | 00 | SETHI: `rd`(29:25) `op2`(24:22) `imm22`(21:0). Branches: `a`(29) `cond`(28:25) `op2`(24:22) `disp22`(21:0) |
| 3 | 10, 11 | `rd`(29:25) `op3`(24:19) `rs1`(18:14) `i`(13). If i = 0: `asi`(12:5) `rs2`(4:0). If i = 1: `simm13`(12:0). FPop/CPop: `opf`(13:5) `rs2`(4:0) |

- `simm13` is sign-extended to 32 bits. disp22/disp30 are word
  displacements: target = PC + 4 × sign_ext(disp) (V8 §5.2, §B.21, §B.24).
- **op2 map** (V8 Table 5-2/F-2): 0 UNIMP, 1 unimplemented, 2 Bicc,
  3 unimplemented, 4 SETHI (NOP when rd = 0 and imm22 = 0), 5 unimplemented,
  6 FBfcc, 7 CBccc.
- **Unused patterns** in the op, op2, op3, opf and i fields cause
  illegal_instruction. Other fields defined as unused are ignored and do
  not trap (V8 §C.6). See the QEMU notes in §7.3 for reserved fields QEMU
  does trap on.

### 2.2 op = 2 opcode map (V8 Table F-3)

| op3 | 0x0_ | 0x1_ (cc) | 0x2_ | 0x3_ |
|---|---|---|---|---|
| x0 | ADD | ADDcc | TADDcc | WRY (rd=0) / WRASR (rd≠0) |
| x1 | AND | ANDcc | TSUBcc | WRPSR |
| x2 | OR | ORcc | TADDccTV | WRWIM |
| x3 | XOR | XORcc | TSUBccTV | WRTBR |
| x4 | SUB | SUBcc | MULScc | FPop1 |
| x5 | ANDN | ANDNcc | SLL | FPop2 |
| x6 | ORN | ORNcc | SRL | CPop1 |
| x7 | XNOR | XNORcc | SRA | CPop2 |
| x8 | ADDX | ADDXcc | RDY (rs1=0) / RDASR (rs1≠0) / STBAR (rs1=15, rd=0) | JMPL |
| x9 | — | — | RDPSR | RETT |
| xA | UMUL | UMULcc | RDWIM | Ticc |
| xB | SMUL | SMULcc | RDTBR | FLUSH |
| xC | SUBX | SUBXcc | — | SAVE |
| xD | — | — | — | RESTORE |
| xE | UDIV | UDIVcc | — | — |
| xF | SDIV | SDIVcc | — | — |

"—" = unassigned → illegal_instruction (V8 §C.6). Test `t_illegal` uses
op=2 op3=0x09 (V9 MULX) (`tests/cpu/src/t_traps.S:30-33`).

### 2.3 op = 3 opcode map (V8 Table F-4)

| op3 | 0x0_ | 0x1_ (alternate, privileged) | 0x2_ (FP) | 0x3_ (CP) |
|---|---|---|---|---|
| x0 | LD | LDA | LDF | LDC |
| x1 | LDUB | LDUBA | LDFSR | LDCSR |
| x2 | LDUH | LDUHA | — | — |
| x3 | LDD | LDDA | LDDF | LDDC |
| x4 | ST | STA | STF | STC |
| x5 | STB | STBA | STFSR | STCSR |
| x6 | STH | STHA | STDFQ (privileged) | STDCQ (privileged) |
| x7 | STD | STDA | STDF | STDC |
| x8 | — | — | — | — |
| x9 | LDSB | LDSBA | — | — |
| xA | LDSH | LDSHA | — | — |
| xB-xC | — | — | — | — (0x3C = V9 CASA: illegal_instruction, `t_rdasr` check 6) |
| xD | LDSTUB | LDSTUBA | — | — |
| xE | — | — | — | — |
| xF | SWAP | SWAPA | — | — |

Test `t_illegal`: op=3 op3=0x08 → illegal_instruction
(`tests/cpu/src/t_traps.S:34-37`).

### 2.4 Condition codes (V8 Table F-7, §B.21, §B.27)

The same `cond` encoding is used by Bicc (op2 = 2) and by Ticc
(op3 = 0x3A):

| cond | Bicc | Ticc | true when |
|---|---|---|---|
| 0 | BN | TN | never |
| 1 | BE | TE | Z |
| 2 | BLE | TLE | Z or (N xor V) |
| 3 | BL | TL | N xor V |
| 4 | BLEU | TLEU | C or Z |
| 5 | BCS (BLU) | TCS | C |
| 6 | BNEG | TNEG | N |
| 7 | BVS | TVS | V |
| 8 | BA | TA | always |
| 9 | BNE | TNE | not Z |
| A | BG | TG | not (Z or (N xor V)) |
| B | BGE | TGE | not (N xor V) |
| C | BGU | TGU | not (C or Z) |
| D | BCC (BGEU) | TCC | not C |
| E | BPOS | TPOS | not N |
| F | BVC | TVC | not V |

The suite's model of this table is `gen_alu.py:265-291`. `t_bicc_conds`
and `t_ticc_conds` check all 16 conditions against all 16 icc values.

### 2.5 Integer ALU instructions

The operand is `op2 = (i ? sign_ext(simm13) : r[rs2])`. Every row is
format 3, op = 2, not privileged, not delayed. The table shows each
instruction's icc rule. The flag formulas below are the acceptance model
(`gen_alu.py:39-149`), and they match V8 §B.11-§B.19.

Flag formulas (a = rs1 operand, b = operand2, r = 32-bit result, bit 31 taken):
- `add_flags`: V = (a & b & ~r) | (~a & ~b & r); C = (a & b) | (~r & (a | b))
  (`gen_alu.py:43-46`).
- `sub_flags`: V = (a & ~b & ~r) | (~a & b & r); C = (~a & b) | (~(a ^ b) & r)
  (`gen_alu.py:49-52`).
- N = r[31]. Z = (r == 0).

| Mnemonic | op3 | Computes | icc (cc form) | Y | Traps |
|---|---|---|---|---|---|
| ADD / ADDcc | 0x00 / 0x10 | a + b | N Z from r; V C by add_flags | — | none |
| ADDX / ADDXcc | 0x08 / 0x18 | a + b + C(psr) | add_flags(a, b, r) with r including the carry-in | — | none |
| SUB / SUBcc | 0x04 / 0x14 | a − b | sub_flags | — | none |
| SUBX / SUBXcc | 0x0C / 0x1C | a − b − C | sub_flags(a, b, r) | — | none |
| AND / ANDcc | 0x01 / 0x11 | a & b | N Z; V = 0; C = 0 | — | none |
| ANDN / ANDNcc | 0x05 / 0x15 | a & ~b | same | — | none |
| OR / ORcc | 0x02 / 0x12 | a \| b | same | — | none |
| ORN / ORNcc | 0x06 / 0x16 | a \| ~b | same | — | none |
| XOR / XORcc | 0x03 / 0x13 | a ^ b | same | — | none |
| XNOR / XNORcc | 0x07 / 0x17 | ~(a ^ b) | same | — | none |
| SLL | 0x25 | a << cnt | unchanged | — | none |
| SRL | 0x26 | a >> cnt (zero fill) | unchanged | — | none |
| SRA | 0x27 | a >> cnt (sign fill) | unchanged | — | none |
| SETHI | op=0 op2=4 | rd ← imm22 << 10 | unchanged | — | none |
| UMUL / UMULcc | 0x0A / 0x1A | {Y, rd} ← a × b (unsigned 64-bit product) | N = r[31], Z = (r[31:0] == 0); V = 0; C = 0 | Y ← product[63:32] | none |
| SMUL / SMULcc | 0x0B / 0x1B | {Y, rd} ← a × b (signed) | same as UMULcc | Y ← product[63:32] | none |
| MULScc | 0x24 | see §2.6 | add_flags of the step add | Y ← (a[0] << 31) \| (Y >> 1) | none |
| UDIV / UDIVcc | 0x0E / 0x1E | ({Y, a}) ÷ b unsigned, saturating | N Z of the quotient after saturation; V = overflow; C = 0 | unchanged (§1.5) | division_by_zero |
| SDIV / SDIVcc | 0x0F / 0x1F | ({Y, a}) ÷ b signed, truncating, saturating | same; V = overflow | unchanged | division_by_zero |
| TADDcc | 0x20 | a + b | add_flags; **V also set if (a \| b) & 3 ≠ 0** | — | none |
| TSUBcc | 0x21 | a − b | sub_flags; V also set if tag bits ≠ 0 | — | none |
| TADDccTV | 0x22 | a + b | as TADDcc when it does not trap (then V = 0) | — | **tag_overflow** if tag bits ≠ 0 or arithmetic overflow; then rd and icc unchanged |
| TSUBccTV | 0x23 | a − b | as TSUBcc when no trap | — | **tag_overflow**, rd and icc unchanged |

Notes:
- **Shift count** = r[rs2][4:0] when i = 0, so the upper 27 bits are
  ignored. When i = 1 it is `shcnt` = bits 4:0, and **bits 12:5 are
  reserved and "should be supplied as zero"** (V8 §B.12). The model uses
  `b & 31` (`gen_alu.py:98-103`). Its vectors include counts 32, 33, 63 and
  `0xffffffe1` (`gen_alu.py:169`).
- UMULcc/SMULcc V and C: V8 marks them "Zero †", which "may change in a
  future revision; software should not test" them (V8 §B.18). The model
  sets V = C = 0 (`gen_alu.py:141-145`). QEMU does the same through
  `do_logic` (`translate.c:3767`, `:3791-3792`).
- **UDIV overflow:** the quotient does not fit in 32 bits → rd =
  `0xffffffff`, V = 1 (V8 §B.19 table; ISP `temp_V = (q<63:32> ≠ 0)`,
  V8 §C.9). The model: `q > M → (M, 1)` (`gen_alu.py:110-114`). QEMU:
  `helper.c:85-101`.
- **SDIV overflow:** positive overflow → `0x7fffffff`; negative overflow →
  `0x80000000`; V = 1 (V8 §B.19). V8 allows two detection methods for a
  negative result: [A] strict truncation, or [B] an exception for the
  maximum negative quotient. The choice is implementation-dependent but
  must be consistent. The ISP uses "no overflow iff `temp_64bit<63:31>` is
  all 0s or all 1s" (V8 §C.9, `sparcv8.txt:7494+614..632`). The model
  truncates toward zero and overflows iff the truncated quotient is outside
  [−2^31, 2^31−1] (`gen_alu.py:115-130`). That is method [A], and QEMU's
  current source matches it (`helper.c:103-131`: overflow if `r != a64`
  after truncating division).
- **SDIV rounding:** toward zero; for example −3 ÷ 2 = −1 remainder −1
  (V8 §B.19).
- **Division by zero** (operand2 = 0) → `division_by_zero` (tt 0x2A). rd,
  icc and Y are unchanged (`gen_alu.py:111-112`, `:116-117`; test
  `t_div_zero`: `udiv %l0, %g0, %l1` leaves `%l1 = 0x77`,
  `tests/cpu/src/t_traps.S:92-104`).
- **UDIVcc/SDIVcc N and Z** are taken from the quotient *after*
  saturation (V8 §B.19).
- **Tagged ops:** a tag_overflow trap of TADDccTV/TSUBccTV leaves "r[rd]
  and the condition codes … unchanged" (V8 §B.14, §B.16; model
  `gen_alu.py:72-73`). QEMU checks the tag bits first, then the
  arithmetic overflow (`helper.c:133-203`). Test `t_tag_overflow`:
  `taddcctv 1,4` traps and leaves `%l2 = 0x55`; `taddcctv 4,4 = 8` does
  not trap; `0x7ffffffc + 4` traps; `tsubcctv 4,2` traps
  (`tests/cpu/src/t_traps.S:106-125`).
- **Trapping vectors in the model:** "the destination register and the icc
  stay as the stub prelude left them" (`gen_alu.py:13-15`). The stub runs
  `op %o0, %o1, %o0`, so for a trapping vector rd keeps operand a
  (`gen_alu.py:224-225`).
- **The model's input icc:** the stub prelude does `subcc %g0, %o3, %g0`,
  which gives C = N = cin, Z = !cin, V = 0. So N xor V = cin, the
  MULScc input (`gen_alu.py:17-19`, `:57-58`).
- **The ALU vector count is 3748**, over every op above, in register and
  immediate forms (`tests/cpu/README.md:69`).

### 2.6 MULScc (op3 0x24) (V8 §B.17)

1. operand2 = r[rs2] (i = 0) or sign_ext(simm13) (i = 1).
2. op1 = (N xor V) << 31 | (r[rs1] >> 1).
3. If Y[0] = 1, op1 + operand2 is computed; otherwise op1 + 0.
4. The sum goes to r[rd].
5. icc is set by that addition (an ADDcc).
6. Y ← (r[rs1][0] << 31) | (Y >> 1), using the **unshifted** r[rs1].

The model is `gen_alu.py:131-138`. QEMU: `translate.c:525-560`
(`gen_op_mulscc`). MULScc always sets icc. V8 lists no traps.

### 2.7 Loads and stores (format 3, op = 3)

Address = r[rs1] + (i ? sign_ext(simm13) : r[rs2]) (V8 §B.1-§B.8).
Big-endian: a byte at addr[1:0] = 0 is bits 31:24 of the word, and the
word at addr[2:0] = 0 of a doubleword is its more significant half
(V8 §5.3 "Addressing Conventions"). Normal (non-alternate) data accesses
use ASI 0x0A when S = 0 and 0x0B when S = 1. Instruction fetches use 0x08
when S = 0 and 0x09 when S = 1 (V8 §5.3 Table 5-3; ISP §C.5:
`addr_space := if (S = 0) then 8 else 9`).

| Mnemonic | op3 | Size | Result | Alignment trap if | Priv. | Traps (V8 list) |
|---|---|---|---|---|---|---|
| LDSB / LDSBA | 0x09 / 0x19 | 8 | sign-extended | never | A only | illegal_instruction (A with i=1); privileged_instruction (A); data_access_exception; data_access_error |
| LDUB / LDUBA | 0x01 / 0x11 | 8 | zero-extended | never | A only | same |
| LDSH / LDSHA | 0x0A / 0x1A | 16 | sign-extended | addr[0] ≠ 0 | A only | + mem_address_not_aligned |
| LDUH / LDUHA | 0x02 / 0x12 | 16 | zero-extended | addr[0] ≠ 0 | A only | same |
| LD / LDA | 0x00 / 0x10 | 32 | word | addr[1:0] ≠ 0 | A only | same |
| LDD / LDDA | 0x03 / 0x13 | 64 | r[rd&~1] ← word at EA, r[rd\|1] ← word at EA+4 | addr[2:0] ≠ 0 | A only | + illegal_instruction (odd rd) |
| STB / STBA | 0x05 / 0x15 | 8 | stores r[rd][7:0] | never | A only | illegal (A, i=1); privileged (A); data_access_exception; data_access_error; data_store_error |
| STH / STHA | 0x06 / 0x16 | 16 | r[rd][15:0] | addr[0] ≠ 0 | A only | + mem_address_not_aligned |
| ST / STA | 0x04 / 0x14 | 32 | r[rd] | addr[1:0] ≠ 0 | A only | same |
| STD / STDA | 0x07 / 0x17 | 64 | even reg → EA, odd → EA+4 | addr[2:0] ≠ 0 | A only | + illegal_instruction (odd rd) |
| LDSTUB / LDSTUBA | 0x0D / 0x1D | 8 | rd ← byte; byte ← 0xFF atomically | never | A only | illegal (A, i=1); privileged (A); data_access_exception; data_access_error; data_store_error |
| SWAP / SWAPA | 0x0F / 0x1F | 32 | rd ↔ word atomically | addr[1:0] ≠ 0 | A only | + mem_address_not_aligned |

Rules:
- **Alternate-space forms need i = 0; i = 1 → illegal_instruction.** They
  are privileged; executing one with S = 0 → privileged_instruction
  (V8 §B.1, §B.4, §B.7, §B.8). Table 7-1 puts privileged_instruction
  (priority 6) above illegal_instruction (7). QEMU checks `i = 1` first
  and raises illegal_instruction (`translate.c:1556-1562`), then
  privilege (`:1563-1606`).
- **A misaligned access writes nothing.** Test `t_align_traps`: a
  misaligned `ld` leaves rd unchanged (check 2) and a misaligned `st`
  leaves memory unchanged (check 6). The saved trap PC is the faulting
  instruction (check 10). LDUH +1, LDD +4, STH +3, STD +4 and SWAP +2 all
  trap. Aligned LDUB/LDUH/LD/LDD do not (`tests/cpu/src/t_ldst.S:122-175`).
- **Atomicity:** LDSTUB and SWAP are performed "without allowing
  intervening interrupts or deferred traps". Concurrent LDSTUB/SWAP to the
  same byte/word on several processors execute in an undefined but serial
  order (V8 §B.7, §B.8). See §5.
- **LDSTUB is a store for the MMU** (SFSR AT 4 through the bypass:
  `tests/cpu/src/t_buserr.S:17-21`).
- **A second-word fault in LDD/STD/LDSTUB/SWAP** may be an interrupting
  trap after the first access changed state ("non-resumable
  machine-check"; V8 §7.2 case 3; §B.1, §B.4, §B.7, §B.8 implementation
  notes). Viking: for an exception on either access of an atomic, "the
  destination register will not be updated" (Viking §4.5.2).
- **Byte/halfword stores merge into the word** (test `t_st_widths`,
  `t_ldst.S:39-61`). Sign/zero extension and byte order are tested by
  `t_ld_widths` (`t_ldst.S:5-37`, including `[reg + reg]` addressing).
- **`t_atomics`** (`t_ldst.S:84-99`): `ldstub [x+1]` on `0x12345678`
  returns `0x34`, memory becomes `0x12ff5678`, and a second ldstub returns
  `0xff`. `swap` exchanges the whole word.
- **`t_alt_space`** (`t_ldst.S:101-120`): `sta`/`lda`/`lduba`/`ldsha` with
  ASI 0x0B read and write the same memory as plain ld/st. On non-SS20
  targets ASI 0x20 (bypass) reads it too.

### 2.8 ASIs the tests and the PROMs use (SS20)

The IU passes the 8-bit ASI with each data access. V8 defines only
0x08-0x0B (V8 §5.3 Table 5-3). The rest are listed as "suggested" in
V8 Appendix I. Viking decodes all 8 bits, and an access to a reserved value
is an error (data_access_exception with MFSR.CS) (Viking §4.16,
§4.11.11.3). All 8 bits matter: 0x4C must not alias the 0x0C I-cache
tag (MMU-12; test `t_asi_width`).

| ASI | Use on the SS20 (SuperSPARC, MBus mode, no MXCC) | Source / user |
|---|---|---|
| 0x02 | MXCC registers / control space. With no MXCC (MCNTL.MB = 1), OBP takes only its SuperSPARC-II banner path through it | QEMU `ldst_helper.c:596-657`; `hardware-access.md` §4 |
| 0x03 | SRMMU flush (sta) / probe (lda) | V8 Table I-1; Viking Table 4-19; `t_mmu*` |
| 0x04 | SRMMU registers, VA[12:8] selects (see §6.3) | Viking §4.11.11; runtime.S:39 (MCNTL read) |
| 0x05 | I-TLB diagnostic (SuperSPARC-II only); Viking: reserved | SS-II A.4.3.3; Viking Table 4-19 |
| 0x06 | TLB diagnostic (64-entry image, MMU-2) | Viking Table 4-19; `t_mmu_diag` |
| 0x08 / 0x09 | user / supervisor instruction space (0x09 reads the PROM in boot mode) | V8 Table 5-3; `hardware-access.md` |
| 0x0A / 0x0B | user / supervisor data | V8 Table 5-3; `t_alt_space` |
| 0x0C-0x0F | I-cache tag / data, D-cache tag / data (Viking: doubleword accesses) | Viking Table 4-19; PLAN A4; `t_asi_width`, `t_cache_diag` |
| 0x10-0x14 | flush cache line (page/segment/region/context/user). **Viking Table 4-19 lists 0x10-0x1F as reserved.** The suite and OBP use 0x10 on the SS20, and QEMU accepts 0x10-0x14 stores as no-ops | `tests/cpu` (14 uses of 0x10, `t_cache2.S`); `ldst_helper.c:1058-1062`; OBP `hardware-access.md` |
| 0x20-0x2F | MMU bypass: PA[35:32] = ASI[3:0] (0x20 memory, 0x2E SBus, 0x2F control space) | V8 Table I-1; Viking §4.5.3; `platform.h:25-38` (IO_ASI 0x2F on the SS20) |
| 0x30-0x32 | store-buffer tags / data / control | Viking Table 4-19; OBP `obp_cache_init_viking` |
| 0x36 / 0x37 | I-cache / D-cache flash clear (store only) | Viking Table 4-19; `t_cache2` |
| 0x38 | MMU breakpoint registers: VA 0x000/0x100/0x200/0x300, **64-bit** (OBP 2.25 keeps the MID at VA 0) | Viking Table 4-19 ("double"); QEMU `ldst_helper.c:736-758`, `:1104-1127`; `t_asi_width` checks 2-5 (SMP-1) |
| 0x39 | BIST diagnostics | Viking Table 4-19 |
| 0x40-0x4B | emulation temporaries/data, counters (SuperSPARC); counters (SuperSPARC-II) | Viking Table 4-19; SS-II Table A-39 |
| 0x4C | ACTION register (breakpoint action). Writes must read back (Solaris 8 writes 0x1000 and polls). QEMU keeps 13 bits | Viking Table 4-19; QEMU `ldst_helper.c:768`, `:1137`; `t_asi_width` checks 1, 6-8 |

- QEMU (sparc32): alternate space in user mode → privileged_instruction.
  With i = 1 → illegal_instruction (`translate.c:1556-1606`). An ASI QEMU
  does not handle → `sparc_raise_mmu_fault` (`ldst_helper.c:771-773`,
  `:1084-1092`).
- **Viking restrictions:** LDSTUBA/SWAPA to an ASI other than 0x08-0x0B and
  0x20-0x2F → data_access_exception. An access whose size differs from
  Table 4-19 → data_access_exception (Viking §4.5.2.3, notes under
  Table 4-19).
- **Viking ASI ordering:** every ASI access is synchronous. The store buffer
  is drained before it, except for ASIs 0x20-0x2F and 0x0A-0x0B
  (Viking §4.5.3).

### 2.9 Control-transfer and trap instructions

| Mnemonic | Encoding | Operation | Traps | Priv. | Delayed |
|---|---|---|---|---|---|
| Bicc | op=0 op2=2, `a`, `cond`, disp22 | if cond: nPC ← PC + 4·sext(disp22). Annul rules in §3.2 | none | no | yes (conditional-delayed) |
| FBfcc | op=0 op2=6 | as Bicc on fcc. **With EF = 0 or no FPU: does not branch, does not annul, traps fp_disabled** | fp_disabled, fp_exception | no | yes |
| CBccc | op=0 op2=7 | as Bicc on CP cc. **With EC = 0 or no CP: no branch, no annul, cp_disabled** | cp_disabled, cp_exception | no | yes |
| CALL | op=1 disp30 | r[15] ← PC; nPC ← PC + 4·disp30 | none | no | yes |
| JMPL | op=2 op3=0x38 | target = r[rs1] + op2. Misaligned target (bits 1:0 ≠ 0) → trap, rd not written. Else rd ← PC; nPC ← target | mem_address_not_aligned | no | yes |
| RETT | op=2 op3=0x39, rd field unused (zero) | §3.5 | illegal_instruction, privileged_instruction, error mode | **yes** | yes |
| Ticc | op=2 op3=0x3A, `cond` 28:25, bit 29 reserved; i=1: imm7 (bits 6:0), bits 12:7 reserved | if cond: trap with tt = 0x80 + ((r[rs1] + op2) & 0x7F); else NOP | trap_instruction | no | **no** (non-delayed) |

(V8 §B.21-§B.27; ISP §C.9.) Test `t_ticc_tt`: `ta 0x10` gives tt 0x90,
trap PC = the `ta`, nPC = PC + 4. `ta %l2 + 0x0a` with `%l2 = 0x75` gives
tt 0xFF. `ta %l2` with `%l2 = 0x81` gives tt 0x81 (0x81 & 0x7F = 1)
(`tests/cpu/src/t_traps.S:5-24`). QEMU masks with `V8_TRAP_MASK 0x7f`
(`translate.c:208`, `:2775-2826`). A Ticc's trap has priority 16, below
all exceptions and above interrupts (V8 Table 7-1, §B.27).

### 2.10 State-register instructions

| Mnemonic | Encoding | Operation | Traps | Priv. |
|---|---|---|---|---|
| RDY | op3=0x28 rs1=0 | rd ← Y | none | no |
| RDASR | op3=0x28 rs1≠0 (≠15 or rd≠0) | §1.6 | privileged / illegal per implementation | impl.-dep. |
| STBAR | op3=0x28 rs1=15 rd=0 (Viking `0x8143c000`) | store barrier (§5) | none | no |
| RDPSR | op3=0x29 | rd ← PSR | privileged_instruction | yes |
| RDWIM | op3=0x2A | rd ← WIM | privileged_instruction | yes |
| RDTBR | op3=0x2B | rd ← TBR | privileged_instruction | yes |
| WRY | op3=0x30 rd=0 | Y ← r[rs1] ^ op2 | none | no |
| WRASR | op3=0x30 rd≠0 | §1.6 (test: no effect, no trap) | impl.-dep. | impl.-dep. |
| WRPSR | op3=0x31 | PSR ← r[rs1] ^ op2 (impl/ver/reserved unchanged) | privileged_instruction; illegal_instruction if result CWP ≥ NWINDOWS (PSR not written) | yes |
| WRWIM | op3=0x32 | WIM ← r[rs1] ^ op2 (implemented bits only) | privileged_instruction | yes |
| WRTBR | op3=0x33 | TBA ← (r[rs1] ^ op2)[31:12]; tt unchanged | privileged_instruction | yes |

(V8 §B.28, §B.29, §C.9.) The privilege check comes before the CWP check
in the WRPSR ISP (V8 §C.9).

**Delayed writes (V8 §B.29):**
1. WRY, WRPSR, WRWIM and WRTBR "may take until completion of the third
   instruction following the write instruction to consummate their write
   operation". The number of delay instructions (0 to 3) is
   implementation-dependent.
2. If one of the three following instructions writes a field of the same
   register, the field is undefined. The exception is a repeat of the same
   WR instruction, which writes as intended.
3. If one of the three following instructions reads a changed field, the
   value read is undefined. Implicit readers: CWP is read by every windowed
   register access, CALL, SAVE, RESTORE, RETT and traps. icc is read by
   Bicc and Ticc. WIM is read by SAVE, RESTORE and RETT. Y is read by
   MULScc, RDY, SDIV(cc) and UDIV(cc).
4. A trap in the three instructions after a WRPSR may see the old or the
   new S and CWP.
5. A trap in the three instructions after a WRTBR may use the old or the
   new TBA.
6. A RD in a trap handler after such a trap sees the new value.
7. "WRPSR appears to write the ET and PIL fields immediately with respect
   to interrupts." In some implementations, a WRPSR that changes PIL and
   sets ET = 1 at the same time may take an interrupt at the old PIL.
   V8's programming note recommends two WRPSRs (ET = 0 with the new PIL,
   then ET = 1).
- The ISP models the delay with a 4-deep chain per register (`PSR'…PSR''''`,
  shifted once per instruction; V8 §C.5).
- Viking: "A three instruction (not cycle) delay is required between
  changing any PSR fields, and using the contents" (Viking §4.4.3).
- QEMU applies writes at once (0 delay). WRPSR also ends the translation
  block (`translate.c:3448-3452`).
- **Every write in the suite is followed by 3 nops** (`runtime.S:49-55`;
  `t_psr.S`; `t_iu2.S:217` "the WRY delay, were it one"; ALU stubs
  `gen_alu.py:224`).

### 2.11 Window instructions

| Mnemonic | op3 | Operation | Traps |
|---|---|---|---|
| SAVE | 0x3C | new_CWP = (CWP − 1) mod N. If WIM[new_CWP]: window_overflow. Else sum ← r[rs1] + op2 (old window), CWP ← new_CWP, r[rd] ← sum (new window) | window_overflow |
| RESTORE | 0x3D | new_CWP = (CWP + 1) mod N. If WIM[new_CWP]: window_underflow. Else as SAVE, with rd in the new window | window_underflow |

(V8 §B.20; ISP §C.9.) **If the instruction traps, the ADD is not performed
and rd is not written.** Handlers re-execute it (V8 §B.20 Programming
Note). QEMU: `win_helper.c:143-163`. Tests: `t_window_basic` check 4 (SAVE
decrements CWP by 1 mod NWINDOWS) and check 5 (`save %o0,5,%o3` writes the
new %o3; `restore %i2,1,%o4` writes the old window's %o4)
(`tests/cpu/src/t_window.S:43-70`). The trap entry itself decrements CWP
**without** a WIM check (V8 §7.5).

### 2.12 Miscellaneous

| Mnemonic | Encoding | Operation | Traps |
|---|---|---|---|
| NOP | `0x01000000` (SETHI 0, %g0) | nothing | none |
| UNIMP | op=0 op2=0, const22 ignored | — | **illegal_instruction** (V8 §B.31; `t_illegal` check 1 `unimp 0x1234`) |
| FLUSH | op=2 op3=0x3B, rd unused | makes the doubleword at the address coherent for instruction fetch; complete within 5 instructions; not privileged | unimplemented_FLUSH or illegal_instruction (implementation-dependent) (V8 §B.32) |
| STBAR | see §2.10 | | none |

- FLUSH ignores address bits 1:0, and "bit 2 of the address is ignored"
  (V8 §B.32).
- Viking FLUSH flushes no cache explicitly (coherence is used). It drains
  the store buffer and clears the pipeline and instruction buffer, and it
  affects only the executing processor (Viking §4.4.4). Viking implements
  no unimplemented_FLUSH trap (Viking Table 4-15). QEMU decodes FLUSH as a
  NOP (`insns.decode:307-308`).
- The suite's `t_selfmod` patches cacheable code, FLUSHes and runs it
  (`README.md:81`; phase 3 test).

### 2.13 Coprocessor instructions (no coprocessor on the SS20)

- CPop1 (op3 0x36), CPop2 (0x37), CBccc (op2 7) and LDC/LDCSR/LDDC/STC/
  STCSR/STDCQ/STDC (op=3, op3 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37)
  → **cp_disabled (tt 0x24)** when EC = 0 or no coprocessor is present
  (V8 §B.3, §B.6, §B.23, §B.34, §C.6). Viking never sets EC and never
  raises cp_exception (Viking §4.13.4.7).
- **They trap in user mode too, and the store forms leave memory
  unchanged** (test `t_cp_ldst`, `tests/cpu/src/t_iu2.S:135-180`;
  IU-3). STDCQ is listed as privileged (V8 §B.6). `t_cp_ldst` expects
  cp_disabled for STDCQ in supervisor mode (check 6). Its only user-mode
  case is STC (check 10).
  - Table 7-1 puts privileged_instruction (6) above cp_disabled (8). The
    suite does not test STDCQ in user mode, so it does not resolve that
    ordering.
- `t_cp_disabled`: CPop1 `0x81b00000` and `cb1` → tt 0x24
  (`tests/cpu/src/t_traps.S:147-155`).
- QEMU: every one of these encodings is `NCP` → `TT_NCP_INSN` (0x24)
  (`insns.decode:19`, `:576`, `:593`, `:702-735`; `translate.c:2748-2760`).

### 2.14 Floating-point instructions: what the IU must do

- FPop1 = op3 0x34 and FPop2 = op3 0x35, with the operation in `opf`.
  FPop1 opf values: 0x01 FMOVs, 0x05 FNEGs, 0x09 FABSs, 0x29/0x2A/0x2B FSQRT
  s/d/q, 0x41-0x43 FADD, 0x45-0x47 FSUB, 0x49-0x4B FMUL, 0x4D-0x4F FDIV,
  0x69 FsMULd, 0x6E FdMULq, 0xC4 FiTOs, 0xC6 FdTOs, 0xC7 FqTOs, 0xC8 FiTOd,
  0xC9 FsTOd, 0xCB FqTOd, 0xCC FiTOq, 0xCD FsTOq, 0xCE FdTOq, 0xD1 FsTOi,
  0xD2 FdTOi, 0xD3 FqTOi. FPop2: 0x51-0x53 FCMP s/d/q, 0x55-0x57 FCMPE
  (V8 Tables F-5, F-6).
- FP loads and stores: LDF 0x20, LDFSR 0x21, LDDF 0x23, STF 0x24,
  STFSR 0x25, STDFQ 0x26 (privileged), STDF 0x27 (V8 Table F-4).
- **fp_disabled (tt 0x04)** for any FPop, FBfcc, or FP load/store when
  PSR.EF = 0 or no FPU is present (V8 §5.3, §7.6, §B.2, §B.5, §B.22,
  §B.33, §C.6). Test `t_fp_disabled`: `fmovs`, `ld [..], %f2` and `fbne`
  each trap 0x04 (`tests/cpu/src/t_traps.S:127-145`). On Viking the
  integer MUL/DIV, which run in the FPU, never raise fp_disabled
  (Viking §4.13.4.6).
- **Unimplemented FPop** → fp_exception with ftt = unimplemented_FPop, not
  illegal_instruction (V8 §7.6 "illegal_instruction" note). SuperSPARC has
  no quad precision (SS-II A.3.4.2; Viking §4.6.2.5).
- **Deferred fp_exception (tt 0x08, priority 11):**
  - An outstanding exception is taken when the next FP instruction (FPop,
    FP load/store including STFSR, FBfcc) is attempted (V8 §7.2
    implementation note).
  - V8 §L.3 describes 3 FPU states: fp_execute → fp_exception_pending (an
    FPop raises an exception) → fp_exception (the IU tries any FP
    instruction; the FQ is loaded and the trap taken). In fp_exception
    state only FP stores run (STDFQ, STFSR). An FPop, FP load or FBfcc
    there → back to pending with ftt = sequence_error, and that instruction
    is not queued. STDFQ that empties the FQ → fp_execute.
  - QEMU models a precise FPU plus the exception state (`translate.c:1489-1512`;
    `int32_helper.c:136-160`).
- **Trap priority with a pending fp_exception:** mem_address_not_aligned
  (10) is taken before fp_exception (11). A misaligned FP store with an
  exception pending takes tt 7, memory is not written, and the exception
  stays pending until the next FP instruction (V8 Table 7-1; FPU-1;
  test `t_fpu_trap_prio`, `tests/cpu/src/t_iu2.S:20-74`).
  fp_disabled (8) is above mem_address_not_aligned (10) (V8 Table 7-1).
- **FQ and STDFQ:**
  - STDFQ stores the front entry, address at EA and instruction at EA + 4,
    then advances the queue. FSR.qne (bit 13) shows whether entries remain
    (V8 §4.4, §L.3).
  - STDFQ with qne = 0 "should cause" fp_exception with ftt = 4
    (sequence_error) (V8 §B.5). STDFQ is privileged (V8 §B.5).
  - Viking's FQ has 4 entries (Viking §4.6.3). QEMU's has 1 (`fq.s`,
    `int32_helper.c:151-157`).
  - Test `t_fpu_fq`: after the trap, qne = 1. STDFQ stores the fdivs'
    address and opcode, then qne = 0. STDFQ in user mode → tt 3. STDFQ on
    an empty queue → fp_exception, ftt 4 (`tests/cpu/src/t_iu2.S:76-133`).
- **FSR identification:** FSR.ver = 0 on SuperSPARC (QEMU `cpu.c:481`;
  SS-II A.3.4.1 and Table A-51).

---

## 3. Control transfer

### 3.1 PC/nPC update (V8 §5.1, ISP §C.5)

- Non-CTI, no trap: PC ← nPC; nPC ← nPC + 4.
- CALL/JMPL/RETT/Bicc/FBfcc/CBccc set PC ← nPC and nPC ← target (or
  nPC + 4 when untaken) themselves. Ticc either traps or acts as a NOP
  (ISP §C.9).
- An annulled instruction: `annul ← 0; PC ← nPC; nPC ← nPC + 4`, and the
  instruction is not dispatched (ISP §C.5).
- In the ISP, the processor checks interrupts and traps before fetching
  each instruction (V8 §C.5).

### 3.2 Annul rules (V8 Table 5-6, §B.21; ISP §C.9 Bicc)

| a | Branch | Delay instruction |
|---|---|---|
| 0 | conditional, taken | executed |
| 0 | conditional, untaken | executed |
| 0 | BA | executed |
| 0 | BN | executed (BN acts as a NOP) |
| 1 | conditional, taken | **executed** |
| 1 | conditional, untaken | annulled |
| 1 | BA | annulled (control goes straight to the target) |
| 1 | BN | annulled |

- ISP form: `PC ← nPC`. If the condition is true: `nPC ← PC + 4·disp`,
  and `annul ← 1` only for BA with a = 1. If false: `nPC ← nPC + 4`, and
  `annul ← 1` if a = 1 (V8 §C.9). The `PC` in the target formula is the
  branch's own address.
- An annulled delay instruction behaves like a NOP (V8 §5.3).
- **"A Bicc should not be placed in the delay slot of a conditional
  branch"** (V8 §B.21; same for FBfcc and CBccc).
- QEMU (`translate.c:2600-2680`):
  - BA,a: PC ← target, nPC ← target + 4.
  - BN,a: PC ← nPC + 4.
  - Conditional,a: taken → (PC ← nPC, nPC ← target); untaken →
    (PC ← nPC + 4, nPC ← nPC + 8).
- Test `t_annul` covers all 7 combinations (`tests/cpu/src/t_branch.S:139-182`).

### 3.3 CALL and JMPL

- CALL: r[15] ← PC (the CALL's address); target = PC + 4·disp30; delayed
  (V8 §B.24).
- JMPL: rd ← PC (the JMPL's address). Target = r[rs1] + op2. If
  target[1:0] ≠ 0 → mem_address_not_aligned, with no link write
  (V8 §B.25; ISP §C.9). Typical returns are `jmpl %i7+8` (`ret`) and
  `jmpl %o7+8` (`retl`) (V8 §B.25 note).
- **JMPL/RETT couple:** "When a RETT instruction appears in the delay slot
  of a JMPL, the target of the JMPL must be fetched from the address
  space implied by the new (post-RETT) value of the PSR's S bit"
  (V8 §B.25 implementation note). Viking uses PSR.PS to check protections
  for the JMPL target fetch of a JMPL/RETT pair (Viking §4.4.3).
- Test `t_call_jmpl`: CALL links its own address; `jmpl %l2, %l3` links
  its own address; the `jmpl %l2+8` immediate form executes its delay slot
  (`mov 0x61`); a misaligned jmpl target (+2) → tt 7
  (`tests/cpu/src/t_branch.S:184-214`).

### 3.4 DCTI couples (V8 §5.3 "Delayed Control-Transfer Couples", Tables 5-11..5-13)

Code: `12: CTI→40`, `16: CTI→60`, with targets 40 and 60.

| Case | 12 | 16 | Execution order |
|---|---|---|---|
| 1 | DCTI unconditional | DCTI taken | 12, 16, 40, 60, 64, … |
| 2 | DCTI unconditional | B*cc (a=0) untaken | 12, 16, 40, 44, … |
| 3 | DCTI unconditional | B*cc (a=1) untaken | 12, 16, 44, 48, … (40 annulled) |
| 4 | DCTI unconditional | B*A (a=1) | 12, 16, 60, 64, … (40 annulled) |
| 5 | B*A (a=1) | any CTI | 12, 40, 44, … (16 annulled) |
| 6 | B*cc | DCTI | 12, unpredictable |

- "DCTI unconditional" = CALL, JMPL, RETT, or B*A with a = 0. "DCTI taken"
  = CALL, JMPL, RETT, B*A (a=0), or B*cc taken. "B*cc" includes BN and
  excludes BA (V8 Table 5-13).
- **The delay instruction of a DCTI that is itself in a delay slot is at
  the first DCTI's target** (where nPC points), not at PC + 4 (V8 §5.3
  "Delay Instruction").
- **Return from a trap is the JMPL, RETT couple** (case 1): `jmpl %r17`
  (old PC) then `rett %r18` (old nPC) re-executes the trapped instruction;
  `jmpl %r18; rett %r18+4` skips it (V8 §B.26 Programming Note). "The
  instruction executed immediately before an RETT must be a JMPL"; if not,
  instruction accesses after the RETT may use the wrong address space
  (V8 §B.26).
- **What `t_dcti` checks (requirement A1):**
  - A trap return is built by hand: `save`, ET cleared (PS set), N stores
    (N = 0, 1, 2, 4, 8), then `jmp %l1; rett %l2` to a `jmpl %g1, %o7`
    whose leaf callee returns with `retl`. It runs 16 times per N with the
    MMU and caches on. **%o7 must equal the jmpl's own address** (check
    codes 0x10-0x18) (`tests/cpu/src/t_dcti.S:1-85`).
  - The bug it catches (described in the test's comment): the JMPL, the RETT's target, reached decode while the
    RETT was still held behind the stores, and it took the RETT's address
    as its PC. The link then pointed at the RETT, and `retl` landed 8
    bytes after it (`t_dcti.S:1-17`).
  - The test needs the caches on because an uncached target fetch "always
    loses the race" (`t_dcti.S:69-71`). It passes under QEMU (README:85).

### 3.5 RETT (V8 §B.26; ISP §C.9, `sparcv8.txt:8330-8360`)

Checks, in priority order:
1. ET = 1 and S = 0 → **privileged_instruction** (normal trap).
2. ET = 1 and S = 1 → **illegal_instruction** (normal trap).
3. ET = 0 and S = 0 → tt ← privileged_instruction (0x03), **error mode**.
4. ET = 0 and WIM[(CWP+1) mod N] = 1 → tt ← window_underflow (0x06),
   **error mode**.
5. ET = 0 and target[1:0] ≠ 0 → tt ← mem_address_not_aligned (0x07),
   **error mode**.
6. Otherwise: ET ← 1; PC ← nPC; nPC ← target; CWP ← (CWP+1) mod N;
   S ← PS.

- RETT is a delayed CTI. Its target is r[rs1] + op2 (V8 §B.26).
- Viking implements the V8 rules (Viking §4.13.4.4). A RETT window
  underflow "will immediately lead to an error mode condition, and
  watchdog reset" (Viking §4.13.4.9).
- **Tests:**
  - `t_rett_supervisor`: `jmp %l0; rett %l0+4` with ET = 1, S = 1 → tt 2.
    **The trap's saved nPC must be the jmp target `%l0`, not the rett's
    own target `%l0 + 4`** (check 2) (`tests/cpu/src/t_traps.S:40-59`).
    QEMU fails this (README deviation 2; `ss20-qemu.log:18-19`).
  - `t_rett_user`: rett with S = 0, ET = 1 → tt 3. Trap PC = the rett.
    The saved PSR has PS = 0 (`t_traps.S:61-90`).
- QEMU (`translate.c:4313-4327`, `win_helper.c:124-139`):
  - It checks privilege when it translates. Then it checks the target's
    alignment as a normal trap. Then `helper_rett` raises
    illegal_instruction if ET = 1.
  - It sets ET = 1 **before** the window check, so an underflowing RETT
    with ET = 0 raises a normal window_underflow trap, not error mode.
  - Both are differences from the V8 order that came out of reading the
    code. The suite does not test them.

### 3.6 Ticc, traps and delay slots

- Ticc is not delayed. A taken Ticc traps before its successor runs, with
  PC = the Ticc and nPC = its nPC (V8 §5.3; test `t_ticc_tt` checks 2-3).
- **A trap on an instruction in a delay slot** saves PC = that instruction
  and nPC = the DCTI's target, which is the "instruction which was to be
  executed next" (V8 §7.1 "Precise Trap"; test `t_rett_supervisor` check 2).
- **A trap taken when the next instruction is annulled:** the ISP saves
  r[17] ← nPC and r[18] ← nPC + 4, so the annulled instruction is skipped
  (V8 §C.8 `execute_trap`).
- **Trap handlers return by**:
  - `jmp %l1; rett %l2`: re-execute (window handlers, interrupts:
    `runtime.S:283-296`, `:324-357`).
  - `jmp %l2; rett %l2+4`: skip the instruction (`runtime.S:292-296`,
    `trap_skip`).
  - Both handlers first restore the PSR saved at entry with
    `wr %l0, %psr; nop; nop; nop` (ET = 0, the trap window's CWP).

---

## 4. Traps

### 4.1 Table 7-1: types, priorities, tt (V8 §7.4)

Priority 1 is the highest. "Only the highest priority exception or
interrupt request is taken". Lower interrupt requests persist, and lower
exceptions recur when the instruction re-executes (V8 §7.3).

| Exception / interrupt | Priority | tt | Viking implements? (Table 4-14/4-15) |
|---|---|---|---|
| reset | 1 | — (tt not written) | yes |
| data_store_error | 2 | 0x2B | yes (store buffer, deferred; Viking §4.13.4.2, §4.11.11.3) |
| instruction_access_MMU_miss | 2 | 0x3C | no |
| instruction_access_error | 3 | 0x21 | **no** (Table 4-15). The suite expects it for bus errors, see §6.4 |
| r_register_access_error | 4 | 0x20 | no |
| instruction_access_exception | 5 | 0x01 | yes |
| privileged_instruction | 6 | 0x03 | yes |
| illegal_instruction | 7 | 0x02 | yes |
| fp_disabled | 8 | 0x04 | yes |
| cp_disabled | 8 | 0x24 | yes |
| unimplemented_FLUSH | 8 | 0x25 | no |
| watchpoint_detected | 8 | 0x0B | no |
| window_overflow | 9 | 0x05 | yes |
| window_underflow | 9 | 0x06 | yes |
| mem_address_not_aligned | 10 | 0x07 | yes |
| fp_exception | 11 | 0x08 | yes |
| cp_exception | 11 | 0x28 | no |
| data_access_error | 12 | 0x29 | **no** (Table 4-15). The suite expects it, see §6.4 |
| data_access_MMU_miss | 12 | 0x2C | no |
| data_access_exception | 13 | 0x09 | yes |
| tag_overflow | 14 | 0x0A | yes |
| division_by_zero | 15 | 0x2A | yes |
| trap_instruction (Ticc) | 16 | 0x80-0xFF | yes |
| interrupt_level_15 … _1 | 17 … 31 | 0x1F … 0x11 | yes |
| implementation-dependent | impl. | 0x60-0x7F | no (Table 4-15) |

- tt 0x00-0x7F are hardware traps and 0x80-0xFF software traps. tt values
  in 0..0x5F not listed above are reserved (V8 §7.4).
- The trap priorities are implementation-dependent, but the tt values are
  fixed (V8 §7.4).
- The ISP `select_trap` order (V8 §C.8) matches Table 7-1.
- **IU-2:** an interrupt has lower priority than a synchronous trap of
  the same instruction (priorities 17-31): a pending interrupt must not
  override an ALU/LSU trap.

### 4.2 Precise, deferred and interrupting traps (V8 §7.1, §7.2)

- **Precise:** taken before any program-visible state changes. r[17] = PC
  of the trapping instruction and r[18] = the next nPC. All earlier
  instructions have completed and no later one has started.
- **Deferred:** may come after state has changed, but before any
  instruction that depends on the trapping one. It "may not be deferred
  past a precise trap, except for a floating-point exception or
  coprocessor exception" (V8 §7.1).
- **Interrupting:** external interrupts, and implementation-dependent
  errors.
- **Default trap model:** every trap is precise except
  - (1) fp/cp exceptions, which may be deferred;
  - (2) non-resumable machine checks;
  - (3) an error on the second access of LDD/STD/LDSTUB/SWAP;
  - (4) events unrelated to the instruction stream (V8 §7.2).
- Viking implements the default model (Viking §4.13). V8's pre-1991 chips
  do too (V8 §L.3).

### 4.3 Trap entry (V8 §7.5; ISP §C.8)

If ET = 1 when a trap is selected:
1. ET ← 0.
2. PS ← S.
3. CWP ← (CWP − 1) mod NWINDOWS, **with no WIM check**.
4. r[17] ← PC and r[18] ← nPC in the **new** window. If the next
   instruction was to be annulled: r[17] ← nPC, r[18] ← nPC + 4
   (ISP §C.8).
5. tt ← trap type (not for reset; for error mode, see §4.6).
6. S ← 1.
7. Reset trap: PC ← 0, nPC ← 4. Otherwise: PC ← TBR, nPC ← TBR + 4.

QEMU does the same steps (`int32_helper.c:162-171`):
`psret = 0; cwp = cwp−1; %l1 = pc; %l2 = npc; psrps = psrs; psrs = 1;
tbr = (tbr & 0xfffff000) | tt << 4; pc = tbr; npc = pc + 4`. For tt
0x10-0x1F it also calls an interrupt-acknowledge hook
(`int32_helper.c:174-179`). Nothing on the SS20 uses an interrupt
acknowledge.

### 4.4 Interrupts (V8 §7.3, §7.6; Viking §4.13.4.16)

- **Taken when** ET = 1 and (IRL = 15 or IRL > PIL), and no
  higher-priority exception is pending (V8 §7.3, §7.6
  "interrupt_level_n"). **Level 15 is non-maskable by PIL but is still
  ignored while ET = 0** (V8 §7.3; Viking §4.13.4.16). QEMU:
  `cpu_pil_allowed`: `pil == 15 || pil > psrpil` (`cpu.h:718-726`), gated
  by `psret` (`cpu.h:704-716`, `cpu.c:87-103`).
- "How quickly a processor responds to an interrupt request, and the
  method by which an interrupt request is removed, is
  implementation-dependent" (V8 §7.3).
- **When sampled:** "between the execution of instructions" (V8 §7.3). In
  the ISP, before each instruction fetch (V8 §C.5). QEMU looks at the
  highest set bit of `pil_in` (`int32_helper.c:70-100`).
- **Viking:**
  - IRL[3:0] are level-sensitive.
  - A request must be held 3 cycles before it reaches the pipeline, and a
    valid instruction must be at that stage.
  - Taking an interrupt flushes the store buffer.
  - Breakpoint/counter logic can raise an internal interrupt at level
    ACTION.BCIPL (Viking §4.13.4.16).
- **WRPSR's ET/PIL** take effect immediately for interrupts (§2.10 point 7).
- **Sun-4M:** a watchdog reset and module errors are sent as a broadcast
  level-15 interrupt (`Sun4M…txt:2098-2106`, `:3272-3276`).

### 4.5 RETT exit

See §3.5. A successful RETT sets ET ← 1, S ← PS and CWP ← CWP + 1, and
jumps (delayed) to the target.

### 4.6 Error mode and the SuperSPARC watchdog reset

- **V8:**
  - A precise trap while ET = 0, or an attempt to run an instruction that
    can take a pending deferred trap while ET = 0, puts the processor in
    error_mode and halts it (V8 §7.3).
  - Interrupts, and interrupting or deferred exceptions caused while
    ET = 1, are ignored while ET = 0 (V8 §7.3, §7.5).
  - **No normal trap actions** happen on entry (no CWP decrement, no saved
    locals). tt is written only for a RETT that traps with ET = 0
    (V8 §7.4 "Error Mode").
  - What happens next is implementation-dependent, "typically … an
    external reset" (V8 §7.4). The ISP leaves error_mode only on
    `bp_reset_in` (V8 §C.5).
- **SuperSPARC (Viking):**
  - Error mode generates an internal **watchdog reset** (Viking §4.3.2,
    §4.13.2).
  - The only state it affects is **MCNTL.BT (boot mode) ← 1**.
    **MFSR.EM ← 1**. Breakpoints are cleared. **tt is not written**,
    except when the error-mode trap came from a RETT. **PSR.PS is not
    affected**. The caches are not changed.
  - A reset trap follows (PC 0) (Viking §4.3.2, §4.13.2, §4.8;
    `viking.txt` "After a Watchdog Reset the contents of the data cache
    are unmodified").
  - Internal errors (for example a multiple tag match) also enter error
    mode, with MFSR.FT = 6 (Viking §4.11.11.3).
- **Sun-4M:**
  - A watchdog reset resets only that processor and sends a broadcast
    level-15 interrupt (`Sun4M…txt:3272-3276`).
  - State after a watchdog reset: caches and module MMUs unchanged, the
    snooping bit unchanged, boot-mode bit 1, module write buffers drain
    normally, watchdog bit 1 (`Sun4M…txt:3295-3306`).
  - On Viking, SFSR bit 17 **EM**, "Error Mode Reset Taken", replaces the
    reset register's WD bit. It raises the module-error pin and is cleared
    when the SFSR is read (`Sun4M…txt:5116-5118`, `:5134`).
- **Requirement IU-1 and the `wdtest` ROM** (PLAN §6;
  `tests/cpu/src/wdtest.S`):
  1. The first boot writes a marker in RAM, clears ET and runs `ta 0x7f`,
     which enters error mode.
  2. The watchdog reset restarts the ROM. On the second boot:
     - the SFSR (ASI 4, VA 0x300) has **EM (bit 17)** set, and that read
       clears it;
     - a later non-clearing read at ASI 4 VA **0xB00** shows EM = 0;
     - the system status register (pa `0xF_F1F0_0000`, ASI 0x2F) has **WD
       (bit 4)**;
     - the RAM marker survived.
  - wdtest is built as a separate image because it resets the machine
    (`wdtest.S:1-27`, `:44-77`).
  - VA 0xB00 is a project-private non-clearing SFSR read, not Viking's.
    Viking's architectural non-clearing SFSR alias is VA 0x1300 (Viking
    Table 4-9; QEMU `ldst_helper.c:682-684`).
- **QEMU:** a trap with ET = 0 calls `cpu_abort(... "Error state")`, which
  stops the emulator (`int32_helper.c:125-134`). It has no watchdog, so
  `wdtest` cannot run there. QEMU also suppresses MMU faults when
  ET = 0 (`mmu_helper.c:250-256`).

### 4.7 Reset

- **V8:** an external reset → reset trap → PC = 0, nPC = 4. Only PSR.ET
  (0) and PSR.S (1) are guaranteed. tt is not written (undefined at
  power-up) (V8 §7.4, §7.5, §7.6). In the ISP, the processor leaves
  reset_mode executing at address 0 with addr_space 9 (V8 §C.5).
- **Viking hardware reset** (Viking Table 4-1):
  - PSR: S = 1, ET = 0, EC = 0, CWP uninitialized. (The table prints
    "Ver=4, Impl=0", which disagrees with §4.4.3's impl 4 / ver 0.)
  - WIM, register file, MFSR (except EM) and caches: uninitialized.
  - PC 0, nPC 4.
  - FQ invalidated. TLB lock bits cleared. ACTION.MIX = 0 (single
    instruction issue). Breakpoints disabled.
  - MCNTL: BT = 1; EN, NF, DE, IE, SB, PE, SE, PSO, PF, AC and TC = 0; MB
    = the CCRDY_ pin. MFSR.EM = 0.
- **Boot mode** (MCNTL.BT = 1): instruction fetches, and ASI 0x08/0x09
  accesses, go to PA `0xFF_0000000 | VA[27:0]`, that is
  `0xF_F000_0000 + VA[27:0]`, uncached. Data accesses are not affected
  (Viking §4.3.4, §4.11.11.1 BT). The SS20 suite runs from VA 0 in boot
  mode with the PROM at pa `0xF_F000_0000` (`platform.h:1-19`). The MMU is
  a later phase.
- **QEMU reset** (`cpu.c:36-84`): the state is zeroed. Then CWP = 0,
  WIM = 1, ET = 0, S = 1, PS = 1, PIL = 0, EF = 0, TBR = 0, PC = 0, nPC = 4,
  FSR = 0. MCNTL: EN and NF cleared, BM (bit 13) set.
- **Sun-4M §12:** no processor register, cache, TLB or memory contents are
  reset by hardware; only I/O devices are (`Sun4M…txt:3283-3288`).
- **The suite's reset code** (`runtime.S:20-130`):
  - At tt 0 it jumps to `reset`. On the SS20 it reads MCNTL (`lda [%g0] 4`)
    bits 3:2 as a CPU number and parks every CPU except 0. Those bits are
    reserved on a real SuperSPARC; QEMU reads 0
    (`runtime.S:36-45`).
  - It then writes `PSR = S|PS|PIL15` (ET = 0, CWP = 0), WIM = 0 and
    TBR = trap_table, each followed by 3 nops.
  - It copies the PROM to RAM through ASI 0x2F. It probes NWINDOWS (WIM)
    and the FPU (EF), sets WIM = 2 and turns ET on with PIL 15.

---

## 5. Memory ordering the IU must honour

- **TSO is the standard model and every implementation must provide it**
  (V8 Chapter 6 introduction). PSO is optional and enabled by the SRMMU
  control register's PSO bit (V8 §6.4; Viking MCNTL.PSO bit 7).
- **TSO** (V8 §6.2):
  - Stores, FLUSHes and atomic load-stores go through a per-processor
    **FIFO store buffer**, so memory performs them in issue order.
  - A load first checks its own store buffer for the same location. If it
    finds one, it returns the most recent such store; otherwise it goes to
    memory. "A processor is blocked from issuing further memory operations
    until the load returns a value."
  - **An atomic load-store (SWAP, LDSTUB) "is placed in the Store Buffer
    like a store, and it blocks the processor like a load". It "blocks
    until the store buffer is empty and then proceeds to memory". No
    operation may intervene between its load and store parts.**
- **The unit of ordering is a doubleword.** References to different
  bytes/halfwords/words in one doubleword count as the same location. The
  largest atomically accessed datum is a doubleword (V8 §6.1). LDD and STD
  "operate atomically" (V8 §B.1, §B.4).
- **I/O locations** (ASIs other than 8, 9, 0xA, 0xB, 0x20-0x2F, or
  non-real memory) are strongly ordered among themselves (V8 §6.1).
- **STBAR:** stores and atomics issued before it complete before any
  issued after it. It is a no-op under TSO or Strong Consistency, and under
  PSO with PSO mode off (V8 §B.30). It is enough to stop issuing stores
  until the earlier ones are observed by all processors (V8 §B.30
  implementation note). Viking marks the store-buffer entry; under TSO it
  "waits for PEND_ at all times" (Viking §4.4.5).
- **FLUSH:** later instruction fetches of the target appear after earlier
  loads, stores and atomics. It is complete within 5 instructions. On an
  MP, stores to the target become visible to other processors' fetches
  "some time after" (V8 §B.32, §6.5).
- **Viking atomics:**
  - The store buffer is copied out before an atomic starts.
  - Cacheable atomics in MBus mode are a read with ownership and then a
    write inside the cache.
  - Non-cacheable atomics in MBus mode are a locked read-write sequence
    (the MBus LOCK bit, with no arbitration release between the two)
    (Viking §4.5.2, §4.5.2.2).
- **Viking non-cacheable loads** copy the store buffer out first (Viking
  §4.5.4).
- **Acceptance tests on atomicity** (phases 3/9): `t_cache_atomic`
  (ldstub/swap on a cached line change only their byte/word),
  `t_smp_atomic` (3 CPUs × 64 increments under an ldstub lock, then a swap
  lock; the total must be exact) (`tests/cpu/README.md:81`, `:83`).

---

## 6. SuperSPARC specifics

### 6.1 Identification

| Register | Value | Sources |
|---|---|---|
| PSR impl/ver | 4 / 0 (byte 0x40) | QEMU `cpu.c:479-480` ("TI-SuperSparc-60", STP1020APGA, `iu_version 0x40000000`, "SuperSPARC 3.x"); Viking §4.4.3 ("PSR.IMPL … always … 0x4. The PSR.VER … 0x0"); SS-II Table A-51 (PSR VER byte 0x40 for SuperSPARC 3.x/4.x/5.x and SuperSPARC II); suite logs `psr=40400fc0`. **Disagreement:** Viking §4.6.1 says "Viking always sets both FSR.VER and PSR.IMPL fields to zero", and Viking Table 4-1 prints "Ver=4, Impl=0" |
| MCNTL (ASI 4 VA 0) IMPL/VER | IMPL 0, VER 1; with MB = 1 the register reads `0x01000800` | QEMU `cpu.c:482` (`mmu_version 0x01000800`, "SuperSPARC 3.x, no MXCC"); SS-II Table A-51 (MCNTL VER: 3.x = 1, 4.x = 2, 5.x = 3; SuperSPARC II 8 / 0xA); the OBP prints "TMS390Z50(3.x) 0Mb External cache" and NetBSD "SuperSPARC v3". **Disagreement:** Viking §4.11.11.1 (1990) says MCNTL.Ver is fixed at 0 |
| FSR.ver | 0 | QEMU `cpu.c:481`; SS-II A.3.4.1 |
| NWINDOWS | 8 | §1.1 |
| QEMU features | `CPU_DEFAULT_FEATURES` = MUL, DIV, FSMULD (no CASA, no FLOAT128) | `cpu.c:489`; `cpu.h:257-258` |
| Other QEMU model fields | `mmu_bm 0x2000`, `mmu_ctpr_mask 0xffffffc0`, `mmu_cxr_mask 0x0000ffff`, `mmu_sfsr_mask 0xffffffff`, `mmu_trcr_mask 0xffffffff` | `cpu.c:483-487` |

### 6.2 ASRs

- Documented: STBAR (`rd %asr15, %g0`) and SIGM (`rd %asr31, %g0`, a NOP
  without JTAG emulation) (Viking §4.4.5, §4.4.6). Nothing else is
  documented. The acceptance behaviour is in §1.6 (`t_rdasr`).

### 6.3 MCNTL and ASI 4 (as seen by software)

**ASI 4 register map** (Viking §4.11.11, Table 4-9; VA[12:8] selects;
32-bit accesses only):

| VA | Register |
|---|---|
| 0x0000 | MCNTL (control) |
| 0x0100 | context table pointer |
| 0x0200 | context |
| 0x0300 | SFSR/MFSR (cleared by a read: QEMU `ldst_helper.c:678-681`; `wdtest`) |
| 0x0400 | SFAR/MFAR |
| 0x1300 | SFSR read/write alias (QEMU: read without clear, `:682-684`) |
| 0x1400 | SFAR read/write alias |
| 0x1500 | shadow SFSR (emulation). SuperSPARC II: data_access_exception (SS-II A.4.3.2) |

- Viking: a byte, halfword or doubleword access to ASI 4, or a VA not in
  this table → data_access_exception with MFSR.CS (Viking §4.11.11,
  §4.11.11.3). QEMU returns `mmuregs[(va >> 8) & 0x1f]` for any VA
  (`ldst_helper.c:674-689`).

**MCNTL bits** (Viking §4.11.11.1; SS-II Table A-28 has the same layout):

| Bit(s) | Name | Meaning | Reset (Viking Table 4-1) |
|---|---|---|---|
| 31:28 | IMPL | read-only | 0 |
| 27:24 | VER | read-only | 1 on SuperSPARC 3.x (SS-II Table A-51) |
| 23:19 | — | reserved, read-only | — |
| 18 | PF | data prefetcher (CC mode only, ignored in MBus mode) | 0 |
| 17 | — | reserved | — |
| 16 | TC | table walks cacheable in the external cache (must be 0 in MBus mode) | 0 |
| 15 | AC | alternate cacheable (accesses not translated by a PTE) | 0 |
| 14 | SE | snoop enable | 0 |
| 13 | BT | boot mode (QEMU `mmu_bm 0x2000`) | **1** |
| 12 | PE | parity enable | 0 |
| 11 | MB | MBus mode; read-only, the CCRDY_ pin (1 on the SS20: no MXCC) | pin |
| 10 | SB | store buffer enable | 0 |
| 9 | IE | I-cache enable | 0 |
| 8 | DE | D-cache enable | 0 |
| 7 | PSO | partial store order | 0 |
| 6:2 | — | reserved (in this project bit 6 is the L2-TLB enable, PLAN §3 phase 3 / `t_mmu_l2`; the suite reads bits 3:2 as a CPU number, `runtime.S:36-45`) | — |
| 1 | NF | no-fault (faults on ASIs 0x08, 0x0A, 0x0B, 0x20-0x2F are not reported; the FSR is still written) | 0 |
| 0 | EN | MMU enable | 0 |

- QEMU write mask: bits 31:24 are kept and bits 23:0 written
  (`ldst_helper.c:1003-1005`). A change of NF or BM flushes QEMU's TLB.
- Known values: OpenBIOS starts secondaries with MCNTL = 0x001; Linux sets
  `0x4140` bits on CPU 0; PLAN §3 phase 9 says
  "OpenBIOS secondary start (MCNTL 0x041)".

### 6.4 Access errors, as the IU sees them

- **MMU faults** (invalid, protection, privilege): instruction side →
  **instruction_access_exception (tt 0x01)**; data side →
  **data_access_exception (tt 0x09)**. The SFSR and SFAR are written
  (Viking §4.11.11.3; QEMU `mmu_helper.c:244-265`).
  - The SFAR never holds an instruction fault address. The saved PC/nPC
    give it instead (`Sun4M…txt` B.I.4.5; QEMU `ldst_helper.c:458-461`).
  - Test `t_mmu_ifault`: a jump into an invalid page traps tt 1 with SFSR
    `0x366` and no OW (`README.md:80`).
- **Bus errors, two sources that disagree:**
  - *Viking:* instruction_access_error and data_access_error are **not**
    implemented (Viking Table 4-15). Bus errors, time-outs and parity
    errors are reported as instruction_access_exception /
    data_access_exception with MFSR bits (Viking §4.11.11.3, §4.13.4.3,
    §4.13.4.12).
  - *Suite and QEMU:* the suite expects **tt 0x29 (data_access_error)** for
    a load the bus refuses (SFSR `0x816`: TO, AT 0, FT 5, FAV; SFAR = VA)
    and **tt 0x21 (instruction_access_error)** for a fetch (SFSR `0x874`,
    no FAV). A table walk that reads a refused address is FT 4 + L, tt 9
    (`tests/cpu/src/t_buserr.S:1-21`, README:87; PLAN A3/B1;
    MMU-4).
  - QEMU raises `TT_CODE_ACCESS` 0x21 / `TT_DATA_ACCESS` 0x29 for
    unassigned accesses with the MMU on (`ldst_helper.c:422-481`). The
    test SKIPs on QEMU (README deviation 11).
- **data_store_error (tt 0x2B):** a store-buffer copy-out error. It is
  deferred and sets MFSR.SB, and it also disables the store buffer (Viking
  §4.11.11.3, §4.5.2).
- **Control-space error:** an invalid ASI, a wrong access size, or an
  invalid VA in a valid ASI → data_access_exception with MFSR.CS (bit 16).
  It does not apply to bus errors on ASIs 0x08-0x0B and 0x20-0x2F, or to
  probes (Viking §4.11.11.3; `Sun4M…txt:5112-5116`).
- **MFSR bit 17 EM:** set by a watchdog reset (see §4.6).

### 6.5 Other SuperSPARC IU behaviours

- **Integer divide is 52 bits by 32 bits:** if {Y, rs1} has significant
  bits beyond bit 51, Viking raises **illegal_instruction (tt 0x02)**, and
  system software is expected to emulate the divide (Viking §4.4.2). If a
  divide by zero is also present, illegal_instruction wins (Viking
  §4.13.4.14). SuperSPARC II keeps the same 52-bit divide
  (`STP1021UG.txt:952-955`).
  - The acceptance model expects the full V8 64 ÷ 32 result for every
    vector, including dividends above 2^52 such as `y = 0xfffffffe,
    a = 0xffffffff, b = 0xffffffff` (`gen_alu.py:185-188`). QEMU also
    divides 64 ÷ 32.
- **IMUL and IDIV run in the FPU** (Viking §4.4.1, §4.4.2, §4.6.7,
  §4.6.8):
  - They wait for the FP queue to empty, or proceed if the FPU is in
    exception mode.
  - They never signal or take a deferred fp_exception.
  - Integer multiply raises no exceptions.
- **WRPSR that tries to set EC → illegal_instruction** (Viking §4.4.3).
- **FLUSH** (Viking §4.4.4) and **STBAR** (§4.4.5): see §2.12 and §5.
- **Superscalar issue** is off after reset (ACTION.MIX = 0, ASI 0x4C bit
  12, "0x1000 (MIX)"). Solaris 8 writes 0x1000 and polls until it reads
  back (Viking §4.3.3; `t_iu2.S:267-273`).
- **FP specifics** (later phase, listed for reference):
  - NaN → integer gives 0. Fixed NaN outputs.
  - Underflow is detected after rounding.
  - FxTOi rounds to zero. No quad precision.
  - FsMULd is supported. FSR.NS is ignored.
  - (Viking §4.6.2-§4.6.6.)

---

## 7. Acceptance

### 7.1 Phase 1 exit tests

PLAN §3 phase 1: "`t_alu`, `t_branch`, `t_dcti`, `t_ldst`, `t_psr`,
`t_traps`, `t_window`, `t_iu2` and `brktest` pass in Verilator, with
results equal to QEMU's (`tests/cpu/expected`)", except where QEMU
deviates (§7.2). The known hazards to test from the start are A1
(`t_dcti`) and IU-1 (`wdtest`).

**`t_alu.S` + `gen_alu.py`** (`README.md:69`)
- `t_alu_vectors`: 3748 one-instruction vectors over every op in §2.5,
  register and immediate forms. Each vector checks the result, icc (NZVC),
  Y, and whether it trapped and with which tt (check code
  `0x100000 + row*16 + {0,1,2,3}`; `t_alu.S:1-63`).
- Divides: the dividend is {Y, a}. Overflow saturates with V = 1.
  Division by zero → tt 0x2A with rd, icc and Y unchanged. Y is unchanged
  in every case (§1.5, §2.5).
- Shifts by 0, 1, 2, 15, 16, 31, 32, 33, 63 and `0xffffffe1` use only
  bits 4:0 (`gen_alu.py:169`).
- MULScc with random Y and N^V inputs (`gen_alu.py:196-202`). Tagged ops
  with and without trapping (tt 0x0A, rd and icc unchanged).
- `t_sethi`: sethi/`%hi`/`%lo`, simm13 sign extension (−1, −4096, 4095),
  %g0 reads 0 and ignores writes (`t_alu.S:66-89`).
- `t_y_register`: `wr` to Y is `rs1 xor op2`, register and immediate
  forms, with 3 nops after each write (`t_alu.S:91-107`).

**`t_ldst.S`** (`README.md:70`)
- `t_ld_widths`: LDUB/LDSB/LDUH/LDSH/LD, sign extension, big-endian byte
  lanes, `[reg+reg]` addressing.
- `t_st_widths`: STB/STH merge into the word; only the low byte/half is
  stored.
- `t_ldd_std`: the pair order (even register = lower address);
  `ldd [..], %g0` writes only %g1.
- `t_atomics`: LDSTUB returns the byte and sets it to 0xFF; SWAP
  exchanges.
- `t_alt_space`: LDA/STA/LDUBA/LDSHA with ASI 0x0B; ASI 0x20 bypass on
  non-SS20 targets.
- `t_align_traps`: misaligned LD/LDUH/LDD/ST/STH/STD/SWAP → tt 7; nothing
  written; trap PC = the faulting instruction; aligned accesses of every
  width do not trap.

**`t_branch.S`** (`README.md:71`)
- `t_bicc_conds`: 16 Bicc conditions × 16 icc values against
  `gen/cond_tab.S`.
- `t_ticc_conds`: 16 Ticc conditions × 16 icc values (`t<cond> 0x21`).
- `t_annul`: the 7 annul/delay-slot cases of §3.2.
- `t_call_jmpl`: CALL and JMPL link their own address; computed `jmpl
  rs1+imm`; the delay slot executes; a misaligned JMPL target → tt 7.

**`t_dcti.S`** (`README.md:85`; requirement A1)
- `t_rett_jmpl`: a hand-built `jmp %l1; rett %l2` with 0, 1, 2, 4 or 8
  stores before the RETT, returning to a `jmpl %g1, %o7`.
- Run 16 times for each count, with the MMU and caches on (it calls
  `mmu_tables_init` / `mmu_on` from `mmu_setup.S`).
- Check: %o7 = the jmpl's address (codes 0x10, 0x11, 0x12, 0x14, 0x18).
- An IU without the fix fails it in simulation (6 of 16 with 8 stores);
  it passes under QEMU.

**`t_psr.S`** (`README.md:74`)
- `t_psr_fields`: impl/ver are read-only under WRPSR; PIL can be written
  and read back; icc can be set and read through the PSR.
- `t_tbr`: after `ta 0x33`, RDTBR shows tt = 0xB3 << 4 and TBA =
  `trap_table`. **WRTBR with 0xFF0 in bits 11:4 leaves tt unchanged**
  (check 4; QEMU fails it).

**`t_traps.S`** (`README.md:72`)
- `t_ticc_tt`: tt = 0x80 + ((rs1 + op2) & 0x7F); saved PC/nPC = the ta
  and ta + 4.
- `t_illegal`: UNIMP, op=2 op3=0x09, op=3 op3=0x08 → tt 2.
- `t_rett_supervisor`: RETT with ET = 1, S = 1 → tt 2; with the rett in a
  jmp delay slot, the **saved nPC = the jmp target** (QEMU fails check 2).
- `t_rett_user`: RETT with S = 0, ET = 1 → tt 3, trap PC = the rett, saved
  PS = 0. `ta SVC_SUPER` (0x7E) returns the test to S = 1.
- `t_div_zero`: `udiv x, %g0` → tt 0x2A, rd unchanged; `sdivcc x, 0` →
  tt 0x2A.
- `t_tag_overflow`: TADDccTV on tag bits or arithmetic overflow, and
  TSUBccTV on tag bits → tt 0x0A, rd unchanged; no trap for clean tags.
- `t_fp_disabled`: with EF = 0, FMOVs, LDF and FBfcc → tt 4.
- `t_cp_disabled`: CPop1 and CBccc → tt 0x24.

**`t_window.S`** (`README.md:73`)
- `t_window_basic`: the caller's outs = the callee's ins; globals are
  shared; SAVE decrements CWP mod NWINDOWS; SAVE/RESTORE add with the
  operands from the old window and rd in the new one.
- `t_window_deep`: 40-deep recursion through the runtime's
  overflow/underflow handlers. Result 820. Overflows − underflows = 2.
  Overflows ≥ 42 − NWINDOWS.
- `t_wim_bits`: NWINDOWS (from the WIM bits that stick) = 8.

**`t_iu2.S`** (`README.md:84`)
- `t_fpu_trap_prio` (FPU-1): a misaligned FP store with an fp_exception
  pending → tt 7 first, memory unchanged. The exception is taken next on
  an aligned FP store. Then ftt = 1, cexc = DZ. It accepts precise and
  deferred FPUs, and SKIPs if PSR.EF does not stick.
- `t_fpu_fq` (FPU-2): the FQ holds the trapping fdivs (address and
  opcode); qne goes 1 → 0 after STDFQ; STDFQ in user mode → tt 3; STDFQ on
  an empty FQ → fp_exception with ftt 4.
- `t_cp_ldst` (IU-3): op=3 op3 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37 →
  tt 0x24, with no memory change, in supervisor and user mode.
- `t_wrpsr_cwp` (IU-5): `wr %psr` with CWP = NWINDOWS → tt 2; CWP
  unchanged.
- `t_rdasr` (IU-6): `rd %asr1/%asr2/%asr15,%l2` read Y; `wr %asr1` does
  not change Y; no trap; CASA → tt 2, memory unchanged.
- `t_asi_width` (SS20; MMU-12, SMP-1): an ASI 0x4C write does not reach
  the ASI 0x0C tag; ASI 0x38 VA 0/0x100 hold 64-bit values (stda/ldda);
  ACTION (0x4C) reads back 0x1000, 0x0AAA and 0.

**`brktest.S`** (built separately with `--main=brktest`; PLAN B2)
- A BREAK on ttya reaches the ESCC: RR0 bit 7, and an External/Status
  interrupt on each edge when WR15 bit 7 and WR1 bit 0 are set.
- PIL stays 15, so the interrupt is only looked at, never taken
  (`brktest.S:1-13`). The IU needs byte ASI accesses through IO_ASI
  (0x2F) for it (`brktest.S:21-31`).

**`wdtest.S`** (separate image; IU-1)
- See §4.6: error mode → watchdog reset, SFSR.EM set and cleared by its
  read, system status WD = 1, memory kept.

**Infrastructure the phase 1 tests use beyond the IU itself** (facts from
the sources):
- The runtime reads MCNTL through ASI 4 at reset.
- It copies the PROM through ASI 0x2F, and ttya is accessed through
  ASI 0x2F on the SS20 (`runtime.S:36-71`, `platform.h:33-38`).
- `t_dcti` turns on the MMU and caches (ASI 4 MCNTL, page tables built
  through ASI 0x20).
- `t_asi_width` uses ASIs 0x0C, 0x38 and 0x4C.

### 7.2 QEMU deviations the core must not copy (README "Known QEMU deviations")

The README says "The core has to follow the manual, not QEMU"
(`tests/cpu/README.md:144-145`). IU-related items:

1. **`sdiv`/`sdivcc` with a negative divisor** (README item 1, lines
   97-100): QEMU divided by the unsigned 32-bit `b`, so 1 ÷ −1 gave 0 and
   69 ALU checks failed.
   - *Status in the sources:* the QEMU source in `scratch/reference`
     divides by the signed `b32` (`helper.c:103-131`).
   - The QEMU 11.1.1 reference log passes `alu` (`ss20-qemu.log:2`). The
     QEMU 8.2.2 logs fail it (`ss20-qemu-8.2.2.log:2-19`: e.g. check
     `0010a570 exp=ffffffff obs=00000000`).
   - The README text describes the old behaviour.
2. **nPC of a trap on a RETT in a JMP's delay slot** (item 2): QEMU saves
   nPC = the RETT's own target (jmp target + 4), not the jmp target, so
   the handler resumes one instruction late. `t_rett_supervisor` check 2
   (`ss20-qemu.log:18-19`: `exp=00002768 obs=0000276c`).
3. **`wr %tbr` overwrites TBR.tt** (item 3): `do_wrtba` moves the whole
   value (`translate.c:3536-3539`). V8: WRTBR writes TBA only. `t_tbr`
   check 4 (`ss20-qemu.log:29-30`).
4. **`rd %asr15` with rd ≠ 0 is a STBAR** in QEMU, which does not write
   rd (item 7; `insns.decode:111-120`). The microSPARC-I/II manuals and
   the test: it reads Y. `t_rdasr` check 4 (`ss20-qemu.log:79-80`).
5. **The STDFQ sequence_error is reported one instruction late** (item 8):
   PC = the next instruction, because `sparc_cpu_do_interrupt` advances
   `pc = npc` for `TT_FP_EXCP` when the queue is empty
   (`int32_helper.c:136-160`). QEMU's FPU is also precise, which V8
   allows; the FPU tests accept both.

Other README items are outside the IU: 4 (DMA2), 5, 6, 9, 10 and 11 (MMU,
bus errors), and 12 (caches).

### 7.3 Further QEMU-vs-V8/Viking differences found while reading the code (not in the README; untested by the suite)

These come from reading the QEMU source in `scratch/reference`, not from
running it.
- A trap with ET = 0 → `cpu_abort` (emulator halt), not a watchdog reset
  (`int32_helper.c:125-134`). MMU faults with ET = 0 are suppressed
  (`mmu_helper.c:250-256`).
- RETT: the target alignment is checked before the ET = 1 checks, so a
  misaligned RETT with ET = 1 and S = 1 gives tt 7, where V8 gives tt 2.
  ET is set before the WIM check, so an underflowing RETT with ET = 0
  takes a normal window_underflow trap instead of error mode
  (`translate.c:4313-4327`, `win_helper.c:124-139`).
- WRPSR ignores EC; Viking traps illegal_instruction (`win_helper.c:83-92`;
  Viking §4.4.3).
- WRPSR, WRWIM, WRTBR, RETT and FLUSH decode only with rd = 0. Other rd
  values → illegal_instruction (`insns.decode:173`, `:207`, `:233`,
  `:304`, `:307-308`). V8 marks those fields reserved/unused (V8 §B.26,
  §B.29, §B.32; §C.6: unused fields "are ignored and do not cause traps").
- A shift with non-zero reserved bits (i = 1: bits 12:5; i = 0: bits 12:5)
  → illegal_instruction (`insns.decode` SLL/SRL/SRA patterns;
  `translate.c:4131-4180`).
- An FPop opf QEMU does not decode → illegal_instruction (no catch-all;
  `translate.c:5749-5751`). V8: fp_exception with unimplemented_FPop
  (V8 §7.6).
- op=3 op3 0x22 decodes as LDQF (`insns.decode:668`): fp_disabled, or
  fp_exception with unimplemented_FPop without FLOAT128
  (`translate.c:2686-2698`). V8 Table F-4 leaves 0x22 unassigned.
- WRASR (rd ≠ 0) is an unprivileged NOP (`insns.decode:150-157`).
- An alternate-space instruction with i = 1 in user mode → illegal
  (checked before privilege) (`translate.c:1556-1606`). Table 7-1 orders
  privileged (6) above illegal (7).
- ASI 4 accepts any size and any VA (`ldst_helper.c:674-689`, `:995-1047`);
  Viking traps (Viking §4.11.11).
- The FQ has one entry (`int32_helper.c:151-157`); Viking's has 4.
- State-register writes take effect at once (V8 allows 0-3 delays).

### 7.4 Facts checked on hardware

- Trap entry and return; PSR impl/ver 0x04 (SS5) and 0x40 (SS20);
  NWINDOWS 8; FSR.ver 4 and 0; `privileged_instruction` over
  `illegal_instruction`; `fp_disabled` over `mem_address_not_aligned`.
- IU-1 error mode, IU-2 interrupt priority, IU-3 LDC/STC family, IU-5
  WRPSR CWP check, IU-6 ASRs and CASA, FPU-1 trap priority, FPU-2 FQ and
  sequence error: each is described above with its test.

---

## Not established from the sources

- What SuperSPARC/Viking does for RDASR/WRASR other than ASR 15/31 with
  rd = 0. Whether reserved ASR reads trap, read Y, or are privileged. The
  Viking document is silent. The suite's rule comes from the microSPARC
  manuals.
- Whether SuperSPARC traps on LDD/STD with an odd rd, or on non-zero
  reserved fields (shift bits 12:5, rd of WRPSR/RETT/FLUSH, Ticc bits
  12:7).
- Which SDIV negative-overflow method ([A] or [B], V8 §B.19) SuperSPARC
  uses. The suite's model and QEMU use [A].
- Whether SuperSPARC writes the divide remainder to Y. The suite requires
  Y unchanged.
- The exact SuperSPARC (as opposed to Viking 1990) MCNTL read-only mask,
  and the meaning of MCNTL bits 6:2 on SuperSPARC 3.x.
- STDFQ in user mode on a machine where the FQ is empty: whether the
  privileged check comes before fp_disabled or sequence_error is not
  stated beyond the Table 7-1 priorities.
- The exact timing of interrupt sampling relative to the pipeline on
  SuperSPARC, beyond Viking's "3 cycles, a valid instruction at that
  stage".
