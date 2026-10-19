# The CPU module

The processor module of the machine: a SPARC V8 integer unit, the FPU,
the SPARC Reference MMU and the two L1 caches, presenting itself to
software as a SuperSPARC (TMS390Z50) in MBus mode without an MXCC, as
VERILOG-PLAN.md §2 decides. This page is the design; the instruction-level
facts it relies on are in [iu-notes.md](iu-notes.md) (the digest of the V8
manual, QEMU and the test suite), and the bus it sits on in [bus.md](bus.md).

Phases (VERILOG-PLAN.md §3): phase 1 is the IU alone, run from a
behavioural memory in Verilator against `tests/cpu`; phase 2 adds the FPU;
phase 3 the SRMMU and caches. The interfaces below are fixed now so the
three can be built and tested separately.

```
                 ┌──────────────────────────────────────────────┐
                 │ cpu_module                                   │
   irl[3:0] ───► │  ┌────────┐ fpop/fq ┌─────┐                  │
   mid[3:0] ───► │  │   IU   │◄───────►│ FPU │                  │
                 │  │        │         └─────┘                  │
                 │  │ F D E M W │ ifetch  ┌──────┐  ┌─────────┐ │
                 │  │        │──────────►│ ITLB │─►│ I-cache │─┼─┐
                 │  │        │ dmem      ├──────┤  ├─────────┤ │ │  MBus-like
                 │  │        │──────────►│ DTLB │─►│ D-cache │─┼─┼─► interconnect
                 │  └────────┘           │ walk │  │ + snoop │ │ │   (bus.md)
                 │       ▲ asi 2-7,      └──────┘  └─────────┘ │ │
                 │       │ 0xC-0x14, 0x36/37: control space     │ │
                 └──────────────────────────────────────────────┘
```

## 1. The integer unit

### 1.1 Pipeline

Five stages, one instruction per cycle on cache hits, in order, with
precise traps:

| stage | work |
|---|---|
| **F** fetch | `pc` → `ifetch` port (the ITLB/I-cache in phase 3; the behavioural memory in phase 1). The register-file read addresses are computed from the fetched word's `rs1`/`rs2`/`rd` fields here, so the RAM-based register file delivers in D. |
| **D** decode | instruction class, operands (register or `simm13`), the window mapping (§1.3), privilege and illegal-instruction checks, the trap tags (§1.5). FPops are handed to the FPU here (§2). Interrupts are attached here. |
| **E** execute | ALU and shifter, `icc`, the effective address for loads/stores (`rs1 + rs2/simm13`) and its alignment check, branch resolution (§1.2), `rd %psr/%wim/%tbr/%y/%asr`, the multiplier and divider (multi-cycle, the pipeline stalls), window overflow/underflow checks for SAVE/RESTORE. |
| **M** memory | `dmem` port: the load/store/atomic, data access exceptions. |
| **W** write-back | register write, `icc`/`Y`/PSR/WIM/TBR writes, trap taking. |

Forwarding: E→E for ALU results (the usual bypass), M→E for loaded data
with a one-cycle load-use stall, `icc` from E to the branch in E (a branch
right after the instruction that sets its condition runs without a bubble).

Stalls: load-use (1 cycle), the multiplier (4 cycles) and divider (≈36
cycles), a FP condition-code or FP-queue interlock (§2), the memory ports
(cache misses, table walks, the atomics), an interrupt arriving while a
`wr %psr` is in flight (§1.5).

### 1.2 Control transfer

SPARC's delayed control transfer: the instruction after a branch (the
delay slot) is always fetched and, unless annulled, executed before the
target. The pipeline fetches sequentially; the branch is resolved in E,
when the delay slot is in D and the instruction after it in F:

- taken: the sequential fetch in F (target-of-nothing, `pc+8`) is dropped
  and F restarts at the target: one bubble per taken branch;
- untaken: nothing happens;
- the annul bit: `a = 1` on an untaken conditional branch (or on BA/BN)
  annuls the delay slot, which is turned into a no-op in D when the branch
  resolves — it must not trap, must not write anything (V8 §5.3.2);
- CALL and JMPL always take (the target is known in E: `pc + disp30`,
  `rs1 + rs2/simm13`); they link `pc` into `%o7`/`rd`;
- RETT: target `rs1 + rs2/simm13`, plus the trap-exit actions (§1.5);
- Ticc: the trap is a trap tag on the Ticc itself; the delay slot is not
  involved.

**DCTI couples** (a DCTI in the delay slot of another DCTI): V8 §B.7 says
the behaviour is implementation-dependent for most couples; the one case
software depends on is `jmpl …; rett …` (every trap handler's return): the
JMPL is resolved in E while the RETT is in D, and the RETT's own target is
computed from its registers in its own E stage, so the pair flows without
a stall. Requirement A1 (`t_dcti`): a JMPL/CALL decoded behind a RETT that
is *held* in E (a store buffer drain, a cache miss) must still link the
JMPL's own address — the link value is the instruction's own `pc` carried
with it down the pipe, never recomputed from the fetch unit.

PC and nPC are kept as such: `pc` and `npc` travel with each instruction
(a trap saves exactly them in `%l1`/`%l2`).

### 1.3 Registers

- **Register file:** 8 globals + 8 windows × 16 = 136 registers, in block
  RAM, three read ports (`rs1`, `rs2`, and `rd` for store data and the
  second register of `std`/`ldd` pairs) and one write port, so three M10K
  copies written together. `%g0` reads as 0 and is never written.
- **Window mapping:** with `cwp` the current window and `r` in 8..31,
  physical index `= (16·cwp + (r − 8)) mod 128`. So a window's outs
  (`r8..15`) are its `16·cwp + 0..7` and its ins (`r24..31`) are
  `16·cwp + 16..23 = 16·(cwp+1) + 0..7`, the outs of window `cwp + 1`;
  SAVE decrements `cwp`, and the caller's outs become the callee's ins.
  The physical address is formed in F from the fetched fields and the
  committed `cwp` (a SAVE/RESTORE in E/M/W changes `cwp` for the
  instructions behind it: they are stalled until it writes back, which is
  rare enough not to matter).
- **PSR**: `impl = 4, ver = 0` (TI SuperSPARC, QEMU `TI-SuperSparc-60`,
  `iu-notes.md` §6), `icc` (N Z V C), reserved bits read 0, `EC` (no
  coprocessor: writes ignored, reads 0), `EF`, `PIL`, `S`, `PS`, `ET`,
  `CWP`. After reset: `S = 1`, `ET = 0`, `EF = 0`, the rest unspecified by
  V8; we clear them (`CWP = 0`, `PIL = 0`).
- **WIM**: 8 valid bits (bits 8-31 read 0). **TBR**: `TBA` (20 bits) and
  `tt` (8 bits), bits 3:0 zero; `wr %tbr` writes TBA only. **Y**.
- **ASRs**: `rd %asr15` with `rd = 0` is STBAR; other `%asrN` reads return
  Y and writes are no-ops, as on the microSPARC/SuperSPARC (`t_rdasr`:
  OpenSSL reads `%asr2` to tell V8 from V9).
- The write-delay rule (`wr %psr/%wim/%tbr/%y`: the three following
  instructions may see either value) is honoured by committing the write
  in W; software written to the rule cannot tell.

### 1.4 Arithmetic

- ALU: add/sub with carry, logic, shifts, `sethi`; `icc` per V8 Appendix
  C (overflow = carry into the sign xor carry out; the tagged ops check
  bits 1:0 of both operands).
- `mulscc`: one cycle (the 1-bit step with Y and icc, V8 §B.17).
- `umul`/`smul`(`cc`): a 32×32 multiplier in DSP blocks, 4 cycles,
  result low word to `rd` and high word to Y; `icc` on the low word (V,
  C = 0).
- `udiv`/`sdiv`(`cc`): the 64-bit (Y:rs1) by 32-bit divide, restoring, one
  bit per cycle (≈36 cycles); overflow → the saturated result and V = 1 for
  the `cc` form; divide by zero → tt 0x2A. **Not** QEMU's negative-divisor
  bug (`tests/cpu/README.md` deviation 1).
- The tagged `taddcctv`/`tsubcctv` trap (tt 0x0A) with the result not
  written.

### 1.5 Traps and interrupts

Precise. Every instruction carries a trap tag (`tt`, valid) set by the
first stage that detects a condition, in priority order (V8 Table 7-1):
instruction access (from `ifetch`), illegal/privileged/unimplemented
(D), `fp_disabled`/`cp_disabled` (D), window overflow/underflow (E),
alignment and the tagged overflow (E), `fp_exception` (the deferred one
attaches to the next FP instruction, §2), data access (M), Ticc (D, with
the condition evaluated in E), divide by zero (E). An interrupt (`irl`
> `PIL`, or 15, with `ET = 1`) is attached in D to the next instruction
to enter D as tt `0x10 + irl`.

The tagged instruction reaches W without side effects (its register write,
`icc`, memory access were suppressed from the stage the tag was set), and
at W the trap is taken: `ET ← 0`, `PS ← S`, `S ← 1`, `CWP ← CWP − 1`
(mod 8, no window check), `%l1 ← pc`, `%l2 ← npc`, `tt ← code`, F restarts
at `TBR` (= `TBA | tt << 4`), `npc = TBR + 4`; every younger instruction
in F/D/E/M is flushed. Reset is tt 0 with PC = 0 (the SS20 boot mode maps
the PROM there) and `ET = 0`.

RETT: with `ET = 1` it is an illegal instruction (tt 0x02, and the manual's
rules for the privileged/underflow cases, `iu-notes.md` §2); otherwise
`CWP ← CWP + 1` with the window-underflow check against WIM (tt 0x06),
`ET ← 1`, `S ← PS`, target as a JMPL.

**Error mode**: a trap while `ET = 0` (or a RETT with ET = 1 taken as a
trap while ET = 0) puts the IU in error mode: it stops and raises
`error_o`. The SuperSPARC's response is a watchdog reset of the module
(requirement IU-1, `wdtest`): the module restarts at tt 0 with
`PSR.ET = 0`, memory untouched, the MMU's SFSR `EM` bit set and the reset
register's `WD` bit set (Sun-4M §4.6), so the PROM can tell a watchdog
reset from a power-on. The CPU module does this itself from `error_o`
(§4); the system is told through the interconnect's module-error signal.

Interrupts are sampled every cycle from `irl_i` (the interrupt
controller's per-processor IRL, [bus.md](bus.md)) and compared with the
committed `PIL`; a `wr %psr` in E/M/W delays the comparison until it
writes back, so an interrupt is never taken with a stale PIL.

### 1.6 Memory access

The `dmem` port carries: VA, ASI, size (1/2/4/8 bytes), read/write,
write data, and the atomic flag for `ldstub`/`swap` (a read-modify-write
the cache performs as one locked transaction on the interconnect,
`t_smp_atomic`). `ldd`/`std` are two 4-byte beats of one 8-byte access
(`size = 8`, doubleword aligned). Alignment is checked in E (tt 0x07,
nothing written). The ASI comes from the instruction (`lda`/`sta`,
privileged: tt 0x03 from user mode) or from `PSR.S` (8/9 user/supervisor
instruction, 0xA/0xB data). The response carries the data or a fault code
that becomes tt 0x09 (data access exception) or 0x2B (data access error,
on a bus error), with the MMU holding SFSR/SFAR.

`ifetch`: PC, the ASI implied by `S` (8/9), and the response's instruction
word or fault (tt 0x01 / 0x21). In boot mode (MMU control `BM = 1` after
reset) fetches go to the PROM at PA `0xF_F000_0000` (the SS20 maps it
at PA 0 too); the SRMMU phase defines the rest.

Control-space ASIs (2-7, 0xC-0x14, 0x36, 0x37, 0x4C) are routed by the
`dmem` port's ASI to the MMU and the caches (phase 3); in phase 1 the
behavioural memory answers them with 0 and ignores writes.

### 1.7 The FPU interface (phase 2)

`fpu_pkg::fpu_req_t` / `fpu_rsp_t` (`rtl/cpu/iu.sv`, `rtl/cpu/fpu.sv`):

- FP instructions (FPop, FBfcc, FP load/store) go through the IU **one
  at a time**: the next waits in D while one is in E/M/W or the FPU is
  busy. So when an FP instruction reaches E the FPU's state is final and
  E decides, after the alignment check (Table 7-1: mem_address_not_aligned
  10 before fp_exception 11; `t_fpu_trap_prio`): the deferred
  `fp_exception` when the FPU is in fp_exception_pending; a sequence
  error (`ftt = 4`) for an FPop/FBfcc/FP load in fp_exception, or for
  `stdfq` with `qne = 0` (`t_fpu_fq`); the FBfcc condition on the FSR's
  fcc. `fp_disabled` (tt 0x04) is tagged in D when `PSR.EF = 0`.
- An FPop is handed to the FPU with its word and `pc` when W commits it;
  the FPU writes its own registers when done. FP loads write the FPU's
  registers (or the FSR) at W from the load data; FP stores take their
  data from the FPU in E (a register or pair, the FSR, the FQ's front
  entry); `stdfq` pops the queue at W. `trap_taken` tells the FPU an
  fp_exception trap was taken: from fp_exception_pending it enters
  fp_exception (the FQ holds the faulting FPop and its address), otherwise
  it records the sequence error.
- Cost: an FP instruction needs about five cycles of pipe plus the FPU's
  execution before the next one can issue. Good enough for the POST and
  the OS; a pipelined FPU with scoreboarding is a later improvement that
  changes only this interface's timing, not its rules.

## 2. The FPU

SPARC V8 single and double precision: `fadds/d`, `fsubs/d`, `fmuls/d`,
`fsmuld`, `fdivs/d`, `fsqrts/d`, the compares (`fcmps/d`, `fcmpes/d`),
the conversions (`fitos/d`, `fstoi`, `fdtoi`, `fstod`, `fdtos`), `fmovs`,
`fnegs`, `fabss`; quad traps as unimplemented (`ftt = 3`), as on the
SuperSPARC. 32 single registers, pairs for doubles. The FSR: `RD`, `TEM`,
`NS` (reads 0), `ver` (0), `ftt`, `qne`, `fcc`, `aexc`, `cexc`; a
one-entry FQ; the fp_execute / fp_exception_pending / fp_exception states
of V8 §4.4.

Arithmetic (`fp_unpack`, `fp_round`, `fp_divsqrt`): operands are unpacked
to a normalised 53-bit significand (subnormals exactly), results are
formed exactly as a 58-bit significand plus a sticky bit and rounded once.
Add/sub align with three guard bits and a sticky; multiply is a 53×53
product registered twice; divide (57 steps) and square root (58 steps)
are restoring, one bit per cycle; the conversions and compares are direct.
Conventions (`tests/fpu/README.md`, from V8 App. N, the Viking manual and
QEMU): tininess detected **after** rounding; UF raised when tiny and
inexact, or tiny with `TEM.UF`; a signalling NaN raises invalid and wins
over a quiet one, otherwise rs2's NaN is returned quieted; the default
NaN is 0x7FFFFFFF / 0x7FFFFFFFFFFFFFFF; `F?TOi` out of range gives
0x7FFFFFFF or 0x80000000 by sign (a NaN 0x7FFFFFFF) with invalid.

Verification: `tests/fpu/fpref.py` is an exact IEEE 754 model (Python
rationals) with the conventions above; `gen_vectors.py` writes 617k
vectors (every op, both precisions, all four rounding modes: random
operands plus every special-case class, halfway cases, subnormal
boundaries, the `t_fpu` values); `rtl/cpu/tb/tb_fpu.sv` runs them through
the FPU's own interface and then exercises the trap states. The
acceptance tests are `t_fpu` and the `t_iu2` FPU checks in `sim/iu`.

## 3. The MMU and caches (phase 3)

Fixed here only as interfaces: the SRMMU with a 64-entry TLB (the
SuperSPARC diagnostic image of ASI 6, `t_mmu_diag`), the three-level walk
through the `dmem`-side bus port, the control registers of ASI 4
(control at 0x000 with the SuperSPARC MCNTL bits, CTPR 0x100, context
0x200, SFSR 0x300, SFAR 0x400, AFSR 0x500, AFAR 0x600, reset 0x700), the
flush/probe ASI 3, the bypass ASIs 0x20-0x2F; I-cache and D-cache of 16 KB,
4-way, 32-byte lines, physically tagged, write-through with snoop
invalidation from the interconnect, flushable by the ASI 0x10-0x14 range
and the flash clears 0x36/0x37, readable through the diagnostic ASIs
0xC-0xF; main memory cached even where a PTE says `C = 0` (E3). The L2
TLB (MCNTL bit 6) as an option (`t_mmu_l2`).

## 4. The module

`cpu_module` wraps the four: the interconnect master port (fetch and data
sharing one port with the fetch side given priority on a miss), the snoop
input with its hold output (`snoop_hold_o`: a cache's 16-entry snoop queue
is nearly full, bus.md), `mid_i` (the MBus module ID, 8 + n), `irl_i`, the module reset
with its causes (power-on, software, the watchdog from `error_o`), and the
module-error output. Two modules in the first SS20 build, up to four if
they fit (VERILOG-PLAN.md §1.3).

## 5. Verification

- Phase 1: `sim/iu/` — the IU with a behavioural 36-bit memory (the test
  ROM image at PA 0 / `0xF_F000_0000`, 16 MB of RAM), the `escc` block at
  `0xF_F110_0000` through ASI 0x2F with a serial-line decoder printing
  ttya, and stubs for the other control-space addresses the suite's
  runtime touches. Runs `tests/cpu/out/ss20/cputest.rom` under Verilator
  and compares with `tests/cpu/expected/ss20-qemu.log` minus the QEMU
  deviations. Exit: `t_alu`, `t_branch`, `t_dcti`, `t_ldst`, `t_psr`,
  `t_traps`, `t_window`, `t_iu2`, `brktest`.
- A unit bench per block (`rtl/cpu/tb/`): the register file and window
  mapping, the multiplier and divider against a Python model (as
  `gen_alu.py` does for the ALU), the trap sequencer.
- Phase 2: `t_fpu`; TestFloat vectors.
- Phase 3: the MMU/cache tests; the whole suite from the real boot
  address; the Sun PROM's POST in `sim/`.

## 6. Timing targets

≥ 55 MHz is the plan's floor; the design aims higher so that two modules
fit with margin: the register file in RAM (addresses from the fetch
stage), the ALU result registered before the `icc` compare of the branch,
no combinational path from the memory response into the ALU, the
multiplier in DSP blocks. `bmbench` and `tlbbench` measure the result.
