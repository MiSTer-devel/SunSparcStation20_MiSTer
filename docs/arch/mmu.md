# The MMU and the caches (phase 3 design)

The design of the SRMMU, the two L1 caches and the data-side sequencer of
the CPU module, from the facts in [mmu-notes.md](mmu-notes.md) (cited
there; this page gives decisions, not sources). The plan's requirements
are VERILOG-PLAN.md §2 and §6 (E3, A3/B1, L2, MMU-2/12, SMP-1, IU-1); the
acceptance list is mmu-notes.md §7.

## 0. Decisions

| Question | Decision | Why |
|---|---|---|
| I-cache geometry | **The real SuperSPARC one: 20 KB, 5 ways × 64 sets × 64-byte lines, a valid bit per 32-byte half-line; fills by half-line.** | The POST and `t_cache_diag` walk the diagnostic image (ASI 0x0C/0x0D) way 0-4, set VA[11:6], and check the two valid bits; the OBP's STAG loop runs at a 64-byte stride. A different storage would need a translated image anyway; the real one costs 20 KB of BRAM. |
| D-cache geometry | The real one: 16 KB, 4 × 128 × 32 B. | ASI 0x0E/0x0F image, the POST's #8. |
| Write policy | Write-through, no write-allocate, both caches physically tagged; main memory cached whatever PTE.C says (E3); snoop invalidation from every write on the interconnect (the own module's writes included for the I-cache, excluded for the D-cache, which updates its line instead). | PLAN §2; `t_cache_force`, `t_selfmod`, `t_smp_coherent`, `t_flash_clear`. Copy-back (MBus mode on the real chip) buys nothing on this interconnect and costs owned-line handling. |
| TLB | 64 entries, fully associative, unified, Viking's replacement (first invalid, else limited-history LRU with lock bits), the ASI 6 image stored as the Viking fields (SEL 0-3), two lookup ports (I and D), one shared walker. **Built from RAM** (2026-10-12): the image in three 64-word RAMs, V/lock/used in flops, the CAM as nine 16-row × 64-bit RAMs (§2). | MMU-2, `t_mmu_diag`, the watchdog path's TLB writes. The flop CAM was 9,200 ALMs, half the CPU; the RAM one is ~1,700 ALMs (the whole `srmmu`) and 21 M10K. |
| L2 TLB / PTP cache (MCNTL bit 6) | Not in this version: bit 6 is stored and ignored; `t_mmu_l2` passes trivially. | PLAN §2 calls it an option; the Viking-size TLB makes it a performance item for later (`tlbbench`). |
| Bus errors | V8's traps as the suite and the POST expect: `instruction_access_error` 0x21 / `data_access_error` 0x29 with FT 5 and TO (never BE); a table-walk error is FT 4 + L, trapped as the access exception of the access (tt 1 / 9). | mmu-notes §4.2; Viking's "always tt 1/9" is not what the SS20 PROM checks. |
| FAV on instruction faults | Set, SFAR = the fetch VA. | `t_mmu_ifault` expects 0x366 (Viking would not write the SFAR). Bus errors on fetches: 0x874, no FAV (the suite). |
| SFSR overwrite | V8 §H.5 classes (instruction, data, translation) with its OW rules; read at 0x300 clears, 0x1300 reads without clearing and is writable; 0x1400 the SFAR alias. | `t_mmu_fault_regs`, `t_mmu_ifault`, `wdtest` (0x1300 is Viking's non-clearing alias, in place of the project-private 0xB00). |
| ASI 4 decode | VA[12:8]; 0x000 MCNTL, 0x100 CTPR (bits 31:6 kept), 0x200 CTX (16 bits), 0x300/0x400 SFSR/SFAR, 0x500/0x600 read 0, 0x700 reset register (bit 2 WD read-only, bit 1 SI write-1 → module reset), 0x1000 a 32-bit storage register (TLB replacement control, written by the SS5 OBP), 0x1300/0x1400 aliases, 0xD00 SYSCONF read-only (a project-private configuration word, read by OpenBIOS and the suite: RAM MB in 31:20, SS20 in bit 4, the CPU count minus one in 1:0; parameters `RAM_MB`, `SS20`, `NCPU_M1`); anything else reads 0, writes ignored. Word access only; other sizes → data_access_exception with CS. | Viking Table 4-9 + what software touches; the Viking "data_access_exception for undefined VAs" is replaced by read-0 (DEC-3 spirit) so that an unexpected probe cannot stop a boot. |
| MCNTL | Reset 0x0100_2800: IMPL 0 VER 1, BM (bit 13), MB (bit 11, read-only 1). Writable bits: PF 18 (stored), TC 16 (stored), AC 15, SE 14, BM 13, PE 12 (stored), SB 10 (stored), IE 9, DE 8, PSO 7 (stored), bit 6 (stored), NF 1, EN 0. Bits 3:2 read 0 (no CPU number there; the MID is in ASI 0x38 / the MSI). | mmu-notes §2.2. |
| Probe | Always a walk that does not touch the TLB; V8 Table H-4 results; no SFSR update except a bus error (FT 4 + L, no trap). | `t_mmu_probe` (deviation 5), `t_mmu_l2_probe` (the memory PTE, not a cached one). |
| M bit on a TLB-hit store with M = 0 | Drop the entry and re-walk; the walk sets R+M with one plain word write. | No PTE address to keep per entry; V8's atomicity note is about R-only updates racing another CPU's R+M — this core writes R+M together on a walk, and an R-only update also as a plain write (noted as a deviation from Viking's atomic swap). |
| Flush ASIs 0x10-0x14 (0x18-0x1C) | A store translates the VA (walk on a miss, faults ignored) and drops the line from both caches (0x18-0x1C: the I-cache only). The `FLUSH` instruction is a pipeline no-op. | `mmu_setup`'s `mmu_flush_lines`, `t_cache_flush_miss` (C-3). |
| Reserved ASIs, ASI 2, 0x30-0x32 | Read 0, writes ignored; ASI 5/7 writes also drop every TLB entry. | A trap on an unknown ASI is a boot risk; the plan asks for ASI 5/7 writes to drop the TLBs (NeXTSTEP). |
| ASI 0x38, 0x49-0x4C | Storage: four 64-bit breakpoint registers (36-bit value/mask, 7-bit control, 4-bit status cleared on read), three counter registers, ACTION 13 bits. | SMP-1 (OBP keeps the MID in 0x38 VA 0), MMU-12, Solaris's MIX poll. |
| Watchdog (IU-1) | `error_o` from the IU → the module resets the IU (PC 0, S = 1, ET = 0), sets MCNTL.BM and SFSR.EM, raises `wd_reset_o` for one cycle (the chipset's RS/WD status, the level-15 broadcast); caches, TLB, the other registers keep their contents. | mmu-notes §5; `wdtest`. |

## 1. Structure

```
            ┌──────────────────────── cpu_module ────────────────────────┐
  ifetch ──►│ iside ─► TLB port I ─► icache ──┐                          │
            │                                │   mem arbiter ──► mem port (mem_pkg)
  dmem  ──►│ dside ─► TLB port D ─► dcache ──┤                          │
            │   │          ▲        uncached ─┘                          │
            │   │       walker ◄─────────────── (table reads, R/M writes)│
            │   └─► ASI registers (srmmu: 3/4/5/6/7; cpu_module: 0x38,  │
            │       0x49-0x4C, cache diag 0xC-0xF, flash 0x36/37, 0x10-14)│
            │ snoop_i ─► icache, dcache                                   │
            └─────────────────────────────────────────────────────────────┘
```

Modules: `srmmu` (registers, TLB with two lookup ports, walker, fault
recording, probe/flush, ASI 6 image), `icache`, `dcache`, `cpu_module`
(the two sides, the ASI decode, the arbiter, the watchdog). The memory
port follows `docs/arch/bus.md`; one request outstanding; the arbiter's
priority is walker > D side > I side (a walk is always on behalf of a
stalled access).

## 2. Translation (`srmmu`)

A lookup port takes `{valid, va, at}` (AT as in the SFSR: bit 2 store,
bit 1 instruction, bit 0 supervisor) and the ASI's rule, and answers
three cycles later (the side holds the request and sees `busy`) with
`{pa, acc, fault}` or `miss`, provided the side still presents the same
VA and AT. The CAM is RAM: the 36 compared bits {VA[31:12], CTX} in nine
4-bit slices, each a 16-row RAM whose row r is the 64-bit vector of the
entries matching nibble r; a lookup reads one row per slice (cycle A),
ANDs the nine vectors with V and takes the first match, reading the image
there (B), and answers (C). A level above 3 and the context of an ACC 6-7
entry are handled when the entry is written: the bits they ignore are
written as "match every row". Writing an entry (a fill; an ASI 6 write of
SEL 0-2) rewrites its bit in all 16 rows of every slice, a 17-cycle
read-modify-write, from the image; V is set only by those writes, so the
CAM is consistent wherever V is. The TLB has **one** CAM: the data side's request is served when it has one and
the instruction side is told `busy` and retries; the instruction side
keeps an eight-entry micro-TLB of the pages it translated (VA tag, PPN,
ACC; the permission re-checked on each use, a failing one going to the
MMU so that the fault is recorded), dropped on `tlb_changed` (a flush, an
ASI 5/6/7 write, a CTX/CTPR/MCNTL write, the watchdog);
on a miss the side asks the walker (`walk_req`) and waits for
`walk_done` (success → the entry is in the TLB, retry the lookup; fault →
the SFSR is written, return the fault to the IU).

- **MMU off (EN = 0):** PA = {4'b0, VA}; **boot mode (BM = 1)** makes a
  fetch PA = {8'hFF, VA[27:0]} whatever EN says (Viking; QEMU's 19-bit
  rule is a deviation). Bypass ASIs 0x20-0x2F never reach the MMU: PA =
  {ASI[3:0], VA}.
- **Hit:** entry V, the VA bits of its level equal (LVL 3: [31:12]; 2:
  [31:18]; 1: [31:24]; 0: none), and (ACC ≥ 6 or CTX equal). PA from the
  PPN with the untranslated low bits per level. Then the permission check
  (V8 §H.5 table, mmu-notes §1.3) → FT 2 / 3 with L = the entry's LVL; a
  store with M = 0 → drop the entry, miss.
- **Walk:** level 0 at `{CTPR[31:6], 6'b0} + CTX*4` (36-bit, as QEMU and
  the suite), then `{PTP, 6'b0} + index*4`; single word reads through the
  memory port. ET 0 → FT 1; ET 3 → FT 4; PTD at level 3 → FT 4; a bus
  error → FT 4 + TO; L = the level being read. A PTE: permission check
  (FT 2/3 with L); R or M to set → write the PTE back (one word); insert
  (first invalid entry, else the LRU victim among unlocked entries;
  used bits as Viking §4.11.4); done.
- **Faults record** (V8 classes with the OW rules in mmu-notes §1.5):
  SFSR {EM, CS, TO, L, AT, FT, FAV, OW}; SFAR = VA, FAV = 1 for data and
  translation faults and for instruction faults (the suite); FAV = 0 for a
  fetch bus error (0x874). NF = 1 masks the trap (not the record) for data
  accesses through ASIs other than 9 and for bus errors on them.
- **Probe** (ASI 3 load, type VA[10:8]): a walk that neither touches the
  TLB nor sets R; types 0-3 return the entry found at the asked level
  (even invalid or a PTD), 0 when the walk ends earlier (a PTE above the
  level, ET 0/3, a bus error); type 4 returns the PTE at whatever level,
  0 otherwise; 5-7 → 0.
- **Flush** (ASI 3 store): clear V of every entry matching V8 Table H-2
  with the LVL conditions (page: LVL 3 & [31:12]; segment: LVL 2-3 &
  [31:18]; region: LVL 1-3 & [31:24]; all with ACC ≥ 6 or CTX equal;
  context: ACC ≤ 5 & CTX equal; entire: all); the other image bits stay.
  Types 0-3 walk the image (65 cycles), entire and ASI 5/7 writes clear V
  at once; lookups answer busy and TLB register accesses wait meanwhile.
- **ASI 6:** entry VA[17:12], SEL VA[10:8]: 0 VA tag (bits 31:12), 1 CTX
  (15:0), 2 the PTE image {PPN 31:8, C, M, V(5), ACC, LVL(1:0)}, 3 lock
  (bit 0); 4-6 read 0, writes ignored. Word access only. Any ASI 5/6/7
  write is also a "drop" for a future L2 TLB.

## 3. The caches

Both: physically tagged, index within the page offset (way size 4 KB),
everything in block RAM: the data, the tag words (PA[35:12] with the valid
bit(s) and the D-cache's D/S image bits), and a per-set word with the MRU
and lock bits — nothing indexed dynamically in flops (a first version
with the valid/MRU/lock bits in flops cost four times the logic). A flash
clear is therefore a sweep, two cycles a set, read-modify-write of the
tag words (the PTAG's tag survives, as the POST checks) or of the lock
bits, with the CPU side held off (`flash_busy`; the data side completes
the flash store when the sweep ends). Lookup: cycle 0 index the RAMs with
the VA (the index bits are the page offset) while the TLB translates;
cycle 1 compare the tags with the PA → hit and the doubleword, answered
in that cycle; the next request is taken in the same cycle, so hits run
one per cycle. Replacement: Viking's limited-history LRU on the MRU
bits with lock bits (mmu-notes §3.1); `cacheable = enable && (PA in RAM
space 0 below 512 MB, or in the PROM 0xF_F000_0000-0xF_F0FF_FFFF)`.

- **I-cache:** a miss fills the 32-byte half-line (one burst), writes the
  data as the beats come and sets the half-line's valid bit after the
  fourth beat; a bus error on a beat leaves the half-line invalid and
  faults the fetch (0x21) only when the demand doubleword failed. Snoop:
  clear the half-line valid bit of a matching line (any writer, this
  module included). Flash 0x36 [0]: all valid and MRU bits; [0x80000000]:
  all locks. Diagnostic: 0x0C tags (PTAG {57:56 V1 V0, 23:0 PA[35:12]},
  STAG {12:8 MRU, 4:0 LCK, bit 0 fixed 0}), 0x0D data.
- **D-cache:** load hit → data; load miss (cacheable) → fill the line (4
  beats), validate after the last, the CPU side blocked meanwhile
  (`t_cache_fill_words`); store → memory write (be) and on a tag hit the
  line's doubleword is updated (no allocate); atomics → the line is
  dropped and the operation is a locked read + write on the memory port;
  uncached accesses straight to the port. Snoop: drop a matching line
  unless the writer is this module. Flash 0x37 as above. Diagnostic: 0x0E
  (PTAG {56 V, 48 D, 40 S, 23:0 PA[35:12]}, D and S stored but never set
  by the hardware; STAG {11:8 MRU, 3:0 LCK}), 0x0F data.
- **Line flush** (ASI 0x10-0x14 store): translate, then drop the line in
  the D-cache and the I-cache (0x18-0x1C: I only). Nothing to write back.

## 4. The data side (`cpu_module`)

One access at a time from the IU (`dmem_req`, held until `ack`). By ASI:

| ASI | What |
|---|---|
| 0x08-0x0B | translate (ASI 8/9 as instruction-space data: AT 2/3/6/7), then cache or port; faults → `fault` 1 (exception) or 2 (bus error) |
| 0x02 | read 0, write ignored (no MXCC) |
| 0x03 | load: probe; store: flush |
| 0x04 | the registers (§0); non-word → fault 1 with CS |
| 0x05, 0x07 | read 0; a write drops the TLBs |
| 0x06 | the TLB image (word only) |
| 0x0C-0x0F | cache diagnostics: doubleword, or a word in its half (the suite's `mmu_off` clears tags with `sta`); else fault 1 |
| 0x10-0x14, 0x18-0x1C | store: line flush; load: 0 |
| 0x20-0x2F | bypass: PA = {ASI[3:0], VA}, uncached, no R/M, atomics allowed |
| 0x30-0x32 | read 0, write ignored (store buffer: none) |
| 0x36, 0x37 | word store: flash clear by VA[31] |
| 0x38 | breakpoint registers (doubleword), 0x49-0x4B counters, 0x4C ACTION |
| other | read 0, write ignored |

The instruction side translates every fetch (boot mode / MMU off / TLB)
and goes through the I-cache; a fault returns `ifetch_rsp.fault` 1 (tt
0x01) or 2 (tt 0x21) with the SFSR written.

## 5. Verification

`sim/cpu/`: `cpu_module` with a behavioural memory on the `mem_pkg` port
(the PROM image at `0xF_F000_0000` and PA 0, 16 MB of RAM at 0, the
`escc` at `0xF_F110_0000`, bus errors for `0xE_0xxx_xxxx-0xE_3xxx_xxxx`,
a configurable response delay and gaps between burst beats) running
`tests/cpu/src/main_cpu.S` (the phase-1/2 subset plus `t_mmu`,
`t_mmu_diag`, `t_mmu_l2`, `t_cache`, `t_cache2`, `t_cache3`,
`t_cache_diag`, `t_cache_force`, `t_buserr`) against the QEMU reference
with the deviations of mmu-notes §7.3 taken as PASS; then `wdtest` as a
second image. Benches: `tb_srmmu` (walk, faults, probe/flush, the image
patterns), `tb_dcache`/`tb_icache` (fills, snoops, diagnostics, flash).
