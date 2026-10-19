# CPU test suite

A bare-metal SPARC V8 test suite that runs **as the boot PROM**. It starts
at the reset vector with the MMU off, sets up traps, windows and a stack,
prints on ttya (ESCC channel A, 9600 8N1), and runs its tests one after
another. The same source runs in three places:

| target | runs on | PROM link address |
|---|---|---|
| `ss5-qemu` | `qemu-system-sparc -M SS-5` | `0x70000000` (a real SPARCstation 5's) |
| `ss20` | `qemu-system-sparc -M SS-20`, and the core's SS20 build | `0` (boot mode); pa `0xF_F0000000` |

The SS20 PROM is not readable at its link address with the MMU off, so
`runtime.S` first copies the image to RAM at pa 0. From then on, constants
and strings are read at their link addresses, while instructions keep
coming from the PROM in boot mode (`platform.h`).

The suite holds the generic V8 ISA tests, and the SRMMU, cache, SMP and
remaining IU/FPU tests written as acceptance tests for the SS20 MMU and
cache work. The POST's diagnostic-ASI tests (TLB and cache
RAM marches, MXCC) are not lifted.

## Build and run

```sh
python3 tests/cpu/build.py                 # all targets -> tests/cpu/out/<target>/cputest.rom
python3 tests/cpu/build.py ss5-qemu -DDETAIL_LIMIT=4000   # print every failing check
tests/cpu/run-qemu.sh ss5                  # run under QEMU, compare with expected/ss5-qemu.log
tests/cpu/run-qemu.sh ss20
```

Toolchain: LLVM 18's `clang --target=sparc-unknown-elf -mcpu=v8` (its
integrated assembler handles V8, the privileged instructions and ASIs
included), and [`tools/sparc_link.py`](../../tools/sparc_link.py), because
LLVM has no 32-bit SPARC linker. Everything is one translation unit
(`src/main.S`). [`tools/romdis/sparcv8.py`](../../tools/romdis/sparcv8.py)
disassembles an image:

```sh
python3 tools/romdis/sparcv8.py tests/cpu/out/ss5-qemu/cputest.rom 0x70000000 0 0x100
```

On the core: `scripts/hwtest.sh 20 cpu` runs `out/ss20/cputest.rom` as
`boot.rom` and compares ttya with `expected/ss20-core-hw.log`; by hand, load
it with the OSD's **Load ROM** and read ttya from the MiSTer UART.

## Output

```
CPUTEST ss5-qemu psr=04400fc0 nwindows=8 fpu=1
PASS alu: sethi / set / %hi %lo
FAIL alu: every integer ALU instruction, table of vectors
    check 0010a570 exp=ffffffff obs=00000000
...
CPUTEST DONE pass=29 fail=3 skip=0
```

Each `check` line names the check code, the expected value and the
observed one. At most 16 are printed per test (`DETAIL_LIMIT`). ALU vector
codes are `0x100000 + row*16 + {0 result, 1 icc, 2 Y, 3 trap}`; look the
row up in `out/alu_vectors.txt`.

## What is tested

| file | tests |
|---|---|
| `t_alu.S` + `gen_alu.py` | 3748 one-instruction vectors over every integer ALU op, register and immediate forms: add/sub with carry, logic, shifts, umul/smul (Y), udiv/sdiv with overflow and divide-by-zero, mulscc, tagged add/sub and their trapping forms. Checks the result, icc and Y, and whether it trapped. Expectations come from a Python model of the V8 manual. Also sethi/simm13 and the Y register. |
| `t_ldst.S` | load widths and sign extension, byte order, partial stores, ldd/std, ldstub/swap, lda/sta, alignment traps (nothing written, trap PC) |
| `t_branch.S` | all 16 Bicc and all 16 Ticc conditions against all 16 icc values (`gen/cond_tab.S`), annul bit and delay-slot cases, call/jmpl links, misaligned jmpl |
| `t_traps.S` | software trap numbers, illegal instructions, rett with ET=1 (illegal_instruction in supervisor mode, privileged_instruction from user mode: the test drops to S=0 and comes back with `ta SVC_SUPER`), divide by zero, tag overflow, fp_disabled, cp_disabled |
| `t_window.S` | save/restore overlap, CWP arithmetic, 40-deep recursion through the spill/fill handlers, NWINDOWS |
| `t_psr.S` | read-only impl/ver, PIL, icc, TBR.tt and TBA |
| `t_cache.S` | SS5 only: MMU on with an identity map (RAM cacheable, I/O uncached, PROM cacheable), I- and D-caches enabled, a routine copied to cacheable RAM run cold and warm (stores, loads, load-use pairs, taken branches to the same and to another 32-byte line), then everything off again. The only test that touches the caches: the rest of the suite runs with the MMU off, on the core's non-cacheable path. |
| `t_fpu.S` | single and double arithmetic, conversions, fcmp/fcc/FBfcc, FSR cexc/aexc |
| `t_chipset.S` | not CPU tests: chipset state after a power-on reset and address decode, with the suite's plumbing. The system control register reads RS = WD = 0; the NVRAM IDPROM has format 1, the machine type (0x80 SS5, 0x72 SS20) and a zero XOR checksum; the frame buffer's slot starts with FCode (`0xf1`, sane length); DMA2 E_BASE_ADDR resets to 0xff; on the SS5 the PROM answers at pa `0x7000_0000` |
| `t_mmu_swift.S` | SS5 only: the POST's microSPARC-II MMU register walking-pattern tests (CTPR, context, TLB replacement control `0x1000`, SFSR/SFAR diagnostic aliases `0x1300`/`0x1400`), with the POST's masks; AFSR/AFAR (`0x500`/`0x600`) read 0. It probes first whether `0x1000` aliases the PCR, as it did on the core before ASI 4 was decoded from VA[12:8] (audit MMU-1), and reports that instead of walking. |
| `mmu_setup.S` | not a test: the MMU-on setup the tests below share. Page tables in `SCRATCH` built through the bypass ASI: an identity map of the first 16 MB (code, VARS, stack; the SS20 runs from the shadow copy of the PROM at pa 0 once boot mode is off, the SS5 maps its PROM region), cacheable, with one page-mapped segment `MT_SEG` (0x280000) whose entries the tests use (invalid, reserved, read-only, supervisor-only, non-cacheable pages, a remappable page), a cacheable alias of RAM at VA 0x4000_0000, and on the SS20 contexts 1, 0x101 and 0x8001 in a 256 KB-aligned context table. `mmu_on` turns the MMU and both caches on (plus SE on the SS20); `mmu_off` flushes the lines the suite may have dirtied (write-back mode), turns everything off, flash-clears (SS20) and clears every tag so the uncached rest of the suite never meets a stale line. Leaf routines: the parked SS20 CPUs use them too. |
| `t_mmu.S` | `t_mmu_ctx_bits` (SS20): walking one over the 16 context bits and CTPR bits 31:6 (the SS20 POST's "MMU Context Table Reg" / "MMU Context Register" tests, QEMU's masks). `t_mmu_ctx_hi` (SS20): contexts 1, 0x101 and 0x8001 map the same VA to three pages (audit MMU-3). `t_mmu_tlb_flush`: a PTE changed in memory is read through the old TLB entry until the page, segment, region, context or entire flush (ASI 3). `t_mmu_probe`: ASI 3 probe types 0-4 on valid entries at every level, 0 on invalid and reserved entries and on a PTE above the level asked for (V8 H-4, microSPARC-II 5.5.2; MMU-5). `t_mmu_fault_regs`: SFSR L/AT/FT/FAV/OW and SFAR for invalid (levels 3 and 1), reserved, protection and privilege (from user mode) faults, read-to-clear, OW on a second data fault, NF (MMU-8). `t_mmu_ifault`: a jump mid-page into an invalid page traps tt 1 with SFSR 0x366 and no OW, although the fetch unit's next fetch faults too (Solaris 8 loops on user text faults when OW is set); it returns through the runtime's `V_TRAP_RESUME`. |
| `t_cache2.S` | `t_flash_clear` (SS20): a stale D-cache line (memory changed through the bypass and through a normal store with DE off) is dropped by ASI 0x37, a patched routine by ASI 0x36 (C-2). `t_cache_wrhit` (SS20, from the POST's "D-Cache Write Hit Special Test"): 16 KB filled by loads, every word stored, read back cached and through ASI 0x20; prints `dcache mode: write-through` or `write-back` (the board's WB option) and checks the matching expectation, then flushes every line and checks memory. `t_cache_flush_miss` (SS20): a line cached through the RAM alias (PA != VA), dirtied in write-back mode or changed in memory behind it in write-through mode, has its DTLB entry evicted and is then flushed by VA with ASI 0x10: a flush that took PA = VA on the miss leaves it stale (C-3). `t_cache_atomic`: `ldstub` and `swap` on a cached line change only their byte / word, in the cache and in memory after a line flush. `t_cache_wback_burst` (SS20): 32 lines of distinct words are each made modified by an `ldstub` and flushed; the memory image must match word for word (a bus-to-Avalon bridge once wrote the odd word of a 64-bit pair twice when the DDR stalled that beat, which fed the lock byte into `t_smp_atomic`'s counter). `t_selfmod`: a routine in cacheable RAM is patched with a normal store, FLUSHed and run again. |
| `t_cache3.S` | line fills on a bus that does not deliver a burst back to back (the MiSTer DDR port under load; `sim/obj_ss20/Vsim_top --ddr-gaps` reproduces it). `t_cache_fill_words`: 2048 lines, a load of word 0 misses and the next instructions load words 7 down to 1; then, with memory changed behind the cache, the same with stores, a bypass read to wait for the fill, and loads back. `t_icache_fill_words`: ten code lines 4 KB apart share one I-cache set, four of nops, six of `add %o0, k` x 7 ending in `retl`; the add lines are called 64 times each (every call a miss) and must return 7k. Both fail whenever a beat gap lets a fetch, load or store of a not yet written word of the line hit the evicted line's words (on an SS20 build with that bug, Solaris 8 and NetBSD corrupted memory under disk I/O). |
| `t_smp.S` | SS20, SKIP where the secondary CPUs do not run (QEMU). CPU 1 and 2 run functions through the dispatcher (`runtime.S`: `mp_post`/`mp_wait`; the parked CPUs poll a mailbox and call the function with the MMU off, no stack, traps disabled). `t_smp_coherent`: CPU 0 holds a line, CPU 1 stores to it with its cache and SE on, CPU 0's next load sees the store, memory too after CPU 1's flush. `t_smp_atomic`: three CPUs add 64 each to a shared counter under an `ldstub` lock, then under a `swap` lock; the total is exact. `t_smp_nosnoop`: with SE off CPU 0 keeps its stale copy, as the module does (C-4). |
| `t_iu2.S` | `t_fpu_trap_prio`: a misaligned FP store with an fp_exception pending takes tt 7 first (V8 table 7-1; FPU-1), works for precise (QEMU) and deferred FPUs. `t_fpu_fq`: the FQ holds the trapping FPop, STDFQ is privileged, empties it, and traps with ftt 4 when it is empty (FPU-2). `t_cp_ldst`: the V8 LDC/STC family (op3 0x30-0x37) traps cp_disabled, in user mode too, without touching memory (IU-3). `t_wrpsr_cwp`: `wr %psr` with CWP = NWINDOWS traps illegal_instruction (IU-5). `t_rdasr`: reserved ASR reads return Y and ASR writes do nothing, as on the microSPARC-I/II (OpenSSL's libcrypto reads `%asr2` to tell V8 from V9: NetBSD's `syslogd` and `login` died of SIGILL when the core trapped it); CASA traps illegal_instruction (IU-6). `t_asi_width` (SS20): ASI 0x4c does not reach the ASI 0x0c tag (MMU-12) and reads back what was written (the ACTION register: Solaris 8 writes 0x1000 and loops until it reads it back); ASI 0x38 holds 64-bit values (SMP-1). |
| `t_dcti.S` | `t_rett_jmpl`: a trap return built by hand (`save`, ET off, N stores, `jmp %l1; rett %l2`) to a `jmpl %g1, %o7` whose leaf callee returns through `%o7`, caches on, N = 0, 1, 2, 4, 8, 16 times each: `%o7` must be the jmpl's address. The IU exempts a JMPL/RETT in DEC from the stall it applies while a JMPL/RETT is in EXE (so that the couple flows), and decoded the RETT's target with the fetch unit's stale pc while the RETT was held in EXE behind the stores: the link pointed at the RETT, and the callee's `retl` landed 8 bytes after it (OpenBIOS's level-14 handler returning to Forth's `call %g1` fell into the window spill handler, 2026-10-03). Fails on the unfixed IU in simulation (6 of 16 with 8 stores), passes under QEMU. |
| `t_mmu_diag.S` | SS20 only (SKIP elsewhere): the SuperSPARC TLB diagnostic image (ASI 6, MMU-2) as the POST uses it. `t_mmu_diag_pattern`: 64 entries x SEL0-3 take the four pattern sets (0xaaaaa000/0xaaaa/0xaaaaaaaa/0, 0x55555000/0x5555/0x55555555/1, 0xfffff000/0xffff/0xffffffff/1, zeros) and read back. `t_mmu_diag_flush`: the POST's five flush modes abridged (context: SEL1 = e, context := j, demap type 3; region, segment, page: SEL0 = e << 24/18/12 at level 1/2/3, demap j << shift; entire: one demap): after step j entry j reads SEL2 with V cleared and entry j + 1 unchanged. MMU off. |
| `t_buserr.S` | bus errors (PLAN.md A3/B1): a read the chipset refuses (an empty SBus slot, SS20 slot 0 at pa `0xe_0000_0010` through ASI 0x2e; the SS5 POST's `0x7cc00010`). `t_buserr_load`: tt 0x29, the destination unchanged, SFSR `0x816` (TO, AT 0, FT 5, FAV), SFAR the VA, clear-on-read; `ldstub` (`0x896`, a store for the MMU); OW on a second error; NF records without a trap; a store is posted and never traps. `t_buserr_mapped`: the slot behind a page of `MT_SEG`: a load (`0x836`, AT 1), a jump into it (tt 0x21, `0x874`, no FAV), the segment's level-3 table moved into the slot (tt 9, `0xb32`: TO, L 3, FT 4). **Both SKIP while the probe read comes back without a trap**: the core before B1, the SS5, and QEMU (note 11). |
| `t_mmu_l2.S` | the second-level TLB (MCNTL bit 6 with the OSD option; `--l2tlb` in the simulation) must stay invisible. `t_mmu_l2_asi6`: an ASI 6 write drops the TLBs and the L2 TLB (a changed PTE is seen with no ASI 3 flush). `t_mmu_l2_enable`: an entry cached at generation g, evicted from the D-TLB by 8 other pages, the PTE changed, 256 CTPR writes with bit 6 off (the generation wraps to g), bit 6 on again: the walk must read the tables (the core sweeps the L2 TLB RAM when bit 6 comes on). `t_mmu_l2_probe`: an ASI 3 probe returns the PTE in memory after a change with no flush. Without the option they pass trivially; QEMU passes them. |

## Known QEMU deviations

The QEMU reference logs (`expected/*-qemu.log`, from QEMU 11.1.1; the
SS20 runs with `-cpu TI-SuperSparc-60`, the core's CPU) are not all-PASS.
Each failure in them is QEMU disagreeing with the SPARC V8 manual or the
SRMMU documents, checked against QEMU's source:

1. **`sdiv`/`sdivcc` with a negative divisor.** `helper_sdiv` does
   `a64 /= b;` with the unsigned 32-bit `b` instead of the signed `b32`
   it has just computed (`target/sparc/helper.c`). For example, 1 / -1
   gives 0. 69 ALU checks fail, all sdiv/sdivcc with a divisor ≥ 2^31.
2. **nPC of a trap on a `rett` in a `jmp`'s delay slot.** QEMU reports
   nPC = the rett's own target (`jmp` target + 4) instead of the `jmp`
   target, so the handler resumes one instruction late.
3. **`wr %tbr` overwrites TBR.tt.** `do_wrtba` moves the whole value into
   `%tbr`; V8 says WRTBR writes TBA only and tt keeps the last trap type.

4. **DMA2 E_BASE_ADDR resets to 0.** The DMA2 manual gives 0xff (the
   Ethernet DMA's high address byte); QEMU leaves the register at 0. Solaris
   never writes it and assumes 0xff (OpenBIOS `ob_le_init`). New in the
   11.1.1 references with `t_chipset.S`.
5. **A probe returns a PTE found above the level asked for.** `mmu_probe`
   returns a level-2 PTE to a page probe (type 0); the microSPARC-II manual
   (5.5.2) and V8 table H-4 give 0. `t_mmu_probe` check 11.
6. **SFSR.L is 0 for protection and privilege faults.** `get_physical_address`
   returns the access-table error without the level; the SRMMU's L is the
   level of the entry that faulted. `t_mmu_fault_regs` checks 11 and 13.
7. **`rd %asr15` with rd != 0 is a STBAR** (rd is not written). The
   microSPARC-I and -II manuals say every ASR read acts as RDY and only
   STBAR (rd = 0) sends it to `%g0`; QEMU's other reserved ASRs do read Y
   and its ASR writes are NOPs, as on those chips. `t_rdasr` check 4.
8. **The sequence_error trap of an empty STDFQ is reported one instruction
   late** (PC = the next instruction); `t_fpu_fq` has a `nop` after it.
   Also, QEMU's FPU is precise (the fp_exception is taken on the FPop
   itself, not deferred to the next FP instruction), which V8 allows; the
   FPU tests accept both: when the trap has not been taken yet after the
   FPop or the STDFQ, they execute one more FP instruction to collect it.
9. **NF: the suppressed fault is recorded twice** (once by the walk, once by
   the redirected access), so OW is set; `t_mmu_fault_regs` masks OW there.
10. **A page flush inside a large page's range flushes the whole TLB.**
    QEMU maps segment-level PTEs as 256 KB pages and `tlb_flush_page` then
    degrades to a full flush; `t_mmu_tlb_flush` does not test that a page
    flush of another page keeps the entry.

11. **Bus errors.** QEMU traps an unassigned access only with the MMU on,
    as tt 9 (data_access_exception) with FT 5 and AT but no TO/BE bit, and
    puts the *physical* address in the SFAR (`sparc_raise_mmu_fault`); with
    the MMU off it records the SFSR and goes on. `t_buserr.S` probes with
    the MMU off and SKIPs there.

12. **No cache.** QEMU models no cache, so `t_cache_force` (a C = 0 page
    of main memory is cached on the SS20) sees the bypass write behind the
    cache and fails there (check 2); it passes on the core.

The core has to follow the manual, not QEMU. On the core, these tests are
expected to pass.

Assembler note: LLVM encodes an out-of-range 13-bit immediate silently
(`add %o1, 0x1000` became `add %o1, -0x1000`; `cmp %l1, 0x4000` compares
with 0). Use `set` and a register for anything outside -4096..4095, and
never put a two-instruction `set` in a delay slot.

## Writing a test

```asm
#include "macros.h"
BEGIN(t_name, "area: what it checks")     /* registers the test, does a save */
        ...
        EXPECT(%l0, 0x1234, 1)            /* obs register, expected constant, code */
        EXPECT_TRAP(TT_ALIGN)             /* arm the trap catcher */
        ld [%l1 + 2], %l2
        CHECK_TRAPPED(TT_ALIGN, 2)
END
```

Add the file to `src/main.S`. Register conventions are at the top of
`src/macros.h`: `%g7` belongs to the runtime; `EXPECT` clobbers the outs
and the icc.
