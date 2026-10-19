# SPARCstation 10/20 POST VRV3.45 — test catalogue

Every self-test in the SS10/SS20 boot PROM (OBP 2.25, 525-1377-08), from the
machine code in [`listing.s`](listing.s). Companion to [`README.md`](README.md)
(reset flow, MP start-up, trap handling) and
[`hardware-access.md`](hardware-access.md). Addresses are image offsets; names
are the labels in [`romdis.json`](romdis.json). Test names in `###` headings
are the ROM's own strings (without the leading `\r\n` and padding).

Values and algorithms come from the instructions (cited by address); anything
inferred is marked "(guess)".

## Summary

| Group | Section | Tests run by POST | Dead (not called) | Runs when |
|---|---|---|---|---|
| IU register file / windows | §2 | 2 | 1 | always (master, before RAM) |
| SuperSPARC caches | §3 | 8 | 2 | SuperSPARC (types 0x40-0x42) |
| SRMMU, SuperSPARC-II suite | §4 | 19 | 6 | 4 on every SuperSPARC, 15 more only on type 0x42 |
| FPU | §5 | 21 | 3 | always |
| MXCC / E-cache | §6 | 7 | 3 | SuperSPARC with MXCC (MCNTL.MB = 0) |
| Memory, EMC/SMC ECC | §7 | 7 | 2 | always |
| Interrupts, timers, MSI/IOMMU, TOD/NVRAM | §8 | 14 | 4 | always |
| On-board SBus I/O (DMA2, ESP, LANCE, parallel port) | §9 | 15 | 5 | always |
| HyperSPARC | §10 | 22 | 7 | module type 0x17 only |
| **Total** | | **115** | **33** | |

On a SuperSPARC with MXCC (type 0x40/0x41) POST runs 78 of these per CPU, on a
SuperSPARC-II (0x42, as under QEMU) 93. The ROM also carries test *names*
with no code at all: 126 of the 216 32-byte name slots at 0x14202-0x15ce2 are
referenced by nothing (store buffer, D-cache miss/copy-back, D_FIFO, MDI/VSIMM,
DBRI, floppy, 85C30, walking-bit ECC, ...). They are listed at the end of each
group. There is no interactive POST menu in this build: the menu strings
(`0x15d02-0x15fe0`) and the key handler `post_console_command` (0x11ba0) are
unreferenced.

What a core has to provide to get through POST is summarised in the
"Notes for the CPU test suite" of each group and in §11.

## 1. Conventions and execution order

### 1.1 How a test is written

- **Entry.** `save %sp,-0x60,%sp`; `andcc %g4,2,%g0` — if bit 1 of `%g4` is set,
  print the test name with `post_printf` (0x11a20). `post_main` sets that bit
  only when NVRAM byte 0x1ff2 == 2 (the verbose mode `post_master_start` selects
  when a keyboard is present or diag-switch? is set). `clr %g3`.
- **Result.** `%g3 = 1` on failure, `ret`. The caller (`post_main`) does
  `tst %g3; bne,a <failure exit>`. Some groups (DMA2/PPORT) only print and return
  `%i0 = 0xff`; compiled-C tests return `%o0` = 0 / -1.
- **Error report.** "ERROR : ..." with `%1..%5` as 8-digit hex, "<<< CPU_n on
  MBus Slot_m >>>", "U-NUMBER : Uxxxx" (20-byte entries at 0x17f00 / 0x18540) and
  "PIN-NUMBER : ..." (20-byte entries at 0x16120).
- **Expected traps.** A test that wants a trap loads its type into `%g5`
  (a second interrupt level in `%g6`, a device selector in `%g7`) and then
  checks `%g5 == 0` afterwards; the handler (README §7) clears `%g5` and resumes
  after the trapping instruction, or retries the interrupted one for
  interrupts. `%g1` is often set to the address of the next instruction
  (`sethi/or %g1`) as a restart point.
- **Environment.** MMU off unless a test turns it on, CPU in boot mode,
  instruction fetches from the PROM, devices through bypass ASIs 0x20/0x2e/0x2f,
  scratch RAM mostly at pa 0x600000 (FPU, handlers) and 0x400000-0x1000000
  (memory tests, page tables), window traps disabled (`%wim` 0 or 2, shallow
  calls; `%sp`/`%fp` are reused as scratch registers).
- **Progress LEDs.** `kbd_send(0x0e); kbd_send(mask)` (Sun keyboard LED command)
  between groups: 8 = Caps Lock on, 0 = off.

### 1.2 Order (post_main, 0x163c0)

The master runs this list, then dispatches `post_main` to each slave CPU in turn
(README §5.1), so the whole list runs once per CPU. A failing test ends POST
through the exit given in the last column.

| # | Call at | Test (entry) | On failure |
|---|---|---|---|
| – | 0x40fc / 0x41dc | IU globals, IU windows (before `post_main`, master only) | IU failure exit, code 3 |
| 1 | 0x16464 | memory configuration probe `mem_probe_simm_config` (0x125c0) | — (result in `%g2`) |
| 2 | 0x164d8 | HyperSPARC suite (0x21790), type 0x17 only; then jump to #13 | MBUS module |
| 3 | 0x16520 | SuperSPARC-II MMU suite `post_supersparc2_mmu_suite` (0x1fb84), type 0x42 only | MBUS module |
| 4 | 0x16564 | MMU Context Table Reg Test (`0xf8dc(0x100, 0xfffffc00)`) | MBUS module |
| 5 | 0x16598 | MMU Context Register Test (`0xf8dc(0x200, 0xfff)`) | MBUS module |
| 6 | 0x165d4-0x16634 | MMU TLB Bit Pattern Tests (`0xf6dc` with 4 pattern tables) | MBUS module |
| 7 | 0x16648 | MMU Flush Tests (0x1c5c8) | MBUS module |
| 8 | 0x1666c-0x16694 | D-Cache RAM / PTAG / STAG Write/Read (0x6dec, 0x6ef4, 0x7004) | MBUS module |
| 9 | 0x166b8-0x166f0 | I-Cache RAM / PTAG / STAG Write/Read (0xcf2c, 0xd034, 0xd124) | MBUS module |
| 10 | 0x16704 | I-Cache Flush Test (0x9c80) | MBUS module |
| 11 | 0x16718 | Cache Flashclear Test (0x1cbd8) | MBUS module |
| 12 | 0x16740 | MXCC suite (0x197ac), only if an MXCC is present (0x194f8) | MBUS module |
| 13 | 0x16754 | EMC/SMC Control Regs Tests (0x93e0) | Main Logic Board |
| 14 | 0x16770 | slot-0 DSIMM check `find_first_dsimm` (0x1274c) | "Replace/install DSIMM" |
| 15 | 0x16784-0x167bc | ECC Multiple UE / CE / CE,UE (0x87e0, 0x8a78, 0x8cf8) | Main Logic Board |
| 16 | 0x167e0 | FPU group 1: Register File, Misaligned Pair, SP, DP (0x9f00) | MBUS module |
| 17 | 0x16804 | FPU group 2: SP/DP exception tests (0x9fa4) | MBUS module |
| 18 | 0x16864 | Memory Address Pattern Test (0x176c0) | DSIMM |
| 19 | 0x16894-0x168e0 | System Interrupt Regs, PROCn Interrupt Regs, Soft Interrupts OFF / ON (0xd300, 0xd3ac, 0xd594, 0xd710) | Main Logic Board |
| 20 | 0x168f8-0x16934 | PROCn User Timer, PROCn Counter/Timer, System Counter (0x10214, 0x104b0, 0x106fc) | Main Logic Board |
| 21 | 0x1695c-0x169ac | MSI/MSBI Control Reg, IOMMU CAM NTA, TLB NTA, CAM TLB Comparator, TLB Flush (0xe4c0, 0xe058, 0xe0c0, 0xe128, 0xe204) | Main Logic Board |
| 22 | 0x169d0-0x16af8 | DMA2/MACIO ID, E_CSR, LANCE Address/Data Port, D_CSR, D_ADDR, D_BCNT, D_NADDR, ESP, P_CSR, P_ADDR, P_BCNT, PPORT Registers, PPORT IO / XFR loopback | Main Logic Board (ESP, LANCE only; DMA2/PPORT failures are printed, not fatal) |
| 23 | 0x16b1c | TOD Registers Test (0x10dc0) | Main Logic Board |
| 24 | 0x16b68 | master: run `post_main` on each slave (MID 9-11) | — |
| 25 | 0x16c08 | `post_exit_to_obp(0, "STATUS : Power-On SelfTest PASSED")` | |

"MBUS module" = `post_fail_cpu_module` 0x16c10: "Power-On SelfTest FAILED ...
Replace MBUS0 Module" (MID & 3 <= 1) or "... MBUS1 Module"; "Main Logic Board" =
`post_fail_main_logic_board` 0x16cf4; "DSIMM" = `post_fail_no_dsimm` 0x16d54;
all leave through `post_exit_to_obp(2, msg)`. The keyboard LED mask at the
failure exit (4/9, 4/9, 1/0xc, 2/1 depending on whether a keyboard type was
detected) tells the class apart when no console is attached. `mp_probe_slaves`
also runs the NVRAM access check 0x10ccc once (§8).

## 2. IU and POST-core tests

These run in `post_entry` on the master only, before any RAM is touched: no
`save` beyond the register file, `%wim = 0` (no window traps), no stack. They
have no name string; a failure prints "ERROR : IU Register File ...", dumps the
registers with 0x12e74/0x12e97/0x12eb9/0x12ed9 "STATUS : Global/Local/Out/In
Registers" and "%1 :  %2" (register number, value), and ends POST through
`post_iu_fail_exit` 0x5cf4 = `post_exit_to_obp(3, 0x12f35 "Power-On SelfTest
FAILED ... Unexpected Trap (tt = %x)", %l3)` — the IU failure reuses the
unexpected-trap message.

### IU global registers (no name string)
- Entry: `post_iu_globals_test` 0x40fc, inline in `post_entry` (master).
- Tests: that `%g0` reads 0 and `%g1-%g7` hold all-zeros and all-ones.
- **Algorithm:** 0x40fc `tst %g0` (after the ttya init call); 0x4108-0x4120 `clr
  %g1..%g7`, 0x4124-0x4174 `tst` each; 0x4178-0x4190 `%g1 = -1`, `%g2..%g7 = %g1`,
  0x4194-0x41d4 `cmp %g1,%gN`.
- **Touches:** `%g0-%g7` only.
- **Expected:** 0 then 0xffffffff in every global; `%g0` = 0.
- **Fails with:** 0x12db0 "ERROR : IU Register File Bit Failure", 0x12e74 "STATUS :
  Global Registers" + dump (`post_iu_fail_globals` 0x590c).

### IU window registers and window pointer (no name string)
- Entry: `post_iu_window_test` 0x41dc, inline in `post_entry` after the globals.
- Tests: CWP decrement on `save`, the in/out overlap of adjacent windows, and
  stuck-at-0/1 of every in, local and out register of windows 7..1.
- **Algorithm:** 0x41dc-0x41f8 `%o0..%o7 = 0..7` (in window 0, CWP 0 from
  `%psr = 0xe0`); 0x41fc `save`, 0x4200 `%g7 = PSR.CWP` (7 with 8 windows) = loop
  count. Loop `post_iu_window_loop` 0x4208, once per window:
  1. 0x4208-0x4264: `%i0..%i7` must equal 0..7 (the caller's outs), else window
     pointer failure.
  2. 0x4268-0x42e4: clear `%i0-%i7`, test each for 0; 0x42e8-0x4368 all-ones test
     (`cmp %g1,%iN` with `%g1 = -1`).
  3. 0x436c-0x446c: the same zero / ones test on `%l0-%l7`.
  4. 0x4470-0x4570: the same on `%o0-%o7`.
  5. 0x4574-0x4590: `%o0..%o7 = 0..7` again; 0x4594 `subcc %g7,1`; `bne,a
     post_iu_window_loop` with `save` in the (annulled) delay slot.
  Seven iterations (CWP 7 down to 1); window 0's locals are not tested.
- **Touches:** all windowed registers, `%psr` (CWP read), `save`.
- **Expected:** `%iN == N` after each `save`; 0 and 0xffffffff read back.
- **Fails with:** 0x12ddc "ERROR : IU Register File Window Pointer" + "STATUS : In
  Registers" dump (`post_iu_fail_window` 0x5b64); 0x12db0 "IU Register File Bit
  Failure" + In/Local/Out dump (0x5a9c / 0x59d4 / 0x5c2c).

### SuperSPARC-II BIST status check (dead code)
- Entry: `post_dead_bist_check` 0x4050; skipped by the unconditional `ba` at
  0x4048 (the preceding `cmp %o0,0x42` is left over).
- **Algorithm (not executed):** for module type 0x42: `lda [0x100] 0x39` (BIST
  status) `& 3` must be 0; `sta %g0,[0] 0x39`; re-read; `ldda` MXCC 0x01c00800
  and 0x01c00a00, clear control bit 3 (parity enable) with `stda`.
- The strings 0x12d38 "*** RUNNIG SHORT BIST ***" and 0x12d54 "Viking Signature:
  %1 BIST Status = %2" belong to it and are unreferenced.

### Checks built into the POST infrastructure

Not tests in their own right, but they decide whether POST runs and on which
CPUs, and they print the banner:

- **Module identification** (`get_module_type` 0x1f22c, `post_print_cpu_id`
  0x1edb4): see README §4. A Ross 605/604 or an unknown module ends POST with
  `post_exit_to_obp(0xff, "... NO POST run")`; MXCC and non-MXCC SuperSPARCs
  may not be mixed (NVRAM 0x1ff1 == 3 → `post_fail_mixed_modules` 0x16c94,
  "TMS390Z55 and TMS390Z50 Modules can NOT be mixed. No POST run.").
- **Slave presence** (`mp_probe_slaves` 0x1f56c): a slave that does not answer
  its mailbox within 50000 polls is "******* NOT installed *******" and loses
  its arbitration.
- **Keyboard** (`kbd_detect` 0x18828): "$$$$$ WARNING : No Keyboard Detected!
  $$$$$" (0x132c8) is only a warning.

## 3. SuperSPARC on-chip cache tests (I-cache, D-cache, flash clear, write hit)

These run per CPU from `post_main`, in the order below, right after the MMU tests. The
keyboard LEDs are set to 0x08 before the D-cache tests (0x1665c/0x16664), to 0x00 before the
I-cache tests (0x166a8/0x166b0), and back to 0x08 before the I-Cache STAG test (0x166e0/0x166e8).
The FSM's sample POST listing prints the same eight names in the same order. The asm tests all
work the same way: they flash-clear the cache under test, then walk every entry with
`stda`/`ldda` on the diagnostic ASI, using only the diag path (no RAM or MMU; the cache-enable
bits are never touched). A failure goes to a shared error exit that prints
`<<< CPU_%1 on MBus Slot_%2 >>>` (0x16088, %1 = MID&3, %2 = (MID&3)>>1) and the Address/exp/obs/xor
line, then "U-NUMBER : Suspect Viking Module" (0x13727), and sets `%g3 = 1`. Nothing uses the
store buffer ASIs 0x30-0x32. No test in this group uses the expected-trap protocol (%g5).

**Diagnostic address and tag formats, derived from the loop bounds and expected values:**

| ASI | what | VA encoding | size |
|---|---|---|---|
| 0x0f | D-cache data | VA[27:26] = way (0..3), VA[11:5] = set (0..127), VA[4:3] = dword (0..3) | 64-bit ldda/stda |
| 0x0e | D-cache tags | VA[31]=1: PTAG(way VA[27:26], set VA[11:5]); VA[30]=1: STAG(set VA[11:5]) | 64-bit |
| 0x0d | I-cache data | VA[28:26] = way (0..4), VA[11:6] = set (0..63), VA[5:3] = dword (0..7) | 64-bit |
| 0x0c | I-cache tags | VA[31]=1: PTAG(way VA[28:26], set VA[11:6]); VA[30]=1: STAG(set VA[11:6]) | 64-bit |
| 0x37 / 0x36 | D / I flash clear | `sta %g0,[0]`: clear all PTAG valid bits + STAG MRU bits; `sta %g0,[0x80000000]`: clear all STAG lock bits | 32-bit store, data ignored |

- The geometry matches STP1021UG A.5/A.6: D-cache 16 KB, 4-way, 128 sets x 32 B; I-cache 20 KB,
  5-way, 64 sets x 64 B.
- D PTAG, as {hi, lo} of the ldda pair. hi bit 24 (bit 56) is V, hi bit 16 (bit 48) is D
  (dirty), hi bit 8 (bit 40) is S (shared), and lo[23:0] is PA[35:12]. Writing all-ones reads
  back hi=0x01010100 and lo=0x00ffffff. On module type 0x42 (MCNTL.ver 8..15, SuperSPARC-II)
  it reads hi=0x01000000, because D and S are reserved there (STP1021UG table A-34).
- I PTAG: hi bits 25:24 (57:56) are two valid bits, and lo[23:0] is PA[35:12]. The two bits
  are probably one per 32-byte half-line (guess, based on STP1021UG A.5).
- D STAG lo. Bits [11:8] are the MRU bits, one per way, which "vld_mru" flash clears. Bits
  [3:1] are the lock bits for ways 1-3, which "lock" flash clears. Bit 0 always reads 0, so
  way 0 probably cannot be locked (guess). Writing all-ones reads back lo=0x00000f0e.
- I STAG lo: bits [12:8] are the MRU bits for 5 ways, and bits [4:1] are the lock bits for
  ways 1-4. Writing all-ones reads back 0x00001f1e.
- The STAG hi word is never compared anywhere.
- The flash clear semantics come from the C test's error text "flash type (lock=1,
  vld_mru=0)" (0x1daca) combined with its expected values.

### D-Cache RAM Write/Read Test
- Entry: `0x6dec`, called from post_main `0x1666c` (also from the dead runner 0x6da0).
- Tests every D-cache data doubleword through the diagnostic data ASI.
- **Algorithm**:
  1. 0x6e20/0x6e24: flash-clear the D-cache with ASI 0x37 at 0x80000000, then at 0.
  2. Loop over set (128, stride 0x20), then way (4, +0x04000000; 0x6ec0, masked with
     0xf3ffffff at 0x6ed0), then dword (4, +8; the index is reset with `and -0x19` at 0x6eb4).
  3. For each dword: 0x6e58 `stda` all-ones to [l0] ASI 0x0f, 0x6e5c `ldda` it back and
     compare both words. Then 0x6e80/0x6e84 do the same with zeros.
- **Touches**: ASI 0x0f VA `way<<26 | set<<5 | dw<<3`, 64-bit r/w; ASI 0x37 (w).
- **Expected**: the readback equals what was written (0xffffffff_ffffffff, then 0).
  2048 dwords are tested.
- **Fails with**: a hi-word mismatch goes to 0x70a8, which prints 0x129f8 "ERROR : Address =
  %1, exp[63:32] = %2, obs[63:32] = %3, xor[63:32] = %4". A lo-word mismatch goes to 0x7108,
  which prints 0x12b00 (the same text for [31:00]). Both then print 0x13727 "U-NUMBER : Suspect
  Viking Module" and set %g3=1.

### D-Cache PTAG Write/Read Test
- Entry: `0x6ef4`, called from post_main `0x16680` (also from 0x6da0).
- Checks which D-cache physical tag bits are writable.
- **Algorithm**:
  1. 0x6f24 `get_module_type` goes into %o2.
  2. 0x6f34/0x6f38: flash-clear with ASI 0x37 at 0x80000000, then at 0.
  3. Loop over set (128, +0x20), then way (4, +0x04000000), starting from base 0x80000000.
  4. For each tag: 0x6f60 `stda` all-ones to ASI 0x0e, 0x6f64 `ldda` it back and compare.
     Then 0x6fa8/0x6fac write zeros and read back.
- **Touches**: ASI 0x0e VA `0x80000000 | way<<26 | set<<5`, 64-bit r/w; ASI 0x37 (w).
- **Expected**:
  - After writing all-ones, hi = 0x01010100 (V, D, S), or 0x01000000 if the module type is
    0x42 (0x6f70-0x6f7c), and lo = 0x00ffffff.
  - After writing zeros, the tag reads back as 0/0.
  - 512 tags are tested.
- **Fails with**: 0x70a8 (0x129f8, hi) or 0x7108 (0x12b00, lo), then 0x13727, with %g3=1.

### D-Cache STAG Write/Read Test
- Entry: `0x7004`, called from post_main `0x16694` (also from 0x6da0). The xref "0x204c8a"
  in the listing is a false hit: 0x7004 is a physical-address constant in a table-fill loop
  there.
- Checks the per-set MRU and lock bits of the D-cache.
- **Algorithm**:
  1. 0x7038/0x703c: flash-clear with ASI 0x37.
  2. Loop over 128 sets starting at base 0x40000000 (+0x20).
  3. For each set: 0x7054 `stda {0, 0xffffffff}`, 0x7058 `ldda` it back, and compare the lo
     word with 0xf0e (0x705c). Then 0x7074 `stda {0xffffffff, 0}` and check that lo == 0.
     The hi word is never compared.
- **Touches**: ASI 0x0e VA `0x40000000 | set<<5`, 64-bit r/w.
- **Expected**: lo = 0x00000f0e (MRU[11:8] and lock[3:1]), then 0. 128 sets are tested.
- **Fails with**: 0x7108 (0x12b00 "exp[31:00]"), then 0x13727, with %g3=1.

### I-Cache RAM Write/Read Test
- Entry: `0xcf2c`, called from post_main `0x166b8` (also from the dead runner 0xcee0).
- Tests every I-cache data doubleword.
- **Algorithm**:
  1. 0xcf60/0xcf64: flash-clear the I-cache with ASI 0x36 at 0x80000000, then at 0.
  2. Loop over set (64, +0x40), then way (5, +0x04000000; masked with 0xe3ffffff at 0xd010),
     then dword (8, +8; reset with `and -0x39` at 0xcff4).
  3. For each dword: 0xcf98 `stda` all-ones to ASI 0x0d, 0xcf9c `ldda` it back and compare.
     Then 0xcfc0/0xcfc4 do the same with zeros.
- **Touches**: ASI 0x0d VA `way<<26 | set<<6 | dw<<3`, 64-bit r/w; ASI 0x36 (w).
- **Expected**: the readback equals what was written. 2560 dwords are tested.
- **Fails with**: a hi mismatch goes to 0xd1cc (0x129f8), a lo mismatch to 0xd22c (0x12b00);
  both then print 0x13727 and set %g3=1.

### I-Cache PTAG Write/Read Test
- Entry: `0xd034`, called from post_main `0x166cc` (also from 0xcee0).
- Checks which I-cache physical tag bits are writable.
- **Algorithm**:
  1. 0xd068/0xd06c: flash-clear with ASI 0x36.
  2. Loop over set (64, +0x40), then way (5, +0x04000000), starting from base 0x80000000.
  3. For each tag: 0xd094 `stda` all-ones, 0xd098 `ldda` back. Then 0xd0c8/0xd0cc write
     zeros and read back.
- **Touches**: ASI 0x0c VA `0x80000000 | way<<26 | set<<6`, 64-bit r/w.
- **Expected**: after all-ones, hi = 0x03000000 (0xd09c) and lo = 0x00ffffff; after zeros,
  0/0. 320 tags are tested. There is no check on module type here.
- **Fails with**: 0xd1cc (0x129f8) or 0xd22c (0x12b00), then 0x13727.

### I-Cache STAG Write/Read Test
- Entry: `0xd124`, called from post_main `0x166f0` (also from 0xcee0).
- Checks the per-set MRU and lock bits of the I-cache.
- **Algorithm**:
  1. 0xd158/0xd15c: flash-clear with ASI 0x36.
  2. Loop over 64 sets starting at base 0x40000000 (+0x40).
  3. For each set: 0xd174 `stda {0, 0xffffffff}` and 0xd178 `ldda` back. The lo word must
     equal 0x1f1e (0xd17c/0xd180). Then 0xd198 `stda {0xffffffff, 0}` and check that lo == 0.
- **Touches**: ASI 0x0c VA `0x40000000 | set<<6`, 64-bit r/w.
- **Expected**: lo = 0x00001f1e (MRU[12:8] and lock[4:1]), then 0. 64 sets are tested.
- **Fails with**: 0xd22c (0x12b00), then 0x13727.
- (Note: the listing has labels L_0000d120..L_0000d1c0 with "xref 0004dXXXb". These are false
  xrefs from data at 0x4dXXX.)

### I-Cache Flush Test
- Entry: `0x9c80`, called from post_main `0x16704`.
- Checks what each of the two I-cache flash-clear variants clears.
- **Algorithm**:
  1. 0x9cc8 `icache_tags_init(0, 0x1f1e, 0x03000000, 0x502, 0x40)`: all 5x64 PTAGs get
     {0x03000000, 0x502} (valid, PA 0x502000), and all 64 STAGs get {0, 0x1f1e}.
  2. 0x9cd4 `sta %g0,[0x80000000]` ASI 0x36 (lock clear).
  3. 0x9ce8 loop over 64 STAGs: (lo & 0x1f) must be 0.
  4. 0x9d20: set up the tags again as in step 1.
  5. 0x9d28 `sta %g0,[0]` ASI 0x36 (valid/MRU clear).
  6. 0x9d44 loop: (STAG lo & 0x1f00) must be 0.
  7. 0x9d84 loop over 5 ways x 64 sets: (PTAG hi & 0x03000000) must be 0.
- **Touches**: ASI 0x0c (PTAG 0x80000000|way<<26|set<<6, STAG 0x40000000|set<<6, 64-bit
  r/w); ASI 0x36 VA 0 and 0x80000000 (w).
- **Expected**:
  - The lock flash clears lock bits [4:0].
  - The valid flash clears MRU [12:8] and both valid bits.
  - (Other bits, such as MRU after the lock flash, are not checked here; see Cache Flashclear.)
- **Fails with**: 0x9e90 (lock) or 0x9e30 (MRU), both printing 0x12b00 "exp[31:00]". 0x9dd0
  (valid) prints 0x129f8 "exp[63:32]". All three print Address=VA, exp=0, obs=masked value,
  then 0x13727.

### Cache Flashclear Test
- Entry: `0x1cbd8` (C code), called from post_main `0x16718`.
- **Algorithm**:
  - The name 0x1dab2 is printed only if NVRAM byte 0x1ff2 (pa 0xf_f120_1ff2) == 2. This test
    does not check `%g4` bit 1.
  - It runs `cache_flashclear_one(t)` (0x1cc74) for t = 0..3: bit 1 of t selects the I-cache
    (else the D-cache), and bit 0 selects lock flash (else vld_mru). So t=0 is D vld_mru, 1 is
    D lock, 2 is I vld_mru, and 3 is I lock.
  - The runner handles abort and scope-loop: 0x1ba04 checks and clears g4 bit 2; if g3 is
    already set, the same t is repeated (0x1cc40).
  - For each type:
    1. Loop over way (4 or 5) and set (0x80 or 0x40), with `off = way<<26 | set<<6`. Write the
       STAG with `{0, 0xf0e | 0x1f1e}` (0x1cd08 -> 0x1d600) and the PTAG with
       `{0x01000000 | 0x03000000, 0}` (0x1cd1c -> 0x1d644).
    2. Flash: 0x1cd64 `sta 0,[t&1 ? 0x80000000 : 0]` ASI 0x36, or 0x1cd78 with ASI 0x37.
    3. Re-read every entry. The STAG is read at 0x1ce04 (lo via %g1) and the PTAG hi at 0x1ce84.
- **Touches**: ASI 0x0c/0x0e (64-bit r/w, through stubs 0xe9e8/0xe9f0/0xea1c/0xea28); ASI
  0x36/0x37; NVRAM byte 0x1ff2 via ASI 0x2f.
- **Expected**:
  - Lock flash: STAG lo = 0xf00 (D) or 0x1f00 (I), and the PTAG hi is unchanged
    (0x01000000 / 0x03000000).
  - vld_mru flash: STAG lo = 0xe (D) or 0x1e (I), and PTAG hi = 0.
  - The D-cache is walked with a 64-byte set stride (`sll %i2,6`, 0x1ccec/0x1cdf4) over 128
    sets. That covers only the even sets, twice, if VA[12] is ignored (guess; this looks like a
    bug in the test).
- **Fails with**:
  - A STAG mismatch prints 0x1daca "Error: wrong cache stag_lo after flash clear\nflash type
    (lock=1, vld_mru=0) %1, asi %2, offset %3, exp %4, obs %5". %2 is 0xc or 0xe.
  - A PTAG mismatch prints 0x1db7c "Error: wrong cache ptag_hi after flash clear ...".
  - Either is followed by "U-NUMBER : Suspect Viking Module, MBus Slot 0" (0x1db45 or
    0x1dbf7). The test sets g3=1 through 0x1ba6c and returns 0xff. An error is printed only
    if g3 was clear.

### D-Cache Flush Test
- Entry: `0x9b40`. Not called (dead code): no call, branch, pointer or constant anywhere in
  the image targets it. The name string 0x14342 is used only here. The C Cache Flashclear
  Test does its job instead.
- It mirrors the I-Cache Flush Test.
- **Algorithm**:
  1. 0x9b84 `dcache_tags_init(0, 0xf0e, 0x01000000, 0x502, 0x80)`: all 4x128 PTAGs get
     {0x01000000, 0x502}, and all 128 STAGs get {0, 0xf0e}.
  2. 0x9b90 ASI 0x37 `[0x80000000]`.
  3. 0x9ba4: (STAG lo & 0xf) must be 0.
  4. 0x9bd8: set up the tags again.
  5. 0x9be0 ASI 0x37 `[0]`.
  6. 0x9bf4: (STAG lo & 0xf00) must be 0.
  7. 0x9c34 over 4 ways x 128 sets: (PTAG hi & 0x01000000) must be 0.
- **Touches**: ASI 0x0e (STAG 0x40000000|set<<5, PTAG 0x80000000|way<<26|set<<5), ASI 0x37.
- **Expected**: as in the I-Cache Flush Test, with the D-cache masks 0xf, 0xf00 and 0x01000000.
- **Fails with**: 0x9e90, 0x9e30 or 0x9dd0 (the same shared exits as the I-cache flush test),
  then 0x13727.

### D-Cache Write Hit Special Test
- Entry: `0x1cf20` (C code). Not called (dead code; no reference anywhere).
- Checks copy-back (MBus-mode) D-cache behaviour on write hits.
- **Algorithm**:
  1. 0x1cf24: if MCNTL bit 11 (MB, no MXCC) == 0, return at once. So the test only runs on
     MBus-mode modules, where the D-cache is copy-back.
  2. Print 0x1dc2e unconditionally.
  3. 0x1cf48 `mem_quick_test(0, 0x40000)`: 0xaaaaaaaa/0x55555555 through ASI 0x20.
  4. 0x1cf6c `copy_ctl_space_to_ram(0xf0000000, 0, 0x40000)`: copy the first 256 KB of the
     PROM (pa 0xf_f000_0000) to pa 0. That also overwrites whatever POST keeps below 0x40000,
     for example the initial %sp 0x1fba0 set at 0x6a64 (a possible reason it is dead; guess).
  5. For ctx = 0..3 and target T = 0x100000, 0x101000, 0x102000, run `dcache_wrhit_run(T,
     ctx)` (0x1d014):
     1. 0x1d7d8: CTX=0 and CTPR=0xf8000, so the tables are at pa 0xf80000. Then 0x1d028
        sets CTX=ctx.
     2. Map VA=PA for 0..0x3ffff and for T..T+0x3fff with level-3 PTEs `(pa>>4)|0x8e`
        (C=1, ACC=3), using `srmmu_set_pte_level` (0x1d688).
     3. `jmp 0x1d0d0`, then set up the MMU and caches: SFAR <- 0 (0xeb90), MCNTL.ME=1
        (0xeae8), BM=0 (0xeb1c), SE=1 (0xeb30), flash-clear both caches (0xeb78), DC=IC=1
        (0xeb58).
     4. 0x1d114: write mem[T+o] = o through ASI 0x20.
     5. 0x1d14c: cached `ld` of all 16 KB (fills 4 ways x 128 sets).
     6. 0x1d180: cached `st` of (o|0x80000000) to every word. All of these are write hits.
     7. Check the tags, data and memory (see Expected).
     8. 0x1d570: DC=IC=0, SE=0, BM=1, ME=0.
- **Touches**: ASI 0x0e/0x0f (r), ASI 0x04 (MCNTL/CTPR/CTX/SFAR), ASI 0x20 (tables at
  0xf80000.., memory 0..0x3ffff and 0x100000..0x105fff), ASI 0x2f (PROM read), ASI 0x36/0x37.
  Needs at least 16 MB of RAM.
- **Expected**: for l = 0..3 the checks read way 3-l, set s = 0..127:
  - STAG lo at `0x40000000|(3-l)<<26|s<<5` must be 0x100 (MRU = way 0 only, no locks), 0x1d200.
  - PTAG at `0x80000000|(3-l)<<26|s<<5`: hi must be 0x01010000 (V + D) if MB, else
    0x01000000; lo must be (T>>12)+l (0x1d2d8-0x1d2f4).
  - Data at `(3-l)<<26|s<<5|dw*8` must be the stored value `0x80000000|(l<<12 + s*32 + byte)`
    (0x1d3e4-0x1d3fc).
  - Memory: `lda [T+o] 0x20` must be o if MB (the write hits did **not** reach memory), else
    o|0x80000000 (write-through) (0x1d4d8-0x1d4f8).
  - The checks imply (inference) three things:
    - Fills into an all-invalid set go to way 3, 2, 1, 0.
    - Page l ends up in way 3-l.
    - The 4 write hits leave the MRU bits and S=0 alone, so an exclusive fill followed by a
      write hit gives E->M with no bus traffic.
- **Fails with**: 0x1dc4f "wrong d-stag lo after wr-hit", 0x1dcdf "wrong d-ptag word (%1)
  after wr-hit", 0x1dd76 "wrong data lo after wr-hit", 0x1ddf9 "wrong mem data after wr-hit".
  Each is followed by "U-NUMBER : Suspect Viking Module, MBus Slot 0" and returns -1 (0xff
  from the runner).

### Name strings with no code in this ROM
These strings at 0x142c2-0x14582 have no reference anywhere; they are name strings only, with
no code in this ROM:
- D-Cache: Read Miss (0x142c2), Read Hit (0x142e2), Write Miss (0x14302), Write Hit (0x14322),
  Read Hit-Miss (0x14442), Copyback RMiss (0x14462), Copyback WMiss (0x14482), MRU/Lock bit
  (0x144a2).
- I-Cache: Read Miss (0x14362), Read Hit (0x14382), Write Miss (0x143a2), Write Hit (0x143c2).
- Store Buffer: TAG (0x14402), RAM (0x14422), Non-Cache (0x144c2), Cachable (0x144e2), Stress
  (0x14502), Timeout (0x14522), "Store Buf Cache Timeout" (0x14542), ECC Error (0x14562).
- "Cache RAM Write/Read Test" (0x14582).

Similarly unreferenced:
- The names 0x145a2 "Cache TAG NTA", 0x145c2 "I-Buffer RAM Write/Read" and 0x145e2
  "I-Buffer TAG NTA".
- The leftover error strings 0x13c6f-0x13f9b ("PTAG Miss Match for Valid, Dirty Bits...", "Data
  Cache Data Miss Match.", "STAG data miss-match.", "D-Cache MRU/Lock 0..E pattern test Failed.").

ASI 0x30 appears only in the generic ASI-n accessor tables at 0x18a98 and 0x18e74; ASI 0x31/0x32
are never used as store-buffer diag accesses.

#### Helpers
- `0x6da0` dcache_ram_groups_runner_unused: dead. It runs 0x6dec, 0x6ef4 and 0x7004 and stops on %g3.
  Its only caller is 0x7180.
- `0xcee0` icache_ram_groups_runner_unused: dead. It runs 0xcf2c, 0xd034 and 0xd124. Its only caller
  is 0x7180.
- `0x7180` cache_ram_groups_runner_unused: dead (uncalled). It runs 0x6da0, then 0xcee0.
- `0x71c0` / `0x721c` run_sbusio_id_ecsr_lance_unused / run_dma2_nbcnt_naloaded_unused: dead, and not cache code. They run 0x7250,
  0x7af0, 0xd9e8 and 0xdb0c, and 0x7874 and 0x79c0. They belong to the SBus I/O group (§9).
- `0x70a8` / `0x7108`: D-cache RAM/PTAG/STAG error exits (hi and lo word). `0xd1cc` / `0xd22c`:
  the I-cache versions. `0x9dd0` / `0x9e30` / `0x9e90`: flush-test exits for valid, MRU and
  lock. All of these save %o2 in %fp around get_mid, which clobbers the caller's %sp on the
  failure path.
- `0x11700` dcache_data_fill_pattern(p_hi, p_lo, incr): dead. It fills all D-cache data through
  ASI 0x0f; when incr != 0 the dword n gets p+n+1.
- `0x1178c` icache_data_fill_pattern: the I-cache version of the above, through ASI 0x0d. Dead.
- `0x11818` dcache_tags_init(st_hi, st_lo, pt_hi, pt_lo, nsets): all PTAGs <- {pt_hi, pt_lo}
  (4 ways), then 128 STAGs <- {st_hi, st_lo}.
- `0x11880` icache_tags_init: the same for the I-cache (5 ways, stride 0x40, 64 STAGs).
- `0xec98` copy_ctl_space_to_ram(src, dst, len): `lda [src] 0x2f` -> `sta [dst] 0x20`. Its only
  caller is the dead Write Hit test.
- `0xecb8` ecache_tag_rw_fail: the error exit of the MXCC E-cache tag write/read helper 0xe820
  (branches at 0xe87c and 0xe89c). It prints 0x129b7 and returns -1, and belongs to the MXCC
  group.
- `0xed1c`, `0xed94`, `0xee0c`, `0xee84`, `0xeefc`: dead Viking scope-loop error blocks. They
  print Address/exp/obs (or "No interrupt received"), then Suspect Viking and "Entering scope
  loop", and finish with `jmp %g1; mov 1,%g3`.
- `0xefa0`, `0xf014`, `0xf098`: dead DMA2 error blocks (U0501 DMA2_ASIC; 0xf014 also prints PIN
  P137_sb_p_irq). They return 0xff.
- `0xef60` / `0xef73`: unreferenced debug format strings.
- `0x1d598` / `0x1d5cc`: cache_stag_read / cache_ptag_read(off, is_icache). These do
  `ldda [off|0x40000000]` or `[off|0x80000000]` with ASI 0xc/0xe, returning hi in %o0 and lo
  in %g1.
- `0x1d600` / `0x1d644`: cache_stag_write / cache_ptag_write(hi, lo, off, is_icache).
- `0x1d688` srmmu_set_pte_level(pte, level, va): builds context and L1/L2/L3 entries in the
  table at CTPR<<4.
  - Layout: L1 at +0x400, L2 at +0x800+i1*0x100, and L3 at +0x10800+i2*0x100 (+0x14800 when
    i1 = 0xf0).
  - It prints "bomb" (0x1de7d) when the level is > 3.
- `0x1d7d8` srmmu_ctx0_ctpr_init: CTX <- 0, CTPR <- 0xf8000.
- Shared stubs used here: 0xeb58/0xeb68 (MCNTL |= / &= ~0x300, IC+DC),
  0xeb78 (flash-clear I and D at both VAs), 0xe978/0xe980 (sta ASI 0x36/0x37).
- `0x19580`: an uncalled D-cache flash clear (ASI 0x37 at 0x80000000, then 0).

#### Notes for the CPU test suite
- **Lift as they are.** All eight asm tests (0x6dec, 0x6ef4, 0x7004, 0xcf2c, 0xd034,
  0xd124, 0x9c80 and the dead 0x9b40) are leaf code:
  - They use no RAM, MMU, MXCC or second CPU.
  - Their only dependencies are `post_printf` (serial), plus get_mid and get_module_type for
    error text and the PTAG hi mask.
  - Pass/fail is `%g3` plus the printed text. Wrap each call as `clr %g4` (quiet), then
    `call`, then `tst %g3`.
- **Keep the structure of the C Flashclear test.** Its runner depends on g3/g4 and on NVRAM
  byte 0x1ff2 for printing. Reimplementing the 4 flash types directly is simpler.
- **Viking features a core would need to pass these:**
  - The diag ASI decode for way and set.
  - 64-bit PTAG with V/D/S at bits 56/48/40, and a 24-bit PA tag.
  - Per-set STAG with MRU and lock fields.
  - Two flash-clear flavours.
  - Data diag access through ASI 0x0d/0x0f.
  - A core whose cache geometry differs from Viking's needs an emulation layer rather than
    a direct view of its tag RAM.
- **The write-hit test is the most useful for a write-back MESI core, even without the diag ASIs.**
  Its memory-contents check alone is a good write-back test:
  1. Map a region cacheable.
  2. Fill it by loads.
  3. Store to every word (all write hits).
  4. Read back through ASI 0x20 bypass.
  - With MB=1, memory must still hold the old values. A cached `ld` must return the new
    ones.
  - This requires that bypass reads neither snoop nor flush the CPU's own dirty lines, as
    on a real Viking, which returns memory.
  - Dependencies: at least 16 MB RAM (tables at 0xf80000), an SRMMU table walk, MCNTL
    ME/BM/SE/DC/IC, and copying the PROM to pa 0 so that code keeps running when BM is
    cleared.
  - Hard parts: the PROM copy overwrites low RAM (the stack), and the exact MRU and fill-order
    expectations (way 3 first, STAG = 0x100) are Viking-specific.

## 4. SuperSPARC / SuperSPARC-II SRMMU tests

Order in `post_main` (0x16504-0x16654): for module type 0x42 (MCNTL[31:24] = 0x08..0x0f,
"SuperSPARC-II", QEMU `TI, STP1021PGA`) the suite `post_supersparc2_mmu_suite` 0x1fb84 runs
first (kbd LED 8 around it, 0x16510..0x1653c); then, for every module type except 0x17
(HyperSPARC branches to 0x21790 and skips all of this), the four common SuperSPARC tests run:
Context Table Reg, Context Register, TLB Bit Pattern (x4 patterns), Flush Tests. The FSM
(801-6189-12, POST listing) shows exactly these four for a TMS390Z55. Failure of anything
here goes to `post_fail_cpu_module` (tested via `%g3`).

Conventions found in this group:
- Suite tests (0x1fb84) print their name only if NVRAM byte `pa 0xf_f120_1ff2 != 0`
  (`ss2_print_test_name` 0x1fb58), return `%o0 = 0 / -1`; the suite sets `%g3 = 1` on any
  failure (`sub_1ba6c`). Errors use `ss2_mmu_case_fail` 0x1fb00: `"Case %1: <text> exp=%2
  obs=%3 xor=%4"` with text = string `0x208b0 + case*0x41` (37 fixed-length strings,
  cases 0..0x24) and, for case > 0xd, `" entry # 0x%1"` with `%1 = addr >> 12`.
- `%g4` bit 2 = skip request (`sub_1ba04` returns and clears it: test returns 0), `%g4` bit 0
  = loop on test (`sub_1ba40`) (both guesses from use).
- TLB diagnostic address (ASI 5 = I-TLB, 16 entries; ASI 6 = D-TLB / SuperSPARC-I unified
  TLB, 64 entries): `entry<<12 | SEL<<8`. Formats as the ROM writes and expects them
  (agree with STP1021UG A.4.3.3):
  - SEL0 = VA tag, bits 31:12 (patterns 0x55555000/0xaaaaa000/0xfffff000 read back exactly).
  - SEL1 = context, 16 bits (0x5555/0xaaaa/0xffff read back).
  - SEL2 = cached PTE: PPN 31:8, C 7, M 6 (always reads 0 in the I-TLB: I-TLB patterns
    are 0x55555515/0xffffffbf), V 5 (replaces R), ACC 4:2, LVL 1:0. LVL = level the PTE came
    from: 0 = context (4 GB), 1 = region (16 MB), 2 = segment (256 KB), 3 = page (4 KB).
    A flush clears only V: the tests expect `PTE & ~0x20` afterwards (LVL stays readable).
  - SEL3 = bit 0 Lock, bit 1 RBO (D-TLB only).
  - SEL4 (ASI 6 addr 0x400) = cached root pointer PTP0; SEL5 = cached level-2 PTP (PTP2)
    `PTP | 01`, SEL6 = its VA tag (VA[31:18]); I-PTP2 at ASI 5 0x500/0x600, D-PTP2 k=0..3 at
    ASI 6 `k<<12 | 0x500/0x600`.
- Flush/probe = ASI 3, address `(va & ~0xfff) | type<<8` (`mmu_flush_va_type` 0xec30 and
  its copy 0x69b8 do `sta %g0`); types 0 page, 1 segment, 2 region, 3 context, 4 entire.
- Every TLB test in the suite except the bit-pattern/RBO tests runs with the MMU really on
  (MCNTL |= ME, &= ~BM, e.g. 0x1ffe0-0x1fff8), so instruction fetches are translated. The
  page tables therefore map VA 0..0x7ffff onto the PROM (pa 0xf_f000_0000).

Page tables built by `tlbtest_build_tables` 0x22290 (TLB_HIT/MISS/PROBE; shared with the HyperSPARC suite) and `mmu_build_ptp_test_tables` 0x20414 (PTP tests), all via ASI 0x20:
```
ASI4 0x200 (context) := 0 ; ASI4 0x100 (CTPR) := 0x100  -> context table at pa 0x1000
ASI6 0x400 (SEL4 PTP0) := 0x101                         -> root: L1 table at pa 0x1000   (*)
[0x1000] = 0x201      L1[0]  (also ctx-table entry 0)   -> L2 table at pa 0x2000
0x22290:  [0x2000] = 0xff00001e  L2[0] PTE  VA 0x00000-0x3ffff -> PROM +0      (ACC7, 256K)
          [0x2004] = 0xff00401e  L2[1] PTE  VA 0x40000-0x7ffff -> PROM +0x40000
          0x22314(base): for i=2..63: [pa 0x80000+(i-2)*0x40000] = base+i
                         [0x2000+4i] = (0x8000+(i-2)*0x4000)|0x8e   L2[i] PTE, C, ACC3,
                         i.e. identity VA=PA 0x80000..0xffffff in 256 KB segments
          0x22364: clears L2[2..63] (writes 0)
0x20414:  mode 0 (D-PTP): [0x2000]=0xff00007e, [0x2004]=0xff00407e (PTEs, R+M preset)
          mode 1/2:       [0x2000]=0x701 -> L3 at 0x7000, [0x2004]=0x711 -> L3 at 0x7100,
                          [0x7000+4k] = 0xff00007e + k*0x100, k=0..127 (PROM 4K pages)
          all modes: L2[2..5] = 0x301,0x401,0x501,0x601 -> L3 tables at 0x3000..0x6000,
                     [0x3000]=0x808e [0x4000]=0xc08e [0x5000]=0x1008e [0x6000]=0x1408e
                     (VA 0x80000/0xc0000/0x100000/0x140000 -> same PA, 4K pages)
```
(*) The context table entry for context 0 is 0x201 (L1 at 0x2000, whose entry 0 is a
PROM PTE), but the expected TLB contents (LVL = 2 for RAM pages, PTP2 = 0x301 at VA tag
0x80000, PTP0 = 0x101) are only produced if the table walk starts from the PTP0 value
injected through ASI 6 SEL4, making pa 0x1000 the L1 table. A walk from the context table
would map VA 0x80000.. onto the PROM. So all MMU-on suite tests need PTP0 injection.

### MMU ICACHE_TLB bit pattern Test
- Entry: `0x6914` (`post_mmu_icache_tlb_bit_pattern_test`), called from 0x1fbb0 in
  `post_supersparc2_mmu_suite` (module type 0x42 only).
- Write/read-back of every field of the 16 I-TLB entries through ASI 5. MMU off.
- **Algorithm**: entries 0..15 (`%l7`=0x10, stride 0x1000 in `%l2`); for SEL 0..3 (`%l5` +=
  0x100 until bit 10 set, 0x6980-0x698c) write 4 consecutive patterns from the PROM table
  0x6200 (fetched with `lda [..] 0x09`, 0x693c): 0x6940 `sta %l0,[%l5] 0x05`, 0x6944 `lda`
  back, 0x6948 compare; table pointer runs on across SELs, reset per entry.
- **Touches**: ASI 5 addresses `entry<<12 | SEL<<8`, 32-bit sta/lda; ASI 9 reads of 0x6200.
- **Expected**: SEL0: 0x55555000, 0xaaaaa000, 0xfffff000, 0; SEL1: 0x5555, 0xaaaa, 0xffff,
  0; SEL2: 0x55555515, 0xaaaaaaaa, 0xffffffbf, 0 (bit 6 = M masked in the I-TLB); SEL3:
  1, 0, 1, 0 (lock). All entries end zeroed. 256 write/read pairs.
- **Fails with**: case 0xf 0x20c7f `"Case %1: I_TLB  mis-matched exp=%2 obs=%3 xor= %4"` +
  `" entry # 0x%1"`. QEMU prints `Case 0000000f: I_TLB mis-matched exp=55555000
  obs=00000000 ... entry # 0x00000000` (first write, entry 0 SEL0): QEMU has no TLB diag.

### MMU ICACHE_TLB context flush Test / region / segment / page / entire flush Test
- Entry: `0x1fdb0` (`post_mmu_icache_tlb_flush_test`, args `%i0`=case, `%i1`=shift,
  `%i2`=flush type), called 5 times from the suite: 0x1fbd4 (0x20, 0, 3) "context",
  0x1fbf8 (0x21, 0x18, 2) "region", 0x1fc1c (0x22, 0x12, 1) "segment", 0x1fc40 (0x23, 0xc,
  0) "page", 0x1fc64 (0x24, 0xc, 4) "entire".
- Checks that ASI 3 demaps of each type clear exactly the matching I-TLB entries. MMU off.
- **Algorithm**: fill loop 0x1fdd8 for entry i=0..15 via `sta_asi05`: SEL0 = `i << shift`,
  SEL1 = i (context and entire cases) or 0, SEL2 = case (0x20|LVL: V=1, LVL 0/1/2/3) or,
  for entire, `0x20 | (i&3)`. Step loop 0x1fe50, j=0..15 (once for entire): context case
  writes ASI4 0x200 := j (others write context 0 once, at j=0), then 0x1fe88 flush at va
  `j << shift` (va 0 for context/entire), type `%i2`. Check loop 0x1fea4 reads SEL2 of all
  16 entries (`lda_asi05`, `entry<<12|0x200`).
- **Expected**: after step j, entries i<=j read `case & 3` (V cleared, LVL kept), entries
  i>j still read `case`; after the entire flush every entry reads `i & 3`. Flushes are
  cumulative (16 steps x 16 reads).
- **Fails with**: case `%i0-0x10` = 0x10..0x14: 0x20cc0 `"I_TLB flush context error  exp=%2
  obs=%3 ..."`, 0x20d01 region, 0x20d42 segment, 0x20d83 pages, 0x20dc4 entire; then
  0x213fe `"U-NUMBER : Suspect Viking Module, MBus Slot 0"`. ROM bug: `" entry # 0x%1"`
  prints `entry_index >> 12` = 0, because 0x1feec passes the index, not the address.

### MMU DCACHE_TLB.RBO_LCK Test
- Entry: `0x688c` (`post_mmu_dcache_tlb_rbo_lck_test`), called from 0x1fc80.
- R/W of the SuperSPARC-II D-TLB SEL3 field (bit 1 RBO, bit 0 Lock). MMU off.
- **Algorithm**: `%l5` = 0x300 (entry 0, SEL3), 64 entries (`%l7`=0x40, stride 0x1000);
  per entry 4 patterns from PROM 0x6240 via ASI 9: 0x68b4 `sta [%l5] 0x06`, 0x68b8 `lda`,
  compare.
- **Expected**: 3, 2, 1, 0 read back exactly (ends unlocked, RBO clear). 256 pairs.
- **Fails with**: case 0xe 0x20c3e `"Case %1: D_TLB.RBO_LCK mis-matched exp=%2 obs=%3
  xor= %4"` + entry #.
- After this test the suite checks `%g2 & 4` (memory present, guess); if clear it sets
  `%g3` and calls `post_fail_no_dsimm` 0x16d54 (0x1fc94-0x1fcb0) before the RAM tests.

### MMU D_cached_level2_PTP_test / MMU I_cached_level2_PTP_test / MMU Cached_root_pointer_PTP0_test
- Entry: `0x205a0` (`post_mmu_cached_ptp_test`, `%i0` = 0 D-PTP2, 1 I-PTP2, 2 PTP0),
  called from 0x1fcc4 / 0x1fce0 / 0x1fcfc.
- Checks that table walks load the SuperSPARC-II PTP caches (1 I-PTP2, 4 D-PTP2, PTP0).
- **Algorithm**: 0x205c4 `mmu_build_ptp_test_tables(%i0)` (tables above, includes PTP0 :=
  0x101 via ASI 6 0x400); 0x205cc-0x205e4 MCNTL |= ME, &= ~BM (code now fetched through the
  I-TLB from VA 0x205xx -> L2[0]); loop 0x20600: `ld`+`st` at VA 0x80000, 0xc0000,
  0x100000, 0x140000 (4 segments -> 4 D-PTP2 fills). Then read the caches (ASI 5/6).
- **Expected**: mode 2: ASI6 0x400 == 0x101. Mode 1: ASI5 0x500 == 0x701 OR ASI5 0x600 == 0
  (VA tag). Mode 0: for k=0..3: ASI6 `k<<12|0x600` == 0x80000/0xc0000/0x100000/0x140000
  OR ASI6 `k<<12|0x500` == 0x301/0x401/0x501/0x601 (first-invalid-first replacement from
  entry 0, STP1021UG A.4.3.3). The ROM accepts either field (OR), so a model that reads 0
  passes the I-PTP2 check. Exit 0x20854/0x20880: MCNTL BM on, ME off, `sta_asi03` with `%o0`=0x400
  as data and the stale `%o1` as address (probably meant a flush-entire at 0x400; ROM bug).
- **Fails with**: 0x21586 `"Cache_root_pointer_PTP0 error exp = 0x101 obs=%1"`, 0x215b9
  `"I_Cached_l2_PTP error: exp_ptp=0x701 obs=%1, exp_vaddr=0 obs=%2"`, 0x215fb / 0x2164b /
  0x2169b / 0x216ec `"D_Cached_l2_PTP_entry#0..3 error: exp_ptp=0x301..0x601 obs=%1,
  exp_vaddr=0x80000..0x140000 obs=%2"`. No U-number.

### MMU TLB_HIT Test
- Entry: `0x202e0` (`post_mmu_tlb_hit_test`), called from 0x1fd18.
- 62 translations must stay resident in the D-TLB after their PTEs are erased.
- **Algorithm**: 0x202e4 `tlb_invalidate_all_i_d` (0x1ff58: SEL2 := 0 for 64 entries on
  ASI 5 and ASI 6); 0x20308 tables; MMU on (0x20310-0x20328); 0x20334 fill with base
  0xa5a5a5a5; loop 0x2034c i=2..63: `ld`/`st` VA 0x80000+(i-2)*0x40000 (D-TLB fill, R+M);
  0x2036c clear L2[2..63] in memory; loop 0x20384: `ld` the same VAs again.
- **Expected**: each word = 0xa5a5a5a5 + i (0x20394 `sub %i5, 0x5a5a5a5b`); needs >= 62
  D-TLB entries and no re-walk (a re-walk finds PTE 0 -> data_access_exception, which is
  unexpected here: `%g5` is not set).
- **Fails with**: 0x21560 `"Tlb_hit error addr=%1 exp=%2 obs=%3"`; MMU restored (BM on, ME
  off) before return -1.

### MMU TLB_MISS Test
- Entry: `0x1ffa4` (`post_mmu_tlb_miss_test`), called from 0x1fd34.
- Table walks fill the D-TLB correctly (PTE bits, level) and the I-TLB gets the PROM entry.
- **Algorithm**: invalidate all (0x1ffa8); 0x1ffd8 tables; 0x1ffe0-0x1fff8 MMU on (ME=1,
  BM=0); 0x20000 fill with base 0x77777700; loop 0x20018 i=2..63: `ld` VA
  0x80000+(i-2)*0x40000. MMU off (0x2007c `sub_eb08` BM=1, `sub_eaf8` ME=0). Then 0x2008c
  I-TLB entry 0 SEL2 and 0x200f8 scan of 64 D-TLB SEL2 values.
- **Expected**: loads return 0x77777700+i. I-TLB entry 0 SEL2 = 0xff00003e (PPN 0xff0000,
  V, ACC 7, LVL 2; checked as `&~0xff == 0xff000000` and `&0xff == 0x3e`; mismatches only
  print). D-TLB: every entry with `(SEL2<<4)&~0xff` in [0x80000, 0xfd0000) must have low
  byte 0xae (C, V, ACC 3, LVL 2, M=0) and there must be exactly 0x3e (62) of them.
- **Fails with**: 0x21435 `"Tlb_miss error addr=%1 exp=%2 obs=%3 xor=%4"`, 0x21464
  `"I_TLB_miss paddr error: exp=0xFF000000 obs=%1 xor=%2"` (non-fatal), 0x2149b
  `"I_TLB_miss PTE error: exp= 0x3E obs=%1 xor=%2"` (non-fatal), 0x214cb
  `"D_Tlb_miss_RAM error entry# %1 exp=0xAE obs=%2 xor=%3"`, 0x21503 `"D_Tlb_miss_test:
  #%1_of tlb miss is not matched (%1)"`.

### MMU TLB_PROBE test
- Entry: `0x201cc` (`post_mmu_tlb_probe_test`), called from 0x1fd50.
- ASI 3 probe returns the level-2 PTE including hardware-updated R and M bits.
- **Algorithm**: invalidate all; tables; MMU on; fill (base 0xa5a5a5a5); loop 0x20238
  i=2..63: `ld`+`st` VA v = 0x80000+(i-2)*0x40000, then 0x20244 `lda [v|0x100] 0x03`
  (probe type 1 = segment). After the loop 0x202a8 clears L2[2..63]; MMU restored.
- **Expected**: probe == `(v >> 4) | 0xee` (PPN of v, C, M, R, ACC 3, ET 2), e.g. 0x80ee.
- **Fails with**: 0x2153a `"TLB_probe error exp = %1  obs = %2 "`.

### ENDIAN-ness Test with IU_registers
- Entry: `0x6250` (`post_endian_ness_test_with_iu_registers`), called from 0x1fd6c.
- SuperSPARC-II PSR.DE (bit 15) byte swapping for integer half/word/doubleword accesses.
- **Algorithm**: `sub_187d0(0x300000, 0x10)` RAM check (else prints 0x1314a `"<<BAD DSIMM IN
  SLOT 0, RUN MEMORY TEST, SKIPPED>>"`). All accesses via ASI 0x20 at pa 0x300000; DE set
  with `wr %psr | 0x8000`, cleared with `& 0xffff7fff` (3 nops after each).
- **Expected**: 0x15 stha/lduha 0x1234, DE=0 -> 0x1234; 0x16 stha big, DE=1, lduha ->
  0x3412; 0x17 DE=1 both -> 0x1234; 0x18 stha DE=1, DE=0 lduha -> 0x3412; 0 sta/lda
  0x01234567 DE=0; 1/2 stda/ldda 0x01234567_89abcdef DE=0; 3 sta big, DE=1 lda ->
  0x67452301; 4-6 same as 0-2 with DE=1; 7 sta DE=1, DE=0 lda -> 0x67452301; 8/9 stda
  big, DE=1 ldda -> 0x67452301 / 0xefcdab89 (integer LDD swaps each word separately);
  0xa/0xb stda DE=1, DE=0 ldda -> same. Ends with DE=0.
- **Fails with**: case N strings 0x208b0.. (0 `Big_endian_word`, 3 `Write_Big_read_little`,
  7 `Write_l_read_big`, 8-0xb `Dwrite_big_read_l_*`, 0x15 `Big_endian_hword`, 0x16-0x18
  `stha_*`). Errors are `bne sub_1fb00` (branch, not call), so after printing it returns to
  0x6268 (last call's `%o7`) and also prints the "BAD DSIMM" line. ROM bug: cases 0x15-0x18
  put the case number in `%o0` (delay slots 0x62cc/0x6310/0x633c/0x6388), so the string
  index is 0x300000 (garbage text). A failure with DE=1 returns with PSR.DE still set.

### ENDIAN-ness Test with FPU_registers
- Entry: `0x65b0` (`post_endian_ness_test_with_fpu_registers`), called from 0x1fd88.
- PSR.DE for FP loads/stores: LDF/STF swap 32 bits, LDDF/STDF swap the full 64 bits.
- **Algorithm**: same RAM check; normal (ASI 0xb, MMU off) accesses at 0x300000, needs
  PSR.EF=1 (PSR 0x10e0 from post_master_start). Setup DE=0: `std`/`ldd %f8` = 0x01234567 /
  0x89abcdef, `%f10`/`%f11` = 0xefcdab89 / 0x67452301. Compare with `fcmps` + `fbne sub_1fb00`.
- **Expected**: 0x19 st/ld `%f8` DE=0 -> equal; 0x1a st DE=0, ld DE=1 -> `%f11`
  (0x67452301); 0x1b DE=1 both -> equal; 0x1c st DE=1, ld DE=0 -> `%f11`; 0x1d/0x1e std/ldd
  DE=0 -> `%f8`/`%f9`; 0x1f/0x20 std DE=0, lddf DE=1 -> `%f0`=0xefcdab89 `%f1`=0x67452301;
  0x21/0x22 DE=1 both -> equal; 0x23/0x24 std DE=1, ldd DE=0 -> `%f10`/`%f11`.
- **Fails with**: case 0x19-0x24 strings 0x20f09..0x211d4 (`st_big_ldf_big` ..
  `std_litle_lddf_big_lowwrd`); same branch-to-sub_1fb00 return quirk (to 0x65c8).

### MMU Context Table Reg Test
- Entry: `post_main` 0x16544 prints 0x14642, then `0xf8dc`
  (`post_mmu_register_walking_one_test`) with `%o0`=0x100, `%o1`=0xfffffc00 (0x16560).
- Walking one through the Context Table Pointer register.
- **Algorithm**: `%l4` = 1, 2, 4 .. 0x80000000 (32 values, stops when it shifts to 0):
  0xf904 `sta %l4,[0x100] 0x04`, 0xf908 `lda`, compare `(w & mask)` vs `(r & mask)`.
- **Expected**: bits 31:10 read back as written (bits 9:0 ignored). Leaves CTPR =
  0x80000000.
- **Fails with**: `"<<< CPU_%1 on MBus Slot_%2 >>>"` + 0x129b7 `"ERROR : Address = %1, exp =
  %2, obs = %3, xor = %4"` (address 0x100) + 0x13727 `"U-NUMBER : Suspect Viking Module"`.

### MMU Context Register Test
- Entry: `post_main` 0x16578 prints 0x14662, then `0xf8dc` with `%o0`=0x200, `%o1`=0xfff.
- Walking one through the context register, 12 bits checked.
- **Expected**: bits 11:0 read back (SuperSPARC has 16 context bits, public knowledge; the
  TLB SEL1 patterns above also use 16).
- **Fails with**: as above, Address = 0x200.

### MMU TLB Bit Pattern Tests
- Entry: `post_main` 0x165ac prints 0x14622, then `0xf6dc` (`post_mmu_tlb_bit_pattern_test`)
  4 times (0x165d4/0x165f4/0x16614/0x16634) with `%o1` = 0x17d98, 0x17d88, 0x17d78, 0x17d68,
  `%o2` = 0x1000, `%o4` = 0. The printing wrapper `0xf188` (`post_mmu_tlb_bit_pattern_tests`)
  does the same and is called from the dead wrapper 0xf120 and from the HyperSPARC suite
  0x21894.
- Write/read of SEL0..3 of all 64 D-TLB (SuperSPARC-I: unified) entries through ASI 6.
- **Algorithm**: 64 entries (`%l7`), 4 SEL words per entry (`%l6`, `%l5` += 0x100); word from
  the table via ASI 9 (0xf704), 0xf708 `sta [%l5] 0x06`, 0xf70c `lda`, full compare; table
  pointer reset per entry (0xf72c).
- **Expected**: (SEL0, SEL1, SEL2, SEL3) = (0xaaaaa000, 0xaaaa, 0xaaaaaaaa, 0), (0x55555000,
  0x5555, 0x55555555, 1), (0xfffff000, 0xffff, 0xffffffff, 1), (0, 0, 0, 0). SEL2 keeps M
  (bit 6) here, unlike the I-TLB. Ends with all entries 0 (invalid, unlocked).
- **Fails with**: 0xf758: CPU banner + 0x129b7 (Address = diag address `entry<<12|SEL<<8`)
  + 0x13727 `"U-NUMBER : Suspect Viking Module"`, `%g3` = 1.

### MMU Flush Tests
- Entry: `0x1c5c8` (`post_mmu_flush_tests`), called from `post_main` 0x16648 (also from the
  dead wrapper 0xf174). Name printed only if NVRAM 0x1ff2 == 2.
- ASI 3 demap of each level on the 64-entry ASI 6 TLB (same idea as the I-TLB flush test).
- **Algorithm**: clear `%g3`; modes 0..4 via `mmu_flush_test_mode` 0x1c694:
  - l0 (0x1c6ac): entry i: SEL0=0, SEL1=i, SEL2=0x20; for c=0..63: context := c, flush
    (va 0, type 3), read all 64 SEL2.
  - l1 (0x1c7bc): SEL0=i<<24, SEL1=0, SEL2=0x21; context 0; flush (r<<24, type 2).
  - l2 (0x1c8d4): SEL0=i<<18, SEL2=0x22; flush (s<<18, type 1).
  - l3 (0x1c9ec): SEL0=i<<12, SEL2=0x23; flush (p<<12, type 0).
  - entire (0x1cafc): SEL0=i<<12, SEL1=i, SEL2=0x20|(i&3); context 0; one flush type 4.
- **Expected**: after step j entries i<=j read `lvl` (0/1/2/3, V cleared), i>j read
  `0x20|lvl`; after flush entire every entry reads `i & 3`. 64 steps x 64 reads per mode.
- **Fails with**: 0x1d812 `"Error: wrong tlb after l0 flush\nflush va 0, entry %1, exp %2,
  obs %3"`, 0x1d897 / 0x1d91d / 0x1d9a3 (l1/l2/l3: `"flush va %1, entry %2, exp %3, obs
  %4"`), 0x1da29 (flush entire), each followed by `"U-NUMBER : Suspect Viking Module, MBus
  Slot 0"`. Only the first error prints (`get_g3` check). ROM quirk: the l1 error path does
  not return -1 and nothing clears `%g3`, so the caller (0x1c64c) re-runs mode 1 until a
  `%g4` bit-2 skip request, even if the retry passes.

### Dead code: MMU TLB Hit, Index 1-3 / Index 1-2 / Index 1 / Context Test (0xf218)
- Entry: `0xf218` (`post_mmu_tlb_hit_index_tests`), reached only from the uncalled wrapper
  `0xf120` (f188 bit pattern, f218, f4dc, f5e8, 1c5c8). Not called.
- Data translation through TLB entries preloaded by diag writes; BM stays 1 (code from
  PROM), `mmu_enable` 0x18950 / `mmu_disable` 0x1896c toggle ME only.
- **Algorithm**: RAM check 0x50000; CTPR := 0x50000, context 0; `tlb_diag_load_table`
  0x18a4c(0, 0x17a40, 0x1000) writes 64 x 4 words (reads 1 KB from 0x17a40, only entries
  0-9 are meaningful). Then: Index 1-3: `sta 0xbeadcafe` pa 0x503184, MMU on, `ld
  [0x80d0d184]`; Index 1-2: `stba 0x69` pa 0x600124, `ldub [0x40f00124]`; Index 1: context
  1, `stha 0xface` pa 0xffffe, `lduh [0x210ffffe]`; Context: context 2, `stda
  0xfeedbabe_cafedead` pa 0x21468, `ldd [0x21468]`. Finally context := MID & 3.
- **Expected**: values read back unchanged. Table entries used: #4 tag 0x80d0d000 PTE
  0x00050367 (LVL 3), #7 0x40f00000 / 0x000600ef (LVL 3 even though the name says 1-2),
  #8 0x21000000 ctx 1 / 0x00000065 (LVL 1, 16 MB), #0 tag 0 ctx 2 / 0x00000064 (LVL 0).
- **Fails with**: 0xf7b8 banner + 0x129b7 + 0x13727.

### Dead code: MMU TLB Read Miss Test (0xf4dc) / MMU TLB Write Miss Test (0xf5e8)
- Entry: `0xf4dc` / `0xf5e8`, only from the uncalled wrapper 0xf120.
- **Algorithm**: RAM check; read miss builds [0x50000]=0x52001, [0x52000]=0x54001,
  [0x54000]=0x1e; write miss [0x50000]=0x52000, [0x52000]=0x54000 (ET 0), [0x54004]=0x11e;
  CTPR := 0x50000; `%g5` := 9 (data_access_exception expected); `ld [0]` / `clr [0x1000]`
  with ME=1.
- **Expected**: read: [0x54000] still 0x1e and ASI6 0x200 (entry 0 SEL2) still 0x64 from
  the Hit table; write: [0x54004] has bit 0 or 2 set and is not 0x16e. With standard CTPR
  semantics (table at CTPR<<4 = 0x500000) the walk never reaches these tables (guess:
  obsolete test). Nothing checks that the trap was taken; the "No trap taken, expected %1"
  printer 0xf818 is unreferenced.
- **Fails with**: 0xf7b8 (address, exp, obs, xor) + 0x13727.

### Helpers
- `0x1fb00` ss2_mmu_case_fail: print case string `0x208b0+case*0x41`, entry # for case > 0xd,
  `%g3`=1, return -1.
- `0x1fb58` ss2_print_test_name: `post_printf(%i0)` if NVRAM 0x1ff2 != 0.
- `0x1fb84` post_supersparc2_mmu_suite: runs only for module type 0x42; order bit pattern,
  5 I-TLB flush tests, RBO_LCK, memory check, D-PTP2, I-PTP2, PTP0, TLB_HIT, TLB_MISS,
  TLB_PROBE, endian IU, endian FPU; first failure -> `%g3`=1, return -1.
- `0x1ff58` tlb_invalidate_all_i_d: SEL2 := 0 for entries 0..63 on ASI 5 and ASI 6.
- `0x20414` mmu_build_ptp_test_tables(mode) (layout above), ends with MMU on.
- `0x22290` tlbtest_build_tables, `0x22314` tlbtest_fill_segments(base),
  `0x22364` tlbtest_clear_segment_ptes (shared; used by 0x1ffa4/0x201cc/0x202e0
  and HyperSPARC 0x21fb8/0x221a4, which take the 0x17 branch at 0x222b4).
- `0xec30` mmu_flush_va_type(va, type) (`sta %g0` ASI 3); `0x69b8` is an identical copy.
- `0xf8dc` post_mmu_register_walking_one_test(asi4_addr, mask), also used by HyperSPARC.
- `0x18950` mmu_enable (MCNTL |= 1), `0x1896c` mmu_disable (MCNTL &= ~1).
- `0x18a24` mmu_set_context, `0x18a38` mmu_set_ctpr (ASI 4 0x200 / 0x100).
- `0x18a4c` tlb_diag_load_table(start, table, stride): 64 entries x SEL0..3 from PROM, no
  read-back, table pointer never reset.
- `0x18988` rom_table_to_asi, `0x189c4` rom_copy_bytes_to_phys, `0x189f4`
  rom_copy_words_to_phys: unreferenced copy loops (PROM via ASI 9 -> ASI x / ASI 0x20).
- Data: 0x6200 I-TLB patterns (4 SEL x 4 words), 0x6240 RBO/LCK patterns (3,2,1,0),
  0x17d68/78/88/98 D-TLB patterns (16 bytes each), 0x17a40 TLB-hit preload table (10
  entries used), strings 0x208b0-0x2173c and 0x1d800-0x1dab1.
- Error printers 0xf758 / 0xf7b8 / 0xf93c do `mov %o2, %fp` around the banner: they clobber
  the caller's `%sp` on failure (common POST error idiom).

#### Notes for the CPU test suite
- Easy to lift, no RAM, MMU off, serial output only: MMU Context Table Reg / Context
  Register (walking one on ASI 4 0x100 / 0x200), TLB Bit Pattern (ASI 6, 64 x SEL0-3),
  MMU Flush Tests (ASI 6 fill + ASI 3 stores + context writes), and for a SuperSPARC-II
  model the I-TLB bit pattern / I-TLB flush / RBO_LCK tests. Pass/fail = compare and
  print; embed the pattern tables instead of reading the PROM through ASI 9.
- A core does not need a real 64-entry translating TLB to pass the four common tests: a
  diag-visible 64 x (tag, ctx16, PTE32, lock) RAM with flush matching (context: ctx ==
  context reg; region/segment/page: ctx match + VA[31:24]/[31:18]/[31:12] match and LVL >=
  1/2/3; entire: all) that clears bit 5 of SEL2 would do. The context register must hold
  at least 12 bits.
- The MMU-on suite tests (PTP, TLB_HIT/MISS/PROBE) need RAM at pa 0x1000-0x7200 (tables)
  and 0x80000-0xfc0004 (>= 16 MB), code mapped at VA 0..0x7ffff (the ROM maps the PROM; a
  RAM-resident suite must map itself instead), PTP0 injection through ASI 6 SEL4,
  invalid-first TLB/PTP2 replacement, >= 62 D-TLB entries, R/M updates visible to the ASI 3
  probe. The stack (`%sp` = 0x1fba0 from post_master_start) is not mapped to RAM while the
  MMU is on, so no window spill may happen there (guess: the ROM relies on shallow calls).
- Endian tests: RAM at pa 0x300000, FPU enabled, PSR.DE; bypass ASI 0x20 accesses must
  honour DE. Nothing in this group needs MXCC or a second CPU.
- Open: exact SEL1 width on SuperSPARC-I (the ROM expects 16 bits read back), and whether
  real SuperSPARC context flushes skip ACC >= 6 entries (the tests use ACC 0, so untested).

## 5. FPU tests (ROM 0x9f00-0xc3c0)

Two group runners, both called from `post_main`, run 21 FPU tests. Three more test functions
are present in the ROM but never called: SP CE Trap Priority, SP Data Store Trap and DP Data
Store Trap. The Field Service Manual lists the same 21 tests in the same order.

**Common environment (all tests).** The MMU is off, so plain `ld/st/ldd/std` (default
ASI 0x0b) access physical RAM. Scratch memory is pa 0x600000..0x600027 (the stores' target
is usually 0x600000). Each test starts with the usual `andcc %g4,2` name print and `clr %g3`,
then calls `sub_187d0(0x600000, 0x10)`. That helper writes 0xaaaaaaaa and then 0x55555555 to
4 words through ASI 0x20 and reads them back. If they do not match, the test prints
0x1314a "<<BAD DSIMM IN SLOT 0, RUN MEMORY TEST, SKIPPED>>" and returns with %g3 = 0 (the
test is skipped, not failed). `%g1` is set to the address of the test body (progress marker).
The FPU is enabled once, in the Register File test (0xa248, PSR |= 0x1000 = EF), and stays
enabled. fp_disabled (tt 0x04) is never exercised.

**Exception-test template (all CEXC, Trap Priority, UE/CE and Data Store tests).**
1. `st 0x0f800000; ld [0x600000],%fsr`. This sets FSR = TEM 0x1f (NVM|OFM|UFM|DZM|NXM all
   enabled), RD = 0 (round to nearest), NS = 0, aexc = cexc = 0.
2. Load the operands by storing words to 0x600000 and doing `ld/ldd` into the f registers.
3. Clear the store target (`clr [%l4]` or `std %g0-pair`).
4. `mov 8,%g5` (expected trap = fp_exception, tt 0x08).
5. Execute the FPop. **The very next instruction is an FP store of the FPop's destination**
   (`st %f3` or `std %f4`), followed by one `nop`.
6. `cmp %g0,%g5; bne,a fpu_fail_no_trap`: the trap must have been taken no later than that
   store.
7. Read back the store target, which must still hold the pre-cleared value, otherwise the
   test fails with "Did Not Block Store".
8. `st %fsr`, then `andcc` with a single cexc bit, which must be set, otherwise the test fails
   with "FPU Status Register". Only that one bit is checked. The full FSR a V8 FPU should hold
   is: RD 0, TEM 0x1f, ftt = 1 (IEEE_754_exception) at bits 16:14, qne 0, aexc 0, and cexc
   containing the tested bit. The ROM does not check the other fields.

**fp_exception handler** (vector 0x80 -> `trap_fp_exception` 0x5884):
- 0x5884-0x5890: compares tt = (%tbr>>4)&0xff with %g5. A mismatch goes to
  `trap_unexpected_sync`.
- Loop 0x58ac-0x58cc: `st %fsr -> [0x600010]`. While FSR bit 13 (qne) is set, it does
  `std %fq -> [0x600018]`.
- Then `clr %g5` and `wr %l0,%psr`, and returns with `jmp %l2; rett %l2+4`. This **resumes at
  nPC, skipping the trapping instruction**, so the FP store that took the deferred trap never
  runs.
- tt 7 (mem_address_not_aligned) is handled by the generic 0x4920 handler: the same compare,
  clear and skip, without touching the FPU.

### Group runners (no name string)
- Entry `0x9f00`, called from post_main `0x167e0`. The keyboard LED command is
  kbd_send(0x0e), kbd_send(0) before it.
  - Sets l0 = get_mid()&3, `mmu_set_ctpr(0x50000)` (context table at pa 0x500000) and
    `mmu_set_context(0)`.
  - Calls, stopping at the first failure: 0xa18c, 0xa4bc, 0xa57c, 0xa800.
  - Exit 0x9f78: on HyperSPARC (module type 0x17) it calls `mmu_disable` 0x1896c. It always
    calls `mmu_set_context(MID&3)`.
- Entry `0x9fa4`, called from post_main `0x16804`, after kbd_send(0x0e), kbd_send(8).
  - Does the same CTPR/context setup.
  - SP tests: 0xa9c0, 0xaaac, [0xab90 skipped if module type 0x17], 0xac70, 0xad58, 0xae4c,
    0xaf24, 0xb054. At 0xa07c a `nop` sits in the call slot where the SP CE test (0xb1c4)
    would go.
  - DP tests: 0xb464, 0xb568, [0xb668 skipped if 0x17], 0xb760, 0xb85c, 0xb968, 0xba44,
    0xbb8c, 0xbd1c.
  - Exit 0xa158: `sta %g0,[8] 0x2f` clears EMC EFSR (pa 0xf_0000_0008), then the same
    HyperSPARC mmu_disable and context restore.
- A failure (%g3 = 1) in either group makes post_main branch to `post_fail_cpu_module`.

### FPU Register File Test
- Entry: `0xa18c`, called from `0x9f24` (first group).
- Tests: the stuck-at behaviour of every FP double register (f0..f30) with 4 patterns.
- **Algorithm:**
  - 0xa1fc-0xa238: builds a pattern table at pa 0x600000:
    FFFFFFFF_FFFFFFFF, 55555555_55555555, AAAAAAAA_AAAAAAAA, 00000000_00000000.
  - 0xa248: sets PSR.EF.
  - Loop 0xa254 (o4 = 0, 8, 16, 24; o5 = 4 iterations):
    - `ldd [0x600000+o4]` into all 16 pairs %f0..%f30, and into %l0/%l1 (expected value).
    - For each pair: `std %fN,[0x600100]` then `ldd [0x600100],%l2`, and compare %l2/%l3
      with %l0/%l1 (0xa298-0xa494).
- **Touches:** pa 0x600000-0x60001f (r/w, 64-bit), pa 0x600100 (64-bit store/load), PSR.
- **Expected:** every register reads back its pattern exactly. All registers hold the same
  value, so aliasing between registers is **not** detected.
- **Fails with:** 0x1391f "ERROR : FPU Registerfile Stuck-at Fault" (from 0xbff0). It then
  dumps all 16 pairs with 0x12e5c "%1 : %2 %3" (register number, hi, lo) and prints 0x13727
  "U-NUMBER : Suspect Viking Module".

### FPU Misaligned Reg Pair Test
- Entry: `0xa4bc`, called from `0x9f38`.
- Tests: that LDDF with an odd register number (rd = %f1) is executed without a trap. The
  ROM expects rd bit 0 to be ignored.
- **Algorithm:**
  - 0xa534: `std` of 0x01234567_fedcba98 to [0x600000].
  - 0xa538: `ldd [..],%f1` (odd rd). 0xa53c: `ldd [..],%f2`.
  - 0xa540: `fcmps %f0,%f2`. 0xa550/0xa554: `fmovs %f1,%f0; fmovs %f3,%f2`. 0xa558:
    `fcmps %f0,%f2`.
- **Expected:** f0 = f2 = 0x01234567 and f1 = f3 = 0xfedcba98, with no trap (%g5 is 0, so an
  illegal_instruction trap or an fp_exception with ftt = 6 invalid_fp_register goes to
  trap_unexpected_sync).
- **ROM bug:** the branches after the compares (0xa548, 0xa560, word 0x128xxxxx) are integer
  `bne`, not `fbne`. They test icc left by the `tst %o0` at 0xa4f0 (Z = 1), so the compare
  result is never checked. **Only "no trap" is actually tested.**
- **Fails with:** (unreachable) 0x1394e "FPU Single-precision Operation" (via 0xc19c).

### FPU Single-precision Tests
- Entry: `0xa57c`, called from `0x9f4c`.
- Tests: fdivs, fadds, fmuls and fsubs, each producing 25.0, interleaved with FP loads and
  stores while FPops are in flight.
- **Operands** (st to 0x600000, then ld; fmovs copies):

  | Register | Value |
  |---|---|
  | f0, f2, f16, f28 | 0x41c80000 (25) |
  | f6 | 0x42c80000 (100) |
  | f7 | 0x40800000 (4) |
  | f9 | 0x43480000 (200) |
  | f10 | 0x41000000 (8) |
  | f12, f13, f19, f25 | 0x40a00000 (5) |
  | f15 | 0x3f800000 (1) |
  | f18 | 0x41a00000 (20) |
  | f21 | 0x41700000 (15) |
  | f22 | 0x41200000 (10) |
  | f24 | 0x41f00000 (30) |
  | f27 | 0x42480000 (50) |

- **Algorithm (0xa69c-0xa6c8):**
  - `st %f0,[0x600010]`, fdivs f6/f7 -> f8, fadds f18+f19 -> f20, `ld [0x600010],%f1`,
    fmuls f12*f13 -> f14, fsubs f24-f25 -> f26.
  - `st %f2,[0x600020]`, fdivs f9/f10 -> f11, fadds f21+f22 -> f23, `ld [0x600020],%f3`,
    fmuls f15*f16 -> f17, fsubs f27-f28 -> f29.
  - Checks: `fcmps fN,%f0; nop; nop; fbne` for f1, f3, f8, f11, f14, f17, f20, f23, f26, f29.
- **Expected:** all 10 results are 0x41c80000. Every operation is exact, so no exception
  occurs whatever TEM holds.
- **Fails with:** 0x1394e "ERROR : FPU Single-precision Operation, exp = %1, obs = %2"
  (0xc19c), after 0x16088 "<<< CPU_%1 on MBus Slot_%2 >>>", then "Suspect Viking Module".
  ROM quirk: obs is printed from %l1 (stale 0x42480000), not %l2.

### FPU Double-precision Tests
- Entry: `0xa800`, called from `0x9f60`.
- Tests: fdivd, faddd, fmuld and fsubd, each producing 25.0, with overlapping ldd/std.
- **Operands** (high word; the low word is always 0):

  | Register | Value |
  |---|---|
  | f0, f4 | 0x40390000 (25) |
  | f8 | 0x40590000 (100) |
  | f10 | 0x40100000 (4) |
  | f14, f16, f28 | 0x40140000 (5) |
  | f20 | 0x402e0000 (15) |
  | f22 | 0x40240000 (10) |
  | f26 | 0x403e0000 (30) |

- **Algorithm:**
  - 0xa8dc-0xa8f8: `std %f0,[0x600010]`; fdivd f8/f10 -> f12; `ldd [0x600010],%f2`;
    faddd f20+f22 -> f24; `std %f4,[0x600020]`; fmuld f14*f16 -> f18;
    `ldd [0x600020],%f6`; fsubd f26-f28 -> f30.
  - Checks: `fcmpd fN,%f0; fbne` for f2, f6, f12, f18, f24, f30.
- **Expected:** all 6 results are 0x40390000_00000000.
- **Fails with:** 0x13997 "ERROR : FPU Double-precision Operation, exp = %1 %2, obs = %3 %4"
  (0xc1f4), with exp = l0/l1 and obs = l2/l3.

### Exception-test summary

All of these follow the template above. "Trap" is the tt value in %g5. The store goes to the
destination of the FPop, "RB" is the value that must be read back, and "cexc" is the bit
that must be set.

| Test (entry, caller) | Operands | FPop (addr) | FP store (addr) -> target | Trap | RB | cexc |
|---|---|---|---|---|---|---|
| SP Invalid (0xa9c0, 0x9fc8) | f1=0x7f800000 (+Inf), f2=0xff800000 (-Inf) | fadds f1,f2,f3 (0xaa54) | st %f3 (0xaa58) -> 0x600000 | 8 | 0 | 0x10 NV |
| SP Overflow (0xaaac, 0x9fdc) | f1=0x7f7fffff (FLT_MAX) | fadds f1,f1,f3 (0xab38) | st %f3 (0xab3c) -> 0x600000 | 8 | 0 | 0x08 OF |
| SP Underflow (0xab90, 0xa004) | f1=0x00800000 (FLT_MIN) | fmuls f1,f1,f3 (0xac18) | st %f3 (0xac1c) -> 0x600000 | 8 | 0 | 0x04 UF |
| SP Divide-by-0 (0xac70, 0xa018) | f1=0x41c80000 (25), f2=0 | fdivs f1,f2,f3 (0xad00) | st %f3 (0xad04) -> 0x600000 | 8 | 0 | 0x02 DZ |
| SP Inexact (0xad58, 0xa02c) | f1=0x3f7fffff (1-2^-24), f2=0x34004000 (2^-23(1+2^-9)) | fadds f1,f2,f3 (0xadf4) | st %f3 (0xadf8) -> 0x600000 | 8 | 0 | 0x01 NX |
| SP Trap Priority > (0xae4c, 0xa040) | 25 / 0 | fdivs (0xaee0) | st %f3 (0xaee4) -> **0x00801000** | 8 | not checked | DZ |
| SP Trap Priority < (0xaf24, 0xa054) | 25 / 0 | fdivs (0xafd4) | st %f3 (0xafd8) -> **0x600002**, then st %f3 (0xb004) -> 0x600000 | **7 then 8** | 0 | DZ |
| SP UE Trap Priority (0xb054, 0xa068) | 25 / 0 | fdivs (0xb144) | st %f3 (0xb148) -> 0x503240 | 8 | 0xd5a5a5a5 | DZ |
| DP Invalid (0xb464, 0xa08c) | f0=0x7ff00000_0 (+Inf), f2=0xfff00000_0 (-Inf) | faddd f0,f2,f4 (0xb500) | std %f4 (0xb504) -> 0x600000 | 8 | 0,0 | NV |
| DP Overflow (0xb568, 0xa0a0) | f0=0x7fefffff_ffffffff (DBL_MAX) | faddd f0,f0,f4 (0xb600) | std %f4 (0xb604) | 8 | 0,0 | OF |
| DP Underflow (0xb668, 0xa0c8) | f0=0x00100000_00000000 (DBL_MIN) | fmuld f0,f0,f4 (0xb6f8) | std %f4 (0xb6fc) | 8 | 0,0 | UF |
| DP Divide-by-0 (0xb760, 0xa0dc) | f0=0x40390000_0 (25), f2=0 | fdivd f0,f2,f4 (0xb7f4) | std %f4 (0xb7f8) | 8 | 0,0 | DZ |
| DP Inexact (0xb85c, 0xa0f0) | f0=0x3fefffff_ffffffff (1-2^-53), f2=0x3cb00800_0 (2^-52(1+2^-9)) | faddd f0,f2,f4 (0xb900) | std %f4 (0xb904) | 8 | 0,0 | NX |
| DP Trap Priority > (0xb968, 0xa104) | 25 / 0 (double) | fdivd (0xba00) | std %f4 (0xba04) -> 0x00801000 | 8 | not checked | DZ |
| DP Trap Priority < (0xba44, 0xa118) | 25 / 0 (double) | fdivd (0xbafc) | std %f4 (0xbb00) -> **0x600004**, then std %f4 (0xbb2c) -> 0x600000 | **7 then 8** | 0,0 | DZ |
| DP UE Trap Priority (0xbb8c, 0xa12c) | f1=25, f2=0 (single!) | **fdivs** f1,f2,f4 (0xbc7c) | std %f4 (0xbc80) -> 0x503240 | 8 | d5a5a5a5 a5a5a5a5 | DZ |
| DP CE Trap Priority (0xbd1c, 0xa140) | f1=25, f2=0 (single) | fdivs f1,f2,f4 (0xbe04) | std %f4 (0xbe08) -> 0x503260 | 8 | 0,0 (corrected) | DZ |

Failure strings shared by every test in this table (each preceded by
"<<< CPU_%1 on MBus Slot_%2 >>>" and followed by "Suspect Viking Module"):
- 0xc370: 0x12c37 "ERROR : No trap taken, expected %1" (prints %g5).
- 0xc2b0: 0x13a2e "ERROR : FPU Exception Did Not Block Store, addr = %1, exp = %2, obs = %3,
  xor = %4".
- 0xc254: 0x139e6 "ERROR : FPU Status Register, exp = %1, obs = %2, xor = %3". ROM quirk: obs
  is printed after the `andcc` masked it, so it always shows 0.
- A trap other than the one in %g5 goes to trap_unexpected_sync: 0x13848 "Unexpected
  Synchronous Trap Taken, Trap Type %1".

**How good the "blocked store" check is:**
- SP tests: f3 is 0 at this point (left by `ldd [0x600010],%f2` at 0xa8e4 in the DP test),
  and the target was pre-cleared to 0. So an FPU that wrongly executed the store (for example
  a precise-trap design resuming at nPC = the store) would still pass. The SP UE test is the
  exception, since there the read-back must equal 0xd5a5a5a5.
- DP tests: f4/f5 still hold 0x40390000_00000000 from 0xa888, so an executed store **is**
  detected.

### FPU SP Invalid CEXC Test
- Entry: `0xa9c0`, called from `0x9fc8`.
- Tests: IEEE invalid (+Inf + -Inf) with NVM = 1. The fp_exception must be deferred to the
  following `st %f3` and must suppress it.
- **Algorithm:** the template. Operands 0xaa34-0xaa48, `clr [0x600000]` at 0xaa4c, %g5 = 8
  at 0xaa50, fadds at 0xaa54, st at 0xaa58, then checks at 0xaa60 (%g5), 0xaa74 (memory) and
  0xaa8c (FSR & 0x10).
- **Touches:** FSR (ld/st), pa 0x600000 (word), and the handler's 0x600010/0x600018.
- **Expected:** trap tt 8 taken at 0xaa58; [0x600000] = 0; FSR.cexc bit 4.
- **Fails with:** see the summary table.

### FPU SP Overflow CEXC Test
- Entry: `0xaaac`, called from `0x9fdc`.
- **Algorithm:** 0x7f7fffff + itself (fadds at 0xab38), then the template.
- **Expected:** tt 8; [0x600000] = 0; FSR & 0x08 (OF). An extra NX bit is allowed, since only
  bit 3 is tested.
- **Fails with:** see the summary table.

### FPU SP Underflow CEXC Test
- Entry: `0xab90`, called from `0xa004`. Skipped when get_module_type = 0x17 (HyperSPARC).
- **Algorithm:** 0x00800000 * itself = 2^-252 (fmuls at 0xac18), with UFM = 1.
- **Expected:** tt 8; FSR & 0x04 (UF). This requires an IEEE trap, not ftt = 2
  (unfinished_FPop), for a tiny result.
- **Fails with:** see the summary table.

### FPU SP Divide-by-0 CEXC Test
- Entry: `0xac70`, called from `0xa018`.
- **Algorithm:** 25.0 / 0.0 (fdivs at 0xad00).
- **Expected:** tt 8; FSR & 0x02 (DZ).
- **Fails with:** see the summary table.

### FPU SP Inexact CEXC Test
- Entry: `0xad58`, called from `0xa02c`.
- **Algorithm:** 0x3f7fffff + 0x34004000 = 1 + 2^-24 + 2^-32, which is not representable
  (fadds at 0xadf4). This exercises the sticky/rounding logic.
- **Expected:** tt 8; FSR & 0x01 (NX).
- **Fails with:** see the summary table.

### FPU SP Trap Priority >  Test
- Entry: `0xae4c`, called from `0xa040`.
- Tests: the pending fp_exception wins over whatever the FP store itself would do. By V8
  priority, fp_exception (11) outranks data_access_error/exception (12/13). The idea that
  0x801000 stands for a faulting address is a guess: in POST, with the MMU off, pa 0x801000 is
  ordinary RAM, so no competing trap actually occurs.
- **Algorithm:** 25 / 0 (fdivs at 0xaee0), then `st %f3,[0x00801000]` at 0xaee4. Checks
  %g5 = 0 and FSR & 2. The target is **not** read back.
- **Expected:** tt 8, DZ.
- **Fails with:** see the summary table.

### FPU SP Trap Priority <  Test
- Entry: `0xaf24`, called from `0xa054`.
- Tests: a trap that outranks fp_exception is taken first. mem_address_not_aligned
  (priority 10) must beat the pending fp_exception (11) on the same FP store, and the FP
  exception must stay pending for the next FP instruction.
- **Algorithm:**
  - l5 = 0x600002. f1 = 25 and f2 = 0.
  - get_module_type: if not 0x17, %g5 = **7** (0xafd0); on HyperSPARC %g5 = 8.
  - fdivs at 0xafd4, then `st %f3,[0x600002]` at 0xafd8 (misaligned). Check %g5 = 0.
  - If not HyperSPARC: `mov 8,%g5; st %f3,[0x600000]` (0xb004, no nop), then check %g5 = 0.
  - Then check [0x600000] = 0 and FSR & 2.
- **Expected:** on SuperSPARC, tt 7 first (the misaligned store is skipped by the 0x4920
  handler), then tt 8 on the aligned store. On HyperSPARC, a single tt 8.
- **Fails with:** "No trap taken"; or unexpected trap type 08 if the FPU exception is taken
  first; plus the common strings.

### FPU SP UE Trap Priority Test
- Entry: `0xb054`, called from `0xa068`.
- Tests: an FP store blocked by a pending fp_exception must never reach memory. Here memory
  holds an uncorrectable ECC error, so a store that got through would do a partial-write
  read-modify-write, hit the UE, and cause an asynchronous error (guess: a data_store_error or
  a level-15 MEM_ERR interrupt).
- **Algorithm** (EMC register addresses in %o0..%o4 = 8/0x18/0/0x10/0x14 as offsets in
  pa 0xf_0000_0000; EFAR0/1 at 0x10/0x14 are never used):
  - 0xb0dc: `sta %g0` -> EFSR (pa 0xf00000008): clears CE/UE/TO and unfreezes EFAR.
  - 0xb0e4: `sta 0x400` -> ECC Diagnostic reg (pa 0xf00000018): DMODE = 01 ("diagnostic
    generate": the CB bits, all 0 here, are written as check bits).
  - 0xb100: `stda 0xd5a5a5a5_a5a5a5a5 -> [0x503240] ASI 0x20`, stored with check bits 0x00.
    That this makes a UE is a guess: presumably the check bits of the 0xa5.. pattern are 0,
    making this a 3-bit error in one nibble.
  - 0xb104: diag reg := 0 (normal). 0xb108: EFSR := 0.
  - 0xb10c: `sub_188f0` reads the ECC Enable reg (pa 0xf00000000) and returns 0x200003fc if
    IMPL (bits 31:28) = 2, else 0x100003fc. The result is ORed with 1 and written back at
    0xb11c: EE = 1 (checking on), EI = 0 (no CE interrupt), MRR<7:0> = 0xff (refresh on for
    all rows). IMPL is read-only.
  - 25 / 0 fdivs at 0xb144; `st %f3,[0x503240]` at 0xb148; check %g5 = 0.
  - 0xb168: ECC Enable := value without EE (checking off).
  - 0xb174: `ld [0x503240]` must equal 0xd5a5a5a5. Then FSR & 2.
  - 0xb1b4: ECC Enable written again without EE.
- **Touches:** ASI 0x2f pa 0xf00000000 (r/w), 0xf00000008 (w), 0xf00000018 (w); pa 0x503240
  (ASI 0x20 stda, default-ASI ld); FSR.
- **Expected:** tt 8, memory unchanged, DZ.
- **Fails with:** "Did Not Block Store" with addr = 0x503240, exp = 0xd5a5a5a5; plus the
  common strings.

### FPU DP Invalid CEXC Test
- Entry: `0xb464`, called from `0xa08c`.
- **Algorithm:**
  - `std` of +Inf into f0/f1 and -Inf into f2/f3.
  - `std %g0-pair` (l2 = l3 = 0) clears 0x600000/4.
  - faddd f0,f2,f4 at 0xb500; `std %f4` at 0xb504.
  - Both read-back words must be 0 (0xb520, 0xb530). Then FSR & 0x10.
- **Expected:** tt 8, NV.
- **Fails with:** see the summary table.

### FPU DP Overflow CEXC Test
- Entry: `0xb568`, called from `0xa0a0`.
- **Algorithm:** DBL_MAX + DBL_MAX (faddd at 0xb600).
- **Expected:** tt 8, FSR & 0x08.
- **Fails with:** see the summary table.

### FPU DP Underflow CEXC Test
- Entry: `0xb668`, called from `0xa0c8`. Skipped on HyperSPARC.
- **Algorithm:** DBL_MIN * DBL_MIN (fmuld at 0xb6f8).
- **Expected:** tt 8, FSR & 0x04.
- **Fails with:** see the summary table.

### FPU DP Divide-by-0 CEXC Test
- Entry: `0xb760`, called from `0xa0dc`.
- **Algorithm:** 25.0 / 0.0 (fdivd at 0xb7f4).
- **Expected:** tt 8, FSR & 0x02.
- **Fails with:** see the summary table.

### FPU DP Inexact CEXC Test
- Entry: `0xb85c`, called from `0xa0f0`.
- **Algorithm:** 0x3fefffff_ffffffff + 0x3cb00800_00000000 = 1 + 2^-53 + 2^-61 (faddd at
  0xb900).
- **Expected:** tt 8, FSR & 0x01.
- **Fails with:** see the summary table. ROM quirk: the first read-back branch at 0xb924 is a
  non-annulled `bne`, which is harmless.

### FPU DP Trap Priority >  Test
- Entry: `0xb968`, called from `0xa104`.
- **Algorithm:** the same as the SP version with doubles: fdivd 25/0 at 0xba00,
  `std %f4,[0x00801000]` at 0xba04. Checks %g5 and FSR & 2; no read-back.
- **Expected:** tt 8, DZ.
- **Fails with:** see the summary table.

### FPU DP Trap Priority <  Test
- Entry: `0xba44`, called from `0xa118`.
- **Algorithm:**
  - l5 = 0x600004 (word-aligned but not doubleword-aligned).
  - %g5 = 7 (not 0x17) or 8 (0x17).
  - fdivd at 0xbafc, then `std %f4,[0x600004]` at 0xbb00 (misaligned).
  - If not HyperSPARC: %g5 = 8 and `std %f4,[0x600000]` at 0xbb2c.
  - Both words at 0x600000 must be 0. Then FSR & 2.
- **Expected:** tt 7 then tt 8 (SuperSPARC).
- **Fails with:** see the summary table.

### FPU DP UE Trap Priority Test
- Entry: `0xbb8c`, called from `0xa12c`.
- **Algorithm:**
  - The same EMC sequence as the SP UE test (0xbc14-0xbc54): EFSR := 0, diag := 0x400,
    `stda 0xd5a5a5a5_a5a5a5a5 -> 0x503240` with CB = 0, diag := 0, EFSR := 0,
    ECC Enable := sub_188f0()|1.
  - The FPop is **single-precision** `fdivs f1,f2,f4` (25/0) at 0xbc7c, followed by a
    doubleword `std %f4,[0x503240]` at 0xbc80. A full-doubleword store that got through would
    need a line fill or RMW of the UE line (guess).
  - 0xbca0: ECC off. `ldd [0x503240]` must return d5a5a5a5 / a5a5a5a5. Then FSR & 2.
    0xbd0c: ECC off again.
- **Expected:** tt 8, DZ.
- **Fails with:** "Did Not Block Store" (addr 0x503240); plus the common strings.

### FPU DP CE Trap Priority Test
- Entry: `0xbd1c`, called from `0xa140` (last test).
- **Algorithm:**
  - EFSR := 0, diag := 0x400.
  - `stda 0x00000008_00000000 -> [0x503260] ASI 0x20` with CB = 0. That this is a
    single-bit (data bit 35) error is a guess, supported by the expected corrected read.
  - diag := 0, EFSR := 0, ECC Enable := sub_188f0()|1 (EE = 1, EI = 0).
  - fdivs f1,f2,f4 at 0xbe04; `std %f4,[0x503260]` at 0xbe08.
  - **With ECC still enabled**, `ldd [0x503260]` must return 0,0: the EMC corrects the CE,
    and with EI = 0 there is no interrupt. Then FSR & 2.
  - 0xbe74: ECC off. EFSR (holding CE) is cleared later by the runner at 0xa15c.
- **Expected:** tt 8, a corrected read of 0, DZ.
- **Fails with:** "Did Not Block Store" (addr 0x503260, exp 0); plus the common strings.

### FPU SP CE Trap Priority Test
- Entry: `0xb1c4`, not called (dead code). The runner has a `nop` at 0xa07c in its call slot,
  and the Field Service Manual does not list it.
- **Algorithm:** the SP twin of the DP CE test:
  - stda 0x00000008_00000000 with CB = 0 -> 0x503260 (0xb268); ECC on.
  - fdivs at 0xb2ac; `st %f3,[0x503260]` at 0xb2b0.
  - A word read with ECC on must give 0 (0xb2c8). Then FSR & 2.
- **Fails with:** see the summary table.

### FPU SP Data Store Trap Test
- Entry: `0xb318`, not called (dead code).
- **Algorithm:**
  - `ld [0x500000],%g0` (touches the line; this is the context table given CTPR 0x50000).
  - fdivs 25/0 at 0xb3ac; `st %f3,[0x500000]` at 0xb3b0.
  - Checks %g5 = 0, then that [0x500000] = 0.
  - FSR & 2; a failure branches to the *SP Operation* message 0xc19c (ROM bug).
  - HyperSPARC only (0xb404-0xb44c): ASI 4 va 0x300 (SFSR) must be 0x3aa. As a standard
    SRMMU SFSR (guess), that is L = 3, AT = 5 (supervisor data store), FT = 2 (protection),
    FAV = 1. ASI 4 va 0x400 (SFAR) must be 0x500020, and a second SFSR read must be 0.
- **Fails with:** 0x129b7 "ERROR : Address = %1, exp = %2, obs = %3, xor = %4" (0xc310),
  plus the common strings.
- **Notes:** this appears to need the MMU on with a page table (HyperSPARC flow). The SFAR
  (0x500020) does not match this test's store address (0x500000); it looks copied from the
  DP version.

### FPU DP Data Store Trap Test
- Entry: `0xbe84`, not called (dead code).
- **Algorithm:**
  - `ld [0x500020],%g0`; fdivd 25/0 at 0xbf24; `std %f4,[0x500020]` at 0xbf28.
  - Both words at 0x500020 must be 0. FSR & 2 (a failure goes to 0xc19c, ROM bug).
  - HyperSPARC: SFSR = 0x3aa, SFAR = 0x500020, then SFSR = 0 (0xbf90-0xbfd8).
- **Fails with:** 0xc310 "Address = ..." and the common strings.

#### Helpers
- `trap_fp_exception` 0x5884 (vector tt 0x08): checks tt against %g5, drains the FQ
  (`st %fsr` -> 0x600010; while qne, `std %fq` -> 0x600018), clears %g5, and returns to nPC
  (skipping the trapping instruction).
- `mmu_set_context` 0x18a24: `sta %i0,[0x200] ASI 4` (context register).
- `mmu_set_ctpr` 0x18a38: `sta %i0,[0x100] ASI 4` (context table pointer).
- `mmu_disable` 0x1896c: MCNTL (ASI 4 va 0) &= ~1 (ME). Called only on HyperSPARC at group
  exit. Its twin 0x18950 sets ME and is not used here.
- `sub_187d0` (memory quick check, not owned here): (base, len) -> 1 if the 0xaaaaaaaa /
  0x55555555 write/readback through ASI 0x20 fails.
- `sub_188f0` (EMC enable value, owned by the ECC group): reads pa 0xf00000000, returns
  0x200003fc if IMPL = 2, else 0x100003fc.
- Error exits: 0xbff0 regfile dump, 0xc19c SP op, 0xc1f4 DP op, 0xc254 FSR, 0xc2b0 store not
  blocked, 0xc310 MMU fault register (Data Store tests), 0xc370 no trap. All set %g3 = 1 and
  return.

#### Notes for the CPU test suite

**No devices needed (FPU, trap table and RAM only)**
- Tests: Register File, Misaligned Reg Pair, SP/DP arithmetic, all 10 CEXC tests, SP/DP Trap
  Priority > and <.
- They need:
  - RAM at pa 0x600000..0x600107, plus 0x801000 for Trap Priority >. Any scratch address
    works if the suite relocates it.
  - PSR.S = 1, ET = 1, EF = 1.
  - A trap table with vectors 0x07 and 0x08 implementing the %g5 protocol (compare tt, clear
    %g5, resume at nPC). The 0x08 handler must also drain the FQ with `std %fq` while
    FSR.qne = 1. A catch-all for other vectors should flag an unexpected trap.
- The MMU can stay off and no serial port or other device is required. Report pass/fail
  through %g3, a result word in RAM, or the unexpected-trap path.

**Priority checks**
- The most valuable single checks are the SP/DP Trap Priority < tests: on an FP load/store,
  mem_address_not_aligned must win over fp_exception (V8 Table 7-1).
- The POST's SuperSPARC path expects tt 7 first; a core that gives fp_exception priority
  stops with "Unexpected Synchronous Trap Taken, Trap Type 08" in "FPU SP Trap Priority <
  Test". The HyperSPARC path (module type 0x17) accepts tt 8 first.

**Needs the memory controller**
- SP/DP UE and CE Trap Priority need the EMC at pa 0xf_0000_0000:
  - ECC Diagnostic reg 0x18 with DMODE = 01 to write chosen check bits.
  - ECC Enable reg 0x0 for EE.
  - EFSR 0x8 to clear errors.
- They also need real ECC generate/check/correct in the RAM path. Without it the UE tests
  reduce to "blocked store leaves memory unchanged" and pass. The CE test cannot
  pass without correction, because it expects the injected 0x00000008 to read back as 0.
- A suite should either implement an EMC model, or turn the CE test into a plain
  blocked-store test with a nonzero pre-load.

**Improvements when lifting the tests**
- Pre-load the FPop destination (f3 or f4) with a nonzero pattern, so the SP
  "Did Not Block Store" checks become meaningful.
- Replace the integer `bne` at 0xa548/0xa560 with `fbne`.
- Compare the full FSR: expect ftt = 1, qne = 0, aexc = 0 and cexc exactly equal to the bit
  (plus NX for OF/UF, which is implementation-defined), not just one bit.
- The register-file test should use a different pattern per register to catch address
  faults.
- The tests only pass if the trap is **deferred**: it must be taken at the next FP
  instruction, including FP stores, not at the FPop itself. A precise-trap FPU returns from
  the handler to nPC = the store and fails Trap Priority < (tt 8 while %g5 = 7).

**Hard or implementation-specific**
- HyperSPARC skips both Underflow tests.
- The Data Store Trap tests (dead) need the MMU on and HyperSPARC-specific SFSR values.
- The group runner sets CTPR = 0x50000 and context 0. The reason is unclear (guess: for the
  HyperSPARC MMU-on case), and it does not matter with the MMU off.

## 6. SuperSPARC MXCC (external E-cache controller) tests

`post_main` runs this group per CPU, right after "Cache Flashclear Test" (0x16718). At 0x1672c it
calls `mxcc_absent` (0x194f8, returns MCNTL & 0x800), and only when MCNTL.MB (bit 11) is 0 does
it call the group runner 0x197ac at 0x16740. On return, `tst %g3` sends a failure to
`post_fail_cpu_module`. The FSM's "Full Diagnostic Mode" sample listing shows the same seven names
in the same order, including "MXCC E-Cache Data RAM Test (1 MB E$DATA RAM, MXCC_CSR=00000000)".

**Conventions that differ from the rest of POST.**
- Test names print only when NVRAM byte 0x1ff2 == 2 (pa 0xf_f120_1ff2, which is also the condition
  for `%g4 |= 2` at 0x16430). They never test `%g4 & 2`.
- Tiny accessors handle the error flag: 0x1ba80 clears `%g3`, 0x1ba6c sets it to 1, and 0x1ba58
  reads it. An error message prints only if `%g3` was still 0, so only the first error of a test
  is shown.
- **Retry on error:** after each step, most tests do `if (%g3) goto retry-same-step`. `%g3` never
  clears, so a failing step repeats forever with no further output. POST hangs after one
  message instead of reaching `post_fail_cpu_module`. The only way out is `%g4` bit 2 (0x1ba04
  tests and clears it; nothing in this group sets it). Exceptions: the Tag RAM and Data RAM
  tests exit on the first error. `%g4` bit 0 (LOOP, console key 'l') repeats a whole test via
  0x1ba40.
- Expected-interrupt protocol: `%g5 = 0x1f` (level-15 interrupt trap) and `%g7 = 0x94`, set via
  0x1b9c4. With `%g7 == 0x94`, the level-15 handler 0x5574 clears `%g5` and does the following:
  1. Sets all system-interrupt mask bits: 0xf87fffff to pa 0xf_f141_000c.
  2. Writes 0x80008000 to every CPU's clear-pending register (pa 0xf_f140_0004 + n*0x1000).
  3. Re-reads its own pending register. If bits 0x80008000 are still set, it sets `%g3 = 1`
     (0x6178).
  4. Otherwise it unmasks again: 0xf87fffff to pa 0xf_f141_0008.

  Neither the EMC EFSR nor the MXCC error register is cleared in the handler. That is only safe
  because level-15 is an *edge*: the sun4m spec says a source sets HARDINT.15 once, and that bit
  is cleared by the clear-pending write. A core whose level 15 is level-sensitive re-traps and
  dies in `trap_unexpected_async`.
- Stream-op timeout: poll the RDY bit up to 1000 (0x3e8) times. Interrupt wait: a 20-iteration
  busy loop (about 40 instructions) after the triggering `stda`.


**MXCC programming model, as the ROM uses it** (bit numbers are 63..0 of the ldda/stda pair; hi =
first word, lo = second word). Cross-checked with Sun4M arch spec B.III, text/Sun4M_SystemArchitecture_edited2.txt.

| ASI 2 address | use in these tests |
|---|---|
| 0x01000000 + line<<7 + sb<<5 + dw<<3 | E$ data diag, 128-byte lines, 4 x 32-byte sub-blocks. 64-bit R/W, plus word `sta`/`lda` (0x19730) and `stba` (0x1a37c) |
| 0x01800000 + line<<7 | E$ tag diag, 64-bit. R/W mask hi 0x0000000f (PA[35:32]), lo 0xfff8eeee: PA[31:19] plus, per sub-block n, nibble 4n+3..4n = {S,O,V,P}. P is not R/W-tested |
| 0x01c00000..0x01c00038 | stream data, 8 dword addresses walked (block ops use 0x00-0x18) |
| 0x01c00100 / 0x01c00200 | stream source / destination. Writing {hi,lo} starts the op: hi bit 4 (bit 36) = C (cacheable), hi[3:0]/lo = PA. Reading gives RDY = hi bit 31 (bit 63) |
| 0x01c00a00 (lo word at 0x01c00a04) | control. Bit 2 CE (E$ enable), 3 PE (parity), 4 MC, 5 PF, 9 RC. **Bit 1 = E$ size, 1 = 2 MB** (ROM use; reserved in the 1991 spec). Accessed with 32-bit `lda`/`sta` at 0x01c00a04 |
| 0x01c00e00 | error register. Cleared by writing {-1,-1}. hi: 31 ME, 29 CC, 28 VP, 27 CP, 26 AE, 25 EV, 24:15 CCOP, 14:7 ERR, 6 S, 3:0 PA[35:32]. lo = PA[31:0] |
| 0x01c00f00 (lo word 0x01c00f04) | port, MID = lo[27:24] (0x1ba94, get_mid) |
| 0x01c00300, 0x01c00b00, 0x01c00c00 | only read (Register Test) |

MCNTL (ASI 4, VA 0) bits used: 11 MB (read), 12 PE (0xeb9c/0xebc8). EMC registers used: MER pa
0xf_0000_0000 (EE bit 0, EI bit 1, MRR 0x3fc), memory delay 0xf_0000_0004, EFSR 0x…008, EFAR0/1
0x…010/0x…014, ECC diag 0x…018 (0x400 = DMODE 01, CB forced).

### (group runner, no name string) "MXCC not installed, skipping the test"
Entry `0x197ac`, called from post_main 0x16740 (only when MB = 0).
- 0x197b0: if `mxcc_absent()`, print 0x1bc00 and return. This is unreachable from post_main.
- 0x197d8: write 0x2895 to the EMC memory delay register (pa 0xf_0000_0004) via 0x18780. The spec
  gives 0x2895 as the Viking/E$ value.
- Runs Register (0x198b4), Tag RAM (0x19b80), Data RAM (0x19c5c, only if NVRAM[0x1ff2] == 2,
  checked at 0x19818), Block Zero (0x19fe4), Block Copy (0x1a628), Cacheable Read (0x1af04) and
  Cacheable Write (0x1b584). After each test, `%g3 != 0` ends the group (0x198ac).
- 0x198a4: write 0x20 to the memory delay register. This happens only when everything passed; an
  error exit leaves 0x2895.

### MXCC Register Test
Entry `0x198b4`, called from runner 0x197e0.
Walks a 1 through every register bit under a mask, then read-only accesses the rest of the MXCC
register set.

**Algorithm:** helper `mxcc_dword_reg_walk` 0x19a2c(asi = 2, addr, mask_hi, mask_lo):
- If both masks are 0, it only does `ldda addr` (0x19a6c).
- Otherwise it saves the original {hi,lo}. For i = 0..31, with b = 1<<i, it writes
  {(orig_hi & ~mask_hi) | (b & mask_hi), (orig_lo & ~mask_lo) | (b & mask_lo)} (0x19ab8), reads
  it back (0x19ac0) and compares both words (0x19ae4/0x19af4).
- Finally it restores the original value (0x19b70).
- An asi other than 2 prints "bomb" (0x1bc3d). This path is dead.

The test calls the helper as follows:
1. 0x19918: addr = 0x01c00000 + 8k for k = 0..7, masks -1/-1 (stream data).
2. 0x199c0: the 12-byte table {addr, mask_hi, mask_lo} at 0x1bb90, terminated by -1:
   0x01c00100, 0x200, 0x300 with masks 0/0; 0x01c00a00 with 0/**0x234**; then 0xb00, 0xe00,
   0xf00, 0xc00 with masks 0/0.

**Touches:** ASI 2, 64-bit `ldda`/`stda` only.

**Expected:** stream data dwords hold all 64 bits (the same bit in hi and lo). Control lo bits 2,
4, 5 and 9 (CE, MC, PF, RC) are R/W; every other control bit must read back as its original
value. The other registers must be readable without a trap.

**Fails with:** 0x1bc42 "CPU_%1 error: dbl word register, asi %2, addr %3" + 0x1bc75 "exp %1 %2,
obs %3 %4", then retries forever (0x1992c/0x199d4).


### MXCC E-Cache Tag RAM Test
Entry `0x19b80`, called from runner 0x197fc.
Pattern-tests every E$ tag.

**Algorithm:**
1. 0x19b84: size = `mxcc_ecache_size_detect` (0x19720):
   - It writes E$ data 0x01000008 = 0x77777777 and 0x01100008 = 0x55555555 (word `sta`).
   - If reading 0x01000008 returns the value read at 0x01100008 (bit 20 ignored, so they alias),
     the cache is 1 MB: clear control bit 1 and return 1.
   - Otherwise set control bit 1 and return 2.
   - The banner code (0x1eedc/0x1ef2c/0x1ef8c) uses the same routine to print "<n>Mb External
     cache".
2. For line = 0..size*0x2000-1, in chunks of 0x100 lines, call `ecache_tag_rw_line` 0xe820(line)
   with tag address 0x01800000 | line<<7:
   - write {0x0000000a, 0x5a584a4a} (0x5a5a5a5a masked with 0xf/0xfff8eeee), `ldda` back, and
     compare hi (0xe864) and lo (0xe884);
   - then do the same with {0x00000005, 0xa5a0a4a4}.

**Expected:** 0x2000 tags (1 MB) or 0x4000 (2 MB). The read-back equals the masked write.

**Fails with:** 0xecb8 `ecache_tag_rw_fail` prints 0x16088 "<<< CPU_%1 on MBus Slot_%2 >>>",
0x129b7 "ERROR : Address = %1, exp = %2, obs = %3, xor = %4" (address = tag+0 or tag+4) and
0x13727 "U-NUMBER : Suspect Viking Module". It sets `%g3 = 1` and returns -1, and the test exits.
Apparent ROM bug: 0xecc4 uses `%fp` as scratch, which corrupts the caller's `%sp` on this path.


### MXCC E-Cache Data RAM Test
Entry `0x19c5c`, called from runner 0x1982c, only when NVRAM[0x1ff2] == 2.
March test of E$ data lines through the diagnostic path.

**Algorithm:**
- The header adds '0'+size (0x12008) and 0x1bcd1 " MB E$ DATA RAM, MXCC_CSR=%1)", where
  %1 = `lda [0x01c00a04]` (0x19c98).
- For base = 0, 0x100, ..., lines-0x100, call `ecache_data_line_march` 0x19e24(base). The line
  address is A = 0x01000000 + base<<7, with 16 dwords at A + 0..0x78:
  - (a) write {addr, addr} to each dword (0x19e50);
  - (b) ascending (0x19e70): read, write {~addr, ~addr}, and expect {addr, addr};
  - (c) descending (0x19f24): read, write {addr, addr}, and expect {~addr, ~addr}.
- **ROM bug:** the pass counter (%l7) runs 256 times, but the address always uses %i0. So only
  lines 0x000, 0x100, ..., 0x1f00 are tested (32 of 8192 for 1 MB), each 256 times.

**Fails with:** 0x1bd2b + 0x1bd39 "f_error: wrong e$ data addr %1, exp %2 %3, obs %4 %5", or
0x1bd6f + 0x1bd7d "b_error: …". The helper returns -1 and the test exits.


### MXCC Non-Cache Block Zero Test
Entry `0x19fe4`, called from runner 0x19848. **Needs a DSIMM in slot 0**: `%g2 & 7` (the
slot-0 size code from memory sizing 0x125c0) must be non-zero, else 0x1bdd4 " << NO DSIMM IN
SLOT 0, TEST SKIPPED >>" (printed only in full-diag mode).

**Algorithm:** for dest = 0, then 0x20, 0x40, 0x80, ..., 0x80000 (16 addresses), call 0x1a0cc(dest):
1. `stda` {0,0} to stream data 0x01c00000..0x18.
2. Pre-fill memory: `sta [dest+k] 0x20 = k` for k = 0..0x1c.
3. 0x1a12c: `stda` {0, dest} to 0x01c00200 (C = 0, starts a non-cacheable stream write).
4. Poll `ldda 0x01c00200` hi bit 31 (RDY), up to 1000 times (0x1a148).
5. Check `lda [dest+k] 0x20` == 0 for the 8 words (0x1a1b8).

**Fails with:** 0x1bdfc "timeout on stream wr, dest = %2", 0x1be2f "target memory asi 20, addr
%2, exp %3, obs %4"; retries forever (0x1a080).


### MXCC Non-Cache Block Copy Test
Entry `0x1a628`, called from runner 0x19864. **Needs a DSIMM in slot 0** (0x1a65c, string
0x1bf5f).

**Setup:**
- 0x1a6a0: system interrupt clear-mask pa 0xf_f141_0008 = 0xf87fffff.
- 0x1a6b4: ITR pa 0xf_f141_0010 = MID&3.
- 0x1a6c8: EMC MER = (IMPL? 0x200003fc : 0x100003fc) | 3, i.e. EE + EI + refresh on (0x188f0).

**Loops:** mode m = 0..2; X = 0, 0x20, 0x40, ..., 0x80000; eoff = 0 only for m = 0, and 0/8/0x10/0x18
for m = 1, 2. Each iteration calls 0x1a7dc(src = X+0x20, dest = X, eoff, m). That helper first
unmasks system interrupts (0x1a804) and ends by masking them (0x1aeec, set-mask 0xf87fffff).

- **m = 0:**
  1. Memory src dwords = {off, off+4}; dest = {0x80000000|off, 0x80000000|off+4}. Stream data is
     zeroed.
  2. 0x1a87c: `stda` {0, src} to 0x01c00100, then poll src RDY.
  3. 0x1a90c: `stda` {0, dest} to 0x01c00200, then poll dst RDY.
  4. Expect stream data = {off, off+4} and dest word k = k.
- **m = 1 (CE):**
  1. 0x1bb1c fills the src block with 0xa5a5a5a5_a5a5a5a5. The eoff dword instead gets
     0x25a5a5a5_a5a5a5a5, written with EMC diag = 0x400 (CB forced to 0), which is a 1-bit error
     at data bit 63.
  2. Zero the stream data and error register; set `%g5 = 0x1f`, `%g7 = 0x94`; `stda` {0, src} to
     the source register; wait 20 loops.
  3. Require `%g5 == 0`, i.e. the level-15 interrupt was taken (0x1ab40).
  4. Check EFSR (0x…008) == 0x8501 | eoff<<1, i.e. SYND 0x85, DW = eoff/8, CE.
  5. Check EFAR0 == MID<<28 | 0x083fc510 | (obs & 0x07c00000): S, VA 0xff, SIZ 5 (32 B),
     TYPE 1 (read), PA[35:32] 0. Check EFAR1 == src.
  6. Clear EFSR, then expect all four stream dwords = 0xa5a5a5a5_a5a5a5a5 (corrected).
- **m = 2 (UE):**
  1. The eoff dword is 0x65a5a5a5_a5a5a5a5 with CB forced to 0 (2-bit error).
  2. Same `%g5`/`%g7` setup and stream read as m = 1.
  3. Only `%g3 == 0` is checked (0x1adec).
  4. Expect the MXCC error register = {**0x06ac00c0**, src}: AE, EV, CCOP 0x158 (NC Stream Read
     Reply), ERR 1 (UE), S. Then clear it.

End: clear the MXCC error register, MER = the value without EE/EI, and mask all system interrupts.

**Fails with:** 0x1bf87 / 0x1bfb8 (stream rd/wr timeouts), 0x1bff6 and 0x1c173 "dw read stream
data reg", 0x1c03f "destination memory word", 0x1c091 "ce intr 15 on stream read did not occur",
0x1c0e9 "ecc fsr", 0x1c131 "ecc far", 0x1c1c9 "ue intr 15 … g3=%3 g5=%4" and 0x1c22e "mxcc error
reg after ue". It retries forever.


### MXCC Cacheable Block Read Test
Entry `0x1af04`, called from runner 0x19880. **Needs a DSIMM in slot 0** (string 0x1c288).
Checks cacheable stream reads against the E$ state of the source sub-block.

**Setup and loops:**
- 0x1af78: unmask system interrupts.
- Loops: src = 0 only (the 0x1b024 loop goes 0 then 0x20, and exits at < 0x20); mode = 0..1;
  estate index 0..4 into the byte table 0x1bb88 = {0x0, 0x2, 0x6, 0xa, 0xe}, whose nibble is
  S|O|V|P; eoff = 0 for mode 0, 0..0x18 for mode 1. That makes 25 calls.

**Per call, 0x1b07c:**
1. Clear all tags (0xec44), CE = 1 (0xec00), CREG.PE = MCNTL.PE = 1 (0xeb9c).
2. Memory src word k = k. E$ data of the src sub-block = {0x80000000|off, 0x80000000|off+4}.
3. Tag = {0, estate << 4*sb} (0x1b14c). Stream data is zeroed.
4. Mode 1 only: with parity off, write {0,0} to E$ data at sub-block + eoff, which gives it bad
   parity (0x1b1b4).
5. Normal path (mode 0, or mode 1 with the O bit clear):
   - 0x1b1f0: `stda` {**0x10**, src} to 0x01c00100 (C = 1), then poll RDY.
   - Expected stream data: E$ data if O (bit 2) is set, otherwise memory {off, off+4}.
6. Owned-parity path (0x1b33c, estate 0x6/0xe in mode 1):
   - Clear the error register; `%g5 = 0x1f`, `%g7 = 0x94`; stream read; wait 20 loops;
     require `%g3 == 0`.
   - Expect the error register = {**0x0e607fc0**, src}: CP, AE, EV, CCOP 0x0c0, ERR 0xff (all 8
     byte lanes), S.
   - Clear it and unmask again.
7. Both paths, 0x1b4b0: expect tag = {0, (estate | (V ? S : 0)) << 4*sb}. So after the read,
   0x2→0xa, 0x6→0xe, 0xa→0xa, 0xe→0xe, and invalid stays 0 (no allocate).
8. Exit: clear the error register, parity off, CE off (0xec18).

**Fails with:** 0x1c2bd "timeout on stream rd src %1, estate %2" (%2 = table index), 0x1c2fd "dw
stream data reg", 0x1c34e "parity error intr 15 … did not occur", 0x1c3b1 "mxcc error reg after
parity error", 0x1c411 "e$ tag". It retries forever.


### MXCC Cacheable Block Write Test
Entry `0x1b584`, called from runner 0x1989c. **Needs a DSIMM in slot 0** (string 0x1c46b).

**Loops:** dest = 0, 0x20, 0x40, 0x80; estate index 0..4 (the same table). That makes 20 calls to
0x1b67c(dest, idx).

**Per call:**
1. Clear tags, CE = 1 (no parity).
2. Memory dest word k = k. E$ data at *line base* (dest & 0xfff80) sub-block 0 =
   {0x80000000|off, 0x80000000|off+4}.
3. Tag (0x01800000 + dest & 0xfff80) = {0, estate << 4*((dest>>5)&3)}.
4. Stream data = {0x40000000|off, 0x40000000|off+4}.
5. 0x1b77c: `stda` {**0x10**, dest} to 0x01c00200 (cacheable stream write), then poll RDY.
6. Expected results:
   - E$ data **unchanged** (0x1b814);
   - the whole tag = {0, 0}, i.e. the sub-block is invalidated whatever its prior state,
     including owned (0x1b8b0);
   - memory dest word k = 0x40000000|k (0x1b938).
7. CE off.

**Fails with:** 0x1c4a0 "timeout on stream wr, dest %1", 0x1c4d2 "e$ destination data", 0x1c524
"e$ dest tag" (it prints 0x01c00220 as the address, a ROM slip), 0x1c56e "destination memory".
It retries forever.


### mxcc parity error test
Entry `0x1a228`. **Not called (dead code).** It forces a byte-parity error into E$ data and
checks that the error is reported through module control space.

**Algorithm:**
- Unmask system interrupts.
- For addr = 0, 8, 0x10, ..., 0x80000 and byte b = 0..7, call 0x1a328:
  1. Clear the error register; parity on; `stda` {-1,-1} to E$ 0x01000000+addr.
  2. Parity off; `stba 0` to E$ +(7-b); parity on.
  3. `%g5 = 9`, `%g7 = 0`; `ldda` pa 0xf_(F0|MID<<24)+addr (module control-space E$ data,
     0xFFn000000). Then read SFSR.
  4. Require the trap to have been taken.
  5. Expect the error register = {0x0a80004f | 1<<(b+7), 0xf0000000|MID<<24|addr}: CP, EV,
     CCOP 0x100, ERR = byte lane, S, PA[35:32] = 0xf.

**Fails with:** 0x1be8b "no trap on e$ parity error", 0x1bee6 "mxcc_err reg".


### MXCC Parity RAM Test
Entry `0x1a4c8`. **Not called (dead code).** It initialises E$ parity for a fixed 0x2000 lines
(1 MB).

**Algorithm:** parity on. Then per line (0x1a584): zero all 16 dwords, ascending read + write
0x11111111_11111111, descending read + write 0. Parity off. There are no compares; errors can
only show up as unexpected parity traps.


### E-cache tag neighbour test (no name string)
Entry `0x19d44`. **Not called (dead code).** It writes tag(line) = pattern masked with
0xf/0xfff8eeee, writes tag(line+1 mod 1 MB) = ~pattern, then reads tag(line) back. Error 0x1bcfd
"error: e$ tag addr %1, exp %2 %3, obs %4 %5".


### 0x195b0-0x19720 (not BIST)
This range is dead memory-config helpers plus one live routine; no ASI 0x39 or MXCC BIST
(0x01c00800) is referenced anywhere in the ROM.
- 0x195b0: returns 0/0x04000000/0x08000000/0x0c000000 from bit 3 of the `%g2` nibbles at bits
  16..31, or 0x99 if none (guess: VSIMM slot offset).
- 0x19618: returns the base address (table 0x19684: n*0x04000000) of the first `%g2` nibble that
  is non-zero with bit 3 clear (first DSIMM), else 0x99000000.
- 0x196a4: unreached code; returns `%g4 & 0xff000000` unless `%g4[31:24] == 0x99`.
- 0x196c8: live `to_lower`, called from the POST console at 0x11be8.
- 0x196f0: an unreferenced debug string "\r\nl1 = %1  l7 = %2  l6 = %3".

#### Helpers
- 0x194f8 `mxcc_absent`: returns MCNTL & 0x800. Used by post_main 0x1672c, the runner and the banner.
- 0x19720 `mxcc_ecache_size_detect`: returns 1 or 2 (MB) and sets control bit 1 to match.
  Clobbers E$ line 0 dword 1.
- 0x19a2c `mxcc_dword_reg_walk`: see Register Test.
- 0xe820 `ecache_tag_rw_line`: two-pattern tag write/read. The error exit is 0xecb8.
- 0x19e24 `ecache_data_line_march`; 0x1a0cc / 0x1a7dc / 0x1b07c / 0x1b67c: per-iteration bodies
  of the block tests.
- 0xeb9c `mxcc_parity_enable` (CREG lo |= 8, then MCNTL |= 0x1000); 0xebc8 `mxcc_parity_disable`
  (both cleared, the two `sta`s back to back after a padding word at 0xebec).
- 0xec00 / 0xec18 `mxcc_ecache_enable` / `_disable` (CREG lo bit 2).
- 0xec44 `mxcc_ecache_tags_clear`: `stda` {0,0} to 0x01800000 + n*0x80 for n = 0..0x1fff, or
  0..0x3fff if CREG bit 1 is set.
- 0x1bb1c `fill_block_with_ecc_error`(src, eoff, hi, lo, cb); 0x1bae8 `emc_diag_write_dword`
  (dead).
- 0x1ba94 `mxcc_get_mid`: port register lo[27:24].
- 0x1b9c4 `set_expected_trap_g5_g7`; 0x1b9e0 `expected_trap_taken` (`%g5 == 0`).
- 0x1ba04 abort flag (`%g4` & 4, cleared); 0x1ba40 loop flag (& 1); 0x1ba28 burn-in flag (& 8,
  dead); 0x1ba58 / 0x1ba6c / 0x1ba80 get / set / clear `%g3`; 0x1babc "hit a key to continue"
  (dead).
- Dead: 0x19470 / 0x194a4 strided store via ASI dispatcher 0x18e74; 0x194d4 / 0x19538 MCNTL
  |= / &= ~0xc100 (AC, SE, DE); 0x19514 / 0x1955c CREG *hi* word 0x01c00a00 bit 2 set / clear
  (probably a slip for 0xa04); 0x19580 D$ flash clear (lock + valid); 0xd9c0 `stba` bit 0x20
  into ASI 2 0x40000000 (guess: sun4c system-enable leftover).

#### Notes for the CPU test suite
- **Without an MXCC** (MB = 1) none of this runs. The only thing to assert is that MCNTL
  bit 11 reads 1. Also note: for module type 0x42 the banner calls 0x19720 without checking MB
  (0x1ef8c). A core that reports MCNTL.ver 8..15 must then tolerate ASI 2 word accesses at
  0x01000008 / 0x01100008 / 0x01c00a04.
- **If an MXCC is ever modelled:**
  - Register, Tag RAM and Data RAM tests lift directly. They need only ASI 2 and the serial port;
    no RAM beyond the stack, no interrupts. Pass/fail is `%g3` plus the serial text.
  - Block Zero/Copy and Cacheable Read/Write need:
    - RAM at pa 0 (they overwrite 32–64 bytes at pa 0, 0x20, 0x40, …, 0x80000, 0x80020, so keep
      the code and stack elsewhere);
    - the EMC (MER, ECC diag register, EFSR/EFAR with exact values);
    - the sun4m interrupt controller (masks, ITR, edge-latched HARDINT.15 cleared by
      clear-pending);
    - the level-15 handler 0x5574 with the `%g5`/`%g7` protocol.
- **Hard parts:**
  - ECC injection (EMC DMODE = 01 check-bit substitution; the check bits of 0xa5a5…a5 are 0x00,
    and syndrome 0x85 means data bit 63);
  - E$ byte parity emulation;
  - exact MXCC error-register CCOP/ERR values (0x06ac00c0, 0x0e607fc0);
  - E$ state rules: an owned sub-block supplies the data on a cacheable stream read, a valid
    line gains S, and a cacheable stream write invalidates without updating E$ data;
  - interrupts within about 40 instructions of the stream `stda`;
  - any mismatch hangs POST (retry loops) instead of failing it, so a bare-metal suite needs its
    own timeout.

## 7. Memory, SIMM probing and EMC/SMC ECC controller tests

Execution order in `post_main` (0x163c0), cross-checked against the Field Service Manual listing
("EMC/SMC Control Regs Tests", "ECC Multiple UE/CE/CE, UE Test", ... "Memory Address Pattern Test"):
0x16464 SIMM probe -> (CPU/MMU/cache/MXCC tests) -> 0x16754 Control Regs -> 0x16770 slot-0 DSIMM check ->
0x16784 Multiple UE -> kbd LED 8 -> 0x167a8 Multiple CE -> 0x167bc Multiple CE,UE -> kbd LED 0 -> FPU groups
(0x9f00, 0x9fa4) -> 0x16820 slot-0 DSIMM check -> 0x16864 Memory Address Pattern Test.
Control Regs and ECC failures go to `post_fail_main_logic_board`; a missing slot-0 DSIMM and address-test
failures go to `post_fail_no_dsimm` (0x16d54).

### Shared facts (EMC/SMC, ECC injection, level-15 path, RAM use)

- **EMC/SMC registers** (pa 0xf_0000_00xx, ASI 0x2f, 32-bit): +0 enable `IMPL[31:28] VER[27:24] DCI[11] A[10]
  MRR[9:2] EI[1] EE[0]` (IMPL 1 = SS10 EMC, 2 = SS20 SMC; MRR = per-logical-slot refresh enable); +4 memory delay
  (RRI[9:0] default 0x20); +8 EFSR `ME[16] SYND[15:8] DW[7:4] UE[3] TO[2] CE[0]` (any write clears and unfreezes);
  +0xc VCR `VCONFIG[15:8]` (2 bits per logical slot 4..7: 00 DRAM, 01 2 MB, 10 4 MB, 11 8/16 MB frame buffer);
  +0x10 EFAR0 `MID[31:28] S[27] rsvd[26:22] VA19:12[21:14] MBL[13] LOCK[12] C[11] SIZ[10:8] TYPE[7:4] PA35:32`;
  +0x14 EFAR1 = PA[31:0]; +0x18 diag `DMODE[11:10] CB32..CBX[7:0]` (sun4m arch spec 5.5, App. A.II.4).
- **Default enable value** `emc_enable_default_value` 0x188f0: reads IMPL from enable[31:28]: 2 -> 0x200003fc,
  else 0x100003fc (MRR=0xff, EE=EI=0). This value is written back after every ECC test.
- **How errors are injected**: diag <- 0x400 (DMODE=01 "generate": CB<7:0>=0x00 are written as the check bits),
  then full-doubleword `stda` via ASI 0x20 writes data whose correct check bits are not 0; diag <- 0. A CE comes from
  data one bit away from a codeword with CB=0 (e.g. 0x80000000_00000000) and is triggered by a `ldda`. A UE is
  triggered by a *partial* write (`stha`/`stba`): the EMC does a read-modify-write and reports UE on the partial
  write. A load that hits a UE would give a synchronous bus error, which the tests avoid.
- **Interrupt**: MEM_ERR = SIPR/ITMR bit 28 (M), a level-15 broadcast. Each test unmasks with
  SITM-clear pa 0xf_f141_0008 <- 0xf87fffff (all sources incl. MA/M) and masks again with SITM-set 0xf_f141_000c <-
  0xf87fffff. The UE test also sets ITR 0xf_f141_0010 <- MID&3. Expected trap: `%g5 = 0x1f` (interrupt level 15),
  `%g7 = 0x96`. The vector at 0x1f0 jumps to the level-15 handler **0x5574** (`L_00005574`). It checks tt against
  %g5 (then %g6, else `trap_unexpected_async`) and clears %g5. For %g7 other than 0x94/0x97/0x98/0x99 it clears
  MCNTL bits 0xc100 (non-Ross), clears enable.EE, copies **EFAR0 -> [0x600010], EFAR1 -> [0x600014],
  EFSR -> [0x600008]** (ASI 0x20), writes EFSR <- 0 and reads it back. It then writes 0x80008000 to the
  clear-pending register of all 4 CPUs (0xf_f140_0004 + n*0x1000), checks that its own pending & 0x80008000 == 0
  (else L_6178), writes SITM-clear <- 0xf87fffff and returns (`jmp %l1; rett %l2`). Only one level-15 interrupt is
  allowed per injection. Because the second error must already be in EFSR.ME when the handler reads EFSR, the
  model must make EFSR reads wait until buffered writes have finished (as the spec says).
- **Waiting**: the tests spin at most 0x100 iterations for %g5 == 0 and never report "No trap taken". A missing
  interrupt shows up only as a mismatch in the RAM copy at 0x600008. The "No trap taken" printer at 0x9058 is dead.
- **RAM used**: ECC scratch lines 0x5032c0..0x5032e8, 0x503b20..0x503b48, 0x503300..0x5034e8 (each first checked by
  `mem_quick_check`); handler save area 0x600000..0x600017 (+0/+4 are used by other %g7 modes for SFSR/SFAR, AFSR/AFAR,
  M-to-S AFSR/AFAR); Address test 0xfc0000..0xfdffff. `%sp` is set to physical 0x1fba0 at 0x6a64 (the window
  overflow handler 0x4838 spills with `stda ... ASI 0x20`). %sp/%fp are also reused as scratch: 0x6ae4 puts the
  keyboard id in %sp; the ECC tests use their %fp (= post_main's %sp) as the 0/8 line offset and leave it 0; the
  memory-test error paths carry the xor value in %sp. So the POST effectively depends on never spilling a window (guess).

### Memory configuration probe (no name string)
- Entry: `0x125c0` `mem_probe_simm_config`, called from post_main 0x16464 (result %g2 saved in %i5) and from the
  POST entry code at 0x473c. No banner and no failure path.
- Builds %g2 = SIMM map, 4 bits per 64 MB logical slot (nibble n = slot n): DSIMM codes 6/4/2/0 from
  `dsimm_size_slot`, VSIMM codes 0xd/0xb/0xa from `vsimm_probe_slot`.
- **Algorithm**: pass 1 (k=0..3, 0x125dc): VCR <- 0x100<<2k. If `vsimm_id_byte_check(k*64MB)` (0x127e4: lduba must
  be 0xf1/0xf2/0xf3/0xfd; address 0 always returns 0) returns 0, then nibble(4+n) = `vsimm_probe_slot(k*64MB)` and
  n++. The ID read at 0x125e4 uses pa k*64MB rather than the VSIMM control space. That looks like a ROM bug (guess).
  Pass 2 (slot 0..7, 0x12630): skip if nibble&0xb != 0. For slots 4..7: VCR <- 0x100<<2k, and a VSIMM ID byte at
  0x9000_0000+(slot-4)*64MB skips the slot (VCR <- 0 in the delay slot 0x1267c). Otherwise
  nibble = `dsimm_size_slot(slot*64MB)`. The probe ends with EFSR <- 0 (0x126a8).
- `vsimm_probe_slot` 0x123c0 (off = k*64MB): VCR <- 0xff00; stba 0x5a to pa 0x9000_0000+off, which must read back
  (else 0). Then 0x1111/0x2222/0x3333 at 0xf000_0000|off +0/+0x400000/+0x800000. No aliasing -> 0xd if +0 is intact,
  else 0xb. With aliasing: VCR <- 0xaa00, write 0x4444 at +0x1000, read +0 = 0x3333 -> 0xb. Otherwise VCR <- 0x5500
  and +0 = 0x4444 -> 0xa, else 0.
- `dsimm_size_slot` 0x1251c: VCR <- 0; 0x5555 @ base|0x3fffff8, 0x6666 @ base|0xfffff8, 0x7777 @ base|0x3ffff8.
  Read-back order 64M, 16M, 4M gives 6 / 4 / 2, else 0.
- **Touches**: VCR 0xf_0000_000c (w), EFSR (w 0), pa 0x0_xxxx_xxxx bytes/words via ASI 0x20 at 64 MB slot bases,
  0x9x00_0000 (VSIMM control), 0xfx00_0000 (frame-buffer alias with a[28:26] = slot).
- **Expected**: slot 0 must yield code 4 or 6 (see next entry). Sizes: tables 0x12848 (DSIMM: 0,1M,4M,8M,16M,32M,64M,128M
  by code) and 0x12888 (VSIMM: code&7 -> 2M/4M/8M/16M at 2..5). Slot base tables 0x12828 (slot*64MB) and 0x12868
  (0xf0000000..0xfc000000 for slots 4..7).
- **Fails with**: nothing (pure probe).

### EMC/SMC Control Regs  Tests
- Entry: `0x93e0` `post_emc_smc_control_regs_tests`, called from post_main 0x16754 (fail -> Main Logic Board).
- Checks the reset/idle values and read/write masks of the EMC/SMC registers.
- **Algorithm**: IMPL = enable[31:28] (0x9430); 2 = SMC, else EMC (0x9440). Enable: read == IMPL<<28|0x3fc (0x945c),
  write it and read back (0x946c), write 0 -> read == IMPL<<28 (0x9480), restore (0x9494). Delay (+4): read == 0x20
  (0x94ac); write 0xffdf (SMC) or 0x01ffffdf (EMC) and read back (0x94c4); restore 0x20 (0x94dc). VCR (+0xc): read 0,
  write/read 0xff00, write/read 0 (0x94f4..0x9528). EFSR (+8) read == 0 (0x9548). Diag (+0x18): read 0, write/read
  0x4ff, write/read 0 (0x956c..0x959c). EFAR0/1 are not tested.
- **Touches**: pa 0xf_0000_0000/04/08/0c/18, ASI 0x2f, 32-bit lda/sta.
- **Expected**: the enable register must already be IMPL<<28|0x3fc. No POST code writes it before this test, so it is
  the reset value (MRR=0xff) (guess). The delay register must be 0x20: the MXCC group (0x197ac) writes 0x2895 via
  `emc_write_delay_reg` 0x18780 and restores 0x20 at 0x198a4. VER must be 0 and all RW bits must clear.
- **Fails with**: 0x95cc: 0x16088 "<<< CPU_%1 on MBus Slot_%2 >>>", 0x129b7 "ERROR : Address = %1, exp = %2, obs =
  %3, xor = %4" (%1 = register offset 0/4/0xc/8/0x18), 0x1294e "U-NUMBER : " + 0x18694 "U0201 (EMC_SMC   ) ", %g3=1.

### Slot-0 DSIMM check (no name string)
- Entry: `0x1274c` `find_first_dsimm`, called from post_main 0x16770 and 0x16820 with %g2 = probe result (%i5) and
  %o4 = 0. %o3 (slot count) is not set by post_main, so it only matters when slot 0 is empty.
- **Algorithm**: loop over nibbles from shift %o4: the first nibble with bit 2 set gives o0 = [0x12828+4*slot],
  o1 = [0x12848+4*code], o2 = shift. If none is found within %o3 nibbles, o0 = 0xff and 0x1317c "***WARNING : No
  DSIMM Detected!" is printed (start shift 0). 0x127d4: a nonzero base also becomes 0xff. Result: 0 only when
  logical slot 0 holds a DSIMM coded 4 (16 MB) or 6 (64 MB). A code-2 (4 MB) SIMM does not count.
- **Fails with**: post_main `cmp %o0,0xff` -> `post_fail_no_dsimm` with %i0=1 -> 0x13102 "STATUS : Power-On SelfTest
  FAILED ... SIMM <J0201> Not Installed".

### ECC Multiple UE Test
- Entry: `0x87e0` `post_ecc_multiple_ue_test`, called from post_main 0x16784 (fail -> Main Logic Board).
- Two uncorrectable errors on partial writes must set UE+ME, freeze the first error's address, and raise exactly
  one level-15 interrupt.
- **Algorithm**: MID -> %l0 = MID&3, %i5 = MID<<28. %i4 = MCNTL>>24 (0x8820). ITR <- MID&3 (0x8830).
  `mem_quick_check(0x5032c0,0x40)` (0x8848): on failure print "<<BAD DSIMM IN SLOT 0, RUN MEMORY TEST, SKIPPED>>"
  and return with %g3=0 (counts as a pass). SITM clear (0x8884). Loop `ecc_ue_loop` 0x8894 for %fp = 0, 8:
  EFSR == 0 (0x88b0); diag <- 0x400 (0x88c8); stda 0xd5a5a5a5_a5a5a5a5 @0x5032c0+fp (0x88e8) and
  0xa5a5a5a5_55a5a5a6 @0x5032e0+fp (0x8908); diag <- 0, EFSR <- 0; enable <- 1|default (0x892c); %g5=0x1f,
  %g7=0x96; stha %g0 @0x5032c0+fp (0x8950) and stba %g0 @0x5032e0+fp (0x8954); wait (0x895c); enable <- default
  (0x8988); compare the handler copies. After the loop: SITM set (0x8a60), EFSR <- 0.
- **Touches**: EMC +0/+8/+0x18 (w), +8 (r); RAM 0x5032c0..0x5032e7 (stda, stha, stba) and 0x600008/10/14 (lda),
  all via ASI 0x20; ITR/SITM (ASI 0x2f); MCNTL (ASI 4 va 0, read).
- **Expected**: [0x600008] = 0x1d008 (ME | SYND 0xd0 | UE, DW 0) (0x89a4). [0x600010] = MID<<28|0x0fffc100
  (S=1, rsvd=0x1f, VA19:12=0xff, SIZ=1 halfword, TYPE=0 write). A Ross module (MCNTL>>24 == 0x17) expects 0x0fc0c100
  (VA=0x03, which equals pa bits 19:12) (0x89ec). [0x600014] = 0x5032c0+fp (0x8a14). Live EFSR = 0 (0x8a2c).
- **Fails with**: `ecc_test_fail` 0x8f70: banner, 0x129b7 "ERROR : Address = %1, exp = %2, obs = %3, xor = %4" (%1 =
  8/0x10/0x14 = which register), "U-NUMBER : " + "U0201 (EMC_SMC   ) ", %g3=1. The code at 0x8fe4/0x9058/0x90dc/
  0x91bc holds unreferenced variants (0x12c37 "No trap taken, expected %1", PIN "P18_U7", "U1002 (SEC_ASIC)" +
  "P136_memctl_irq*", "Suspect Viking Module").

### ECC Multiple CE Test
- Entry: `0x8a78` `post_ecc_multiple_ce_test`, called from post_main 0x167a8 (fail -> Main Logic Board).
- Two correctable errors on reads must set CE+ME and raise one level-15 interrupt with EI=1.
- **Algorithm**: same frame as the UE test. There is no ITR write and no MCNTL read; the Ross check uses
  `get_module_type`. `mem_quick_check(0x503b20,0x40)`. Loop `ecc_ce_loop` 0x8b14 for fp = 0, 8: EFSR == 0;
  diag <- 0x400; stda 0x80000000_00000000 @0x503b20+fp (0x8b60) and 0xffffffff_fffffffe @0x503b40+fp (0x8b78);
  diag <- 0, EFSR <- 0; enable <- 3|default (EE|EI, 0x8b9c); %g5=0x1f, %g7=0x96; ldda @0x503b20+fp (0x8bc0) and
  @0x503b40+fp (0x8bc4); wait; enable <- default.
- **Touches**: as in the UE test (addresses 0x503b20..0x503b47; ldda instead of partial stores).
- **Expected**: [0x600008] = 0x18501 (ME | SYND 0x85 | CE) (0x8c14). EFAR0 is compared only on Ross, against
  MID<<28|0x0fc0c310 (SIZ=3 doubleword, TYPE=1 read). On other modules the value MID<<28|0x0fffc310 is built but the
  compare is skipped (0x8c54). [0x600014] = 0x503b20+fp (0x8c94). Live EFSR = 0. The corrected load data is not checked.
- **Fails with**: `ecc_test_fail` 0x8f70 (as above).

### ECC Multiple CE, UE Test
- Entry: `0x8cf8` `post_ecc_multiple_ce_ue_test`, called from post_main 0x167bc (fail -> Main Logic Board).
- A CE with EI=0 is captured without an interrupt. A later UE must take priority in the EFARs and raise the
  interrupt, with CE, UE and ME all set.
- **Algorithm**: `mem_quick_check(0x503300,0x200)`. Loop `ecc_ceue_loop` 0x8d88 for fp = 0, 8: EFSR == 0;
  diag <- 0x400; stda 0xffffffff_ffbfffff @0x503300+fp (0x8dd8) and 0xa5a5a555_a5a5a5a5 @0x5034e0+fp (0x8df8);
  diag <- 0, EFSR <- 0; enable <- 1|default (EE only, 0x8e1c); %g5=0x1f, %g7=0x96; ldda @0x503300+fp (CE, 0x8e40);
  stba %g0 @0x5034e0+fp (UE, 0x8e44); wait; enable <- default.
- **Expected**: [0x600008] = 0x1a509 (ME | SYND 0xa5 | UE | CE) (0x8e94). [0x600010] = MID<<28|0x0fffc000 (SIZ=0 byte,
  TYPE=0 write; Ross 0x0fc0c000), checked on all modules (0x8ee4). [0x600014] = 0x5034e0+fp (0x8f0c). Live EFSR = 0.
- **Fails with**: `ecc_test_fail` 0x8f70 (as above).

### Memory Address Pattern Test
- Entry: `0x176c0` `post_memory_address_pattern_test` (engine). post_main prints the name (0x16840) and calls it at
  0x16864 with o0=0xfc0000, o1=0x20000, o2=8 (stride), o3=0x20 (unused), o4=-1 (mask), o5=4 (SIMM code for U-number).
- Address-in-address test of the last 128 KB below 16 MB, with doubleword accesses.
- **Algorithm**: up (0x176f0): `stda (a, a+4) -> [a]` for a = start..end-8. Up `addr_pat_up_loop` 0x17720: ldda,
  word0 == a&mask and word1 == (a+4)&mask, then stda (~a, ~(a+4)) (0x1775c). Down `addr_pat_down_loop` 0x17784
  (from end-8 to start): ldda == (~a, ~(a+4))&mask. Returns %g3.
- **Touches**: RAM pa 0x00fc0000..0x00fdffff, ASI 0x20 stda/ldda, 16384 doublewords.
- **Expected**: patterns as above. Any mismatch fails.
- **Fails with**: 0x17860 (word 0) / 0x17944 (word 1). Only the first failure prints (0x17864). a&0xf selects
  0x12aa6 "exp[127:96]" / 0x12a4f "exp[63:32]" / 0x12bae "exp[95:64]" / 0x12b57 "exp[31:00]" ("ERROR : Address = %1,
  exp[..] = %2, obs[..] = %3, xor[..] = %4"). Then `simm_print_unumber` prints the DSIMM chip ("U-NUMBER : U0210" ...),
  and %g3 = %i0 = 0xff. post_main clears %i0 and goes to `post_fail_no_dsimm` -> 0x13411 "STATUS : Power-On SelfTest
  FAILED ... Replace/install DSIMM card on <J0201>".

### EMC/SMC Memory Timeout Tests
- Entry: `0xf9a0` `post_emc_smc_memory_timeout_tests`. **Not called (dead code)**: no call and no pointer anywhere.
- A read (and, without MXCC, a write) to non-existent memory must fault synchronously with MBus timeout status.
- **Algorithm**: SITM clear. %g5=9 (data_access_exception), lda pa 0x0_2000_0000 (0xf9ec), and %g5 must be cleared.
  SFSR (ASI 4 va 0x300) & ~0x300 == 0x836 (TO, AT=1 load supervisor data, FT=5 access bus error, FAV). SFAR (0x400)
  == 0x20000000. SFSR read again == 0 (clear-on-read). If MCNTL == 0x800 exactly (0xfa5c): %g5=9, sta %g0 to pa
  0x20001020, SFSR&~0x300 == 0x8b6 (AT=5), then 0. Finally SITM set.
- **Fails with**: L_fec0 (exp/obs + "U0201 (EMC_SMC)" + 0x13803 "ERROR : Suspect MSI Module"); L_ffc8 0x12c37
  "ERROR : No trap taken, expected %1" + "Suspect MSI Module". These are outside this range and shared with the MBus
  to EBus Timeout test.

### Unreferenced MATS engine (no name string; probably the removed "Memory MATS Pattern Tests")
- Entry: `0x16de0` `mem_mats_dw_engine`, unreached (the listing shows `.word`). It is code: save/ret/restore and
  consistent branches into the shared error paths 0x17860/0x17944.
- **Algorithm**: args %i0 start, %i1 size, %i2 stride, %i4 mask; ASI 0x20 doubleword. Up: stda 0:0 (0x16e0c). Up:
  ldda, both words &mask == 0, then stda ffffffff:ffffffff (0x16e40..0x16e68). Up: ldda == ones&mask, stda 0:0,
  ldda == 0 (0x16ea4..0x16efc). This is MATS++ with the last element ascending.

### Generic march engine used by the "NTA Pattern" tests (no memory caller)
- Entry: `0x16f2c` `nta_pattern_engine_asi`, called by 0xe0a0 (IOMMU CAM NTA: 0xe0000100, 0x40, 4, ASI 0x2f,
  mask 0x7ffff000), 0xe108 (IOMMU TLB NTA: 0xe0000200, 0x40, 4, 0x2f, mask -0x7a), 0x11390 (0, 0x2000, 0x20, ASI 0xc,
  mask 0xffffff80), 0x115cc (0, %l7, 0x20/0x40, ASI 0xe, mask -2) and 0x218c4 (0, 0x400, 8, ASI 6, -1).
  "Memory NTA Pattern Test" itself has no code.
- **Algorithm**: word accesses through `lda_by_asi`/`sta_by_asi`, all reads compared under mask %i4.
  Elements (up = ascending from start, down = descending from start+size-stride): 0x16f48 up w0; 0x16f7c up r0,w1;
  0x16fdc down r1; 0x1702c up r1,w0; 0x1708c down r0; 0x170d8 down r0,wA; 0x1713c up rA; 0x17190 down rA,w5;
  0x171fc up r5; 0x17250 up r5,wA,w5; 0x172cc down r5; 0x17320 down r5,wA,w5,wA; 0x173ac up rA; 0x17400 up w1;
  0x17438 up r1,w0,w1; 0x174a8 down r1; 0x174f8 down r1,w0,w1,w0; 0x17578 up r0.
  (1=0xffffffff, A=0xaaaaaaaa, 5=0x55555555.)
- **Fails with**: `mem_test_fail_word` 0x177ec: banner, 0x129b7 Address/exp/obs/xor, optional `simm_print_unumber`
  if %i5 != 0, return o0=0xff. It does not set %g3.

### Name strings in 0x14962-0x14bc2 and 0x15822-0x15882
| String (addr) | Code? |
|---|---|
| ECC Walking 1 (CE) Tests (0x14962), ECC Walking 0 (CE) Tests (0x14982) | no |
| ECC Double Bit (UE) (0x149a2), Triple Bit (UE) (0x149c2), Quad Bit (UE) (0x149e2) | no |
| ECC Wrapped CR (UE) (0x14a02), CRI (UE) (0x14a22), CR (CE) (0x14a42), CRI (CE) (0x14a62) | no |
| EMC/SMC MBus Timeout Tests (0x14a82) | no |
| EMC/SMC Memory Timeout Tests (0x14aa2) | yes, 0xf9a0 (dead) |
| EMC/SMC Control Regs  Tests (0x14ac2) | yes, 0x93e0 |
| ECC Multiple UE (0x14ae2) / CE (0x14b02) / CE, UE (0x14b22) Test | yes, 0x87e0 / 0x8a78 / 0x8cf8 |
| EMC/SMC Data Path Tests (0x14b42), "... 4th/3rd/2nd/1st Doubleword of Burst" (0x14b62..0x14bc2) | no (0x175d0 may be a remnant, guess) |
| Memory MATS Pattern Tests (0x15822) | no reference; engine 0x16de0 is unreached |
| Memory NTA Pattern Test (0x15842) | no reference; engine 0x16f2c is used only by other groups |
| Memory Address Pattern Test (0x15862) | yes, printed by post_main 0x16840, engine 0x176c0 |
| Memory Checker Pattern Test (0x15882) | no |
(Checked by scanning the whole ROM for sethi/or pairs that form each address.)

#### Helpers
- `mem_quick_check` 0x187d0 (o0 addr, o1 bytes): per word, write 0xaaaaaaaa and read back, then a second pass with
  0x55555555 (ASI 0x20). Returns 0 = ok, 1 = bad. Used by ~38 tests (0x300000, 0x400000, 0x50000, 0x600000, 0x0/0x40000,
  0xf00000/0x1000, ECC lines). Callers print "<<BAD DSIMM IN SLOT 0, RUN MEMORY TEST, SKIPPED>>".
- `emc_enable_default_value` 0x188f0: returns 0x200003fc (IMPL 2) or 0x100003fc.
- `emc_write_delay_reg` 0x18780: EMC +4 <- %o0.
- `lda_by_asi` 0x18a98 (o0 addr, o2 asi -> o1) and `sta_by_asi` 0x18e74 (o0 value, o1 addr, o2 asi). There is no
  computed jump. Each is a linear chain of 49 five-instruction cases (`cmp %i2,N; bne next; nop; ba done; lda/sta
  [...] N` in the delay slot; the last case, 0x30, falls through) covering ASI 0x00..0x30 at 20-byte spacing (verified
  for every case). An ASI above 0x30 does nothing: a load returns the stale %o1. The listing already shows both as code.
- `simm_print_unumber` 0x19250 (o0 addr, o1 exp, o2 obs, o3 SIMM code): finds the highest differing nibble 7..0.
  A byte table picked by addr&0xc and code (0xb VSIMM, 6 64 MB, other 16 MB; tables at 0x1870c..0x1876b) gives an index,
  and it prints "U-NUMBER : " + the string at 0x17f00+20*idx. The 64 MB table has 0x40 (U0404) at 0x1873e where the
  16 MB table has U0116 (probably a table typo).
- `vsimm_probe_slot` 0x123c0, `dsimm_size_slot` 0x1251c, `vsimm_id_byte_check` 0x127e4: see the probe entry.
- `find_first_vsimm` 0x126b4 (dead): like `find_first_dsimm` but looks for VSIMM codes (mask 0xb, bit 3). Returns the
  frame-buffer base (0x12868) and size (0x12888); otherwise prints 0x13226 "<< NO VSIMM/MDI DETECTED, TEST SKIPPED >>".
- `emc_dump_regs` 0x9240 (dead): prints "---> mem_fsr/mem_far0/mem_far1/mem_enable_reg/mem_diag_reg= %1"
  (strings 0x9364..0x93d0).
- `mem_fill_copy_fragment` 0x175d0 (dead): fills with ones, then 0x00876543; copies with the destination fixed at
  0x600000 (it increments the wrong register) and compares with 0x00876543; ends with VCR <- 0. Looks unfinished.
- `sys_timer_heartbeat_start` 0x193f8 (dead): 0xf_f131_0000 <- 0x30000000, %g2=8, SITM clear <- 0x80080000 (MA, T).
- Error tails: `ecc_test_fail` 0x8f70, `emc_ctlregs_fail` 0x95cc, `mem_test_fail_word` 0x177ec,
  `mem_test_fail_dw_word0/1` 0x17860/0x17944 (these pass xor via %sp and clobber %fp = the caller's %sp).
- Data in range owned by the MMU group: 0x17a40..0x17adf (10 x 16-byte entries, "MMU TLB Hit, Index 1-3", used by
  0xf278) and 0x17d68..0x17da7 (4 x 16-byte TLB bit patterns: zero / ones / 0x5555.. / 0xaaaa.., used by
  0xf1c0.. and post_main 0x165c8..). 0x17a1c/0x17a2e hold "g4 = %1 i6 = %2" (unreferenced).

#### Notes for the CPU test suite
- **Easy to lift**: the Memory Address Pattern test (0x176c0), `mem_quick_check` and the MATS/NTA engines. They need
  only RAM through ASI 0x20 (Address test: 16 MB minimum; it tests 0xfc0000..0xfdffff) and serial output through
  `post_printf`. Pass means %g3 == 0 (the NTA engine returns o0 != 0xff). The NTA engine with its `lda/sta_by_asi`
  helpers is a good generic ASI tester for cache tag/data (ASI 0xc/0xe), TLB diagnostic (ASI 6) and IOMMU (0x2f)
  arrays.
- **Needs an EMC/SMC model**: Control Regs (reset values: enable IMPL<<28|0x3fc with IMPL=2 for
  SS20, delay 0x20, VCR 0, EFSR 0, diag 0; RW masks 0x3fc/0xffdf/0xff00/0x4ff) and the three ECC tests. The ECC tests
  also need: diag DMODE=01 check-bit substitution with a real SEC/S4ED code, so that the patterns give the syndromes
  0xd0/0x85/0xa5; UE on partial-write RMW and CE on reads; EFSR/EFAR freeze with ME; MEM_ERR as SIPR bit 28 ->
  level-15 broadcast through ITMR; per-CPU clear-pending bit 15; EFSR reads that wait for the write buffer; and the ROM
  level-15 handler (0x5574) with the %g5/%g7 protocol and the RAM copy at 0x600008..0x600017. An easy intermediate
  target is to make only the Control Regs test pass: a register file with those reset values and masks.
- **SIMM probe**: to reach "passed", logical slot 0 must size as 16 or 64 MB (`dsimm_size_slot(0)` returns 4 or 6).
  VSIMM probing writes 0x5a/0x1111.. into whatever pa 0x9x00_0000 and 0xfx00_0000 alias to, so a core that aliases
  those addresses onto low RAM will have bytes at pa 0x0/0x1000/0x400000/0x800000 (with 256 MB wrap) overwritten
  before the POST data is set up. That is harmless but worth knowing.
- **Hard parts**: exact EFAR0 contents (Viking VA19:12 = 0xff, S=1, rsvd bits 26:22 read as 1), the single-interrupt
  timing for two back-to-back errors, and the POST's habit of using %sp/%fp as scratch, which makes any window spill
  during these tests fatal.
- **Open question**: pass 1 of the probe reads the "VSIMM ID" byte from pa k*64MB instead of 0x9x00_0000 (bug or
  intended?).

## 8. System tests: interrupt controller, counter/timers, MSI + IOMMU, TOD/NVRAM, MBus timeouts

### Who runs these tests

- Every CPU runs all of `post_main` 0x163c0.
- The master (MID 8) goes first. At the end of its run (0x16b68..0x16be4), for each MID 9, 10
  and 11 that `mpcntl(5,mid)` reports as present, the master:
  1. clears PSR.ET;
  2. calls `mp_dispatch(mid, mp_run_with_target 0x1eb98, post_main, mid)`;
  3. waits in `mp_wait_idle`.
- `mp_dispatch` also rewrites the Arbiter Enable register at pa 0xf_e000_1008: it clears bits
  [3:0] and sets bit (mid&3).
- On the slave, `mp_run_with_target` writes ITR = mid&3 (0xf_f141_0010), then calls `post_main`.
  A slave returns at 0x16b78 (MID > 8).
- So the PROC1/PROC2/PROC3 tests are run by that slave on its own register block. Every
  per-CPU test indexes its registers with N = `get_mid()&3`, and the name string it prints is
  chosen by N. The master never tests another CPU's interrupt or timer registers.
- The system-level tests (System Interrupt, System Counter, MSI, IOMMU, TOD) are repeated by
  each CPU in turn.
- Only two pieces of code touch all four CPU blocks:
  - `mp_probe_slaves` 0x1f598 (master, before post_main) writes 0 to the four limit registers
    0xf_f130_N000.
  - The level-15 handler's error paths (L_574c) write 0x80008000 to the four clear-pending
    registers 0xf_f140_N004.
- No POST code in this group sends a soft interrupt to another CPU. Soft interrupts are only
  tested CPU to itself, so inter-processor interrupts (IPIs) are not covered by POST.

**Interrupt handler behaviour these tests depend on** (per-level vectors at tt 0x11..0x1f;
handlers 0x49c0..0x5574, not in this group's range):
- Each handler compares tt with %g5, then with %g6, clears whichever matched, and otherwise goes
  to `trap_unexpected_async` 0x5d08.
- It then writes `0x10000<<level` to its own clear-pending register 0xf_f140_N004, does a dummy
  read of pending, and returns with `jmp %l1; rett %l2` (re-executes the interrupted
  instruction).
- The handlers for levels 4, 6, 10, 14 and 15 are selected by %g7:
  - `0x99`: clear the soft bit only. Level 15 clears 0x80008000.
  - `0x69`: timer check. Levels 10 and 14 (0x51a0, 0x54e4) do the following:
    1. set all ITMR mask bits (0xf87fffff to 0xf_f141_000c);
    2. require bit 31 set in the counter (+4), and bit 31 set in the limit (+0);
    3. read the limit again and require bit 31 clear (the limit read clears L);
    4. write limit = 0 (free-run).

    A failure prints "Processor Counter Limit Bit" (0x13500) or "System Counter Limit Bit"
    (0x13554), then U1002, and sets %g3=1.
  - `0x98` (level 15, 0x5704):
    1. copy the M-to-S AFSR/AFAR (0xf_e000_1000/1004) to RAM 0x600000/0x600004;
    2. write the AFSR to clear it;
    3. clear 0x80008000 on all four CPUs;
    4. require that its own pending bits 31 and 15 are clear;
    5. clear the whole mask (unmask all).
- Level 10 with any other %g7 value is a heartbeat: it prints the spinner "\b|", "\b/",
  "\b-", "\b\\" (0x12942..0x1294b) and sets %g5=0x1a. It is only armed by the dead
  0x193f8, so it never runs.

Tests that fail in post_main branch to `post_fail_main_logic_board`. Failure U-numbers:
- U1002 (SEC_ASIC) = 0x17f00+0x7bc: interrupt controller and timers.
- U0101 (MSI_ASIC) = +0x640: MSI and IOMMU.
- U1004 (TOD_NVRAM) = +0x7d0: TOD/NVRAM.

Keyboard LEDs (`kbd_send(0x0e)`, mask) are set to 0x00 before System Interrupt, 0x08 before
Soft ON, 0x00 before System Counter, 0x08 before MSI, and 0x00 after the IOMMU tests.

### NVRAM access test (no name string printed; "NVRAM Access Test" 0x15602 is unreferenced, probably this test (guess))
- Entry: `0x10ccc`. Called only from `mp_probe_slaves` 0x1f5c4, on the master, before
  `post_main`; the result is ignored. Also called from the dead wrapper 0x10c38.
- Checks that one NVRAM byte can be written and read back.
- **Algorithm**:
  1. 0x10cf8..0x10d68: write 0xaa, 0x55, 0xff and 0x00 to pa 0xf_f120_0003, reading each back.
  2. 0x10d8c: read the byte, invert it, write it, and read it back.
- **Touches**: pa 0xf_f120_0003 (NVRAM byte 3), ASI 0x2f, byte r/w.
- **Expected**: each readback equals the value written.
- **Fails with**: the four patterns fail to L_10ff4, which prints 0x129b7 "ERROR : Address = %1,
  exp = %2, obs = %3, xor = %4". The inverted value fails to L_10f80, which prints 0x13b39
  "ERROR : NVRAM (%1) Battery Failure, exp = %2, obs = %3, xor = %4". Both print U1004
  (TOD_NVRAM) and set %g3=1.

### System Interrupt Regs Tests
- Entry: `0xd300`, called from post_main `0x16894`. The dead group wrapper 0xd2a0 also calls it.
- Read/write check of the Interrupt Target Mask register (ITMR) through its set and clear
  pseudo-registers.
- **Algorithm**:
  1. 0xd340: write 0xf87fffff to mask-SET (0xf_f141_000c). 0xd34c: read the ITMR (0xf_f141_0004);
     it must equal 0xf87fffff.
  2. 0xd378: write 0xf87fffff to mask-CLEAR (0xf_f141_0008). 0xd384: read the ITMR; it must be 0.
- **Touches**: 0xf_f141_0004 (r), 0x..08 and 0x..0c (w), ASI 0x2f, 32-bit.
- **Expected**:
  - 0xf87fffff is the sum of MA (31), ME (30), I (29), M (28), V (27) and bits 22..0.
  - Bits 26..23 are never written by POST. Since the test compares the whole word, they must
    read 0.
  - The test leaves the mask all-clear, so every source is enabled.
- **Fails with**: L_d858. It prints 0x16088 "<<< CPU_%1 on MBus Slot_%2 >>>" (%1 = MID&3,
  %2 = (MID&3)>>1), then 0x129b7 "ERROR : Address = %1, exp = %2, obs = %3, xor = %4", then
  U1002 (SEC_ASIC), and sets %g3=1.

### PROC0 Interrupt Regs Tests (also "PROC1/PROC2/PROC3 Interrupt Regs Tests")
- Entry: `0xd3ac`, called from post_main `0x168a8`.
- Name strings: PROC0 0x154e2, PROC1 0x15702, PROC2 0x15722, PROC3 0x15742, selected by
  N = MID&3.
- Checks this CPU's pending, set-soft and clear-pending registers, with traps off.
- **Algorithm**:
  1. 0xd3c8: write N to the ITR (0xf_f141_0010).
  2. 0xd494: set PSR.PIL=15 and clear ET.
  3. 0xd4b8: read pending (0xf_f140_N000); it must be 0.
  4. 0xd4e4: write 0x7ffe0000 to set-soft (+8). 0xd4f0: read pending; it must be 0x7ffe0000.
  5. 0xd518: write 0x7ffe8000 to clear (+4). 0xd524: read pending; it must be 0.
  6. 0xd54c: write 0 to set-soft.
  7. 0xd560: write 0xf87fffff to mask-CLEAR.
  8. 0xd570: write 0 to the ITR.
  9. Restore the PSR.
- **Touches**: 0xf_f140_N000/4/8, 0xf_f141_0008/0010, ASI 0x2f, 32-bit.
- **Expected**:
  - Soft levels 14..1 (bits 30..17) can be set and cleared. Level-15 soft (bit 31) is not
    tested here.
  - The clear value also sets INT<15>.CLR (bit 15).
  - Pending must be 0 at the start. With the mask all-clear and the ITR pointing at this CPU,
    no device may be asserting an interrupt (HARD_INT bits).
- **Fails with**: L_d858, as above (U1002).

### Soft Interrupts OFF Test
- Entry: `0xd594`, called from post_main `0x168bc`.
- Soft interrupts must latch in pending but must not trap while PIL=15.
- **Algorithm**:
  1. 0xd5d0: write N to the ITR. 0xd5dc: write 0 to mask-SET (no effect).
  2. 0xd5fc: write 0x7ffe0000 to clear (+4); pending must be 0.
  3. 0xd628: write 0xffffffff to mask-CLEAR.
  4. 0xd630: read system pending (0xf_f141_0000) AND 0xbfffffff; it must be 0. ME (bit 30) is
     ignored.
  5. 0xd658: set PIL=15; ET is left unchanged (1).
  6. Loop 0xd678, with l1 = 0x40000000 >> k while l1 & 0xfffe0000:
     - write l1 to set-soft (+8); pending must read exactly l1;
     - write l1 to clear (+4); pending must read 0.
  7. Restore the PSR. 0xd700: write 0 to the ITR.
- **Expected**:
  - 14 levels (14 down to 1) are tested.
  - Any trap taken is unexpected (%g5=0), so it goes to `trap_unexpected_async`.
  - The system pending register must show no device interrupt at all (raw sources,
    independent of the mask).
- **Fails with**: L_d858 (U1002).

### Soft Interrupts ON Test
- Entry: `0xd710`, called from post_main `0x168e0`.
- Each soft level 1..15 must deliver a trap with tt 0x10+level.
- **Algorithm**:
  1. 0xd748: write N to the ITR.
  2. 0xd754: set PIL=0 (ET must already be 1).
  3. 0xd77c: pending must be 0.
  4. 0xd7a0: write 0xf87fffff to mask-CLEAR.
  5. Loop 0xd7b4, with l3 = 0x11.. and l1 = 0x20000 << k until l1 == 0:
     - set %g5=l3 and %g7=0x99;
     - 0xd7c8: write l1 to set-soft (+8);
     - poll %g5 up to 0x1000 times (0xd7d0) for the handler to clear it;
     - 0xd7fc: pending must then be 0 (the handler cleared the soft bit).
  6. 0xd838: write 0xf87fffff to mask-SET. Restore the PSR. %g7 is left at 0x99.
- **Expected**: tt 0x11..0x1f, one per level, bits 17..31. This includes level 15 soft (bit 31,
  NMI level); its handler clears 0x80008000.
- **Fails with**:
  - A mismatch goes to L_d858.
  - A timeout goes to L_d8cc, which prints 0x12c05 "ERROR : No interrupt received, expected %1"
    (%1 = tt), then U1002, then PIN-NUMBER 0x16120 "P1_m0_irl<3>", 0x16134 "P2_m0_irl<2>",
    0x16148 "P3_m0_irl<1>" and 0x1615c "P4_m0_irl<0>", and sets %g3=1.

### PROC0 User Timer Test (also "PROC1/PROC2/PROC3 User Timer Test")
- Entry: `0x10214`, called from post_main `0x168f8` with %o4=0xf1300000 and %o1=1. The dead
  wrapper 0x101e0 also calls it.
- Name strings: PROC0 0x15662, PROC1 0x15762, PROC2 0x15782, PROC3 0x157a2.
- Checks this CPU's counter in user-timer (64-bit) mode. The register base is
  B = 0xf_f130_0000 + N·0x1000.
- **Algorithm**:
  1. 0x10304: write 0 to timer config (0xf_f131_0010); it must read 0.
  2. 0x10320: write 0xffffffff; it must read 0xf.
  3. 0x10338: write 1<<N (this CPU's counter becomes a user timer).
  4. 0x10340: write 0 to start/stop (B+0xc); it must read 0. Write 0xffffffff; it must read 1.
     Write 0.
  5. 0x10384: while stopped, `stda` 0/0 to B; `ldda` must return 0/0.
  6. 0x103b4: `stda` 0xffffffff/0xffffffff; `ldda` must return MSW 0x7fffffff and LSW 0xfffffe00.
  7. 0x103e8: write %i1 (=1) to B+0xc (start).
  8. 0x103f8: `stda` 0/0. Then, up to 4 tries (0x10400):
     - `ldda` (l2,l3), 4 nops, `ldda` (l4,l5);
     - pass when l5 > l3 (signed).
  9. 0x10444: `stda` 0x7fffffff/0xffffffff, 4 nops, two `ldda`. MSW bit 31 (L) must be set.
  10. 0x10478: `sta` 0x80000000 to B (32-bit MSW write); the next `ldda` must have MSW bit 31
      clear.
  11. 0x104a0: write 0 to B+0xc (stop). Timer config is left at 1<<N.
- **Expected**:
  - Timer config bits 31:4 read 0, and all four T bits are RW regardless of how many CPUs are
    fitted.
  - Start/stop: only D<0> (RUN).
  - MSW bit 31 (L) is read-only.
  - LSW bits 8:0 read 0.
  - The count advances in LSW bit 9, every 500 ns.
  - L sets on overflow past 0x7FFFFFFF_FFFFFE00, and is cleared by any write.
- **Fails with**:
  - A register mismatch goes to L_10890 (Address/exp/obs/xor, then U1002).
  - Not counting goes to L_10904, 0x13464 "ERROR : Processor User Timer Not Incrementing" (U1002).
  - An L-bit problem goes to L_10944 (Address/exp/obs/xor, then U1002).

### PROC0 Counter/Timer Test (also "PROC1/PROC2/PROC3 Counter/Timer Test")
- Entry: `0x104b0`, called from post_main `0x16910` with %o4=0xf1300000.
- Name strings: PROC0 0x15682, PROC1 0x157c2, PROC2 0x157e2, PROC3 0x15802.
- Checks the per-CPU counter/timer and its level-14 interrupt.
- **Algorithm**:
  1. 0x104c8: write 0xf87fffff to mask-CLEAR. 0x104e0: write N to the ITR.
  2. 0x105bc: write `~(1<<N)&0xff` to timer config (this CPU is a counter, the others become
     user timers).
  3. Limit register (B+0):
     - 0x105d4: write 0x1ff; it must read 0;
     - 0x105f4: write 0xffffffff; it must read 0x7ffffe00.
  4. 0x10614: read the counter (B+4), 3 nops, read it again; the second value must be greater
     (signed).
  5. 0x1064c: write 0x7ffffe00 to the limit (this resets the count to 0x200). 0x10650: the
     counter must be < 0x40000.
  6. 0x10678: write 0x7ffffe00 to the non-resetting limit (B+8). 0x1067c: the counter must be
     greater than the previous read.
  7. 0x10694: set %g5=0x1e and %g7=0x69, then poll up to 0x80000 times for %g5=0 (the level-14
     handler, see above).
  8. 0x106d4: write 0 to timer config. 0x106ec: write 0xf87fffff to mask-SET.
- **Expected**:
  - Limit bits 8:0 and 31 are not writable. A limit write resets the count to 0x200.
  - The level-14 trap (tt 0x1e) must be taken. Inside the handler:
    - L (bit 31) must be set in both the counter and the limit;
    - the first read of the limit clears L.
  - The count has to climb from about 0x200 to 0x7ffffe00, which is about 2.1 s at 500 ns per
    tick. POST bounds the wait with 0x80000 passes through a 6-instruction loop, so it
    assumes at least about 4 µs per pass, i.e. slow uncached boot-PROM instruction fetch
    (about 0.7 µs per instruction; inferred).
- **Fails with**:
  - L_10890 for register mismatches.
  - L_109b8, 0x13499 "ERROR : Processor Counter Timer Not Incrementing".
  - L_10a38, "No interrupt received, expected 0000001e", plus the P1..P4_m0_irl pins.
  - Handler errors print 0x13500 "Processor Counter Limit Bit".
  - All of these print U1002.

### System Counter Test
- Entry: `0x106fc`, called from post_main `0x16934`.
- The same checks on the system counter, with a level-10 interrupt routed through the ITR and
  the mask.
- **Algorithm**:
  1. 0x10730: write N to the ITR. 0x10748: write 0xf87fffff to mask-SET.
  2. System limit (0xf_f131_0000):
     - 0x1075c: write 0; it must read 0;
     - 0x10778: write 0xffffffff; it must read 0x7ffffe00.
  3. 0x1079c: read the counter (0xf_f131_0004), 3 nops, read it again; the second value must be
     greater.
  4. 0x107d8: write 0x7ffffe00 to the limit; the counter must be < 0x40000.
  5. 0x10808: write 0x7ffffe00 to the non-resetting limit (0xf_f131_0008); the counter must be
     greater than the previous read.
  6. 0x10824: set %g5=0x1a and %g7=0x69. 0x1083c: write 0xf87fffff to mask-CLEAR.
  7. Poll up to 0x80000 times. 0x10880: write 0xf87fffff to mask-SET.
- **Expected**: the level-10 trap (tt 0x1a) arrives through the ITMR T bit (bit 19) and ITR=N.
  The handler checks L as described above. The same 2.1 s count and 0x80000-poll timing
  assumption applies.
- **Fails with**:
  - L_10890 for register mismatches.
  - L_109f8, 0x134d1 "ERROR : System Counter Not Incrementing".
  - L_10b28, "No interrupt received, expected 0000001a", plus the pins.
  - Handler errors print 0x13554 "System Counter Limit Bit".
  - All of these print U1002.

### MSI/MSBI Control Reg Tests
- Entry: `0xe4c0`, called from post_main `0x1695c`.
- A walking-pattern read/write check of the MSI registers, each with an alias check against a
  neighbour register.
- **Algorithm**: `msi_reg_walk_test(reg, other, mask, or)` at 0xe59c does the following:
  1. Start with p = 0x5a5a5a5a and ~p (kept in %sp).
  2. Write p to reg and ~p to other; read reg; it must equal (p & mask) | or.
  3. Swap: write ~p to reg and p to other, and check again.
  4. Repeat step 2 with p <<= 1 until p == 0.
- The walker is called three times:
  1. 0xe51c: slot configuration registers, reg = 0xf_e000_101c, 18, 14, 10 (slots 3..0). Other
     = the next lower slot's register (slot 0 uses slot 2). Mask 0x3800f.
  2. 0xe54c: IOMMU base 0xf_e000_0004 (other = control), mask 0xfffffc00.
  3. 0xe570: IOMMU control 0xf_e000_0000 (other = base), mask 0x1f. %o3=0 each time.
- **Expected**:
  - Slot config RW bits: SEGA<31:30> (bits 17:16), CP (15), BA32/BA16/BA8/BY (3:0).
  - IBA bits 31:10.
  - IOMMU control RANGE, DE, ME (bits 4:0).
- **Fails with**: L_e650 (Address/exp/obs/xor), then U0101 (MSI_ASIC), and sets %g3=1. The
  error path calls functions while %sp holds pattern data (inferred: it would probably crash).
- QEMU note (public knowledge): QEMU's IOMMU_SBCFG_MASK 0x00010003 would also fail this test.

### IOMMU CAM NTA Pattern Test
- Entry: `0xe058`, called from post_main `0x16970`. The dead wrapper 0xe020 also calls it.
- A march test of the 16 IOMMU tag (CAM) entries through diagnostic access.
- **Algorithm**:
  1. 0xe080: IOMMU control = 2 (DE=1, ME=0).
  2. `sub_16f2c`(0xf_e000_0100, 0x40 bytes, stride 4, ASI 0x2f, mask 0x7ffff000, 0) is a
     march with elements 0, ~0, 0xaaaaaaaa and 0x55555555. It goes up and down, reading and
     verifying before each write, and every compare is masked.
  3. 0xe0ac: IOMMU control = 0.
- **Expected**: tag bits TAG<30:12> are RW in all 16 entries.
- **Fails with**: the march helper prints the Address/exp/obs/xor line and returns 0xff. It does
  not set %g3, so POST continues (a non-fatal failure).

### IOMMU TLB NTA Pattern Test
- Entry: `0xe0c0`, called from post_main `0x16984`. The dead wrapper 0xe03c also calls it.
- The same march over the TLB (translation cache) data entries 0xf_e000_0200..023c, mask
  0xffffff86 (PPN 31:8, C 7, W 2, V 1), with control = 2 (DE=1), then control = 0.
- **Fails with**: the same non-fatal print.

### IOMMU CAM TLB Comparator Test
- Entry: `0xe128`, called from post_main `0x16998`.
- Checks that each tag entry matches its VA in the diagnostic comparator.
- **Algorithm**:
  1. 0xe14c: `iommu_get_impl` 0x19598 returns control>>28. If IMPL != 0 the test returns (pass).
  2. 0xe170: control = 2.
  3. 0xe190: for i = 0..15, tag[i] (0xf_e000_0100+4i) = 0x40000000>>i.
  4. 0xe1c0: for k = 0..15:
     - write 0x8000<<k to the diagnostic VA register (0xf_e000_0140);
     - read the comparator output (0xf_e000_0150); it must be 0x8000>>k.
- **Expected**: exactly one comparator bit is set, the one for entry 15-k (VA<30:15>
  one-hot). Control is left at 2.
- **Fails with**: L_e3d0 (Address/exp/obs/xor), then U0101, and sets %g3=1.

### IOMMU TLB Flush Tests
- Entry: `0xe204`, called from post_main `0x169ac`.
- Tests single-address flush and flush-all.
- **Algorithm**:
  1. `iommu_fill_tlb_and_tags` 0xe304:
     - control = 2;
     - for k = 0..15, write ((16-k)<<12)|2 to both TLB[k] (0xf_e000_0200+4k) and TAG[k]
       (0xf_e000_0100+4k), so each entry is valid for VA page 16-k;
     - control = 1.
  2. For k = 0..15:
     - 0xe260: write 0x80000000|((16-k)<<12) to address flush (0xf_e000_0018), with ME=1 and DE=0;
     - `iommu_check_tlb_valid_except` 0xe35c: with control = 2, TLB[k].V (bit 1) must be 0 and
       every other V must be 1; then control = 1;
     - 0xe26c: control = 2; TLB[k] |= 2 (make it valid again); control = 1.
  3. 0xe2a8: refill. 0xe2b8: write 0 to flush-all (0xf_e000_0014).
  4. Read all 16 TLB entries while DE=0; V must be 0 in every one.
- **Expected**:
  - An address flush matches FA<30:12> against TAG<30:12> and invalidates only that entry.
  - Flush-all clears every V.
  - A TLB diagnostic read with DE=0 must return V=0 (0 or real data).
  - The IOMMU is left enabled (control = 1).
- **Fails with**: L_e3d0 or L_e444 (Address/exp/obs/xor), then U0101, and sets %g3=1.

### TOD Registers Test
- Entry: `0x10dc0`, called from post_main `0x16b1c`. The dead wrapper 0x10c40 also calls it.
- Saves the clock, walks values through every MK48T08 clock register, then restores it.
- **Algorithm**:
  1. 0x10dec: `sub_187d0`(0x400000, 0x10) is a RAM quick check. If it fails, print 0x1314a
     "<<BAD DSIMM IN SLOT 0 ...SKIPPED>>" and skip the test.
  2. 0x10e30: write and read bytes 0x55 then 0xaa at pa 0x400000..7 (the 8th byte is written but
     not compared).
  3. 0x10e80: control 0x1ff8 = 0x40 (R, freeze for reading). Copy 0x1ff8..0x1fff to RAM
     0x400000..7.
  4. 0x10eb0: control = 0x80 (W). For each register r = 1..7 (0x1ff9..0x1fff):
     - write 0 and read back 0;
     - then, using mask m = the byte at 0x1113c+r (read through ASI 9), write each value
       v = m, m-1, ..., 1 and read it back.
  5. 0x10f44: control = 0x80. Restore 0x1ff9..0x1fff from RAM.
  6. 0x10f6c: control = saved & 0x3f (clears W and R, restarts the clock).
- **Expected**:
  - Masks: seconds 0x7f (ST bit 7 excluded), minutes 0x7f, hours 0x3f, day 0x07 (FT bit 6
    excluded), date 0x3f, month 0x1f, year 0xff.
  - Non-BCD values must read back unchanged while W=1.
  - The saved seconds byte, including ST, is written back unchanged, so a stopped oscillator
    stays stopped.
- **Fails with**:
  - L_10ff4, Address/exp/obs/xor (%1 = register address), then U1004.
  - L_110dc, 0x13c36 "ERROR : Memory area used to save TOD regs is bad," then
    Address/exp/obs/xor, with no U-number.
- **Kickstart**: this ROM has no code for it. The strings 0x13b88 ("TOD Oscillator NOT
  Running, Kickstart in Progress") and 0x13bd7 are unreferenced. 0x13c04 "Unable to Kickstart"
  is used only by the orphan error tail 0x11068. The SS5 ROM is the same. On an MK48T08 a
  kickstart would presumably mean writing ST (0x1ff9 bit 7) to 1 and then 0 under W (guess,
  from datasheet knowledge).

### NVRAM/TOD probe (no name string)
- Entry: `0x10c58`, called only from the dead wrapper 0x10c20. Not called in this ROM.
- **Algorithm**:
  1. Set %g5=9 and read pa 0xf_f120_0003 (a trap here means the part is missing).
  2. If a trap was taken, print 0x13adc "ERROR : Data Access Execption in Probing TOD/NVRAM ...
     Skipping".
  3. Otherwise write 0x5a, read it back, and print 0x13a8f "WARNING : TOD/NVRAM Not Installed"
     if it does not match.
  4. Return 1 = absent.
- %g5 is left at 9 when no trap is taken (a latent bug).

### MBus to EBus Timeout Tests (not called: dead code)
- Entry: `0xfad8`. There is no caller and no pointer to it in the image.
- Tests the synchronous read-error path and the asynchronous write-error path for EBus
  accesses.
- **Algorithm**:
  1. 0xfb04: `sub_187d0`(0x600004, 0x10); on failure, skip.
  2. 0xfb50: clear the whole mask. 0xfb68: Arbiter Enable (0xf_e000_1008) |= 0x801f0000.
  3. 0xfb84: with %g5=9, read pa 0xf_f170_0300 (floppy space). A data access exception must be
     taken.
  4. Check the MMU fault registers:
     - SFSR (ASI 4 0x300) & ~0x300 must be 0x436 (EBE bit 10, probably bus error (guess); AT=1;
       FT=5; FAV);
     - SFAR (0x400) must be 0xf1700300;
     - SFSR read again must be 0.
  5. 0xfc04: with %g5=0x1f and %g7=0x98, write to pa 0xf_f110_0060, then poll up to 0x100
     times for the level-15 trap.
  6. The saved AFSR must be 0x9500000f | MID<<20 (ERR, BERR, SIZ=word, S, MID, PA=0xf), and the
     saved AFAR must be 0xf1100060. The live AFSR bit 31 must be clear.
  7. Restore the arbiter and mask.
- **Fails with**:
  - L_fec0, Address/exp/obs/xor, then U0201 (EMC_SMC), then 0x13803 "ERROR : Suspect MSI
    Module". This error exit is shared with the EMC/SMC Memory Timeout test.
  - L_ffc8, 0x12c37 "ERROR : No trap taken, expected %1".
  - L_ff44, AFSR/AFAR mismatch, then U0101.
  - L_100f0, "No interrupt received", then U0101, P18_mis_int*, U1002, P137_msi_cntrl_irq,
    and "Suspect MSI Module".

### MBus to SBus Timeout Tests (not called: dead code)
- Entry: `0xfcd8`, with no caller.
- The same flow on SBus:
  1. 0xfd7c: read pa 0xe_0000_0010 (empty slot 0, ASI 0x2e). It must trap with tt 9, SFSR must be
     0x836 (EBE bit 11, probably timeout (guess)), and SFAR must be 0x10.
  2. 0xfdf0: byte write to pa 0xe_0000_0e00 must raise a level-15 trap. The AFSR must be
     0xa100020e | MID<<20 (ERR, TO, SIZ=byte, S, SSIZ=byte, PA=0xe), and the AFAR must be 0xe00.
- Same error exits.

### System timer heartbeat (no name string)
- `0x193f8` (dead) starts it: system limit = 0x30000000 (about 0.79 s), %g2=8, and
  mask-CLEAR 0x80080000 (MA+T). The level-10 default path then prints the spinner.
- `0x19424` stops it: mask-SET 0x80080000, %g2=0, system limit = 0, LEDs 0. It is called at
  post_main 0x1687c and 0x16b30, and on the fail paths 0x16c10, 0x16c94, 0x16cf4 and 0x16d54.
  Only the stop is ever executed.

### Name strings with no code
- The following strings have no code reference: no sethi/or pair in strrefs.txt, and no word
  in the image equal to the address.
  - 0x15542 "Multiple Interrupts Test"
  - 0x15562 "Auxiliary IO Registers Tests"
  - 0x15582/0x155a2/0x155c2/0x155e2 "Keyboard/Mouse/Serial Port A/Serial Port B 85C30 Test"
  - 0x15602 "NVRAM Access Test"
  - 0x15622 "TOD Oscillator Test"
  - 0x156c2 "EPROM Checksum Test" (its error 0x135a5 is also unreferenced)
  - 0x156e2 "Floppy 82077A Tests"
  - 0x15be2 "IOMMU CAM MATS Pattern Test", 0x15c22 "IOMMU TLB MATS Pattern Test" (the NTA
    variants replaced them)
  - 0x15ca2 "MBus to VME Timeout Tests"
  - all seven floppy error strings 0x14026, 0x14096, 0x140d4, 0x1410d, 0x14148, 0x14198, 0x141cc
- Two orphan error tails remain, with no xref: 0x11068 (Kickstart, U1004) and 0x11160
  (Address/exp/obs/xor, U0801 KBM_85C30, U1002; the tail of a removed 85C30 test).
  0x10014 ("No interrupt received", MSI pins) is also unreferenced.
- 0x101cc "\r\n o = %1" is an unreferenced debug string.
- The strings that do have code: "MBus to EBus/SBus Timeout Tests" (0x15c82, 0x15c62), but
  only in the dead functions above.

Helpers
- `0xd2a0` intr_tests_group_unused: dead runner for d300, d3ac, d594, d710.
- `0xe020` / `0xe03c`: dead wrappers for the CAM and TLB NTA tests.
- `0x101e0` timer_tests_group_unused: dead runner for the user timer, counter/timer and system
  counter tests.
- `0x10c20` tod_nvram_tests_group_unused: dead; runs probe, then access test, then TOD
  registers test.
- `0xe304` iommu_fill_tlb_and_tags; `0xe35c` iommu_check_tlb_valid_except(o2 = 16-k);
  `0x19598` iommu_get_impl (returns control[31:28]).
- `0xe59c` msi_reg_walk_test(reg, other, mask, or).
- Shared, owned elsewhere: `0x16f2c` (the march used by the NTA tests), `0x187d0` (RAM quick
  check, returns 1 if bad).

#### Notes for the CPU test suite
- **Easy to lift.** The interrupt tests (d300, d3ac, d594, d710), the three timer tests and the
  TOD test need only:
  - control-space ASI 0x2f and `get_mid` (MXCC port register or 0xf_e000_2000);
  - a trap table whose level handlers compare tt with %g5, clear it, and clear the soft bit
    `0x10000<<lvl` at 0xf_f140_N004;
  - for the TOD test, 8 bytes of RAM (pa 0x400000).

  Pass/fail can be reported through %g3 or an LED/serial byte. MXCC and a second CPU are not
  required.
- **For 3 CPUs.** Run the per-CPU tests on each CPU, as POST does: dispatch, set the ITR to self,
  run.
- **Add an IPI test.** POST has none. Have CPU A write to CPU B's set-soft register
  0xf_f140_B008; B takes the trap with tt 0x10+lvl and clears it at 0xf_f140_B004. Also check
  that B's pending bits do not appear in A's pending register, and that level-14 timers stay
  per-CPU.
- **Replace the timing loops.** Do not copy POST's poll-count waits (0x1000 and 0x80000
  passes). Use a short limit, e.g. 0x00100000 = 1 ms, or poll the counter's L bit instead. The
  POST values assume about 0.7 µs per uncached PROM instruction. Likewise the "increments
  between two reads 3-4 nops apart" checks should poll with a bounded counter.
- **Needs 64-bit I/O.** The user-timer test uses `ldda`/`stda` to I/O space (a 64-bit bypass
  access that must split into MSW at +0 and LSW at +4).
- **IOMMU and MSI tests** need only control space, no DVMA. They need
  tag/TLB diagnostic access, the comparator (0x140/0x150), per-entry address flush, and the
  slot configuration registers.
- **MBus timeout tests** (dead in the ROM) are worth reviving for async-error validation. They
  need:
  - RAM at 0x600000 for the handler save area;
  - tt 9 precise data-access errors with SFSR/SFAR (ASI 4);
  - the M-to-S write buffer raising a level-15 broadcast, with AFSR/AFAR at 0xf_e000_1000/1004.
- **Hard parts**:
  - POST's serial printf and NVRAM mailboxes.
  - Every CPU re-runs system-wide tests; the suite should run those once.
  - Any interrupt source that asserts during the Soft OFF/ON checks will break them, because
    the system pending register must read 0 (for example the keyboard, serial port, or a
    leftover ESP/LANCE interrupt).

## 9. On-board SBus I/O tests (DMA2/MACIO, ESP, LANCE, parallel port)

All called tests run from `post_main` between 0x169c0 and 0x16b0c. They are grouped by the
keyboard-LED commands `kbd_send(0x0e); kbd_send(0)` at 0x169c0, then `(0x0e, 8)` at 0x16a48,
and `(0x0e, 0)` at 0x16b0c (the next group starts at 0x10dc0). The MMU is off. All device
accesses use bypass ASI 0x2e (pa 0xe_xxxx_xxxx) or 0x2f (pa 0xf_xxxx_xxxx).

**Two kinds of failure.**
- DMA2, ID and PPORT tests (0x7250-0x87c0) *never* set `%g3`. Their error exits print the
  error and U-number, set `%i0 = 0xff` and return. `post_main` only tests `%g3`, so these
  failures are **print-only and non-fatal**.
- The ESP test (0x995c) and the LANCE port tests (0xde74, 0xdee8, 0xdf80) set `%g3 = 1`. That
  is **fatal**: `post_main` goes to `post_fail_main_logic_board`.

**Register map used** (register names from Linux `sparc/dma.h` / `sunbpp.h`; this is public
knowledge, not ROM text):

| pa | register | width |
|---|---|---|
| 0xe_f000_0000 | MACIO ID register, read-only, value 0xfe810103 (QEMU `macio_idreg` has the same bytes) | 8/16/32 |
| 0xe_f040_0000 | D_CSR (ESP DMA): bits 31:28 DEV_ID = 0xA (DMA2); 26 A_LOADED; 27 NA_LOADED; 24 EN_NEXT; 13 EN_CNT; 7 RESET (also resets the ESP); 6 ACC_SZ_ERR (slave size error); 5 FLUSH (write-only); 3:2 PACK_CNT/DRAIN, masked with `and -0xd` | 32 |
| 0xe_f040_0004 / +0x8 | D_ADDR (D_NADDR when EN_NEXT=1) / D_BCNT, 24-bit | 32 |
| 0xe_f040_0010 | E_CSR (LANCE DMA): same DEV_ID, RESET (resets the LANCE) and bit 6 | 32 |
| 0xe_f040_0014 / +0x18 / +0x1c | E test CSR / E cache-valid bits / E_BASE (DVMA A[31:24] for the LANCE, byte register) | 32 / 32 / 8 |
| 0xe_f080_0000 + 4n | ESP 53C9x registers: +0 TCLO, +4 TCMID, +8 FIFO, +0xc CMD, +0x20 CFG1 | 8 |
| 0xe_f0c0_0000 / +2 | LANCE RDP / RAP | 16 |
| 0xe_f480_0000 | P_CSR, +4 P_ADDR, +8 P_BCNT (24-bit); +0x10 HCR (16), +0x12 OCR (16), +0x15 TCR (8), +0x16 OR (8), +0x17 IR (8), +0x18 ICR (16) | mixed |
| 0xf_e000_1000 / 1004 | M-to-S AFSR / AFAR. AFSR is cleared by `sta %g0` | 32 |

**Slave size-error protocol** (used by D_CSR, D_ADDR, D_BCNT, D_NADDR, D_NBCNT, E_CSR and the
LANCE port tests). The test does a **byte store** (`stba`) to a register that only accepts
full-width accesses. The real hardware then:
- does *not* perform the write;
- sets bit 6 in D_CSR or E_CSR, so the CSR reads `0xa0000040` (or with the current EN bits);
- answers the SBus cycle with an error ack. The MBus-to-SBus write buffer latches it in the
  AFSR as `0x91800_0_0e | MID<<20 | SA<<12`: ERR, BERR, SIZ=000 (byte), S=1, MID of the CPU
  that ran the test (`get_mid`), SA = pa[4:0] of the register, SSIZ=001 (byte), PA=0xe.
- latches `AFAR = pa[31:0]`.

Bit 6 is then cleared by writing `0x40` to the CSR (helpers 0x11980 / 0x119b0) and the AFSR by
`sta %g0`. The level-15 interrupt this raises (ITMR bit 29) stays masked, except in the dead
PPORT Slave test.

### DMA2/MACIO ID Register Test
- Entry: `0x7250`, called from `post_main` 0x169d0 (also from the unused runner 0x71c4).
- Tests: the read-only MACIO ID register, at every access width.
- **Algorithm**:
  - 0x728c `lda [0xf0000000] 0x2e` must equal 0xfe810103.
  - 0x72a0 / 0x72c4: `lduha` at +0 and +2 must read 0xfe81 and 0x0103.
  - 0x72e0-0x7334: `lduba` at +0..+3 must read fe, 81, 01, 03.
  - 0x7348 `sta %g0` to the register, then 0x734c `lda` must still read 0xfe810103.
- **Touches**: pa 0xe_f000_0000 through ASI 0x2e (32/16/8-bit reads, one 32-bit write).
- **Expected**: 0xfe810103. The write must be ignored *without* an SBus error. The AFSR is
  not cleared here, and the next test compares it exactly (inference).
- **Fails with**: 0x7bf4 `dma2_reg_fail`. It prints "<<< CPU_%1 on MBus Slot_%2 >>>" (0x16088)
  and "ERROR : Address = %1, exp = %2, obs = %3, xor" (0x129b7; the Address argument `%l3`
  is stale here) plus U-NUMBER "U0501 (DMA2_ASIC )" (0x18554). Non-fatal.

### DMA2/MACIO E_CSR Reg. Test
- Entry: `0x7af0`, from `post_main` 0x169e4 (also from runner 0x71d8).
- Tests: the E_CSR reset bit and DEV_ID, and the size error on a byte store.
- **Algorithm**:
  - 0x7b34 `sta 0x80` to E_CSR. 0x7b38 read `& ~0xc` must be 0xa0000080.
  - 0x7b5c `sta 0`, then 0x7b68 `stba 0` to E_CSR. The read `& ~0xc` must be 0xa0000040.
  - 0x7b84 clear bit 6 (0x119b0).
  - 0x7ba8 AFSR must equal `0x9181020e | mid<<20` (SA = 0x10). 0x7bc8 AFAR must equal
    0xf0400010. 0x7bdc clear the AFSR.
- **Touches**: pa 0xe_f040_0010 (32-bit and 8-bit writes, 32-bit reads); pa 0xf_e000_1000
  and 0xf_e000_1004.
- **Fails with**: `dma2_reg_fail` (U0501). AFSR/AFAR mismatches go to 0x7c68
  `dma2_afsr_fail`, which prints "U0101 (MSI_ASIC  )" (0x18540) and U0501. Non-fatal.

### LANCE Address Port Tests
- Entry: `0xd9e8`, from `post_main` 0x169f8 (also from runner 0x71ec).
- **Algorithm**:
  - 0xda18 E_CSR reset pulse (0x11960: 0x80, then 0).
  - 0xda2c `stha 1` to RAP (pa 0xe_f0c0_0002), `lduha` must read 1. 0xda40 `stha 0`, read 0.
  - E_CSR reset pulse again.
  - 0xda78 `stba 1` to RAP. 0xda8c E_CSR must read **exactly** 0xa0000040 (no mask).
  - 0xda9c clear bit 6. 0xdac0 AFSR must equal `0x9180220e | mid<<20` (SA = 2). 0xdae0 AFAR
    must equal 0xf0c00002. Clear the AFSR.
- **Fails with** (all **fatal**, `%g3 = 1`):
  - RAP mismatch: 0xdde8 `lance_port_fail` (U0503 "LANCE" 0x18568 + U0501).
  - E_CSR mismatch: 0xde80 `lance_ecsr_fail` (U0501).
  - AFSR/AFAR mismatch: 0xdef4 `lance_afsr_fail` (U0101 + U0501).

### LANCE Data Port Tests
- Entry: `0xdb0c`, from `post_main` 0x16a0c (also from runner 0x7200).
- **Algorithm**:
  - E_CSR reset pulse.
  - 0xdb50 RAP = 0. 0xdb5c `stha 4` (STOP) to RDP, `lduha` must read CSR0 = 0x0004.
  - 0xdb88 RAP = 1. 0xdb98 RDP = 0xaaa8 (CSR1 = IADR[15:1]), read back 0xaaa8.
  - E_CSR reset pulse, RAP = 1, then 0xdbdc `stba 0xa8` to RDP. E_CSR must read exactly
    0xa0000040. Clear bit 6.
  - 0xdc24 AFSR must equal `0x9180020e | mid<<20` (SA = 0). AFAR must equal 0xf0c00000.
- **Fails with**: same exits as the Address Port test. **Fatal.**

### DMA2/MACIO D_CSR Reg. Test
- Entry: `0x7374`, from `post_main` 0x16a20.
- **Algorithm**:
  - 0x73b4 `sta 0x80` (RESET). 0x73b8 read `& 0xfffffff3` must be 0xa0000080.
  - 0x73d0 D reset pulse (0x11920).
  - 0x73f4 `stba 0x80` to D_CSR (byte 0 = bits 31:24). 0x73f8 `lda` must be exactly
    0xa0000040: the write is dropped and ACC_SZ_ERR is set.
  - 0x7408 clear bit 6 (0x11980).
  - 0x742c AFSR must equal `0x9180020e | mid<<20`. 0x7448 AFAR must equal 0xf0400000.
    0x745c clear the AFSR.
- **Fails with**: `dma2_reg_fail` / `dma2_afsr_fail`. Non-fatal.

### DMA2/MACIO D_ADDR Reg. Test
- Entry: `0x7474`, from `post_main` 0x16a34.
- **Algorithm**:
  - D reset pulse.
  - 0x74bc D_ADDR = 0x55555555, read back.
  - 0x74e0 `D_CSR & 0x0c000000` must equal 0x04000000 (A_LOADED set, NA_LOADED clear).
  - 0x7508 D_ADDR = 0, read back 0.
  - 0x7530 D_CSR = 0x80. The read `& ~0xc` must be 0xa0000080, so RESET clears A_LOADED.
  - D reset pulse. 0x7578 `stba 0x55` to D_ADDR. D_CSR `& ~0xc` must be 0xa0000040.
  - Clear bit 6. AFSR must equal `0x9180420e | mid<<20` (SA = 4). AFAR must equal
    0xf0400004. Clear the AFSR.
- **Fails with**: `dma2_reg_fail` / `dma2_afsr_fail`. Non-fatal.

### DMA2/MACIO D_BCNT Reg. Test
- Entry: `0x7610`, from `post_main` 0x16a58. It does not `clr %g3` (harmless).
- **Algorithm**:
  - D reset pulse. 0x7648-0x7654 D_CSR |= 0x2000 (EN_CNT).
  - 0x7668 D_BCNT = 0x00e69f10, read back equal. 0x767c D_BCNT = 0, read back 0.
  - D reset pulse. 0x76b8 `stba 0x10` to D_BCNT. D_CSR `& ~0xc` must be 0xa0000040.
  - Clear bit 6. AFSR must equal `0x9180820e | mid<<20` (SA = 8). AFAR must equal
    0xf0400008. Clear the AFSR.
- **Fails with**: `dma2_reg_fail` / `dma2_afsr_fail`. Non-fatal.

### DMA2/MACIO D_NADDR Reg. Test
- Entry: `0x7750`, from `post_main` 0x16a6c.
- **Algorithm**:
  - 0x777c `dma2_d_reset_en_next` (0x1193c): D_CSR = 0x80, then 0x01002000 (EN_NEXT | EN_CNT).
  - 0x779c write 0x55555555 to +4 (goes to NADDR because EN_NEXT = 1). Read D_CSR (value
    discarded), then +4, then D_CSR again. The +4 value must be 0x55555555.
  - Repeat the reset. 0x77dc `stba 0x55` to +4. D_CSR `& ~0xc` must be 0xa1002040.
  - Clear bit 6. AFSR must equal `0x9180420e | mid<<20`. AFAR must equal 0xf0400004.
- **Fails with**: `dma2_reg_fail` / `dma2_afsr_fail`. Non-fatal.

### ESP Registers Tests
- Entry: `0x9640`, from `post_main` 0x16a80.
- **Algorithm**:
  - 0x9670 D reset pulse (DMA2 RESET also resets the ESP).
  - CFG1 (+0x20): 0x9684-0x96b8 write 0x55, 0xaa, 0x00 with `stba`; `lduba` each back.
  - Reset. FIFO (+8): 0x96e8-0x9700 push 0x89, 0xab, 0xcd, 0xef, then 4 `lduba` must return
    them in FIFO order.
  - CMD (+0xc): 0x9768 write 0x80 (DMA | NOP), read back 0x80.
  - Reset. TCLO: 0x9798 +0 = v, 0x97a8 CMD = 0x80 (DMA NOP loads the counter), then 0x97ac
    `lduba` +0 must be v, for v = 0x55, 0xaa, 0.
  - Reset. TCMID: +4 = v, TCLO = 0, CMD = 0x80, then +4 must be v (same values).
- **Touches**: pa 0xe_f080_0000 +0x00/+0x04/+0x08/+0x0c/+0x20 (8-bit), and D_CSR.
- **Fails with**: 0x98d0 `esp_reg_fail`. It prints ERROR Address/exp/obs/xor, "U0504
  (ESP_SCSI  )" (0x1857c) and U0501, then `%g3 = 1` (**fatal**).

### DMA2/MACIO P_CSR Reg. Test
- Entry: `0x7d00`, from `post_main` 0x16a94.
- **Algorithm**:
  - 0x7d38 P_CSR = 0x80 (RESET), 5 nops, P_CSR = 0.
  - 0x7d54 read P_CSR. Bits 0 (INT_PEND), 1 (ERR_PEND), 6 (SLAVE_ERR) and 3:2 (DRAINING)
    must all be 0.
- **Touches**: pa 0xe_f480_0000 (32-bit).
- **Fails with**: 0x8408 `pport_reg_fail` (ERROR + U0501). Non-fatal.

### DMA2/MACIO P_ADDR Reg. Test
- Entry: `0x7db8`, from `post_main` 0x16aa8.
- **Algorithm**: P reset pulse and a dummy read. Then 0x7e20-0x7e54 write P_ADDR (+4) with
  0xa55a5aa5, 0xffffffff, 0; each must read back unchanged (full 32 bits).
- **Fails with**: `pport_reg_fail`. Non-fatal.

### DMA2/MACIO P_BCNT Reg. Test
- Entry: `0x7e78`, from `post_main` 0x16abc.
- **Algorithm**: P reset pulse. Then write P_BCNT (+8) with 0xa55a5aa5, 0xffffffff, 0. The
  reads must return 0x005a5aa5, 0x00ffffff, 0: the counter is 24 bits and bits 31:24 read 0.
- **Fails with**: `pport_reg_fail`. Non-fatal.

### PPORT Registers Tests
- Entry: `0x7f48`, from `post_main` 0x16ad0.
- **Algorithm**: P reset pulse, then:
  - 0x7fa8 HCR (+0x10) = 0 with `stha`, read back 0.
  - 0x7fd0 OCR (+0x12) must read 0x200a after reset. With Linux bit names this is
    DS_DSEL | IDLE | V_ILCK (guess).
  - 0x7fec TCR (+0x15) bit 3 (DIR) must be 1.
  - 0x8008 OR (+0x16) must be 0.
  - 0x8024 ICR (+0x18) = 0xfc00. The IRQ status bits are write-1-to-clear, so the read must
    be 0.
- **Fails with**: `pport_reg_fail`. Non-fatal.

### DMA2/MACIO PPORT IO Lpbck Tst
- Entry: `0x82f0`, from `post_main` 0x16ae4.
- **Algorithm**: 0x8320 OCR = 0x0400 (EN_DIAG). Loop 0x8340 over v = 0..7: OR (+0x16) = v,
  then IR (+0x17) must equal v. The diagnostic loopback routes INIT/AFXN/SLCT_IN to
  PE/SLCT/ERR. Afterwards 0x8368 OR = 0; OCR is left with EN_DIAG set.
- **Fails with**: `pport_reg_fail`. The pin-list exit 0x847c (P94_p_pe*, P95_p_slct_in,
  P96_p_slct, P123_p_afxn, P125_p_error, P126_p_init) is never branched to.

### DMA2/MACIO PPORT XFR Lbck Tst
- Entry: `0x8380`, from `post_main` 0x16af8 (the last test of the group).
- **Algorithm**: OCR = 0x0400. Loop 0x83c8 over v = 0..7: TCR (+0x15) = v (DS/ACK/BUSY),
  then `lduba` TCR must equal v. Afterwards TCR = 0.
- **Fails with**: 0x85c8 `pport_xfr_lpbk_fail`. It prints ERROR, U0501 and PIN-NUMBER
  "P84_p_d_strb*", "P108_p_bsy*", "P110_p_ack*" (pin table 0x1624c + 0x3c / 0xa0 / 0xb4).
  Non-fatal.

### DMA2/MACIO D_NBCNT Reg. Test
- Entry: `0x7874`. Reached only from runner 0x721c, which has no caller: **dead**.
- **Algorithm**:
  - `%i5 = mid<<20`. Run `dma2_d_reset_en_next`.
  - 0x78cc D_BCNT = 0x00e69f10, then 0x78e0 D_ADDR = 0x55555555.
  - 0x78e4 BCNT must read 0x00e69f10. 0x78fc D_CSR `& ~0xc` must be 0xa5002000: the first
    address written under EN_NEXT is loaded as the current address (A_LOADED).
  - Repeat the reset. 0x7934 `stba` to +8. D_CSR must be 0xa1002040. Clear bit 6.
  - AFSR must equal `0x9180820e | %i5`. AFAR must equal 0xf0400008.
- **Fails with**: the DMA2 exits (non-fatal).

### DMA2/MACIO D_NA_LOADED Test
- Entry: `0x79c0`, via runner 0x721c only: **dead**.
- **Algorithm**:
  - D_CSR = 0x80, then 0x01002000.
  - 0x7a14 BCNT = 0x00e69f10, 0x7a28 ADDR = 0xaaaaaaaa. Both read back. D_CSR `& ~0xc` must be
    0xa5002000 (A_LOADED).
  - 0x7a84 BCNT = 0x89abcdef, 0x7a90 ADDR = 0x55555555 (the next-address pair). D_CSR must
    be 0xad002000 (A_LOADED and NA_LOADED).
  - 0x7abc D_CSR = 0x01002020 (FLUSH). The CSR must read back 0xa1002000: FLUSH clears both
    LOADED bits and reads as 0.
- **Fails with**: `dma2_reg_fail` (non-fatal).

### DMA2/MACIO PPORT Slave Tests
- Entry: `0x8050`. **No caller (dead)**.
- Tests: a byte access to a halfword PPORT register raises a size error, and that error
  arrives as a level-15 interrupt.
- **Algorithm**:
  - `sub_187d0(0x600004, 0x10)` checks RAM with 0xaaaaaaaa / 0x55555555. If bad, it prints
    "<<BAD DSIMM IN SLOT 0, RUN MEMORY TEST, SKIPPED>>" (0x1314a). The skip `bne` at 0x80ac
    relies on condition codes that survive `post_printf`.
  - 0x80c8 ITMR clear 0xf87fffff (pa 0xf_f141_0008) unmasks everything. P reset pulse.
  - 0x811c `%g5 = 0x1f` (expected trap: level-15 interrupt), 0x8120 `%g7 = 0x98`, then
    0x8124 `stba %g0` to HCR (+0x10).
  - Wait up to 0x100 iterations for `%g5 = 0`. With `%g7 = 0x98`, the level-15 handler
    (0x5704) stores the AFSR to pa 0x600000 and the AFAR to 0x600004, then clears the AFSR.
  - 0x8158 P_CSR bit 6 must be set. Write 0x40 to clear it. The check that it cleared is
    vacuous (mask 0 at 0x8170).
  - 0x8194 mem[0x600000] must equal `0x9101020e | mid<<20` (SA = 0x10). mem[0x600004] must
    equal 0xf4800010. The live AFSR ERR check at 0x81d4 is vacuous (`clr %l0` overwrites the
    mask).
  - Repeat with OCR (+0x12): AFSR `0x9101220e | mid<<20`, AFAR 0xf4800012.
  - 0x82dc ITMR set 0xf87fffff masks everything again.
- **Fails with**:
  - 0x86a8 `pport_slave_no_irq_fail`: "ERROR : No interrupt received, expected %1" (0x12c05),
    U0501, "P137_sb_p_irq".
  - 0x872c `pport_slave_afsr_fail`: U0101 + U0501.
  - The second bit-6 check goes to 0x119e4 (print, then `jmp %g1` retry).

### Ethernet Loopback Test
- Entry: `0xdc6c`. **No caller (dead)**. Despite the name, it is a register-dump stub with no
  loopback.
- **Algorithm**:
  - E_CSR = 0x80, then 0x00040000 (E burst32). Print "Ether COntrol/status reg = %1" (0xdf8c).
  - 0xdcfc E test CSR (+0x14) = 0x00700000, read and print (0xdfad).
  - 0xdd3c read cache-valid (+0x18), print (0xdfd3).
  - 0xdd7c `stba 0` to E_BASE (+0x1c), `lduba` and print (0xdff6).
  - 0xddc4 loop stores 0xa5a5a5a5 to pa 0x40, 0x3c, ... through ASI 0x20. The loop uses
    `sub` without setting cc, so `bne,a` tests stale condition codes. Depending on those
    flags it runs once or never ends.
- **Fails with**: nothing (it always returns `%g3 = 0`).

### LANCE Internal Loopback Tests / LANCE External Loopback Tests
- Entry: `0x1df50` (compiled C). **No caller (dead)**, like the other C extended tests.
  Loopback engine `lance_loopback_run` at 0x1e200 (called with mode 1 = internal, 2 = external).
- **Algorithm**:
  - `sub_187d0(0xf00000, 0x1000)` checks RAM. If it fails, print
    "...<< NO DSIMM IN SLOT 0, TEST SKIPPED >>" (0x1e918 / 0x1e95e) and return.
  - 0x1dfac arbiter 0xf_e000_1008 = `0x00100000 | 1<<(mid&3)`. This enables EN<F> (on-board
    SBus masters) and **turns off arbitration for all other MBus CPUs**.
  - `lance_lpbk_iommu_setup` 0x1de88 (IOMMU regs at pa 0xf_e000_0000):
    - IOMMU CTRL = 2;
    - zero the 16 diagnostic words 0xf_e000_0200..023c;
    - CTRL = 0, BASE (+4) = 0x000e0000, so the page table is at pa 0xe00000;
    - IOPTE[i] at pa 0xe00000 + 4i = `((0xf00000 + i*4K) >> 4) | 6` (V | W), i = 0..3;
    - CTRL = 1 (enable, 16 MB range), so DVMA 0xff000000.. maps to pa 0xf00000.
  - Each pass: E_CSR |= 0x80, then clear it (polled). ITMR clear 0xf87fffff. Run the engine.
    ITMR set 0xf87fffff. Delay 0x10000. Repeat while the `%g4` bit-0 "loop" flag is set.
  - Cleanup 0x1e1ac: 16 writes to 0xf_e000_0014 (flush all TLB), then IOMMU BASE = 0x43210000.
- **Engine 0x1e200**. RAM layout at pa 0xf00000 = DVMA 0xff000000:
  - Init block at 0xf00000:
    - MODE = 0x0044 (INTL | LOOP), or 0x0004 (LOOP) for external;
    - PADR = 0x0200, 0, 0; LADRF = 0 (+8..+0xe);
    - RDRA = 0x0020 with 0x2000 = RLEN 1 (2 descriptors);
    - TDRA = 0x0060 with 0x2000 = TLEN 1.
  - RMD0 at 0xf00020 = {0x0200, 0x0000, 0xffe0, 0}: 32-byte buffer at DVMA 0xff000200.
    TMD0 at 0xf00060 = {0x0100, 0, 0xffe0, 0}. Descriptor 1 of each ring is left
    uninitialised.
  - Chip setup: CSR0 = 4 (STOP), CSR1 = 0, CSR2 = 0, CSR3 = 3 (ACON | BCON, no BSWP).
    E_BASE = 0xff, E test CSR (+0x14) = 0, then CSR0 = 1 (INIT).
  - 0x1e448 poll RDP for IDON (0x0100), at most 99 999 times.
  - TX buffer 0xf00100[i] = i (i < 32) with header 02 00 00 00 00 00 02 00 00 00 00 00.
    RX buffer 0xf00200 = 0.
  - Set OWN | STP | ENP (0x8300) in RMD1 and TMD1 (spin until OWN reads back set). CSR0 = 2
    (STRT).
  - 0x1e63c wait for TMD1.OWN to clear (at most 99 999 999 polls). Clear 0x8300. TMD1 bit 14
    (ERR) means a transmit error. `CSR0 & 0x4800` (BABL | MERR) prints "X_Status error".
  - 0x1e74c wait for RMD1.OWN to clear. **Bug** at 0x1e778: TMD1 is copied into RMD1 before
    RMD1.ERR is tested, so receive errors are never seen. `CSR0 & 0x1800`: MISS returns
    silently; MERR prints "R_Status error".
  - 0x1e8b8 compare 32 bytes, 0xf00200+i against 0xf00100+i.
- **Fails with** (strings at 0x1e9e4-0x1eb5c): "Initialization failure, CSR0 exp %1, obs %2"
  (the test continues afterwards), "Transmit error: CSR0=..", "Receive error: ..",
  "<<<*** CHECK ETHERNET EXTERNAL LOOPBACK CONNECTOR ***>>>" (external only; the receive path
  also calls `sub_1ba6c`, which sets `%g3 = 1`), "Error in receive buffer: asi %1 addr %2,
  exp %3, obs %4".

#### Name strings with no code ("name string only")
No code reference was found, either in the listing or by a raw sethi/or scan of the ROM:
- **DMA2/MACIO interrupt tests**: P_DS Interrpt, P_ACK Interpt, P_BUSY Intrpt, P_SLCT Intrpt,
  P_ERR Intrpt, P_PE Interrpt (0x14de2-0x14e82).
- **PPORT MEM_CLR tests**: Unchained, Chained, Auto-Chain (0x14ea2-0x14ee2).
- **P_FIFO Alignment tests**: Burst 8, 4, 1 (0x14f02-0x14f42).
- **D_FIFO tests** (0x14fc2-0x15182):
  - 4 / 8 Word Burst RD and WR;
  - Align RD / WR Burst 4 and 8;
  - Chained RD and WR Slow / Med / Fast;
  - D_INVALIDATE.
- **DMA2/MACIO RD disable WR Test** (0x151a2).
- **DBRI**: Register, Interrupt, Internal Loopback (0x158a2-0x158e2).
- **MDI** (0x15902-0x15b22): Page0 / Page1 / Readonly Registers, Address Load, Interrupt
  Level, Invalid Pages, XLUT / CLUT1 / CLUT2 / CPL0 / CPL1 RAM, Auto-increment Regs / XLUT /
  CLUT1 / CLUT2 / CPL0 / CPL1, RAM Uniqueness.
- **VSIMM Chunky**: XBGR MATs, XBGR NTA, XBGR ADDR, BGR Mode (0x15b42-0x15ba2).

The strings with code are the 17 at 0x14be2-0x14dc2 plus 0x14f62, 0x14f82 and 0x14fa2.

#### Helpers
- `0x11920 dma2_d_reset_pulse`: D_CSR = 0x80, then 0 (resets the DMA2 D channel and the ESP).
- `0x1193c dma2_d_reset_en_next`: D_CSR = 0x80, read, D_CSR = 0x01002000 (EN_NEXT | EN_CNT),
  read.
- `0x11960 dma2_e_reset_pulse`: E_CSR = 0x80, then 0 (resets the LANCE).
- `0x11980 / 0x119b0 dma2_{d,e}_clear_slave_err`: write 0x40 to D_CSR or E_CSR, then read
  back. If bit 6 is still set, go to 0x119e4.
- `0x119e4 err_print_retry_g1` (shared): prints "ERROR : Address..", then `jmp %g1`. It
  re-runs the sub-test from its `%g1` progress marker without restoring the register window,
  so a stuck bit loops forever.
- Runners with no caller:
  - `0x7180`: D-cache group 0x6da0, then I-cache group 0xcee0.
  - `0x71c0`: ID, E_CSR, LANCE Address, LANCE Data.
  - `0x721c`: D_NBCNT, D_NA_LOADED.
- Unreferenced error blocks:
  - 0x847c: PPORT IO pin list.
  - 0x9980: ESP, U0504 + U0501.
  - 0x9a1c: ESP interrupt pins P61_INT*, P53_D_IRQ*, P124_SB_D_IRQ*.
- `0x1de88 lance_lpbk_iommu_setup`; `0x1e200 lance_loopback_run(mode, dvma, pa)`.
- All error exits do `mov %o2, %fp`. This overwrites the caller's `%sp` with the slot number.
  It is harmless only because POST runs with WIM = 0 and never spills (inference).

#### Notes for the CPU test suite
- **Easiest to lift**: all 15 called tests are pure slave-register tests. They need no RAM
  (only `save` with WIM = 0) and serial output only. Pass/fail is `%g3` (ESP, LANCE) or
  `%i0 = 0xff` (DMA2, PPORT). For a suite, have every exit set a result word, because
  `%g3` is not set for DMA2/PPORT.
- **Needed for the size-error half of each DMA2/LANCE test** (non-fatal DMA2 checks, but the
  fatal LANCE port tests):
  - the SBus slave size error (byte access to DMA2/LANCE registers is dropped, sets CSR bit 6,
    and is error-acked);
  - M-to-S AFSR/AFAR with the exact fields: MID of the requesting CPU, S, SIZ/SSIZ = byte,
    SA = pa[4:0], PA = 0xe;
  - AFSR clear-on-write.
- **Store ordering**: the CSR read right after the buffered `stba` must already see bit 6,
  so the SuperSPARC store buffer and the MBus-to-SBus write buffer must complete in order
  before a bypass load. The AFSR read must also stall until the write buffer drains (Sun-4M
  spec 5.2.1).
- **MP**: the tests take the expected MID from `get_mid` (MXCC port register), so the bridge
  must latch the MID of the MBus master that issued the write. Any CPU can run them.
- **Hard parts**:
  - PPORT Slave needs a level-15 interrupt from the M-to-S error, the ITMR, and the
    `%g5 = 0x1f` / `%g7 = 0x98` handler protocol that saves AFSR/AFAR to pa 0x600000.
  - LANCE loopback needs RAM at 0xe00000 and 0xf00000, IOMMU translation for DVMA
    0xff000000, the E_BASE high byte, LANCE INTL/LOOP, and descriptor OWN handshakes.
  - Its arbiter write disables the other CPUs' MBus arbitration: run it only on a
    single-CPU build or restore 0xfe0001008 afterwards.
- Quick wins:
  - MACIO ID register at 0xef0000000 (0xfe810103, write-ignore);
  - D_BCNT, A_LOADED / NA_LOADED, EN_NEXT and bit 6 in the DMA2 registers;
  - AFSR/AFAR in the M-to-S bridge;
  - a BPP register stub at 0xef4800000 with the reset values above; without it every
    PPORT test prints an error.

## 10. HyperSPARC (one line each)

Run only when `get_module_type` returns 0x17 (MCNTL[31:24] = 0x17): `post_main`
0x164d8 calls the suite runner `post_hypersparc_suite` (0x21790), then skips the
SuperSPARC MMU/cache block and continues at the EMC test. The runner stops at the
first test returning `%o0 != 0` and sets `%g3`. Test names are printed from the
55-byte slot table at 0x223f8 (`hs_print_test_name` 0x21740) when NVRAM 0x1ff2
!= 0; the two E-cache tests also need 0x1ff2 != 0.

| Slot | Test (ROM name) | Entry | What it does |
|---|---|---|---|
| 0 | HyperSparc Context Pointer Reg Test | `0xf8dc(0x100, 0xfffffc00)` from 0x217a8 | walking one on CTPR (ASI 4 0x100) |
| 1 | HyperSparc Context Reg Test | `0xf8dc(0x200, 0xfff)` from 0x217c8 | walking one on CTX, 12 bits |
| 2 | HyperSparc Root Pointer Reg Test | `0xf8dc(0x1000, 0xffffffc1)` from 0x217e8 | walking one on ASI 4 0x1000 |
| 3 | HyperSparc Instr Pointer Reg Test | `0xf8dc(0x1100, 0xfffffff1)` from 0x2180c | walking one on ASI 4 0x1100 |
| 4 | HyperSparc Data Pointer Reg Test | `0xf8dc(0x1200, 0xfffffff1)` from 0x21830 | walking one on ASI 4 0x1200 |
| 5 | HyperSparc Index Tag Reg Test | `0xf8dc(0x1300, 0xfffcfffc)` from 0x21858 | walking one on ASI 4 0x1300 |
| 6 | HyperSparc TLB Replace Reg Test | `0xf8dc(0x1400, 0x3f)` from 0x21878 | walking one on the 6-bit replacement counter |
| 7 | HyperSparc TLB RAM bit pattern Test | shared `0xf188` | the SuperSPARC TLB pattern test (§4) run on HyperSPARC |
| 8 | HyperSparc TLB/CAM NTA pattern Test | `0x16f2c(0, 0x400, 8, 6, -1, 0)` from 0x218c4 | 18-element march over ASI 6 (TLB RAM/CAM, entry << 4) |
| 0xf | HyperSparc MMU tlbmiss_test | 0x21f84 | page tables at pa 0x1000/0x2000 (root pointer 0x101), MMU on, 62 segment loads must each miss and fill TLB RAM/CAM consistently |
| 0x10 | HyperSparc MMU_tlbhit_test | 0x22184 | same tables; after the first pass the L2 PTEs are zeroed in memory and every access must still hit in the TLB |
| 0x13 | HyperSparc MMU Flush Tests | 0x22ae0 → `hs_mmu_flush_level_test` 0x22b4c | stuff the TLB through ASI 6, flush levels 0-4 (ASI 3), check which entries lose bit 0 |
| 0xe | HyperSparc Cache RAM W/R Test (Ec_size=0x%1) | 0x11460 | E-cache data (ASI 0x0f) word test over the size found by `ecache_size_probe` 0x115e4 (128 KB-2 MB) |
| 9 | HyperSparc Cache Tag NTA Test. | 0x1157c | march over E-cache tags (ASI 0x0e), stride 0x20/0x40 by MCNTL.CS |
| 0xa | HyperSparc ICache RAM Test. | 0x11200 | 64-bit I-cache data (ASI 0x0d) test, address / complement / 0x55.. / 0xaa.. over 8 KB |
| 0xb | HyperSparc ICache Tag NTA Test. | 0x1136c | march over I-cache tags (ASI 0x0c), both ways |
| 0xc | HyperSparc Write buffer/write-thru mode. | `0x21d68(0x82100)` | write-buffer ordering at pa 0x700000-0x73ffff with caches in write-through |
| 0xd | HyperSparc Write buffer/copy-back mode. | `0x21d68(0x82500)` | the same with copy-back (MCNTL.CM) |
| 0x11 | HyperSparc Block copy test/mmu_off | 0x21aa4 | ASI 0x17 block copy 0x700000 → 0x740000, 64 K words |
| 0x12 | HyperSparc Block fill test/mmu_off | 0x21bf8 | ASI 0x1f block fill of 256 KB at 0x700000 with (0xa5a5a5a5, 0x77777777) |
| 0x14 | HyperSparc Block Copy Test/MMU_ON | 0x24450 | block copy with the MMU on, over the E-cache size, PTE checks |
| 0x15 | HyperSparc Block Fill Test/MMU_ON | 0x24714 | block fill (0xfeedc0ed, 0xdeadcafe) with the MMU on |
| – | HyperSparc Icache RAM test (dead) | 0x239f8 | I-cache tag/data march from the table 0x24278 |
| – | HyperSparc Icache Flush Test (dead) | 0x23b10 | tries every I-cache flush flavour (flush, ICCR invalidate-all, ASI 0x10-0x14) |
| – | HyperSparc Icache Hit Test (dead) | 0x23e38 | plant tags + data through ASI 0x0c/0x0d, execute it |
| – | HyperSparc Icache Miss Test (dead) | 0x24060 | execute a filled page at va 0x80000 and check the I-cache contents |
| – | HyperSparc Ecache flush test (dead) | 0x24a18 | E-cache flush by ASI 0x10-0x14 in write-through and copy-back |
| – | HyperSparc Ecache write Miss test (dead) | 0x24de4 | write-miss allocation in WT and CB modes |
| – | HyperSparc Ecache read Hit/Miss test (dead) | 0x25334 | read miss fill / hit / copy-back tag states |

HyperSPARC registers and ASIs as this ROM uses them: MCNTL (ASI 4 va 0) with
MID in [18:15], BM bit 14, CS bit 12 (E-cache size), CM bit 10 (copy-back), CE
bit 8, ME bit 0 (names from Linux `ross.h`); CTPR mask 0xfffffc00; CTX 12 bits;
ASI 4 0x1000-0x1400 root pointer, instruction/data pointer, index tag, TLB
replace; ASI 6 TLB diag at `entry << 4` (+0 "RAM" PTE-like, +8 "CAM" VA/ctx);
ICCR = `%asr31` (bit 0 I-cache enable, bit 1 flush-trap disable); ASI 0x0c/0x0d
I-cache tag/data (2 ways × 128 lines × 32 B), 0x0e/0x0f E-cache tag/data (the
address wraps at the cache size), 0x10-0x14 combined flushes, 0x17 block copy,
0x1f block fill, 0x31 flush the whole I-cache.

## 11. Candidate CPU test suite

For [`tests/cpu/`](../../../tests/cpu/README.md), which
already boots as the PROM on the `ss20` target (boot mode, image copied to pa
0, ttya 9600 8N1 — the same set-up `post_zs_init_serial` uses) and holds the
generic V8 tests. The POST gives expectations for the SuperSPARC-specific
tests to add next; §11.4 lists what the POST does not test at all.

### 11.1 Tests that lift directly

Each needs the POST trap protocol (a trap table whose handlers compare tt with
`%g5`, clear it and skip or retry — README §7), which a suite should implement
once in its stub. "Serial" = only the ttya port for reporting.

| Test (section) | Needs | Pass/fail |
|---|---|---|
| IU globals, IU windows (§2) | nothing (no RAM) | branch to a fail stub |
| FPU Register File, Misaligned Reg Pair, SP / DP arithmetic (§5) | RAM scratch (pa 0x600000 in POST), PSR.EF | compare, `%g3` |
| FPU SP/DP Invalid, Overflow, Underflow, Divide-by-0, Inexact CEXC (§5) | RAM, tt 8 handler that drains the FQ (`std %fq` while FSR.qne) | `%g5` cleared + cexc bit + blocked store |
| FPU SP/DP Trap Priority > / < (§5) | RAM, tt 7 and tt 8 handlers | trap order |
| MMU Context Table Reg / Context Register (§4) | ASI 4 only | walking one |
| MMU TLB Bit Pattern, MMU Flush Tests (§4) | ASI 6 diag (entry << 12 \| SEL << 8), ASI 3 flush, pattern tables | read-back compare |
| D-/I-Cache RAM, PTAG, STAG, I-Cache Flush, Cache Flashclear (§3) | ASI 0x0c-0x0f diag, ASI 0x36/0x37 flash clear | read-back compare |
| Soft Interrupts OFF / ON, PROCn Interrupt Regs, System Interrupt Regs (§8) | interrupt controller pa `0xf_f140_0000/0xf_f141_0000`, level handlers | `%g5`, register compare |
| PROCn User Timer, Counter/Timer, System Counter (§8) | counters pa `0xf_f130_n000`, `0xf_f131_0000`, 64-bit `ldda/stda` to I/O | increments, limit bit, level 14/10 interrupt |
| TOD Registers (§8) | MK48T08 at `0xf_f120_1ff8..`, 8 bytes RAM | read-back |
| MSI/MSBI Control, IOMMU CAM/TLB NTA, Comparator, TLB Flush (§8) | pa `0xf_e000_0000-0x1fff` | read-back |
| DMA2/ESP/LANCE/PPORT register tests (§9) | SBus pa `0xe_f040_0000..0xe_f480_0000`; M-to-S AFSR/AFAR for the byte-size-error half | read-back, AFSR value |
| Memory Address Pattern, MATS/NTA engines (§7) | ≥ 16 MB RAM via ASI 0x20 | compare |
| EMC/SMC Control Regs, ECC Multiple UE/CE (§7) | EMC at pa `0xf_0000_0000`, ECC generation/check, level-15 | register values, EFSR/EFAR |
| MXCC suite (§6) | ASI 2 MXCC, E-cache | compare, stream completion |

Changes worth making when lifting (from the group sections): preload FP
destinations with non-zero data and use `fbne` in the misaligned-pair test;
compare the whole FSR, not one cexc bit; give each FP register a distinct
pattern; replace the POST's poll-count delays (tuned for ~0.7 µs per uncached
PROM instruction) by counter-based time-outs; add a time-out to the MXCC stream
polls (the POST loops forever on a stuck stream).

### 11.2 MP and coherency tests

What POST itself exercises across CPUs is limited:

- the start/stop protocol (arbiter enable register + NVRAM mailboxes,
  README §5) — every other MP feature depends on it;
- each CPU identifying itself (`get_mid`: MXCC port register, MSI MID
  register, or ASI 0x38 va 0) — with IOMMU IMPL 0 and MCNTL.MB = 1, if the
  MSI MID register (pa `0xf_e000_2000`) reads 0 and ASI 0x38 va 0 does not
  hold its value, **all CPUs identify as MID 8** and the reset path and POST
  run the master path on every CPU;
- per-CPU registers exercised by their owner: each slave runs `post_main`
  itself, so PROCn interrupt/timer tests use its own `0xf_f140_n000` /
  `0xf_f130_n000` (n = MID & 3), and `mp_run_with_target` points the interrupt
  target register at that CPU so undirected interrupts reach it;
- `ldstuba` on NVRAM byte 0x1e20 as the console lock (an atomic on an 8-bit
  device register, taken by several CPUs).

There is **no** inter-processor interrupt test, no cache-coherency test between
CPUs, and no MP memory-ordering test in this POST. Suggested additions, built on
the same mailbox idea but with the suite's own RAM mailboxes:

1. **Identity**: every CPU reports `get_mid`, `%tbr`, MXCC/MSI MID register;
   all distinct, 8..10 for three CPUs.
2. **Start/stop**: master clears and sets a slave's arbiter bit; the slave's
   progress counter must stop and resume.
3. **IPI**: CPU A writes bit 16+l to CPU B's set-soft register
   `0xf_f140_B008`; B takes tt 0x10+l and clears it at `0xf_f140_B004`; A's
   pending register must not show it. Repeat for all pairs and levels; add the
   broadcast/undirected cases through the interrupt target register
   `0xf_f141_0010`.
4. **Per-CPU timers**: level-14 counters of two CPUs running at the same time
   stay independent.
5. **Coherency (MESI)**: A writes a line (M), B reads it (A must supply or write
   back, both end S), B writes (A invalidated), A reads the new value; also
   false sharing (different words of one line), and `ldstub`/`swap` contention
   on one lock word by all CPUs with a shared counter (final count = sum of
   increments). The dead "D-Cache Write Hit Special Test" (§3) adds the
   single-CPU half: after write hits, memory read through bypass ASI 0x20 must
   still show the old data (write-back), and the tags must show V+D.
6. **Store ordering**: Dekker/Peterson-style flags between two CPUs with and
   without `stbar`, TSO vs PSO (MCNTL bit 7).
7. **DVMA vs caches**: an SBus master (LANCE loopback, §9) writing a line
   another CPU holds modified (needs IOMMU and DMA2; the POST's LANCE loopback
   is dead code but gives the descriptor layout).

### 11.3 First failure under QEMU

Under QEMU (SuperSPARC-II identity) the first failure is "MMU ICACHE_TLB bit
pattern Test", Case 0xf (ASI 5 I-TLB diag not modelled).

### 11.4 Generic SPARC V8 behaviour POST does not test

POST checks hardware, not the instruction set. A suite has to add at least:

- **Integer**: every ALU op with and without cc, all 16 Bicc conditions and
  the annul bit (taken/untaken), delay-slot behaviour of `ba,a`/`bn,a`, `call`,
  `jmpl`, `rett`; shifts with counts 0/31; `sethi`; `save`/`restore` as `add`.
- **Multiply/divide**: `umul/smul(cc)`, `udiv/sdiv(cc)` including overflow
  (V bit, result saturation) and division by zero (tt 0x2a), `mulscc`, `%y`
  reads/writes and the write delay.
- **Tagged arithmetic**: `taddcc/tsubcc` (V on tag bits) and `taddcctv/tsubcctv`
  (tag overflow trap, tt 0x0a).
- **Memory**: `ldsb/ldsh/ldub/lduh/ld/ldd/stb/sth/st/std` at every alignment
  (mem_address_not_aligned tt 7 — POST only checks one FP store case),
  `ldd/std` with odd rd (illegal instruction), `ldstub`, `swap`, their alternate
  forms and atomicity, `stbar`, `flush` and self-modifying code.
- **Traps and modes**: window overflow/underflow (POST runs with WIM 0 or 2 and
  never spills), `ta` with every software trap number, privileged-instruction
  traps in user mode (`rd/wr %psr`, alternate-space accesses), illegal
  instruction and `unimp`, instruction access exceptions, error mode (trap with
  ET = 0) and the watchdog reset path, `rett` checks, PIL masking of every
  interrupt level, trap priority for simultaneous exceptions.
- **FPU**: IEEE corner cases (NaNs and their propagation, denormals, ±0, ±∞),
  all four rounding modes, `fcmp` vs `fcmpe` and all 16 FBfcc conditions
  (including the fcmp → FBfcc delay), `fsqrt`, int/float/double conversions and
  their overflow, `fsmuld`, quad ops (unimplemented FPop, tt 8 ftt 3),
  `fp_disabled` (tt 4, never exercised by POST), FSR.ver, NS mode, `ldfsr`
  timing, FQ depth.
- **MMU in normal operation**: page faults of each level and their SFSR/SFAR,
  R/M bit updates, access permissions for every ACC value, context switch and
  flushes, the MMU with caches on (POST tests the TLB mostly through
  diagnostic ASIs).
