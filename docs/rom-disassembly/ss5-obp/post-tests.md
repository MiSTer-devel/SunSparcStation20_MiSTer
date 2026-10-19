# SPARCstation 5 POST (OBP 2.15): test catalogue

Every self-test in the power-on self-test (POST) of `ss5.bin`, with its entry
address, algorithm, the exact registers, ASIs and values it uses, and what it
prints when it fails. See [`README.md`](README.md) for how the POST is entered and left,
[`hardware-access.md`](hardware-access.md) for the register map and
[`listing.s`](listing.s) for the code. Addresses are PROM link addresses
(`0x70000000` + offset).

## 1. Conventions

- The POST runs with the MMU off in boot mode. Device registers are reached with
  `lda`/`sta`/`lduba`/`stba`/`lduha`/`stha`/`ldda`/`stda` and **ASI 0x20** (MMU
  bypass, PA = VA[30:0]); TLB and cache arrays with their diagnostic ASIs
  (0x06, 0x0c-0x0f); MMU registers with ASI 0x04.
- A test returns `%i0` = 0 (pass) or 0xff (fail). The first failure ends the
  POST: the sequencer lights a keyboard LED pattern and calls
  `post_exit_soft_reset(2, message)` (§11.2).
- `%g4` bit 1 = diagnostic mode: test names are printed only then. Error
  messages are always printed.
- `%g5` = trap type the test expects next, `%g6` = expected interrupt, `%g7` =
  sub-test code for the interrupt handlers (§8.1). A handler that sees the
  expected tt clears the register; the test then checks it is 0 ("No trap
  taken, expected %1" / "No interrupt received, expected %1").
- `%g3` = sticky "error already reported" flag, cleared at the start of each
  test; `%g2` = memory configuration (§6.2); scratch RAM is at
  `base + 0x2000` and `base + 0x2100`, base = `%g2 & 0x0f000000` = the lowest
  populated SIMM bank.
- `sethi %hi(X),%g0 ; mov N,%g0` pairs write `%g0`: no-ops used as checkpoint
  markers (visible on a logic analyser); they are not mentioned below.
- `post_printf` (`0x700070e0`): `%1`..`%4` print `%o1`..`%o4` as 8 hex digits.
  The generic error line is "ERROR  : Address= %1, exp= %2, obs= %3, xor= %4";
  most device tests add "UNUMBER: " and a chip location from the table at
  `0x7000a980` (U0103, U1102, U1507, U1506, …), CPU tests add "WARNING: Suspect
  Swift Module".

## 2. The sequence

`post_sequencer` (`0x700098c0`) calls the tests in this order; the order and
names match the SS5 service manual's "Full Diagnostic Mode Tests" table
(SS5 Model 110 Service Manual, Table 3-2) exactly — 55 tests. "Fail →" is the
failure path (§11.2): **CPU** = Num Lock LED + "Replace CPU Board", **NVRAM**
= Scroll Lock + "Replace NVRAM", **SIMM** = Compose + "Replace (%s) SIMM".

| # | Test (as printed) | Routine @ addr | Called at | Fail → | QEMU |
|---|---|---|---|---|---|
| 1 | MMU Context Table Reg Test | `post_mmu_regs` @ 0x70006000 | 0x70009900 | CPU | pass |
| 2 | MMU Context Register Test | ″ | ″ | CPU | pass |
| 3 | MMU TLB Replace Ctrl Reg Tst | ″ | ″ | CPU | pass |
| 4 | MMU Sync Fault Stat Reg Test | ″ | ″ | CPU | pass |
| 5 | MMU Sync Fault Addr Reg Test | ″ | ″ | CPU | pass |
| 6 | MMU TLB RAM NTA Pattern Test | `post_mmu_tlb_nta` @ 0x70005eb8 | 0x70009914 | CPU | **fail** |
| 7 | MMU TLB CAM NTA Pattern Test | ″ | ″ | CPU | – |
| 8 | MMU TLB LCAM NTA Pattern Test | ″ | ″ | CPU | – |
| 9 | IOMMU SBUS Config Regs Test | `post_iommu_regs` @ 0x70005a40 | `post_iommu_group` ← 0x70009928 | CPU | pass |
| 10 | IOMMU Control Reg Test | ″ @ 0x70005aa4 | ″ | CPU | **fail** |
| 11 | IOMMU Base Address Reg Test | ″ @ 0x70005ae8 | ″ | CPU | – |
| 12 | IOMMU TLB Flush Entry Test | `post_iommu_tlb_flush` @ 0x70005be0 | ″ | CPU | – |
| 13 | IOMMU TLB Flush All Test | ″ @ 0x70005c80 | ″ | CPU | – |
| 14 | SBus Read Timeout Test | `post_sbus_read_timeout` @ 0x70006360 | ″ | CPU | – |
| 15 | EBus Read Timeout Test | `post_ebus_read_timeout` @ 0x70006240 | ″ | CPU | – |
| 16 | D-Cache RAM NTA Test | `post_dcache_ram_nta` @ 0x70004f9c | 0x7000994c | CPU | – |
| 17 | D-Cache TAG NTA Test | `post_dcache_tag_nta` @ 0x70005000 | 0x70009960 | CPU | – |
| 18 | I-Cache RAM NTA Test | `post_icache_ram_nta` @ 0x7000516c | 0x70009984 | CPU | – |
| 19 | I-Cache TAG NTA Test | `post_icache_tag_nta` @ 0x700051d0 | 0x70009998 | CPU | – |
| 20 | Memory Address Pattern Test | inline, `mem_march_test` @ 0x7000a55c | 0x700099bc | SIMM | pass |
| 21 | FPU Register File Test | `post_fpu_regfile` @ 0x700023c0 | `post_fpu_basic_group` ← 0x70009a68 | CPU | pass |
| 22 | FPU Misaligned Reg Pair Test | `post_fpu_misaligned_pair` @ 0x700026b8 | ″ | CPU | pass |
| 23 | FPU Single-precision Tests | `post_fpu_single` @ 0x70002770 | ″ | CPU | pass |
| 24 | FPU Double-precision Tests | `post_fpu_double` @ 0x700029bc | ″ | CPU | pass |
| 25 | FPU SP Invalid CEXC Test | `post_fpu_sp_invalid_cexc` @ 0x70002b44 | `post_fpu_cexc_group` ← 0x70009a8c | CPU | pass |
| 26 | FPU SP Overflow CEXC Test | `post_fpu_sp_overflow_cexc` @ 0x70002c08 | ″ | CPU | pass |
| 27 | FPU SP Divide-by-0 CEXC Test | `post_fpu_sp_divzero_cexc` @ 0x70002d7c | ″ | CPU | pass |
| 28 | FPU SP Inexact CEXC Test | `post_fpu_sp_inexact_cexc` @ 0x70002e38 | ″ | CPU | pass |
| 29 | FPU SP Trap Priority > Test | `post_fpu_sp_trap_prio_gt` @ 0x70002f00 | ″ | CPU | pass |
| 30 | FPU SP Trap Priority < Test | `post_fpu_sp_trap_prio_lt` @ 0x70002fb4 | ″ | CPU | **fail** |
| 31 | FPU DP Invalid CEXC Test | `post_fpu_dp_invalid_cexc` @ 0x70003088 | ″ | CPU | – |
| 32 | FPU DP Overflow CEXC Test | `post_fpu_dp_overflow_cexc` @ 0x70003164 | ″ | CPU | – |
| 33 | FPU DP Divide-by-0 CEXC Test | `post_fpu_dp_divzero_cexc` @ 0x7000330c | ″ | CPU | – |
| 34 | FPU DP Inexact CEXC Test | `post_fpu_dp_inexact_cexc` @ 0x700033e0 | ″ | CPU | – |
| 35 | FPU DP Trap Priority > Test | `post_fpu_dp_trap_prio_gt` @ 0x700034c4 | ″ | CPU | – |
| 36 | FPU DP Trap Priority < Test | `post_fpu_dp_trap_prio_lt` @ 0x70003580 | ″ | CPU | – |
| 37 | PROC0 Interrupt Regs Tests | `post_proc0_irq_regs` @ 0x70005240 | 0x70009ab8 | CPU | pass |
| 38 | Soft Interrupts OFF Test | `post_soft_irq_off` @ 0x7000535c | 0x70009acc | CPU | pass |
| 39 | Soft Interrupts ON Test | `post_soft_irq_on` @ 0x70005498 | 0x70009af0 | CPU | pass |
| 40 | PROC0 User Timer Test | `post_proc0_user_timer` @ 0x700065c0 | 0x70009b04 | CPU | **fail** |
| 41 | PROC0 Counter/Timer Test | `post_proc0_counter_timer` @ 0x70006814 | 0x70009b18 | CPU | **fail** |
| 42 | DMA2 E_CSR Register Test | `post_dma2_e_csr` @ 0x700042ec | 0x70009b3c | CPU | **fail** |
| 43 | LANCE Address Port Tests | `post_lance_addr_port` @ 0x70005680 | 0x70009b50 | CPU | – |
| 44 | LANCE Data Port Tests | `post_lance_data_port` @ 0x70005798 | 0x70009b64 | CPU | – |
| 45 | DMA2 D_CSR Register Test | `post_dma2_d_csr` @ 0x70003b50 | 0x70009b78 | CPU | – |
| 46 | DMA2 D_ADDR Register Test | `post_dma2_d_addr` @ 0x70003c5c | 0x70009b8c | CPU | – |
| 47 | DMA2 D_BCNT Register Test | `post_dma2_d_bcnt` @ 0x70003dfc | 0x70009bb0 | CPU | – |
| 48 | DMA2 D_NADDR Register Test | `post_dma2_d_naddr` @ 0x70003f44 | 0x70009bc4 | CPU | – |
| 49 | ESP Registers Tests | `post_esp_regs` @ 0x70004bc0 | 0x70009bd8 | CPU | – |
| 50 | DMA2 P_CSR Register Test | `post_dma2_p_csr` @ 0x700044a0 | 0x70009bec | CPU | – |
| 51 | DMA2 P_ADDR Register Test | `post_dma2_p_addr` @ 0x7000455c | 0x70009c00 | CPU | – |
| 52 | DMA2 P_BCNT Register Test | `post_dma2_p_bcnt` @ 0x7000461c | 0x70009c14 | CPU | – |
| 53 | PPORT Registers Tests | `post_pport_regs` @ 0x700046ec | 0x70009c28 | CPU | – |
| 54 | NVRAM Access Test | `post_nvram_access` @ 0x70006c00 | 0x70009c4c | NVRAM | pass |
| 55 | TOD Registers Test | `post_tod_regs` @ 0x70006cf8 | 0x70009c60 | NVRAM | **fail** |

QEMU: "pass"/"**fail**" as observed (§13); "–" = not observed (an earlier test
stops the POST, or it was skipped to reach later tests).

**Present in the image but never called** (13 routines): FPU SP Underflow and
DP Underflow CEXC (`0x70002cc4`, `0x7000323c`); D-cache and I-cache "flash
clear" checks (`0x70004ed8`, `0x700050b8`); DMA2 ID Register, D_NBCNT and the
D_ chain test (`0x700039d8`, `0x7000406c`, `0x700041bc`, reachable only from
the uncalled groups `post_dma2_misc_group`/`post_dma2_esp_group`); DMA2 PPORT
Slave Error, IO Loopback, XFR Loopback (`0x700047b4`, `0x700049dc`,
`0x70004a6c`); the system-counter and TOD-kickstart remnants (§8.7, §10.2);
`mem_march_test_b` (`0x7000a634`). They are documented below with the tests
they belong to.

**Named but without code**: see §12.

## 3. MMU tests

### 3.1 MMU register tests — `post_mmu_regs` @ 0x70006000

Five tests, one routine. Each calls the walking-pattern checker
`mmu_reg_walk_test(reg, mask, orbits)` (`0x70006148`) on one ASI 0x04 register
and returns 0xff on the first failure.

`mmu_reg_walk_test` algorithm (`%i0` = VA in ASI 4, `%i1` = mask of
implemented bits, `%i2` = bits forced on in every write):

1. `0x70006168`: `%o5` = `0x5a5a5a5a`; `%sp` = `~%o5` = `0xa5a5a5a5` (the stack
   pointer is used as a scratch register; it is restored by `restore`).
2. `0x70006178`: `sta (0x5a5a5a5a | orbits),[reg] 4`, `lda [reg] 4`, compare
   `(read & mask)` with `((0x5a5a5a5a & mask) | orbits)`.
3. `0x7000619c`: same with `0xa5a5a5a5`.
4. `0x700061bc`-`0x700061e8`: walking loop: pattern `%o5`, then
   `%o5 += %o5` (shift left by one) until it becomes 0 — 31 patterns
   `0x5a5a5a5a << k`, k = 0..30, each written, read and compared as above.
5. Failure (`0x70006200`): "ERROR  : Address= %1, exp= %2, obs= %3, xor= %4"
   with %1 = the ASI-4 VA, %2 = expected, %3 = observed (masked), %4 = xor,
   then "WARNING: Suspect Swift Module"; returns 0xff.

| # | Name printed | ASI 4 VA | Mask (implemented bits) | Forced bits | Register |
|---|---|---|---|---|---|
| 1 | MMU Context Table Reg Test | `0x100` | `0x00ffffc0` | 0 | context table pointer |
| 2 | MMU Context Register Test | `0x200` | `0x000000ff` | 0 | context (8 bits) |
| 3 | MMU TLB Replace Ctrl Reg Tst | `0x1000` | `0x0011ffff` | `0x40` | TLB replacement control |
| 4 | MMU Sync Fault Stat Reg Test | `0x1300` | `0x00016fff` | 0 | SFSR, diagnostic (writable) alias |
| 5 | MMU Sync Fault Addr Reg Test | `0x1400` | `0xffffffff` | 0 | SFAR, diagnostic alias |

Under QEMU 8.2.2 all five pass (console shows the five names and no error).

### 3.2 MMU TLB RAM / CAM / LCAM NTA tests — `post_mmu_tlb_nta` @ 0x70005eb8

Three calls of the march routine `nta_march_test(base, len, stride, asi, mask)`
(`0x70009f00`, element sequence in [its own section](#11-shared-routines)):

| Name printed | Call | Range (ASI 6) | Stride | Data mask | TLB part |
|---|---|---|---|---|---|
| MMU TLB RAM NTA Pattern Test | `0x70005ef0` | `0x000-0x0fc` | 4 | `0x07ffffdc` | PTE words of the 64 entries (PPN + C, M, ACC; R and ET not stored) |
| MMU TLB CAM NTA Pattern Test | `0x70005f34` | `0x300-0x3fc` | 4 | `0xffffffff` | upper tag: VA[31:12] tag, context, V, level |
| MMU TLB LCAM NTA Pattern Test | `0x70005f78` | `0x100-0x1fc` | 4 | `0x000003ff` | lower tag: permission / M / IO / PTP bits |

- **Called:** by `post_sequencer` second (`0x70009914`).
- **On failure prints:** `report_nta_error` (`0x7000a6e8`): "ERROR  : Address=
  %1, exp= %2, obs= %3, xor= %4" + "WARNING: Suspect Swift Module"; the POST then
  stops with "Replace CPU Board" (Num Lock LED).
- **Evidence:** QEMU fails the first one with
  `Address= 000000fc, exp= 07ffffdc, obs= 00000000` — the first read of the
  descending element; QEMU has no TLB diagnostic access.

The ASI 6 layout (PTE at `0x000+4n`, lower tag at `0x100+4n`, upper tag at
`0x300+4n`, n = 0..63) is inferred from these masks, from `tlb_init_clear`
(which zeroes `0x000-0x1fc` and `0x300-0x3fc`) and from the watchdog path's
TLB loads; the manual's Table 41 did not survive text extraction.

### 3.3 Unused MMU group — `post_mmu_group` @ 0x70005e80

Calls `post_mmu_regs` then `post_mmu_tlb_nta`; nothing calls it. The names
"MMU Data Pointer Reg Test" and "MMU Index Tag Reg Test" have no code.

## 4. IOMMU and bus time-out tests

Called as one group, `post_iommu_group` (`0x700059e0`), from the sequencer at `0x70009928`, right after the MMU tests; any failure → `post_fail_cpu_board`.

### 4.1 IOMMU SBUS Config Regs Test — `post_iommu_regs` @ 0x70005a40
- **Called:** `post_iommu_group` 0x700059e4, the 1st call. The group is called from the sequencer at 0x70009928. This is the 1st of 3 sub-tests in this routine.
- **Tests:** read/write patterns on the SBus slot configuration registers. Because of a loop bug, only SSCR0 (0x10001010) is tested.
- **Algorithm:**
  1. 0x70005a44: print the name if `%g4` bit 1 is set.
  2. 0x70005a64: `%l0` = 0x7000a780, a ROM table of 5 words {0x10001010, 0x10001014, 0x10001018, 0x1000101c, 0x10001020} (SSCR0-4). `%l1` = 5.
  3. 0x70005a70: `lda [%l0] 0x09` (supervisor-instruction ASI, which reads the PROM) loads `%o0` = register address.
  4. 0x70005a80: call `iommu_reg_walk_test(%o0=reg, %o1=0x00010003 writable mask, %o2=0 fixed bits, %o3=0x10000000 "other" register)`. The mask covers SA30 (bit 16), BA8 (bit 1) and BY (bit 0) [MS2 §5.7.7]. If it returns 0xff, set `%g3`=1 and exit (0x70005a8c).
  5. 0x70005a94..0x70005a9c: `%l0`+=4, `subcc %l1,1`, then **`be`** back to step 3. `%l1` goes 5→4, which is not zero, so the loop never repeats. SSCR1-4 are never touched (ROM bug; it should be `bne`).
  6. `iommu_reg_walk_test` 0x70005b38, with P = 0x5a5a5a5a and Q = ~P = 0xa5a5a5a5:
     - 0x70005b64/68: word P → reg, word Q → other, read reg (0x70005b6c). Compare with `(P & mask) | fixed`.
     - 0x70005b84/88/8c: the same with Q → reg and P → other.
     - Loop at 0x70005ba4: for k = 0..30, word (P<<k) → reg, word R → other (R alternates 0xa5a5a5a5 / 0x5a5a5a5a), read reg, compare with `((P<<k) & mask) | fixed`. It exits when the shifted value becomes 0 (0x70005bc4 `addcc %l2,%l2`, 31 iterations).
     - The "other" register here is the IOMMU control register. So this test also toggles the IOMMU ME (enable) bit and RANGE; no DVMA is active.
- **Pass criteria / expected values:** SSCR0 reads back `(written & 0x00010003)`. After P the first check expects **0x00000002**, after Q it expects **0x00010001**. All other bits read 0.
- **On failure prints:** `L_70005e3c`: `ERROR  : Address= %1, exp= %2, obs= %3, xor= %4` with %1=register (0x10001010), %2=expected `%l5`, %3=observed `%l4`, %4=xor `%l7`. Then `WARNING: Suspect Swift Module`. No UNUMBER. The routine returns 1 and the group returns 0xff.

### 4.2 IOMMU Control Reg Test — `post_iommu_regs` @ 0x70005aa4
- **Called:** the 2nd part of `post_iommu_regs`, reached by fall-through.
- **Tests:** the writable bits and the fixed IMPL/VER field of the IOMMU control register (IOCR) 0x10000000.
- **Algorithm:**
  1. 0x70005aa4: print the name if verbose.
  2. 0x70005ad4: `iommu_reg_walk_test(reg=0x10000000, mask=0x1d, fixed=0x04000000, other=0x10000004 IBAR)`. The patterns are the same as in the SSCR test. The mask covers RANGE (bits 4:2) and ME (bit 0). The fixed value is IMPL=0 (bits 31:28) and VER=4 (bits 27:24) [MS2 §5.7.1].
  3. 0x70005ae0: if 0xff comes back, set `%g3`=1 and return.
- **Pass criteria / expected values:** the read value equals `(written & 0x1d) | 0x04000000`. After P it expects **0x04000018**, after Q **0x04000005**. Bit 1 and bits 23:5 must read 0.
- **On failure prints:** the same as above (`L_70005e3c`, Address=0x10000000, then `WARNING: Suspect Swift Module`).

### 4.3 IOMMU Base Address Reg Test — `post_iommu_regs` @ 0x70005ae8
- **Called:** the 3rd part of `post_iommu_regs`.
- **Tests:** the implemented bits of the IOMMU base address register (IBAR) 0x10000004.
- **Algorithm:**
  1. 0x70005ae8: print the name if verbose.
  2. 0x70005b18: `iommu_reg_walk_test(reg=0x10000004, mask=0x07fffc00, fixed=0, other=0x10000000 IOCR)`. The mask is IBA[30:14] in bits 26:10. Bits 31:27 and 9:0 are unimplemented and read 0 [MS2 §5.7.2].
  3. 0x70005b24: if 0xff comes back, set `%g3`=1. 0x70005b2c: return `%i0`=`%g3`.
- **Pass criteria / expected values:** the read value equals `written & 0x07fffc00`. After P it expects **0x025a5800**, after Q **0x05a5a400**.
- **On failure prints:** `L_70005e3c` with Address=0x10000004, then `WARNING: Suspect Swift Module`.

### 4.4 IOMMU TLB Flush Entry Test — `post_iommu_tlb_flush` @ 0x70005be0
- **Called:** `post_iommu_group` 0x700059f8, the 2nd call. It runs only if `post_iommu_regs` passed.
- **Tests:** that a write to the IOMMU address flush register (0x10000018) invalidates exactly the TLB entry that matches. microSPARC-II has one 64-entry TLB shared by CPU and IOMMU; the test sees it through ASI 6 diagnostic accesses.
- **Algorithm:**
  1. 0x70005be4: print the name if verbose. 0x70005c04: `clr %g3`, then a checkpoint.
  2. 0x70005c14: `iommu_tlb_fill` 0x70005cfc. For i = 0x40 down to 1 (entry k = 0x40-i, offset 4k), three ASI-6 word stores:
     - `[0x000+4k]` ← `0xe0000000 | (i<<8)` (0x70005d24). This is the PTE: level=111 and PPN=i (field meaning from [MS2] Fig 5.8, guess).
     - `[0x300+4k]` ← `(i<<12) | 8` (0x70005d28). This is the upper tag: VA tag = page i, context 0, V = bit 3 (layout from [MS2] Fig 5.35, guess).
     - `[0x100+4k]` ← `0x1b4` (0x70005d34). This is the lower tag with permissions and IO flag (guess).
  3. 0x70005c24: `sta 1 → 0x10000000` (IOCR ME=1, RANGE=0).
  4. Loop at 0x70005c38, i from 0x40 down to 1:
     - 0x70005c3c: word `i<<12` → **0x10000018** (address flush).
     - 0x70005c40: call `iommu_tlb_check(i)` 0x70005d54. It reads all 64 upper tags `ASI6 [0x300+4k]` (0x70005d60). The entry with tag i must have bit 3 **clear**; every other entry must have bit 3 **set** (0x70005d70-0x70005d90).
     - 0x70005c54..0x70005c60: read `ASI6 [0x300+4k]`, OR in 8 to make the flushed entry valid again, write it back, read it again.
  5. 0x70005c78: `sta 0 → 0x10000000` (IOMMU disabled). Then fall through to Flush All.
- **Pass criteria / expected values:** after flushing VA page i, only the matching tag loses V (bit 3); all 63 others keep it.
- **On failure prints:**
  - `L_70005df4`: `ERROR  : Address= %1, exp= %2, obs= %3, xor= %4` with %1=ASI-6 address `%l4` (0x300..0x3fc), %2=expected tag (observed with bit 3 cleared or set as required), %3=observed tag, %4=xor. Then `UNUMBER: U0103`.
  - The routine returns `%g3`=1. On this path the IOMMU is left enabled.

### 4.5 IOMMU TLB Flush All Test — `post_iommu_tlb_flush` @ 0x70005c80
- **Called:** the 2nd part of `post_iommu_tlb_flush`, reached by fall-through.
- **Tests:** that a write to 0x10000014 invalidates all 64 IOPTE TLB entries.
- **Algorithm:**
  1. 0x70005c80: print the name if verbose. 0x70005ca0: `clr %g3`, then a checkpoint.
  2. 0x70005cb0: `iommu_tlb_fill` again (as above).
  3. 0x70005cc0: `sta 0 → 0x10000014` (flush all). The IOMMU is disabled at this point.
  4. Loop at 0x70005ccc: for all 64 entries, read `ASI6 [0x300+4k]`. Bit 3 must be clear (0x70005cd4).
- **Pass criteria / expected values:** every upper tag has V (bit 3) = 0.
- **On failure prints:** `L_70005dac`: `ERROR  : Address= %1, ...` with %1=ASI-6 address `%l5`, %2=observed with bit 3 cleared, %3=observed, %4=xor. Then `UNUMBER: U0103`. Returns 0xff.

### 4.6 SBus Read Timeout Test — `post_sbus_read_timeout` @ 0x70006360
- **Called:** `post_iommu_group` 0x70005a0c, the 3rd call.
- **Tests:** that a CPU read from an SBus address with no device times out as a data-access-error trap, with SFAR and SFSR set correctly.
- **Algorithm:**
  1. 0x70006364: print the name if verbose. 0x70006384: `clr %g3`.
  2. 0x700063a0 / 0x700063a4: word 0xf05dff80 → 0x71e1000c (system mask **set**), then → 0x71e10008 (system mask **clear**). The net effect is that the sources MA, ME, I, M, FL, VI, T, SC, E, S, K and SBus<7:1> are unmasked [S4M §5.7.3].
  3. 0x700063b0-0x700063b8: read MID 0x10002000, OR in 0x001f0000 (SBAE[4:0], arbitration enable for SBus slots 0-4 [MS2 §5.7.10]), write it back. Then a checkpoint.
  4. 0x700063c8: `%g5` = **0x29** (data_access_error). 0x700063d0: `lda [0x7cc00000]` into `%g0`. This is an unused offset in slot 5, so there is no acknowledge and the read times out.
  5. Handler `trap_data_access_error` 0x70001220: tt must equal `%g5`, otherwise `report_sync_trap`. It then clears `%g5` and returns past the load (`jmp %l2; rett %l2+4`). The `%g7`==0x96 path is not used here.
  6. 0x700063d4: `%g5` must now be 0, otherwise `L_70006528`.
  7. 0x700063e8: `lda [0x400] ASI 4` (SFAR) must equal **0x7cc00000**.
  8. 0x70006400: `lda [0x300] ASI 4` (SFSR; this read clears it). Mask off L (bits 9:8) and AT (bits 7:5). The result must equal **0x816**: TO (bit 11) | FT=5 "access bus error" (bits 4:2) | FAV (bit 1) [MS2 §5.6.4].
  9. 0x7000641c: read SFSR again; it must be **0** (cleared by the previous read).
  10. Pass path 0x70006434..0x7000646c: return `%g3`. Clear SBAE[4:0] in MID again, then write 0xf05dff80 to mask set, clear, and set again, which leaves all sources masked.
- **Pass criteria / expected values:** the trap is taken, SFAR = 0x7cc00000, `SFSR & ~0x3e0` = 0x816, then SFSR = 0.
- **On failure prints:**
  - No trap: `L_70006528`: `ERROR  : No trap taken, expected %1` with %1=`%g5`=0x29, then `WARNING: Suspect Swift Module`.
  - Wrong SFAR or SFSR: `L_70006478`: `ERROR  : Address= %1, exp= %2, obs= %3, xor= %4` with %1=ASI-4 address (0x400 or 0x300), %2=expected, %3=observed, %4=xor. Then `UNUMBER: U0103` and `WARNING: Suspect Swift Module`.
  - Both paths return 0xff without restoring MID or the interrupt mask.

### 4.7 EBus Read Timeout Test — `post_ebus_read_timeout` @ 0x70006240
- **Called:** `post_iommu_group` 0x70005a20, the 4th and last call.
- **Tests:** that a read from an unused EBus (on-board I/O) address traps with a bus-error status.
- **Algorithm:** identical to the SBus test, except:
  - The address is 0x71400300 (floppy 82077 base + 0x300; `lda` at 0x700062b4).
  - SFAR must be **0x71400300** (0x700062d0).
  - `SFSR & ~0x3e0` must be **0x416** (0x700062e8): BE (bit 10) | FT=5 | FAV. So the EBus returns an error acknowledge rather than timing out.
  - The steps are at 0x70006280/84 (mask set/clear), 0x70006290-98 (SBAE), 0x700062a8 (`%g5`=0x29), 0x70006304 (SFSR must be 0), and the pass path 0x7000631c..0x70006354.
- **Pass criteria / expected values:** the trap is taken, SFAR = 0x71400300, `SFSR & ~0x3e0` = 0x416, then SFSR = 0.
- **On failure prints:** as for the SBus test (`L_70006528` or `L_70006478`, `UNUMBER: U0103`, `WARNING: Suspect Swift Module`).

## 5. Cache tests

All four run with the caches **disabled** (PCR IE=DE=0 after reset) and access
the arrays only through the diagnostic ASIs. Each first and last calls
`dcache_clear_tags` (`0x7000ac34`: `sta %g0,[16·n] 0xe`, n = 0..511) or
`icache_clear_tags` (`0x7000ac10`: `sta %g0,[32·n] 0xc`, n = 0..511).

| Name printed | Label @ addr | `nta_march_test` args | Array |
|---|---|---|---|
| D-Cache RAM NTA Test | `post_dcache_ram_nta` @ 0x70004f9c | base 0, len `0x2000`, stride 4, ASI `0xf`, mask `0xffffffff` | 8 KiB D-cache data |
| D-Cache TAG NTA Test | `post_dcache_tag_nta` @ 0x70005000 | base 0, len `0x2000`, stride `0x10`, ASI `0xe`, mask `0xffffefff` (bit 12 not stored) | 512 D-cache tags (16-byte lines) |
| I-Cache RAM NTA Test | `post_icache_ram_nta` @ 0x7000516c | base 0, len `0x4000`, stride 4, ASI `0xd`, mask `0xffffffff` | 16 KiB I-cache data |
| I-Cache TAG NTA Test | `post_icache_tag_nta` @ 0x700051d0 | base 0, len `0x4000`, stride `0x20`, ASI `0xc`, mask `0xffffcfff` (bits 13:12 not stored) | 512 I-cache tags (32-byte lines) |

- **Called:** `post_sequencer` `0x7000994c` (D RAM), `0x70009960` (D TAG),
  `0x70009984` (I RAM), `0x70009998` (I TAG), between Caps Lock LED toggles.
- **On failure:** `report_nta_error` as above → "Replace CPU Board".

Unused (no callers):

- "D-Cache FLASH Clear Test" `post_dcache_flash_clear` @ 0x70004ed8: write 1
  to every D-cache tag (`0x70004f24`, 16-byte steps up to `0x2000`), call
  `dcache_clear_tags`, then check tag bit 0 = 0 for every line. It is a
  software clear, not a flash-clear ASI.
- `post_icache_flash_clear` @ 0x700050b8: the same for the I-cache (32-byte
  steps up to `0x4000`), but it prints **"MMU TLB RAM NTA Pattern Test"** (wrong
  string pointer at `0x700050cc`).
- `post_dcache_group` @ 0x70004ea0, `post_icache_group` @ 0x70005080: wrappers.

## 6. Memory

### 6.1 Memory Address Pattern Test (inline in `post_sequencer`) @ 0x700099bc-0x70009a50
- **Called:** inline in the sequencer, after the I-cache tests and LED 0x08, before the FPU tests.
- **Tests:** address-in-address on the top 64 KB of the highest populated bank and on the first 20 KB of the lowest populated bank.
- **Algorithm:**
  1. 0x700099bc: title (verbose only). 0x700099d8: `mem_find_test_bank` returns %o0 = base of the highest populated bank and %o1 = its size in bytes, or %o0 = -1.
  2. If %o0 = -1 (0x700099e0): print "\r\n\tWARNING: No Memory Detected !!!\r\n" (always, not only in verbose mode) and go to `post_fail_simm`.
  3. 0x70009a04-0x70009a20: `mem_march_test(base | (size-0x10000), 0x10000, 4, 0xffffffff, 4)`.
  4. 0x70009a30-0x70009a48: `mem_march_test(%g2 & 0x0f000000, 0x5000, 4, 0xffffffff, 4)`. This is the lowest populated bank, and the region contains the POST stack area at +0x000..+0xc00.
  5. Either failure goes to `post_fail_simm`.
- **`mem_march_test` 0x7000a55c** (args: %i0 base, %i1 length, %i2 stride, %i3 data mask, %i4 = "print U-number" flag). Word accesses, ASI 0x20:
  - E0 ⇑ 0x7000a588: write each word's own address.
  - E1 ⇑ 0x7000a5b4: read; exp (addr & mask). Write ~addr.
  - E2 ⇓ 0x7000a5f4 (from end-stride down to base, signed `bge`): read; exp (~addr & mask).
  - Returns %g3 (0 on pass).
- **Pass criteria / expected values:** every word reads back its address, then its complement.
- **On failure prints:** `L_7000a724`: "ERROR  : Address= %1,  exp= %2, obs= %3, xor= %4" (string 0x70007a8c, two spaces before "exp"). %1 = address, %2 = exp & mask, %3 = obs & mask, %4 = xor. %i4 ≠ 0 (the sequencer passes 4), so `print_simm_unumber(address)` follows: "UNUMBER: " + the entry at 0x7000a9ce + ((addr & 0x0e000000) >> 21) + (addr & 4 ? 8 : 0). Bank 0..7 prints U0300, U0301, U0302, U0303, U0400, U0401, U0402, U0403; even and odd words give the same string. Returns 0xff. The sequencer then shows the SIMM LED and "FAILED ... Replace (%s) SIMM" (no argument for %s is prepared at the call site; guess: filled in later by the firmware).
- **`mem_march_test_b` 0x7000a634:** never called. It is an address-line pair test: write 0xaaaaaaaa at base|a|b and 0x55555555 at base|a, base|b and base, then check base|a|b. a starts at 8, b at 0x10, both walk up to the size in %i1. Word offsets 0 and 4 (%i2). On failure it sets %g3 = 1 and returns **without** setting %i0 (0x7000a760).

### 6.2 Memory sizing — `mem_size_banks` @ 0x7000769c, `mem_probe_bank` @ 0x700075e0, `mem_size_to_code` @ 0x7000780c
- **Called:** `mem_size_banks` only from `post_main` 0x70002188. `mem_probe_bank` only from 0x700076cc. `mem_size_to_code` only from 0x70007708.
- **Tables:** 0x70007844 lists the 8 bank bases 0x0, 0x2000000, …, 0xe000000; **it is unreferenced**, because the code adds 0x2000000 itself. 0x70007864 holds the probe offsets 0x02000000, 0x01000000, 0x00800000, 0x00400000, 0x00200000, 0x00100000, then the terminator 0x20 (and 0). 0x70007880 is the size-code → bytes table: [0]=0, [1]=0x100000, [2]=0x200000, [3]=0x400000, [4]=0x800000, [5]=0x1000000, [6]=0x2000000, [7]=0.
- **`mem_probe_bank(base)`:**
  1. Write 0x02000000 at [base] and [base+4] (0x700075f8).
  2. For each following offset o (0x1000000 … 0x100000, 0x20), write o at [base|o] and [base|o+4] (0x70007600-0x7000761c).
  3. On a SIMM of size S, every o ≥ S aliases back to base, and the last such write is o = S. So [base] = [base+4] = S. The last value put on the bus is 0x20, so an empty bank that echoes the bus reads 0x20.
  4. Compare [base] with [base+4] (0x70007630-0x7000763c).
     - Equal, and [base] is a table size: return that size in bytes.
     - Equal otherwise, including 0x20: return **0xff** (empty).
     - Unequal, and [base] is not a size: return **1**.
     - Unequal, and [base] is a size: return **2**.
- **`mem_size_to_code(bytes)`:** 0x2000000→6, 0x1000000→5, 0x800000→4, 0x400000→3, 0x200000→2, 0x100000→1, anything else →0. The result is in %i1.
- **`mem_size_banks`:** %g2 = 0x80000000 (0x700076ac). For bank n = 0..7 at base n·0x2000000, call `mem_probe_bank`. Results 0xff, 1 and 2 are all skipped as "no bank"; a faulty bank is not reported. Otherwise:
  - %g2 |= 0x40000000.
  - %g2 |= code << 3n (0x70007710-0x70007714).
  - %g2 &= ~0x80000000.
  - For the first bank found: %g2 |= base (0x70007734), and remember the shifted code and n.
  - Returns %o0 = %g2 & 0x0f000000, %o1 = the first bank's shifted code, %o2 = the first bank's index. post_main ignores all three.
- **%g2 layout:**

  | Bits | Meaning |
  |---|---|
  | 31 | 1 = no bank found (set at start, cleared when the first bank is found) |
  | 30 | 1 = at least one bank found |
  | 29:28 | 0 |
  | 27:24 | base address bits of the **lowest** populated bank (= index·0x2000000, so bits 27:25; bit 24 always 0) |
  | 23:0 | eight 3-bit size codes, bank n in bits [3n+2:3n]: 0 empty or bad, 1 = 1 MB, 2 = 2 MB, 3 = 4 MB, 4 = 8 MB, 5 = 16 MB, 6 = 32 MB (7 unused) |

- **`mem_find_test_bank` @ 0x70007774:** scans the size codes from bank 7 down to 0 (mask 0x00e00000 >> 3 per step). It returns the **highest** populated bank: %o0 = n·0x2000000 and %o1 = table_0x70007880[code]. It returns %o0 = -1 if bit 30 is clear or all codes are 0.
- **POST stack (post_main 0x70002140-0x700021b4):** first PSR = 0x10e0 (EF, S, PS, ET, PIL 0, CWP 0), TBR = 0x70000000, WIM = 2, %g0-%g7 cleared, then `mem_size_banks`. If %g2 & 0x40000000 is set, %sp = (%g2 & 0x0f000000) | 0xc00; otherwise %sp = 0xc00 (0x70002190-0x700021b4). So the stack is lowest-bank base + 0xc00, growing down. The window-overflow handler (0x70001104) spills to [%sp] with ASI 0x20, so this must be real RAM. %fp is not set.

## 7. FPU tests

Scratch memory: `%l0`/`%l4` = `base + 0x2000` where base = `%g2 & 0x0f000000`
(first populated SIMM bank). The FPU is enabled by PSR.EF=1 (`post_main`).

### 7.1 FPU Register File Test — `post_fpu_regfile` @ 0x700023c0

- **Called:** `post_fpu_basic_group` (`0x70002264`) ← `post_sequencer` `0x70009a68`.
- **Algorithm:**
  1. `0x70002418`-`0x7000244c`: pattern table at `base+0x2000`: 64-bit
     `0xffffffff_ffffffff`, `0x55555555_55555555`, `0xaaaaaaaa_aaaaaaaa`,
     `0x00000000_00000000`.
  2. For `%l1` = 0, 8, 0x10, 0x18 (`0x7000269c`): `ldd [base+0x2000+%l1]` into
     all sixteen pairs `%f0`…`%f30` and into `%l2/%l3`.
  3. For each pair: `std %fN,[base+0x2100]`, `ldd` into `%l6/%l7`, compare both
     words with `%l2/%l3` (`0x70002498`…`0x70002690`).
- **Pass:** every register pair reads back the pattern.
- **On failure** (`fpu_regfile_fail` `0x7000366c`): "ERROR  : FPU Registerfile
  Stuck-at Fault", then sixteen lines "%1 :  %2  %3" (register number
  0,2,…,0x1e and its two words), "WARNING: Suspect Swift Module".

### 7.2 FPU Misaligned Reg Pair Test — `post_fpu_misaligned_pair` @ 0x700026b8

- **Called:** `post_fpu_basic_group` (`0x70002278`).
- **Tests:** that `ldd` into an **odd** FP register behaves as the even pair
  (microSPARC-II ignores rd bit 0 for LDDF).
- **Algorithm:** store `0x01234567`, `0xfedcba98` at `base+0x2000`
  (`0x7000270c`); `ldd [..],%f1` (encoding rd=1, `0x70002710`); `ldd [..],%f2`;
  `std %f0` → `%l4/%l5`, `std %f2` → `%l6/%l7`; `fcmps %f0,%f2` must be equal;
  `fmovs %f1,%f0 ; fmovs %f3,%f2 ; fcmps %f0,%f2` must be equal.
- **Pass:** `%f0`=`0x01234567`, `%f1`=`0xfedcba98` after `ldd …,%f1`.
- **On failure** (`fpu_sp_op_fail` `0x70003818`): "ERROR  : FPU Single-precision
  Op, exp= %1, obs= %2" (%1 = `%f0` image, %2 = `%f2` image), "Suspect Swift".

### 7.3 FPU Single-precision Tests — `post_fpu_single` @ 0x70002770

- **Called:** `post_fpu_basic_group` (`0x7000228c`).
- **Algorithm:** operands are loaded with `st`/`ld` through `base+0x2000`;
  **every result must equal 25.0** (`%f0` = `0x41c80000`):

  | Op (addr) | Operation | Operands |
  |---|---|---|
  | `0x70002860` | `fdivs %f6,%f7,%f8` | 100.0 (`0x42c80000`) / 4.0 (`0x40800000`) |
  | `0x70002864` | `fadds %f18,%f19,%f20` | 20.0 (`0x41a00000`) + 5.0 (`0x40a00000`) |
  | `0x7000286c` | `fmuls %f12,%f13,%f14` | 5.0 × 5.0 |
  | `0x70002870` | `fsubs %f24,%f25,%f26` | 30.0 (`0x41f00000`) − 5.0 |
  | `0x70002878` | `fdivs %f9,%f10,%f11` | 200.0 (`0x43480000`) / 8.0 (`0x41000000`) |
  | `0x7000287c` | `fadds %f21,%f22,%f23` | 15.0 (`0x41700000`) + 10.0 (`0x41200000`) |
  | `0x70002884` | `fmuls %f15,%f16,%f17` | 1.0 (`0x3f800000`) × 25.0 |
  | `0x70002888` | `fsubs %f27,%f28,%f29` | 50.0 (`0x42480000`) − 25.0 |
  | `0x7000285c`/`0x70002868` | `st %f0` then `ld %f1` (interleaved with the ops) | memory round trip |
  | `0x70002874`/`0x70002880` | `st %f2` then `ld %f3` | memory round trip |

  `fmovs` copies 25.0 into `%f2`, `%f16`, `%f28` and 5.0 into `%f13`, `%f19`,
  `%f25` first. The loads/stores between the FPops check the FPU/IU interlocks.
  Then each result is stored (`st`) and compared with `fcmps %fN,%f0` / `fbne`.
- **On failure:** "ERROR  : FPU Single-precision Op, exp= %1, obs= %2"
  (%1 = `0x41c80000`, %2 = result image), "Suspect Swift".

### 7.4 FPU Double-precision Tests — `post_fpu_double` @ 0x700029bc

- **Called:** `post_fpu_basic_group` (`0x700022a0`).
- **Algorithm:** operands via `std`/`ldd` at `base+0x2000` (low word 0);
  every result must equal **25.0 = `0x40390000_00000000`** (`%f0`):
  `fdivd %f8,%f10,%f12` = 100.0 (`0x40590000`) / 4.0 (`0x40100000`);
  `faddd %f20,%f22,%f24` = 15.0 (`0x402e0000`) + 10.0 (`0x40240000`);
  `fmuld %f14,%f16,%f18` = 5.0 (`0x40140000`) × 5.0; `fsubd %f26,%f28,%f30` =
  30.0 (`0x403e0000`) − 5.0; `%f2` and `%f6` are memory round trips of `%f0`
  and `%f4`. Compared with `fcmpd`.
- **On failure** (`fpu_dp_op_fail` `0x70003848`): "ERROR  : FPU Dbl-Precision
  Op, exp= %1 %2, obs= %3 %4" (%1 %2 = `40390000 00000000`), "Suspect Swift".

### 7.5 FPU exception (CEXC) tests — `post_fpu_cexc_group` @ 0x700022c0

Common frame (e.g. `post_fpu_sp_invalid_cexc` `0x70002b44`-`0x70002c04`):

1. `ld [base+0x2000],%fsr` with `0x0f800000`: **TEM = 0x1f** (all five IEEE
   traps enabled), RD = nearest, NS = 0.
2. Load the operands, `clr [base+0x2000]` (the result slot).
3. `mov 8,%g5` (expect `fp_exception`, tt 0x08), execute the FPop.
4. `st %f3,[base+0x2000]` (or `std %f4`): the **deferred fp_exception is taken
   on this FP store**; `trap_fp_exception` drains the FQ and resumes after the
   store, so the store must not happen.
5. `%g5` must be 0 ("ERROR  : No trap taken, expected %1", `fpu_no_trap_fail`).
6. The result slot must still be 0 ("ERROR  : FPU Exception Didn't Block
   Store, addr= %1, exp= %2, obs= %3, xor= %4", `fpu_store_not_blocked_fail`;
   for doubles both words are checked).
7. `st %fsr` → the **cexc bit** of the exception must be set ("ERROR  : FPU
   Status Register, exp= %1, obs= %2, xor= %3", `fpu_fsr_fail`; exp = obs | bit).

| Name printed | Label @ addr | Operation (addr) | Operands | Expected cexc | Called |
|---|---|---|---|---|---|
| FPU SP Invalid CEXC Test | `post_fpu_sp_invalid_cexc` @ 0x70002b44 | `fadds %f1,%f2,%f3` (`0x70002bb4`) | +∞ `0x7f800000` + −∞ `0xff800000` | NV `0x10` | yes (1st) |
| FPU SP Overflow CEXC Test | `post_fpu_sp_overflow_cexc` @ 0x70002c08 | `fadds %f1,%f1,%f3` (`0x70002c70`) | `0x7f7fffff` (max) × 2 | OF `0x08` | yes |
| FPU SP Underflow CEXC Test | `post_fpu_sp_underflow_cexc` @ 0x70002cc4 | `fmuls %f1,%f1,%f3` (`0x70002d28`) | `0x00800000` (min normal)² | UF `0x04` | **no** |
| FPU SP Divide-by-0 CEXC Test | `post_fpu_sp_divzero_cexc` @ 0x70002d7c | `fdivs %f1,%f2,%f3` (`0x70002de4`) | 25.0 / 0.0 | DZ `0x02` | yes |
| FPU SP Inexact CEXC Test | `post_fpu_sp_inexact_cexc` @ 0x70002e38 | `fadds %f1,%f2,%f3` (`0x70002eac`) | `0x3f7fffff` + `0x34004000` | NX `0x01` | yes |
| FPU SP Trap Priority >  Test | `post_fpu_sp_trap_prio_gt` @ 0x70002f00 | `fdivs` 25.0/0.0, then `st %f3,[base+0x2100]` (aligned) | | fp_exception taken on the store; DZ | yes |
| FPU SP Trap Priority <  Test | `post_fpu_sp_trap_prio_lt` @ 0x70002fb4 | `fdivs` 25.0/0.0, then `st %f3,[base+0x2002]` (**misaligned**) with `%g5`=7, then `st %f3,[base+0x2000]` with `%g5`=8 | | first `mem_address_not_aligned` (tt 7), the fp_exception stays pending and is taken on the next FP store; slot stays 0; DZ | yes |
| FPU DP Invalid CEXC Test | `post_fpu_dp_invalid_cexc` @ 0x70003088 | `faddd %f0,%f2,%f4` (`0x70003100`) | +∞ `0x7ff00000_0` + −∞ `0xfff00000_0` | NV | yes |
| FPU DP Overflow CEXC Test | `post_fpu_dp_overflow_cexc` @ 0x70003164 | `faddd %f0,%f0,%f4` | `0x7fefffff_ffffffff` × 2 | OF | yes |
| FPU DP Underflow CEXC Test | `post_fpu_dp_underflow_cexc` @ 0x7000323c | `fmuld %f0,%f0,%f4` | `0x00100000_00000000`² | UF | **no** |
| FPU DP Divide-by-0 CEXC Test | `post_fpu_dp_divzero_cexc` @ 0x7000330c | `fdivd %f0,%f2,%f4` | 25.0 / 0.0 | DZ | yes |
| FPU DP Inexact CEXC Test | `post_fpu_dp_inexact_cexc` @ 0x700033e0 | `faddd %f0,%f2,%f4` | `0x3fefffff_ffffffff` + `0x3cb00800_00000000` | NX | yes |
| FPU DP Trap Priority >  Test | `post_fpu_dp_trap_prio_gt` @ 0x700034c4 | `fdivd` 25/0, `std %f4,[base+0x2100]` | | fp_exception; DZ | yes |
| FPU DP Trap Priority <  Test | `post_fpu_dp_trap_prio_lt` @ 0x70003580 | `fdivd` 25/0, `std %f4,[base+0x2004]` (misaligned, `%g5`=7) then aligned `std` (`%g5`=8) | | tt 7 first, then tt 8; DZ | yes |

The group runs them in the order SP invalid, overflow, div-0, inexact,
prio >, prio <, DP invalid, overflow, div-0, inexact, prio >, prio <
(`0x700022c4`-`0x700023a0`); it stops at the first failure. The two underflow
tests exist but are not called.

The V8 trap priorities say `mem_address_not_aligned` (priority 10) beats
`fp_exception` (11); the "<" tests check exactly that, plus that the pending
FP exception survives the alignment trap.


`trap_fp_exception` (`0x70001eb0`) stores the FSR to the **absolute** address
`0x2100` and the FQ to `0x2108` (not base-relative), so these tests need RAM
at physical 0.

### 7.6 FPU tests not present

"FPU Register-file" (a status dump format), and nothing else: this POST has
no FSR register test and no `fsqrt`, conversion (`fitos`, `fstod` …) or
compare-exception test.

## 8. Interrupt and timer tests

### 8.1 Interrupt handlers used by these tests (trap_irq01..trap_irq15)

Common prologue (for example 0x700012ac-0x700012e4): tt = (TBR >> 4) & 0xff. If
tt == %g5, clear %g5. Otherwise, if tt == %g6, clear %g6. Otherwise go to
`report_async_trap` 0x70001f1c. That routine reads and clears the SBus AFSR
(0x10001000) and AFAR (0x10001004), prints "ERROR : Async Trap, PSR =%1, PC =%2,
TBR= %3", then the AFSR and AFAR lines, then calls `post_exit_soft_reset(2, "…Replace CPU
Board")`, which is fatal. Handlers return with `wr %l0,%psr ; jmp %l1 ; rett %l2`, so the
interrupted instruction runs again. `trap_irq10` first tests %g1 (0x70001918), and when
%g1 ≠ 0 it takes the LED-blink path before the prologue.

| Handler | tt | Clear-pending write (0x71e00004) | %g7-dependent part |
|---|---|---|---|
| irq01 0x700012ac | 0x11 | 0x00020000, always | — |
| irq02 0x70001318 | 0x12 | 0x00040000, always | — |
| irq03 0x70001384 | 0x13 | 0x00080000 unless %g7 ∈ {0x400,0x800,0x1000,0x2000,0x4000,0x8000,0x200,2} | parallel-port paths (0x7c800000 / 0x7c800018), not in scope |
| irq04 0x70001534 | 0x14 | 0x00100000 only if %g7 = 0x99 | 0x155/0x166/0x177: DMA2 D_CSR 0x78400000 paths |
| irq05 0x70001648 | 0x15 | 0x00200000, always | — |
| irq06 0x700016b4 | 0x16 | 0x00400000 only if %g7 = 0x99 | 0x199/0x188: DMA2 E_CSR 0x78400010 paths |
| irq07 0x700017c8 | 0x17 | 0x00800000, always | — |
| irq08 0x70001834 | 0x18 | 0x01000000, always | `cmp %g7,0x96 ; bne 0x7000187c` falls through to the same place |
| irq09 0x700018ac | 0x19 | 0x02000000, always | — |
| irq10 0x70001918 | 0x1a | 0x04000000 only if %g7 = 0x99 | 0x69: system-counter L-bit check (unreachable, see §8.7). Any other value: read the system limit twice, set %g5 = 0x1a again, and print a spinner character `\b|` `\b/` `\b-` `\b\` (0x7000799c/9f/a2/a5) as %g7 steps 0x11→0x22→0x33→0x44→0x11 |
| irq11 0x70001adc | 0x1b | 0x08000000, always | — |
| irq12 0x70001b48 | 0x1c | 0x10000000, always | — |
| irq13 0x70001bb4 | 0x1d | 0x20000000, always | — |
| irq14 0x70001c20 | 0x1e | 0x40000000 only if %g7 = 0x99 | 0x69: processor-counter L-bit check (see §8.6) |
| irq15 0x70001d0c | 0x1f | %g7 = 0x99: 0x80008000 (soft 15 plus INT<15>.CLR). Otherwise 0x00008000, then re-read pending and go to `irq15_cant_clear_error` 0x700020cc if bit 15 is still set | when %g7 ∉ {0x98,0x96,0x94}, first mask-set 0xf05dff80 (0x70001da4). %g7 = 0x94 returns past the instruction (`jmp %l2 ; rett %l2+4`, 0x70001e00) |

The error helpers `irq10_limit_bit_error`, `irq14_limit_bit_error` and `irq15_cant_clear_error`
print only when %g3 = 0, and they always set %g3 = 1 (0x70002068, 0x700020c0, 0x700020e8). They
print with `post_printf_nosave` using %i0-%i4. Inside a trap window those registers are the
interrupted routine's %o0-%o4, so the print overwrites them. The limit-bit helpers print
`UNUMBER: ` and then the string at 0x7000a980+0x70 = 0x7000a9f0. That address falls in the
middle of the "U0302" entry, so the output is **"302  "** (see Surprises).

System-interrupt mask value 0xf05dff80 (0x7000532c and others) sets bits 31 MA, 30 ME, 29 I,
28 M, 22 FL, 20 VI, 19 T, 18 SC, 16 E, 15 S, 14 K and 13:7 SBus<7:1> (Sun-4M §5.7.3.2). Bits
27 V, 21 MI, 17 A and 6:0 VME stay unchanged. The ROM always writes it as set → clear → set,
which leaves every source masked.


### 8.2 PROC0 Interrupt Regs Tests — `post_proc0_irq_regs` @ 0x70005240
- **Called:** only by `post_sequencer` at 0x70009ab8. A nonzero return goes to `post_fail_cpu_board_leds` (0x70009ac4).
- **Tests:** processor 0 set-soft and clear-pending pseudo-registers with interrupts masked by PIL.
- **Algorithm:**
  1. 0x70005244: print the title only when %g4 bit 1 is set. 0x70005264: `clr %g3`.
  2. 0x70005274-0x70005288: word read of pending into %l2. exp %l1 = 0 (0x7000527c).
  3. 0x7000528c-0x70005294: %l5 = PSR. Write PSR | 0xf00 (PIL = 15; soft levels 1-14 cannot trap).
  4. 0x700052b0-0x700052cc: `sta 0x7ffe0000` to set-soft (0x7ffe0000 = SOFTINT<14:1>, bits 30:17). Read pending. exp == 0x7ffe0000.
  5. 0x700052e0-0x70005300: `sta 0x7ffe8000` to clear-pending (bits 30:17 plus bit 15 INT<15>.CLR). Read pending. exp 0 (%l1 cleared at 0x700052f8).
  6. 0x70005308: restore PSR. 0x7000531c-0x7000533c: 0xf05dff80 to mask-set, mask-clear, then mask-set. Restore PSR again (0x70005340).
  7. Return %g3 (0x70005350). %g3 is nonzero only if an interrupt handler reported an error.
- **Pass criteria / expected values:** pending = 0 at entry. After the set, pending = 0x7ffe0000 exactly: no hardware bits (15:1) and no soft-15 bit 31. After the clear, pending = 0. Soft level 15 (bit 31) is never set.
- **On failure prints:** at `L_700055f4` (0x700055f4): "ERROR  : Address= %1, exp= %2, obs= %3, xor= %4". %1 = register address (%l0, always 0x71e00000 here), %2 = exp (%l1), %3 = obs (%l2), %4 = exp^obs (%l7). Then "UNUMBER: " and "U1507" (0x7000a990). Returns 0xff. The error path does **not** restore PSR (PIL stays 15) and does not mask the system interrupts again.

### 8.3 Soft Interrupts OFF Test — `post_soft_irq_off` @ 0x7000535c
- **Called:** only by `post_sequencer` at 0x70009acc. Failure goes to `post_fail_cpu_board_leds` (0x70009ad8).
- **Tests:** with PIL = 15, a soft interrupt can be set and cleared one level at a time without trapping.
- **Algorithm:**
  1. 0x70005380: `clr %g3`. 0x70005390: pending, exp 0. 0x700053a8: sys-pending 0x71e10000, exp 0.
  2. 0x700053c0-0x700053c8: PIL = 15 (old PSR in %l5).
  3. 0x700053d8-0x700053e0: %l1 = 0x40000000, %l3 = 0xfffe0000 (loop mask), %l4 = %l1.
  4. Loop at 0x700053ec: `sta %l1` to set-soft. Read pending, exp == %l1 (0x70005404). `sta %l1` to clear-pending (0x70005418). Read pending, exp 0 (%l1 cleared at 0x70005424). Then `srl %l4,1,%l4` (0x70005434). Loop while (%l4 & 0xfffe0000) ≠ 0, with the annulled delay slot `mov %l1,%l4` at 0x70005440.
  5. 0x70005444: restore PSR. Mask set/clear/set 0xf05dff80. Return %g3.
- **Intent vs. actual (ROM bug):** the loop was meant to walk bits 30 down to 17 (soft levels 14→1). The delay-slot instruction at 0x70005440 is `or %g0,%l1,%l4` (word 0xa8100011), which copies %l1 (already 0) into %l4, instead of `mov %l4,%l1`. The actual run is therefore: iteration 1 tests 0x40000000 (level 14 only). Iteration 2 writes and expects 0. Then %l4 = 0 and the loop ends. **Only soft level 14 is exercised.**
- **Pass criteria / expected values:** pending = 0 and sys-pending = 0 at entry. After set-soft 0x40000000, pending == 0x40000000. After clear, pending == 0.
- **On failure prints:** same as §8.2 (`L_700055f4`): Address/exp/obs/xor, "U1507", returns 0xff.

### 8.4 Soft Interrupts ON Test — `post_soft_irq_on` @ 0x70005498
- **Called:** only by `post_sequencer` at 0x70009af0, right after the LED command 0x0e,0x08. Failure goes to `post_fail_cpu_board_leds` (0x70009afc).
- **Tests:** each soft level 1-15 raises an interrupt trap with the matching tt, and the handler can clear it.
- **Algorithm:**
  1. 0x700054bc: `clr %g3`. 0x700054c0-0x700054c8: PSR &= ~0xf00 (PIL = 0; ET is still 1 from post_main's PSR 0x10e0).
  2. 0x700054e4: pending exp 0. 0x700054fc: sys-pending exp 0.
  3. 0x70005514-0x70005524: 0xf05dff80 to **mask-clear** (0x71e10008), which unmasks all system sources for the length of the test.
  4. %l3 = 0x11 (tt), %l6 = 0x00020000 (soft level 1). Loop at 0x70005538: %g5 = %l3 (expected tt), %g7 = 0x99. `sta %l6` to set-soft (0x7000554c). Poll up to 0x100 times until %g5 = 0 (0x70005550-0x70005564). The handler `trap_irqNN` matches tt with %g5, clears %g5, writes 1<<(16+N) to clear-pending (bit 31 plus bit 15 for level 15), reads pending once, and returns.
  5. 0x70005578: pending exp 0. `sll %l6,1` and `%l3++`, then loop while %l6 ≠ 0. This covers bits 17..31, tt 0x11..0x1f (levels 1-15, including level 15).
  6. 0x700055a0: restore PSR. Mask set/clear/set 0xf05dff80. Return %g3.
- **Pass criteria / expected values:** every level traps within 256 poll iterations with tt = 0x10 + level. Pending reads 0 after each handler. %g7 is left at 0x99 on exit and is not cleared.
- **On failure prints:** a pending mismatch goes to `L_700055f4` (Address/exp/obs/xor, "U1507"). A timeout goes to `L_7000563c`: "ERROR  : No interrupt received, expected %1" with %1 = %g5 (0x00000011..0x0000001f), then "UNUMBER: U1507". Both return 0xff. An interrupt with an unexpected tt goes through `report_async_trap`, which is fatal ("Replace CPU Board").

### 8.5 PROC0 User Timer Test — `post_proc0_user_timer` @ 0x700065c0
- **Called:** only by `post_sequencer` at 0x70009b04. Failure goes to `post_fail_cpu_board_leds` (0x70009b10).
- **Tests:** the timer configuration register, the user-timer start/stop register, the 64-bit user-timer read/write mask, counting, and the L (overflow) bit.
- **Algorithm:** (reset_power_on had already put T0 in user-timer mode and started it; 0x7000bba8-0x7000bbd4)
  1. 0x700065e4: `clr %g3`. 0x700065f4-0x7000660c: write 0 to timer config 0x71d10010, read back, exp 0.
  2. 0x70006620-0x70006634: write 0xffffffff to config, exp **1** (only T0 exists on a uniprocessor).
  3. 0x70006648-0x7000664c: config = 1 (T0 = user timer). 0x70006650-0x70006668: write 0 to start/stop 0x71d0000c, exp 0.
  4. 0x7000667c-0x70006690: write 0xffffffff to start/stop, exp **1** (only RUN bit 0).
  5. 0x700066a4: stop (write 0). 0x700066b4: `stda %l4:%l5 = 0:0` to 0x71d00000 (MSW at +0, LSW at +4). `ldda` → %l2 (MSW), %l3 (LSW). exp MSW 0 (0x700066c4) and LSW 0 (0x700066d4).
  6. 0x700066e8-0x70006718: `stda 0xffffffff:0xffffffff`, `ldda`. exp MSW **0x7fffffff** (bit 63 L is not writable) and LSW **0xfffffe00** (bits 8:0 read as 0).
  7. 0x7000672c-0x70006748: start (write 1 to 0x71d0000c), `stda 0:0`. Up to 3 tries (%l7 = 3): `ldda` → %l2:%l3, 5 nops, `ldda` → %l4:%l5. Pass when LSW2 > LSW1, a signed `bg` at 0x70006770.
  8. 0x70006798-0x700067c4: while running, `stda 0x7fffffff:0xffffffff` (the maximum count). After 4 nops, `ldda`: exp MSW bit 31 (L) **set**.
  9. 0x700067d8-0x700067f0: `stda 0x80000000:%l3` (%l3 is the previous LSW). `ldda`: exp MSW bit 31 **clear**, because any write clears L and L is not writable.
  10. 0x700067fc-0x70006804: stop (0 to 0x71d0000c). Config is left at 1. Return %g3.
- **Pass criteria / expected values:** config reads 0 then 1. Start/stop reads 0 then 1. The user timer reads 0:0, then 0x7fffffff:0xfffffe00. The LSW advances across 5 nops (within 3 tries). L is set after overflow from the maximum count and cleared by a write.
- **On failure prints:**
  - Register mismatch at `L_70006a00`: "ERROR  : Address= %1, exp= %2, obs= %3, xor= %4" + "UNUMBER: U1507". %1 is the register address (0x71d10010, 0x71d0000c or 0x71d00000; for LSW checks the printed address is still 0x71d00000 and obs = LSW).
  - Not counting at `L_70006a48`: "ERROR  : Processor User Timer Not Incrementing" + "U1507".
  - L bit at `L_70006a84`: Address/exp/obs/xor + "U1507". Step 8 passes exp 0x80000000, obs = MSW, "xor" = MSW & ~0x80000000 (an `andn`, 0x700067c8). Step 9 passes exp 0, obs = MSW, xor = MSW.
  - Every path returns 0xff.

### 8.6 PROC0 Counter/Timer Test — `post_proc0_counter_timer` @ 0x70006814
- **Called:** only by `post_sequencer` at 0x70009b18. Failure goes to `post_fail_cpu_board_leds` (0x70009b24).
- **Tests:** the processor 0 limit register mask, counting, reset-on-limit-write, limit-without-reset, and the level-14 interrupt with its L-bit semantics.
- **Algorithm:**
  1. 0x70006838: `clr %g3`. 0x70006848-0x70006850: timer config 0x71d10010 = 0 (T0 = counter/timer). Mask set/clear/set 0xf05dff80.
  2. 0x70006878-0x7000688c: write 0 to limit 0x71d00000, read, exp 0.
  3. 0x700068a0-0x700068b8: write 0xffffffff to limit, read, exp **0x7ffffe00** (L bit 31 and bits 8:0 read 0).
  4. 0x700068cc-0x700068f4: read counter 0x71d00004 twice with 5 nops between. exp 2nd > 1st (signed `bg`). One try only.
  5. 0x70006910-0x70006934: write 0x7ffffe00 to limit, which resets the count to 0x200. Read counter → %l3. exp %l3 < **0x40000** (signed `bl`, under 512 ticks since the reset).
  6. 0x70006950-0x7000696c: write 0x7ffffe00 to limit-no-reset 0x71d00008. Read counter → %l4. exp %l4 > %l3 (the count was not reset).
  7. 0x70006988-0x700069a0: %g5 = **0x1e** (expected tt, level 14), %g7 = **0x69**. 0xf05dff80 to mask-clear (unmask all).
  8. 0x700069a4-0x700069c4: poll %g5 up to 0x80000 times. The counter has to count from about 0x200 up to the limit 0x3fffff ticks (about 2.1 s at 500 ns per tick) before L sets and IRL 14 is raised.
  9. Handler `trap_irq14`, %g7 = 0x69 path (0x70001c90): mask-set 0xf05dff80. Read counter 0x71d00004, exp bit 31 (L) set (0x70001cb8). Read limit 0x71d00000, exp L set (0x70001ccc). Read the limit again, exp L **clear**, because the first limit read cleared it (0x70001ce0). Write 0 to the limit (free-run) and read it twice.
  10. 0x700069d0-0x700069f0: mask set/clear/set 0xf05dff80. Return %g3.
- **Pass criteria / expected values:** limit reads 0 and 0x7ffffe00. The counter increments. After a limit write it is < 0x40000. After a limit-no-reset write it keeps increasing. A tt 0x1e trap arrives within 0x80000 polls. The L bit is visible in the counter, visible in the first limit read, and gone on the second limit read.
- **On failure prints:**
  - `L_70006a00`: Address/exp/obs/xor + "U1507" (steps 2 and 3).
  - `L_70006acc`: "ERROR  : Processor Counter Timer Not Incrementing" + "U1507" (steps 4, 5 and 6, including the "not reset" case).
  - `L_70006b44`: mask-set 0xf05dff80, then "ERROR  : No interrupt received, expected %1" with %1 = 0x0000001e, + "U1507".
  - The handler's L-bit errors go to `irq14_limit_bit_error` 0x70002074: "ERROR  : Processor Counter Limit Bit, addr= %1, exp= %2, obs= %3, xor= %4". %1 = 0x71d00004 or 0x71d00000, %2 = 0x80000000 (0 for the third check), %3 = value read, %4 = xor (for the third check, obs & ~0x80000000). Then "UNUMBER: 302  ". It sets %g3 = 1, so the test returns 1.
  - The direct paths return 0xff.

### 8.7 System Counter test — none (dead remnants only)
- **Called:** never. No routine in this ROM tests the system (level-10) counter. The name string "System Counter Test" at 0x7000947e and the message "ERROR  : System Counter Not Incrementing" (0x70008033) have no reference apart from the orphan block below. The byte scan at 0x70000000-0x7003ffff found no `call`, branch or `sethi/or` pair that points at them.
- **Remnants:**
  1. 0x70006b08-0x70006b40: an unlabelled tail after `ret/restore` at 0x70006b00. It prints "System Counter Not Incrementing", then "UNUMBER: U1507", and returns 0xff. Nothing branches to it.
  2. 0x70006b94-0x70006be0: a second unlabelled copy of the "No interrupt received, expected %1" (U1507) tail. Nothing branches to it.
  3. `trap_irq10` %g7 = 0x69 path (0x70001988-0x700019f8): mask-set 0xf05dff80. Read system counter 0x71d10004, exp L (bit 31) set. Read system limit 0x71d10000, exp L set. Read again, exp L clear. Write 0 to the limit. Errors go to `irq10_limit_bit_error` 0x7000201c: "ERROR  : System Counter Limit Bit, addr= %1, exp= %2, obs= %3, xor= %4" + "UNUMBER: 302  ". This path is unreachable: the only code that sets %g7 = 0x69 (0x7000698c) sets %g5 = 0x1e, and no code sets %g5 or %g6 = 0x1a together with %g7 = 0x69.
  4. Uncalled helpers that use the system timer: `sys_timer_irq10_arm` 0x7000ab28 (system limit = 0x00080000, which is 0x400 ticks or 512 µs; %g7 = 0x11, %g5 = 0x1a; mask-clear 0xf05dff80; drives the irq10 spinner), `sys_timer_irq10_disarm` 0x7000ab64, and `sys_timer_limit_irq_setup` 0x7000b860 (system limit = 0x30000000, which is 0x180000 ticks or about 0.79 s; %g1 = 8; mask-clear 0x80080000 = MA+T; drives the irq10 LED-blink path at 0x70001aa0).

## 9. DMA2, LANCE, ESP and parallel-port tests

### 9.0 Shared helpers and the slave-error pattern

**Shared failure routines.** Each one prints the error, then `UNUMBER: `, then a string from the table at `0x7000a980` (`+0` "U0103", `+8` "U1102", `+0x10` "U1507"), and returns `0xff`:
- `dma2_reg_fail` @ 0x70004408: `ERROR  : Address= %1, exp= %2, obs= %3, xor= %4` with %1=`%l0` (register address), %2=`%l3` (expected), %3=`%l4` (observed), %4=`%l7` (xor). Then `UNUMBER: U1102`.
- `dma2_afsr_fail` @ 0x70004450: the same message with %1=`%l0` (0x10001004 AFAR or 0x10001000 AFSR), %2=`%l1`, %3=`%l2`, %4=`%l7`. Then `UNUMBER: U1102`.
- `dma2_slave_err_stuck_fail` @ 0x70007044 (reached from `dma2_d_clear_slave_err` or `dma2_e_clear_slave_err`):
  - It prints `ERROR : Unable to clear Slave Error Bit in CSR `, then `ERROR  : Address= %1 ...`. %1 is the address of the format string, 0x70007a59 (bug, 0x7000705c). %2 is 0x40, %3 is the CSR value read, %4 is the xor.
  - Then it prints `WARNING: Suspect Macio Module` and `UNUMBER: U1102`.
  - It then runs `jmp %g0; restore` (0x700070a0). In boot mode this fetches from the PROM, so the PROM restarts and the routine never returns.
- `pport_reg_fail` @ 0x70004af4: the same fields as `dma2_reg_fail`. `pport_afsr_fail` @ 0x70004b78: %1=`%l0`, %2=`%l2`, %3=`%l3`, %4=`%l7`. `pport_no_irq_fail` @ 0x70004b3c: `ERROR  : No interrupt received, expected %1` with %1=`%g5`. All three print `UNUMBER: U1102`.

**DMA2 helpers** (leaf routines, no `save`):
- `dma2_d_reset` 0x70006fa0: word 0x80 then word 0 to D_CSR 0x78400000.
- `dma2_d_reset_chain` 0x70006fb8: 0x80 to D_CSR, read, then 0x01002000 (D_EN_NEXT bit 24 | D_EN_CNT bit 13) to D_CSR, read.
- `dma2_e_reset` 0x70006fdc: 0x80 then 0 to E_CSR 0x78400010.
- `dma2_d_clear_slave_err` 0x70006ff8 and `dma2_e_clear_slave_err` 0x7000701c: word 0x40 (SLAVE_ERR, write-1-to-clear) to the CSR, read it back. If bit 6 is still set they go to `dma2_slave_err_stuck_fail`.
- `sbus_clear_afsr` 0x7000ba5c: read AFAR 0x10001004, read AFSR 0x10001000, write 0 to AFSR.

**The "slave error" pattern.** Most DMA2, LANCE and BPP tests use it. A byte store to a register that must be accessed as a word (DMA2) or a half (LANCE, BPP) must do three things:
1. Set SLAVE_ERR (bit 6) in that channel's CSR. [S4M] calls it "wrong-sized access".
2. Leave the register itself unchanged.
3. Answer with an SBus error acknowledge. The store is write-buffered, so [MS2] Table p.198 has the SBus controller latch the AFSR and AFAR.

The ROM then expects AFAR = the PA of the store and AFSR = **0x93820000**. That is ERR (bit 31) | BE (bit 28) | SIZ=001, a byte in SBus encoding (bits 27:25) | S (bit 24) | 0x00800000 (bits 23:20, forced to 1000) | FAV (bit 17), with RD = 0 [MS2 §5.7.5, S4M §5.2.1].

[MS2] also says the store raises a level-15 interrupt (the "I", M-to-S write buffer error, source, bit 29 of the system mask). Only `post_dma2_pport_slave_err` expects that interrupt. In all the other tests the system interrupt mask is still set: `post_proc0_counter_timer` ends with set/clear/set of 0xf05dff80 at 0x700069e8-0x700069f0. If the interrupt got through, `trap_irq15` would report `Async Trap` (`report_async_trap`) and POST would fail.

**Groups.** Two group routines exist, but nothing calls either one (no xrefs, no pointer words in the image):
- `post_dma2_misc_group` 0x70003960 calls ID, E_CSR, LANCE address, LANCE data.
- `post_dma2_esp_group` 0x70003990 calls D_CSR, D_ADDR, D_BCNT, D_NADDR, D_NBCNT, D_CHAIN, ESP.

The sequencer (`post_sequencer` 0x700098c0) calls the tests itself. Its order is exactly SS5 service manual Table 3-2:
- `post_iommu_group` at 0x70009928, right after `post_mmu_tlb_nta`. On failure it goes to `post_fail_cpu_board`.
- The DMA2/LANCE/ESP/BPP tests at 0x70009b3c..0x70009c28, after `post_proc0_counter_timer`. On failure each one goes to `post_fail_cpu_board_leds`.

### 9.1 DMA2 ID Register Test — `post_dma2_id_reg` @ 0x700039d8
- **Called:** never. The only caller is `post_dma2_misc_group` 0x70003964, and nothing calls that group.
- **Tests:** the 4-byte read-only ID register at 0x78000000, read as a word, as halves and as bytes. QEMU calls it `idreg`; its contents are fe 81 01 03.
- **Algorithm:**
  1. 0x700039dc: print the name if verbose. 0x700039fc: `clr %g3`.
  2. 0x70003a1c: word read of 0x78000000; expect **0xfe810103**.
  3. 0x70003a38: half read of +0; expect **0xfe81**. 0x70003a68: half read of +2; expect **0x0103**.
  4. Byte reads: 0x70003a90 (+0) expects **0xfe**, 0x70003ab8 (+1) **0x81**, 0x70003ae0 (+2) **0x01**, 0x70003b08 (+3) **0x03**.
  5. 0x70003b28: word write of 0 to 0x78000000. 0x70003b2c: read it back; still **0xfe810103** (read-only).
  6. Checkpoints before each step.
- **Pass criteria / expected values:** as listed.
- **On failure prints:** `dma2_reg_fail`: Address= always 0x78000000, even for the +1/+2/+3 accesses. exp, obs and xor as listed. Then `UNUMBER: U1102`.

### 9.2 DMA2 E_CSR Register Test — `post_dma2_e_csr` @ 0x700042ec
- **Called:** sequencer 0x70009b3c, the first test of the DMA2/LANCE block. Also listed in `post_dma2_misc_group` 0x7000396c, which is never called.
- **Tests:** E_CSR reset and ID bits, and that a byte store to E_CSR sets SLAVE_ERR and is captured in AFSR/AFAR.
- **Algorithm:**
  1. 0x700042f0: print the name if verbose. 0x70004310: `clr %g3`. 0x70004314: `sbus_clear_afsr`. 0x70004328: `dma2_e_reset`.
  2. 0x70004348: `sta 0x80,[0x78400010]` (E_CSR RESET, bit 7 [S4M A.II.6.1.2]). 0x7000434c: read, mask with ~0xc (drop E_DRAINING bits 3:2). Expect **0xa0000080** (ID=0xA in bits 31:28, RESET=1).
  3. 0x70004384: `sta 0,[0x78400010]` (release reset). 0x70004388: `stba 0,[0x78400010]` (byte, wrong size). 0x7000438c: read, mask ~0xc, expect **0xa0000040** (SLAVE_ERR bit 6).
  4. 0x700043a0: `dma2_e_clear_slave_err` (word 0x40; bit 6 must read 0).
  5. 0x700043b8: AFAR 0x10001004 must be **0x78400010**. 0x700043d8: AFSR 0x10001000 must be **0x93820000**.
  6. 0x700043ec: `sta 0` → AFSR. 0x700043f4: `sbus_clear_afsr`. Return `%g3`.
- **Pass criteria / expected values:** 0xa0000080, 0xa0000040, SLAVE_ERR clears, AFAR 0x78400010, AFSR 0x93820000.
- **On failure prints:** `dma2_reg_fail` (Address 0x78400010) or `dma2_afsr_fail` (Address 0x10001004 or 0x10001000), each followed by `UNUMBER: U1102`. A stuck SLAVE_ERR goes to `dma2_slave_err_stuck_fail`, which restarts the PROM.

### 9.3 LANCE Address Port Tests — `post_lance_addr_port` @ 0x70005680
- **Called:** sequencer 0x70009b50. Also listed in `post_dma2_misc_group` 0x70003974, which is never called.
- **Tests:** read/write of the LANCE register address port (RAP), and the slave-error response to a byte access.
- **Algorithm:**
  1. 0x70005684: print the name if verbose. 0x700056a4: `clr %g3`. 0x700056b4: `dma2_e_reset` (resets the LANCE). There is no `sbus_clear_afsr`; the test relies on E_CSR having cleared it.
  2. 0x700056c8: `stha 1,[0x78c00002]` (RAP). 0x700056cc: read it back; expect **0x0001**.
  3. 0x700056dc: `stha 0,[0x78c00002]`. 0x700056e0: read it back; expect **0x0000**.
  4. 0x70005700: `dma2_e_reset`. 0x70005714: `stba 1,[0x78c00002]` (byte to RAP, wrong size).
  5. 0x70005728: word read of E_CSR 0x78400010, unmasked. Expect **0xa0000040**.
  6. 0x70005738: `dma2_e_clear_slave_err`.
  7. 0x70005750: AFAR must be **0x78c00002**. 0x70005770: AFSR must be **0x93820000**.
  8. 0x70005784: `sta 0` → AFSR. Return `%g3`.
- **Pass criteria / expected values:** RAP 1/0 read back; E_CSR 0xa0000040; AFAR 0x78c00002; AFSR 0x93820000.
- **On failure prints:**
  - RAP mismatch: `L_700058ec`: `ERROR  : Address= %1, exp= %2, obs= %3, xor= %4` with %1=0x78c00002, %2=`%l1`, %3=`%l2`, %4=xor. Then `UNUMBER: U1102`.
  - E_CSR mismatch: `L_70005934` prints %1=`%l3`, %2=`%l6`, %3=`%l5`. None of these are set in this routine, so Address, exp and obs are garbage; only xor is correct (bug). Then `UNUMBER: U1102`.
  - AFSR/AFAR mismatch: `L_7000597c` with %1=`%l0`, %2=`%l1`, %3=`%l2`, then `UNUMBER: U1102`.

### 9.4 LANCE Data Port Tests — `post_lance_data_port` @ 0x70005798
- **Called:** sequencer 0x70009b64. Also listed in `post_dma2_misc_group` 0x7000397c, which is never called.
- **Tests:** access to CSR0 and CSR1 through the register data port (RDP), and the slave-error response to a byte access to RDP.
- **Algorithm:**
  1. 0x7000579c: print the name if verbose. 0x700057bc: `clr %g3`. 0x700057cc: `dma2_e_reset`.
  2. 0x700057e0: `stha 0,[0x78c00002]` (RAP=0, select CSR0). 0x700057ec: `stha 4,[0x78c00000]` (CSR0 = STOP). 0x700057f0: read it back; expect **0x0004**.
  3. 0x70005818: `stha 1,[0x78c00002]` (RAP=1, CSR1). 0x70005828: `stha 0xa8a8,[0x78c00000]`. 0x7000582c: read it back; expect **0xa8a8**. CSR1 is IADR[15:0] and bit 0 is 0; it is writable only while STOP is set.
  4. 0x70005848: `dma2_e_reset`. 0x7000585c: RAP=1 (half). 0x7000586c: `stba 0xa8,[0x78c00000]` (byte to RDP, wrong size).
  5. 0x70005880: E_CSR, unmasked; expect **0xa0000040**.
  6. 0x70005890: `dma2_e_clear_slave_err`.
  7. 0x700058a4: AFAR must be **0x78c00000**. 0x700058c4: AFSR must be **0x93820000**.
  8. 0x700058d8: `sta 0` → AFSR. Return `%g3`.
- **Pass criteria / expected values:** CSR0 0x0004, CSR1 0xa8a8, E_CSR 0xa0000040, AFAR 0x78c00000, AFSR 0x93820000.
- **On failure prints:** as in the address-port test. `L_700058ec` for the data values (Address 0x78c00000). `L_70005934` for E_CSR, with the same garbage-register bug. `L_7000597c` for AFSR/AFAR. Each prints `UNUMBER: U1102`.

### 9.5 DMA2 D_CSR Register Test — `post_dma2_d_csr` @ 0x70003b50
- **Called:** sequencer 0x70009b78. Also listed in `post_dma2_esp_group` 0x70003994, which is never called.
- **Tests:** D_CSR (ESP DMA) reset and ID bits, and the slave error from a byte store.
- **Algorithm:**
  1. 0x70003b54: print the name if verbose. 0x70003b74: `clr %g3`. 0x70003b78: `sbus_clear_afsr`. Checkpoint. 0x70003b8c: `dma2_d_reset`.
  2. 0x70003ba4: `sta 0x80,[0x78400000]` (D_CSR RESET, bit 7 [S4M A.II.6.2.2]). 0x70003ba8: read, mask ~0xc (D_DRAINING). Expect **0xa0000080**.
  3. 0x70003bc0: `dma2_d_reset`.
  4. 0x70003be4: `stba 0x80,[0x78400000]` (byte to bits 31:24). 0x70003be8: read, **unmasked**. Expect **0xa0000040**: SLAVE_ERR set, and the byte store did not reset anything.
  5. 0x70003bf8: `dma2_d_clear_slave_err`.
  6. 0x70003c0c: AFAR must be **0x78400000**. 0x70003c2c: AFSR must be **0x93820000**.
  7. 0x70003c40: `sta 0` → AFSR. 0x70003c48: `sbus_clear_afsr`. Return `%g3`.
- **Pass criteria / expected values:** 0xa0000080, then exactly 0xa0000040, AFAR 0x78400000, AFSR 0x93820000.
- **On failure prints:** `dma2_reg_fail` (Address 0x78400000) or `dma2_afsr_fail`, each followed by `UNUMBER: U1102`. A stuck SLAVE_ERR goes to `dma2_slave_err_stuck_fail` (PROM restart).

### 9.6 DMA2 D_ADDR Register Test — `post_dma2_d_addr` @ 0x70003c5c
- **Called:** sequencer 0x70009b8c. Also listed in `post_dma2_esp_group` 0x7000399c, which is never called.
- **Tests:** D_ADDR read/write, the D_A_LOADED status bit, and the slave error from a byte store to D_ADDR.
- **Algorithm:**
  1. 0x70003c60: print the name if verbose. 0x70003c80: `clr %g3`. 0x70003c84: `sbus_clear_afsr`. 0x70003c98: `dma2_d_reset`.
  2. 0x70003cb0: `sta 0x55555555,[0x78400004]`. 0x70003cb4: read it back; expect **0x55555555**.
  3. 0x70003cdc: read D_CSR and mask with 0x0c000000. Expect **0x04000000**: D_A_LOADED (bit 26) set, D_NA_LOADED (bit 27) clear [S4M].
  4. 0x70003cfc: `sta 0,[0x78400004]`. 0x70003d00: read it back; expect **0**.
  5. 0x70003d30: `sta 0x80` → D_CSR. 0x70003d34: read, mask ~0xc, expect **0xa0000080**. So RESET must clear D_A_LOADED.
  6. 0x70003d48: `dma2_d_reset`. 0x70003d78: `stba 0x55,[0x78400004]` (byte). 0x70003d80: D_CSR masked ~0xc; expect **0xa0000040**.
  7. 0x70003d94: `dma2_d_clear_slave_err`. 0x70003dac: AFAR must be **0x78400004**. 0x70003dcc: AFSR must be **0x93820000**.
  8. 0x70003de0: `sta 0` → AFSR. 0x70003de8: `sbus_clear_afsr`.
- **Pass criteria / expected values:** as listed.
- **On failure prints:** `dma2_reg_fail` (Address 0x78400004 or 0x78400000) or `dma2_afsr_fail`, each followed by `UNUMBER: U1102`.

### 9.7 DMA2 D_BCNT Register Test — `post_dma2_d_bcnt` @ 0x70003dfc
- **Called:** sequencer 0x70009bb0. Also listed in `post_dma2_esp_group` 0x700039a4, which is never called.
- **Tests:** read/write of the D_BCNT byte counter with D_EN_CNT set, and the slave error from a byte store.
- **Algorithm:**
  1. 0x70003e00: print the name if verbose. 0x70003e20: `clr %g3`. 0x70003e24: `sbus_clear_afsr`. 0x70003e38: `dma2_d_reset`.
  2. 0x70003e44-0x70003e50: read D_CSR, OR in 0x2000 (D_EN_CNT, bit 13), write it back.
  3. 0x70003e64: `sta 0x00e69f10,[0x78400008]`. 0x70003e68: read it back; expect **0x00e69f10**.
  4. 0x70003e78: `sta 0`. 0x70003e80: read it back; expect **0**.
  5. 0x70003e9c: `dma2_d_reset`. 0x70003eb4: `stba 0x10,[0x78400008]` (byte). 0x70003ec8: D_CSR masked ~0xc; expect **0xa0000040**.
  6. 0x70003edc: `dma2_d_clear_slave_err`. 0x70003ef4: AFAR must be **0x78400008**. 0x70003f14: AFSR must be **0x93820000**.
  7. 0x70003f28: `sta 0` → AFSR. 0x70003f30: `sbus_clear_afsr`.
- **Pass criteria / expected values:** as listed. The test value has bits 31:24 = 0, so the 24-bit limit is not tested.
- **On failure prints:** `dma2_reg_fail` or `dma2_afsr_fail`, each followed by `UNUMBER: U1102`.

### 9.8 DMA2 D_NADDR Register Test — `post_dma2_d_naddr` @ 0x70003f44
- **Called:** sequencer 0x70009bc4. Also listed in `post_dma2_esp_group` 0x700039ac, which is never called.
- **Tests:** the D_ADDR write path with D_EN_NEXT (chaining) enabled, and the slave error in that mode.
- **Algorithm:**
  1. 0x70003f48: print the name if verbose. 0x70003f68: `clr %g3`. 0x70003f6c: `sbus_clear_afsr`.
  2. 0x70003f80: `dma2_d_reset_chain` (D_CSR = 0x01002000: EN_NEXT + EN_CNT).
  3. 0x70003f9c: `sta 0x55555555,[0x78400004]`. Then D_CSR is read at 0x70003fa0, D_ADDR at 0x70003fa4, D_CSR again at 0x70003fa8; both D_CSR values are discarded. Expect D_ADDR = **0x55555555**. With no current address loaded, the first write goes straight to D_ADDR; `post_dma2_d_chain` confirms this.
  4. 0x70003fc4: `dma2_d_reset_chain`. 0x70003fec: `stba 0x55,[0x78400004]` (byte). 0x70003ff0: D_CSR masked ~0xc; expect **0xa1002040** (ID | EN_NEXT | EN_CNT | SLAVE_ERR; A_LOADED not set).
  5. 0x70004004: `dma2_d_clear_slave_err`. This writes the whole word 0x40, which also clears EN_NEXT and EN_CNT.
  6. 0x7000401c: AFAR must be **0x78400004**. 0x7000403c: AFSR must be **0x93820000**.
  7. 0x70004050: `sta 0` → AFSR. 0x70004058: `sbus_clear_afsr`.
- **Pass criteria / expected values:** as listed.
- **On failure prints:** `dma2_reg_fail` or `dma2_afsr_fail`, each followed by `UNUMBER: U1102`.

### 9.9 DMA2 D_NBCNT Register Test — `post_dma2_d_nbcnt` @ 0x7000406c
- **Called:** never. It is listed only in `post_dma2_esp_group` 0x700039b4, which is never called.
- **Tests:** D_BCNT in chain mode and the loaded-status bits, and the slave error from a byte store to D_BCNT in chain mode.
- **Algorithm:**
  1. 0x70004070: print the name if verbose. 0x70004090: `clr %g3`. 0x70004094: `sbus_clear_afsr`. 0x700040a8: `dma2_d_reset_chain`.
  2. 0x700040d0: `sta 0x00e69f10,[0x78400008]`. 0x700040d4: `sta 0x55555555,[0x78400004]`. 0x700040d8: read D_BCNT; expect **0x00e69f10**.
  3. 0x700040f4: D_CSR masked ~0xc; expect **0xa5002000** (ID | D_A_LOADED | EN_NEXT | EN_CNT).
  4. 0x70004114: `dma2_d_reset_chain`. 0x7000413c: `stba 0x10,[0x78400008]`. 0x70004140: D_CSR masked ~0xc; expect **0xa1002040**.
  5. 0x70004154: `dma2_d_clear_slave_err`. 0x7000416c: AFAR must be **0x78400008**. 0x7000418c: AFSR must be **0x93820000**. 0x700041a0: `sta 0` → AFSR. 0x700041a8: `sbus_clear_afsr`.
- **Pass criteria / expected values:** as listed.
- **On failure prints:** `dma2_reg_fail` or `dma2_afsr_fail`, each followed by `UNUMBER: U1102`.

### 9.10 FPU Misaligned Reg Pair Test (really the DMA2 D_ chain test) — `post_dma2_d_chain` @ 0x700041bc
- **Called:** never. It is listed only in `post_dma2_esp_group` 0x700039bc, which is never called.
- **Tests:** D_ADDR/D_BCNT chaining: the current and next address/count registers and the D_A_LOADED/D_NA_LOADED status bits. It prints the wrong name, the string at 0x70008f9e, which belongs to an FPU test.
- **Algorithm:**
  1. 0x700041c0: print "FPU Misaligned Reg Pair Test" if verbose (bug). 0x700041e0: `clr %g3`. There is no `sbus_clear_afsr`.
  2. 0x700041f0: `dma2_d_reset_chain`.
  3. 0x70004218: `sta 0x00e69f10` → D_BCNT. 0x7000421c: `sta 0xaaaaaaaa` → D_ADDR.
  4. 0x70004220: D_BCNT must read **0x00e69f10**. 0x70004238: D_ADDR must read **0xaaaaaaaa**. 0x70004254: D_CSR masked ~0xc must read **0xa5002000** (A_LOADED).
  5. 0x70004288: `sta 0x89abcdef` → D_BCNT (goes to NEXT_COUNT). 0x7000428c: `sta 0x55555555` → D_ADDR (goes to NEXT_ADDR). 0x7000429c: D_CSR masked ~0xc must read **0xad002000** (adds D_NA_LOADED, bit 27).
  6. 0x700042c4: `sta 0x01002020` → D_CSR (EN_NEXT | EN_CNT | D_INVAL, bit 5). 0x700042c8: D_CSR masked ~0xc must read **0xa1002000**; D_INVAL clears both LOADED bits.
  7. Return `%g3`. D_CSR is left in chain mode.
- **Pass criteria / expected values:** as listed.
- **On failure prints:** `dma2_reg_fail` (Address 0x78400008, 0x78400004 or 0x78400000), then `UNUMBER: U1102`.

### 9.11 ESP Registers Tests — `post_esp_regs` @ 0x70004bc0
- **Called:** sequencer 0x70009bd8. Also listed in `post_dma2_esp_group` 0x700039c4, which is never called.
- **Tests:** byte read/write of the ESP 53C9x configuration 1 register, the FIFO, the command register, and the transfer counter low/high. Registers are spaced 4 bytes apart; accesses are bytes.
- **Algorithm:**
  1. 0x70004bc4: print the name if verbose. 0x70004be4: `clr %g3`. 0x70004bf4: `dma2_d_reset`, which pulses D_CSR RESET and so resets the ESP.
  2. CFG1 at 0x78800020: write/read 0x55 (0x70004c08/0c), 0xaa (0x70004c20/24), 0x00 (0x70004c38/3c). Each must read back as written.
  3. 0x70004c58: `dma2_d_reset`. FIFO at 0x78800008: write 0x89, 0xab, 0xcd, 0xef (0x70004c6c..0x70004c84). Read 4 times (0x70004c88, 0x70004c9c, 0x70004cb0, 0x70004cc4); expect **0x89, 0xab, 0xcd, 0xef** in that order.
  4. Command register 0x7880000c: 0x70004cf0 writes **0x80** (DMA | NOP). 0x70004cf4 reads it back; expect **0x80**.
  5. 0x70004d10: `dma2_d_reset`. Transfer count low 0x78800000. Each sub-step writes the value (0x70004d20, 0x70004d48, 0x70004d70), writes command 0x80 to 0x7880000c (DMA NOP, which loads the counter from the TC registers), then reads 0x78800000 (current count low). The values are:
     - First, at 0x70004d20, 0x80 instead of the intended 0x55: 0x70004d1c `mov 0x55,%l6` loads the wrong register, and `%l1` is still 0x80 from step 4 (bug).
     - Second, 0xaa.
     - Third, 0x00.
  6. 0x70004da0: `dma2_d_reset`. Transfer count high 0x78800004. Each sub-step writes the value, writes 0 to TC low (0x70004dbc, 0x70004dec, 0x70004e1c), writes command 0x80, then reads 0x78800004. The values are:
     - First, 0x55 (0x70004db4).
     - Second, 0xaa (0x70004de4).
     - Third, 0xaa again instead of 0x00: 0x70004e10 `clr %l6` clears the wrong register (bug).
- **Pass criteria / expected values:** every read equals the byte written. With the bugs above, TC-low sees 0x80/0xaa/0x00 and TC-high sees 0x55/0xaa/0xaa.
- **On failure prints:** `L_70004e50`: `ERROR  : Address= %1, exp= %2, obs= %3, xor= %4` with %1=register `%l0`, %2=`%l1`, %3=`%l2`, %4=`%l7`. Then `UNUMBER: U1102`.

### 9.12 DMA2 P_CSR Register Test — `post_dma2_p_csr` @ 0x700044a0
- **Called:** sequencer 0x70009bec.
- **Tests:** that the parallel-port DMA CSR has its status bits clear after a reset. The ID bits are not checked.
- **Algorithm:**
  1. 0x700044a4: print the name if verbose. 0x700044c4: `clr %g3`. Checkpoint.
  2. 0x700044dc: `sta 0x80,[0x7c800000]` (P_RESET). 5 nops. 0x700044f4: `sta 0`. 0x700044f8: read P_CSR.
  3. Check that these bits are 0:
     - bit 0 P_INT, at 0x70004504 (printed exp 0xfffffffe);
     - bit 1 ERR_INT, at 0x70004518 (exp 0xfffffffd);
     - bit 6 SLAVE_ERR, at 0x7000452c (exp 0xffffffbf);
     - bits 3:2 P_DRAINING, at 0x70004540 (exp 0xfffffff3).
     Bit names are from [S4M A.II.6.3.2].
- **Pass criteria / expected values:** `P_CSR & 0x4f` = 0 after a reset.
- **On failure prints:** `pport_reg_fail`: Address=0x7c800000, exp=inverted bit mask (not a real expected value), obs=P_CSR, xor. Then `UNUMBER: U1102`.

### 9.13 DMA2 P_ADDR Register Test — `post_dma2_p_addr` @ 0x7000455c
- **Called:** sequencer 0x70009c00.
- **Tests:** 32-bit read/write of P_ADDR.
- **Algorithm:**
  1. 0x70004560: print the name if verbose. 0x70004580: `clr %g3`.
  2. P_CSR reset: 0x70004598 `sta 0x80`, 0x700045b0 `sta 0`, 0x700045b4 read.
  3. At 0x7c800004, write and read back: 0xa55a5aa5 (0x700045c8/cc), 0xffffffff (0x700045e0/e4), 0x00000000 (0x700045f8/fc).
- **Pass criteria / expected values:** every value reads back unchanged.
- **On failure prints:** `pport_reg_fail` (Address 0x7c800004), then `UNUMBER: U1102`.

### 9.14 DMA2 P_BCNT Register Test — `post_dma2_p_bcnt` @ 0x7000461c
- **Called:** sequencer 0x70009c14.
- **Tests:** that P_BCNT is 24 bits wide and bits 31:24 read 0.
- **Algorithm:**
  1. 0x70004620: print the name if verbose. 0x70004640: `clr %g3`.
  2. P_CSR reset (0x70004658, 0x70004670, 0x70004674).
  3. At 0x7c800008:
     - 0x70004690: write 0xa55a5aa5, read back, expect **0x005a5aa5**.
     - 0x700046b0: write 0xffffffff, expect **0x00ffffff**.
     - 0x700046c8: write 0, expect **0**.
- **Pass criteria / expected values:** as listed.
- **On failure prints:** `pport_reg_fail` (Address 0x7c800008), then `UNUMBER: U1102`.

### 9.15 PPORT Registers Tests — `post_pport_regs` @ 0x700046ec
- **Called:** sequencer 0x70009c28, the last I/O test before NVRAM and TOD.
- **Tests:** the reset values of the BPP hardware configuration (HCR), operation configuration (OCR) and transfer control (TCR) registers, and HCR write/read.
- **Algorithm:**
  1. 0x700046f0: print the name if verbose. 0x70004710: `clr %g3`.
  2. P_CSR reset (0x70004728, 0x70004740, 0x70004744).
  3. 0x70004754: `stha 0,[0x7c800010]` (HCR). 0x70004758: half read; expect **0x0000**.
  4. 0x70004778: half read of OCR 0x7c800012; expect **0x200a**. That is bit 13 DS_DSEL [S4M "DSEL"] | bit 3 IDLE | bit 1. [Linux] names bit 1 `P_OCR_V_ILCK`.
  5. 0x70004794: byte read of TCR 0x7c800015. Bit 3 (0x08, DIR [S4M]) must be **set**.
- **Pass criteria / expected values:** HCR 0, OCR 0x200a, `TCR & 0x08` ≠ 0.
- **On failure prints:** `pport_reg_fail` (Address=register, exp=0 / 0x200a / 0x08, obs, xor), then `UNUMBER: U1102`.

### 9.16 DMA2 PPORT Slave Error Tests — `post_dma2_pport_slave_err` @ 0x700047b4
- **Called:** never. It has no caller at all, not even a group.
- **Tests:** that a byte store to the 16-bit BPP registers HCR and OCR sets P_CSR SLAVE_ERR, sets AFSR/AFAR, and raises the level-15 async-error interrupt.
- **Algorithm:**
  1. 0x700047b8: print the name if verbose. 0x700047d8: `clr %g3`. 0x700047dc: `sbus_clear_afsr`.
  2. 0x70004800 / 0x70004804: word 0xf05dff80 → mask set 0x71e1000c, then → mask clear 0x71e10008. This unmasks all system sources, including I (bit 29, M-to-S write buffer error).
  3. P_CSR reset: 0x70004810 `sta 0x80`, 0x70004828 `sta 0`, 0x7000482c read (discarded).
  4. 0x70004844: `%g5` = **0x1f** (interrupt level 15). 0x70004848: `%g7` = **0x98**. 0x7000484c: `stba 0,[0x7c800010]` (byte to HCR).
  5. Loop at 0x70004854: wait up to 0x100 passes for `%g5` to become 0. If it is still set, `pport_no_irq_fail`.
  6. The expected handler is `trap_irq15` 0x70001d0c:
     - tt 0x1f matches `%g5`, so it clears `%g5` (0x70001d28).
     - `%g7`==0x98 branches to 0x70001da8. This skips the "mask everything" store at 0x70001da4 that other codes do.
     - 0x70001db4: word 0x8000 → 0x71e00004 (processor-0 clear-pending, HARDINT bit 15).
     - 0x70001dbc: reads 0x71e00000. If bit 15 is still set it goes to `irq15_cant_clear_error`, which prints `ERROR  : Can't clear intrpt pend reg -> intrpt = %1` with %1=0x1f and sets `%g3`=1.
     - The handler then returns to the interrupted instruction (`jmp %l1; rett %l2`). It does not touch the AFSR.
  7. 0x70004880: P_CSR bit 6 SLAVE_ERR must be **set**. 0x70004890: write 0x40 (W1C). 0x70004894: bit 6 must now be **clear**.
  8. 0x700048b4: AFAR must be **0x7c800010**. 0x700048d4: AFSR must be **0x93820000**.
  9. 0x700048e4: `sta %g0,[%l1]` with `%l1`=0x80. This writes 0 to **RAM PA 0x00000080** instead of the AFSR (bug; `%l0`=0x10001000 was intended).
  10. Repeat steps 4-8 for OCR:
      - 0x700048fc: `%g5`=0x1f. 0x70004900: `%g7`=0x98. 0x70004904: `stba 0,[0x7c800012]`.
      - Wait loop at 0x7000490c.
      - SLAVE_ERR set and clear at 0x70004938-0x7000494c.
      - 0x7000496c: AFAR must be **0x7c800012**. 0x7000498c: AFSR must be **0x93820000**.
      - 0x7000499c: `sta 0` → AFSR (correct this time).
  11. 0x700049bc-0x700049c4: 0xf05dff80 → mask set, clear, set (ends masked). 0x700049c8: `sbus_clear_afsr`. Return `%g3`.
- **Pass criteria / expected values:** one level-15 interrupt within 0x100 loop passes for each byte store. SLAVE_ERR set, then cleared by W1C. AFAR = the store address. AFSR = 0x93820000.
- **On failure prints:** `pport_no_irq_fail` (`No interrupt received, expected 0000001f`), `pport_reg_fail` (Address 0x7c800000, exp 0x40) or `pport_afsr_fail`, each followed by `UNUMBER: U1102`.

### 9.17 DMA2 PPORT IO Loopback Test — `post_dma2_pport_io_loopback` @ 0x700049dc
- **Called:** never (no caller).
- **Tests:** meant to check PIO loopback of the control-output and status-input lines in BPP diagnostic mode. As written it cannot pass.
- **Algorithm:**
  1. 0x700049e0: print the name if verbose. 0x70004a00: `clr %g3`.
  2. 0x70004a10: `stha 0x400,[0x7c800012]` (OCR EN_DIAG, bit 10 [S4M "DIAG"]).
  3. Loop at 0x70004a1c:
     - `%l0`=0x7c800016 (OR, control output). `%l1`=0x7c800017 (IR, status input). `%l2`=0.
     - 0x70004a34: `stba 0,[0x7c800017]`. 0x70004a38: `lduba [0x7c800016]` → `%l3`.
     - 0x70004a3c: `cmp %l0,%l2` compares the **address** 0x7c800016 with 0, so the test always branches to `pport_reg_fail` (bug).
     - The loop step (`add %l0,1`; `cmp %l0,7`; `ble`) is also broken: it would exit after one pass.
  4. The cleanup at 0x70004a58 (`stba 0,[0x7c800017]`) is unreachable.
- **Pass criteria / expected values:** none reachable.
- **On failure prints:** `pport_reg_fail`: Address=0x7c800016, exp=`%l3` (the value read), obs=stale `%l4`, xor=`%l2^%l3`. Then `UNUMBER: U1102`.

### 9.18 DMA2 PPORT XFR Loopback Test — `post_dma2_pport_xfr_loopback` @ 0x70004a6c
- **Called:** never (no caller).
- **Tests:** in diagnostic mode, that 0 written to the transfer control register reads back as 0. A loop over TCR values was probably intended; it runs once.
- **Algorithm:**
  1. 0x70004a70: print the name if verbose. 0x70004a90: `clr %g3`.
  2. 0x70004aa0: `stha 0x400,[0x7c800012]` (EN_DIAG).
  3. Loop at 0x70004aac:
     - `%l2` is cleared on every pass. 0x70004abc: `stba 0,[0x7c800015]` (TCR). 0x70004ac0: read it back; expect **0**.
     - The loop test `cmp %l0,7; ble` uses the address 0x7c800015, so the loop exits after one pass.
  4. 0x70004ae0: `stba %g0,[%l1]` with `%l1`=0x400. This writes a 0 byte to **RAM PA 0x00000400** instead of clearing OCR (bug). The OCR stays in diagnostic mode.
- **Pass criteria / expected values:** TCR reads 0x00 after 0x00 is written.
- **On failure prints:** `pport_reg_fail` (Address 0x7c800015), then `UNUMBER: U1102`.

## 10. NVRAM and TOD tests

### 10.1 NVRAM Access Test — `post_nvram_access` @ 0x70006c00
- **Called:** only by `post_sequencer` at 0x70009c4c. Failure goes to `post_fail_nvram` (0x70009c58).
- **Tests:** byte read/write of one NVRAM SRAM cell (MK48T08 offset 3).
- **Algorithm:** %l0 = 0x71200003. All accesses are `lduba`/`stba`.
  1. 0x70006c3c-0x70006c54: read the byte, write back its complement (`xnor` then `& 0xff`), read, exp complement.
  2. 0x70006c68: write 0xaa, exp 0xaa. 0x70006c8c: 0x55. 0x70006cb0: 0xff. 0x70006cd0: 0x00.
  3. Return %g3 (cleared at 0x70006c24).
- **Pass criteria / expected values:** each read equals the byte just written. The byte is **not restored** and is left as 0x00.
- **On failure prints:** a first-check failure goes to `L_70006e54`: "ERROR  : NVRAM (%1) Battery Failure, exp = %2, obs = %3, xor = %4". %1 = 0x71200003, %2 = ~original & 0xff, %3 = read, %4 = xor. Pattern failures go to `L_70006e9c`: "ERROR  : Address= %1, exp= %2, obs= %3, xor= %4". Both then print "UNUMBER: U1506" (0x7000a998) and return 0xff. The sequencer then lights the NVRAM LED and prints "Power-On Selftest FAILED ... Replace NVRAM".

### 10.2 TOD Registers Test — `post_tod_regs` @ 0x70006cf8
- **Called:** only by `post_sequencer` at 0x70009c60. Failure goes to `post_fail_nvram` (0x70009c6c).
- **Tests:** every value from 0 up to each clock register's writable mask can be written and read back while the clock is halted.
- **Algorithm:** all accesses are bytes.
  1. 0x70006d24-0x70006d30: control 0x71201ff8 = **0x40** (R = 1, freezes the registers for reading; also sets S = 0 and CAL = 0).
  2. 0x70006d38-0x70006d54: copy 0x71201ff8..0x71201fff (8 bytes, including control) to **physical RAM 0x2300..0x2307** (fixed address, ASI 0x20; not relative to %g2).
  3. 0x70006d58: `clr %g3`. 0x70006d64-0x70006d68: control = **0x80** (W = 1, halts the clock for writing).
  4. For each register r = 0x71201ff9..0x71201fff (seconds, minutes, hours, day, date, month, year), with mask m from the table at 0x70006e4c (read with `lduba` ASI 0x09) = **7f 7f 3f 07 3f 1f ff** (8th byte 00 unused):
     - 0x70006d98: write 0, exp 0.
     - 0x70006dbc-0x70006dd8: for v = m, m-1, …, 1: write v, exp v.
  5. 0x70006df4-0x70006e3c: control = 0x80. Copy RAM 0x2301..0x2307 back to 0x71201ff9..0x71201fff. Then write the saved control byte from RAM 0x2300 (`and -1` is a no-op) to 0x71201ff8.
  6. Return %g3.
- **Pass criteria / expected values:** 7 + 673 write/read pairs, each exact. Register widths: sec 7 bits, min 7, hour 6, day 3, date 6, month 5, year 8. Seconds bit 7 (ST) is never set, so the oscillator is not stopped.
- **On failure prints:** `L_70006e9c`: "ERROR  : Address= %1, exp= %2, obs= %3, xor= %4" (%1 = register address, %2 = value written, %3 = read, %4 = xor) + "UNUMBER: U1506", returns 0xff. On failure the TOD is **not restored**: control is left at 0x80 (clock halted) with test values in the registers.
- **Side effects on success:** the saved control byte was read after writing 0x40, so the value restored is 0x40. R stays set after POST and the original calibration and sign bits are lost. The time is restored from the snapshot, so the time spent in the test is lost.
- **Unreached TOD oscillator code:** 0x70006ee4-0x70006f28 prints "ERROR  : Unable to Kickstart TOD Oscillator " (0x700084b4; the string has no %n, but %o1-%o4 = %l2, %l1, %l3, %l7 are loaded anyway) + "U1506" and returns 0xff. 0x70006f2c-0x70006f70 prints Address/exp/obs/xor with %l4/%l3/%l6/%l7 + "U1506". Neither has any reference. The title "TOD Oscillator Test" (0x700093fe) is unreferenced too. They are remnants of a removed oscillator test.

## 11. Shared routines

<a name="nta_march_test"></a>
### 11.1 Generic march — `nta_march_test` @ 0x70009f00
- **Called:** `post_dcache_ram_nta` 0x70004fd8 (base 0, len 0x2000, stride 4, ASI 0xf, mask 0xffffffff). `post_dcache_tag_nta` 0x70005040 (0, 0x2000, 0x10, ASI 0xe, mask 0xffffefff). `post_icache_ram_nta` 0x700051a8 (0, 0x4000, 4, ASI 0xd, 0xffffffff). `post_icache_tag_nta` 0x70005210 (0, 0x4000, 0x20, ASI 0xc, 0xffffcfff). `post_mmu_tlb_nta` 0x70005ef0 ("MMU TLB RAM", 0, 0x100, 4, ASI 6, 0x07ffffdc), 0x70005f34 ("CAM", 0x300, 0x100, 4, ASI 6, 0xffffffff) and 0x70005f78 ("LCAM", 0x100, 0x100, 4, ASI 6, 0x3ff). All callers pass %o5 = 0.
- **Args:** %o0 base, %o1 length (end = base+len), %o2 stride, %o3 ASI (passed as %o2 to the stubs), %o4 data mask (applied to both expected and observed), %o5 = print SIMM U-number on error (≠ 0). %o5 is used, not unused.
- **Accessors:** `asi_st_word(data=%o0, addr=%o1, asi=%o2)` 0x7000af64 jumps to 0x7000af7c + asi·8. `asi_ld_word(addr=%o0, -, asi=%o2)` 0x7000b48c jumps to 0x7000b4a4 + asi·8 and returns the word in %o1. Each table holds 49 stubs (ASI 0x00-0x30), one `ba ; sta/lda [..] asi` each, with no range check.
- **Element sequence** (0 = 0x00000000, 1 = 0xffffffff, A = 0xaaaaaaaa, 5 = 0x55555555. ⇑ = base → end-stride with signed `bl`. ⇓ = end-stride → base with signed `bge`. rX = read and compare (value & mask) with (X & mask). The address in parentheses is each element's checkpoint marker):

  | # | Addr | Dir | Ops |
  |---|---|---|---|
  | M0 | 0x70009f20 | ⇑ | w0 |
  | M1 | 0x70009f50 | ⇑ | r0, w1 |
  | M2 | 0x70009fac | ⇓ | r1 |
  | M3 | 0x70009ff8 | ⇑ | r1, w0 |
  | M4 | 0x7000a054 | ⇓ | r0 |
  | M5 | 0x7000a09c | ⇓ | r0, wA |
  | M6 | 0x7000a0fc | ⇑ | rA |
  | M7 | 0x7000a14c | ⇓ | rA, w5 |
  | M8 | 0x7000a1b4 | ⇑ | r5 |
  | M9 | 0x7000a204 | ⇑ | r5, wA, w5 |
  | M10 | 0x7000a27c | ⇓ | r5 |
  | M11 | 0x7000a2cc | ⇓ | r5, wA, w5, wA |
  | M12 | 0x7000a354 | ⇑ | rA |
  | M13 | 0x7000a3a4 | ⇑ | w1 |
  | M14 | 0x7000a3d8 | ⇑ | r1, w0, w1 |
  | M15 | 0x7000a444 | ⇓ | r1 |
  | M16 | 0x7000a490 | ⇓ | r1, w0, w1, w0 |
  | M17 | 0x7000a50c | ⇑ | r0 |

  March notation: ⇑(w0); ⇑(r0,w1); ⇓(r1); ⇑(r1,w0); ⇓(r0); ⇓(r0,wA); ⇑(rA); ⇓(rA,w5); ⇑(r5); ⇑(r5,wA,w5); ⇓(r5); ⇓(r5,wA,w5,wA); ⇑(rA); ⇑(w1); ⇑(r1,w0,w1); ⇓(r1); ⇓(r1,w0,w1,w0); ⇑(r0). The memory is left all 0.
- **Pass criteria:** every masked read matches. Returns %g3, which is cleared at 0x70009f14 and is 0 unless a trap handler set it.
- **On failure prints:** `report_nta_error` 0x7000a6e8: "ERROR  : Address= %1, exp= %2, obs= %3, xor= %4". %1 = address (%l4), %2 = exp & mask, %3 = obs & mask, %4 = xor. If %i5 ≠ 0, `print_simm_unumber(address)` follows. Returns 0xff. Other routines (0x70004f6c, 0x7000513c) also branch into `report_nta_error`.

### 11.2 Keyboard / LED protocol used by POST
- **Z85C30 keyboard channel A:** control 0x71000004, data 0x71000006, 1200 baud (`escc_init_kbd` 0x7000a8dc uses the table at 0x7000a95c: WR9 0xc0 reset, WR4 0x46, WR3 0xc0, WR5 0xe2, WR9 0x02, WR11 0x55, WR12 0x7e, WR13 0, WR14 0x82, WR3 0xc1, WR5 0xea, WR14 0x83, WR0 0x10 twice; WR9 MIE = 0, so no ESCC interrupts). RR0 bit 0 = Rx available, RR0 bit 2 = Tx empty. After writing 1 to the control register, the next read is RR1, whose bit 0 = All Sent.
- **`kbd_send(byte)` 0x70007490:** up to 0x100 polls. While RR0 bit 0 is set, read and discard the data register (drains stale Rx). If Rx never drains, return **1**. Otherwise wait for RR0 bit 2 (Tx empty; this wait has **no timeout**, with a 0x16-iteration delay per poll), `stba` the byte to 0x71000006, and return 0.
- **`kbd_recv_timeout(-, flag)` 0x700074f4:** polls RR0 bit 0 up to 0x100 times. On a character it returns the data byte. On timeout it returns **0** if %o1 = 0x999 and **1** otherwise. The 0x999 flag exists because 1 is the L1/Stop key code. `kbd_detect` calls it without setting %o1.
- **`kbd_detect()` 0x7000aa60:**
  1. `kbd_send(0x01)` (reset); a failed send returns 0.
  2. Up to 0x100 receives waiting for 0xFF; none returns 0.
  3. Delay loop of 0x28b0a iterations, then one receive (the ID byte). ID 5 returns 5. Any ID other than 4 returns 0.
  4. ID 4: `kbd_send(0x0f)` (layout request), up to 0x100 receives waiting for 0xFE, then one receive. Layout 9 returns 9; anything else returns 4.
  - The result is kept in %l7 by post_main and post_sequencer. At 0x700098c0, %l7 = 0 prints "$$$$$ WARNING: No Keyboard Detected! $$$$$" (verbose only), and %l7 = 4 is changed to 0. So a normal ID-4 keyboard and no keyboard both use LED set A below. Only 5 or 9 selects set B. What ID 5 and layout 9 mean is not known (guess: other keyboard models).
- **`kbd_set_leds(v)` 0x7000b8bc:** `kbd_send(0x0e)` then `kbd_send(v)`. Sun LED bits: 0x01 Num Lock, 0x02 Compose, 0x04 Scroll Lock, 0x08 Caps Lock (these match the SS5 service manual, Table 3-1).
- **`post_quiesce_leds_off` 0x7000b88c:** mask-set 0x80080000 (MA + T), %g1 = 0 (LED-blink state), system limit 0x71d10000 = 0, then `kbd_set_leds(0)`.
- **Progress LEDs** (the sequencer writes 0x0e,v directly; Caps Lock toggles):

  | At | After | LEDs |
  |---|---|---|
  | 0x7000993c | MMU regs, TLB NTA, IOMMU group | 0x08 |
  | 0x70009974 | D-cache RAM/tag NTA | 0x00 |
  | 0x700099ac | I-cache RAM/tag NTA | 0x08 |
  | 0x70009a58 | Memory Address Pattern Test | 0x08 (no change) |
  | 0x70009a7c | FPU basic group | 0x00 |
  | 0x70009aa0/0x70009aa8 | FPU cexc group | quiesce (0), then 0x00 |
  | 0x70009ae0 | PROC0 irq regs, Soft Int OFF | 0x08 |
  | 0x70009b2c | Soft Int ON, user timer, counter/timer | 0x00 |
  | 0x70009ba0 | DMA2 E-CSR, LANCE addr/data, DMA2 D-CSR/addr | 0x08 |
  | 0x70009c3c | DMA2 D-bcnt/naddr, ESP, DMA2 P-csr/addr/bcnt, pport | 0x00 |
  | 0x70009c74 | NVRAM access, TOD regs | quiesce (0) → PASS |

- **Failure LEDs** (each path: quiesce, set LEDs, wait up to 0x2710 polls for keyboard RR1 All Sent, then `post_exit_soft_reset(2, msg)`):

  | Path | Reached from | %l7 = 0 (set A) | %l7 ≠ 0 (set B) | Message |
  |---|---|---|---|---|
  | `post_fail_cpu_board` 0x70009e9c | MMU, TLB, IOMMU, caches, FPU | 0x01 Num Lock | 0x09 Caps+Num | "…Replace CPU Board" |
  | `post_fail_cpu_board_leds` 0x70009d7c | irq regs, soft ints, timers, DMA2, LANCE, ESP, pport | 0x01 Num Lock | 0x0c Caps+Scroll | "…Replace CPU Board" |
  | `post_fail_nvram` 0x70009d1c | NVRAM access, TOD regs | 0x04 Scroll Lock | 0x08 Caps | "…Replace NVRAM" |
  | `post_fail_simm` 0x70009ddc | no memory, Memory Address Pattern Test | 0x02 Compose | 0x01 Num | "…Replace (%s) SIMM" |
  | dead 0x70009cbc (after the PASS call) | nothing | 0x01 Num | 0x04 Scroll | "…Replace CPU Boot PROM" |
  | dead 0x70009e3c (after the SIMM call) | nothing | 0x02 Compose | 0x05 Num+Scroll | "…Replace (%s) SIMM" |

  Set A matches the service manual: Num Lock = main logic board, Scroll Lock = NVRAM, Compose = DSIMMs. PASS (0x70009c74-0x70009cb8): quiesce, wait for **ttya** (0x71100004) RR1 All Sent, then `post_exit_soft_reset(0, "Power-On Selftest PASSED")`.
- **`post_exit_soft_reset(status, msg)` 0x7000bac0** (listed as noreturn):
  - %g1 = 0x504f5354 ("POST"), %g2 = status (0 pass, 2 fail, -1 skipped), %g3 = 0xffd00010 + (msg & 0x7ffff), %g4-%g7 = %o2-%o5.
  - `boot_puts("\r\n")`.
  - Stores 0 to NVRAM 0x71201dd8 **8 times at the same address** (the loop never increments %l3).
  - Jumps through boot space to `sysctl_soft_reset` (0x71f00000 = 1).
- **Power-on keyboard checks, `reset_power_on` 0x7000bb48-0x7000bd08:**
  1. Init ttya and the keyboard ESCC (9600, then keyboard at 1200).
  2. Put processor timer 0 in user-timer mode and start it at 0: 0x71d0000c = 0, 0x71d10010 = 1, MSW = LSW = 0, 0x71d0000c = 1, MSW = LSW = 0. `kbd_getc_timeout` (0x7000c354) uses this timer: deadline = LSW + 0x3d090000, about 1.0 s per byte.
  3. Drain the keyboard until a timeout, then send 0x01 (reset) and clear %g6. If the first read times out (no keyboard), jump to **0x70001000 (run POST)**.
  4. Parse the reset reply (0x7000bc24): after 0xFF the next byte (the ID) is read in the delay slot of `be,a` and discarded. Then read bytes until a timeout: 0x01 (L1/Stop) sets %g6 |= 1, 0x4f ('D') sets %g6 |= 2.
  5. %g6 = 1 (L1): `boot_puts("Skipping POST because of L1 keyboard command.")`, then soft reset. **POST skipped.**
  6. %g6 = 3 (L1-D): if NVRAM 0x7120004e = 1 or 2 (guess: security-mode command/full), clear the D bit, which gives %g6 = 1 and POST is skipped. Otherwise write NVRAM 0x71200001 (diag-switch?) = 0xff (persistent), print "Setting diag-switch? because of L1-D keyboard command.", and **run POST**.
  7. %g6 = 0 or 2: if NVRAM 0x71200001 ≠ 0, **run POST**; otherwise soft reset (skip POST).
  - `boot_puts` prints only when NVRAM 0x71200001 ≠ 0 (0x7000c298), so "Power-ON Reset" and the L1 message appear only with diag-switch? set.
  - This ROM has no L1-N (0x69) or L1-A check in the POST/reset assembly.
- **`post_main` 0x700021dc-0x70002258 (second check):**
  1. After ESCC re-init, 11 calls of `kbd_recv_timeout(0, 0x999)`: byte 0x01 sets %l3 = 1, byte 0x4f sets %l4 = 1.
  2. %l7 = `kbd_detect()`.
  3. If %l3 & %l4: `post_sequencer` with %g4 |= 2 (verbose).
  4. Else if `nvram_diag_switch()` (NVRAM 0x71200001 ≠ 0): verbose POST.
  5. Else if %l7 = 0 (no keyboard): POST with %g4 &= ~2 (quiet; matches the manual's "keyboard disconnected and diag-switch? false").
  6. Else `post_exit_soft_reset(-1)` (skip).
  - `escc_init_kbd` has just reset the channel, so step 1 only sees bytes that arrive in a window of a few ms. The L1-D case is really handled by step 4, because reset_power_on already set diag-switch?.

## 12. Test names without code

The image carries a larger Sun POST string library than this POST uses. These
names and messages have **no code referring to them**:

- IU: "IU Register File Bit Failure", "IU Register File Window Pointer", the
  "STATUS : PSR= %1, TBR= %2, WIM= %3" and Global/Local/Out/In register dump
  headers — **there is no IU test** in this POST.
- FPU: "STATUS : FPU Register-file" (dump header); there is no FSR test.
- MMU: "MMU Data Pointer Reg Test", "MMU Index Tag Reg Test".
- "EPROM Checksum Test" and "EPROM Checksum Miscompare" (the checksum at
  `0x7003fffe` is valid: 16-bit byte sum), "Trigger Soft Reset Test", "NVRAM
  Address Test", "TOD Oscillator Test" (its kickstart code survives, §10.2),
  "System Counter Test" (remnants, §8.7).
- Memory: MATS, NTA, Checker Pattern, Address Line, SIMM Parity Bit/Addr
  tests, "Test All Memory", the six "MEM ScopeLoop" tests, the interactive
  memory-test options ("Select Memory Bank to Test (0-7)", …) and "SIMM Parity
  bit may be corrupted".
- I/O: DMA2 P_DS_/P_ACK_/P_BUSY_/P_SLCT_/P_ERR_/P_PE_ interrupt tests, PPORT
  MEM_CLR (unchained, chained, auto-chain), P_FIFO alignment bursts, System and
  PROC0 "Multiple Interrupts" tests, "Auxiliary IO Registers Tests", the four
  85C30 port tests, audio 53C90 MAP/MPI/MUX/loopback, DBRI register /
  interrupt / loopback, SBus and EBus **Write** Timeout tests.
- The menu frame: "An invalid function was chosen", "Option not currently
  supported" (a stub prints it, `post_option_unsupported` `0x7000ab98`,
  uncalled), scope/infinite loop prompts, "DEBUG : Routine Address".

## 13. The POST under QEMU

QEMU 8.2.2 (`qemu-system-sparc -M SS-5 -m 64 -bios ss5.bin`) runs this PROM
to the `ok` prompt ([`qemu-console.txt`](qemu-console.txt)). QEMU is a model,
so its pass/fail is evidence, not ground truth. Unmodified, the POST (diagnostic
mode: QEMU's NVRAM has `diag-switch?` set, and there is no keyboard) passes the
five MMU register tests and stops at the first TLB test:

```
MMU TLB RAM NTA Pattern Test
	ERROR  : Address= 000000fc, exp= 07ffffdc, obs= 00000000, xor= 07ffffdc
```

To see the later tests, a **scratch copy** of the image (never the repository)
was patched so that `post_sequencer` skips each failing call (the `call` word
replaced by `nop`; `%o0` still holds the previous test's 0, so the sequencer
carries on). Skipped in turn: `0x70009914` (TLB NTA), `0x7000994c`,
`0x70009960`, `0x70009984`, `0x70009998` (caches), `0x70009928` (IOMMU group),
`0x70009a8c` (FPU CEXC group), `0x70009b04` (user timer), `0x70009b18`
(counter/timer), `0x70009b3c`-`0x70009c28` (the twelve DMA2/LANCE/ESP/PPORT
tests), `0x70009c60` (TOD). Results:

| Test | QEMU | First failure message |
|---|---|---|
| MMU Context Table / Context / TLB Replace / SFSR / SFAR | pass | |
| MMU TLB RAM NTA | **fail** | `Address= 000000fc, exp= 07ffffdc, obs= 00000000` (no TLB diagnostic ASI) |
| IOMMU SBUS Config Regs | pass | |
| IOMMU Control Reg | **fail** | `Address= 10000000, exp= 04000018, obs= 05000018` (QEMU's IOMMU control register reads implementation/version `0x05` in bits 31:24) |
| Memory Address Pattern | pass | |
| FPU Register File, Misaligned Reg Pair, Single, Double | pass | |
| FPU SP Invalid / Overflow / Div-0 / Inexact / Prio > | pass | |
| FPU SP Trap Priority < | **fail** | `Sync Trap, PSR= 040010c5, PC= 70003020, TBR= 70000080`: QEMU takes the fp_exception (tt 8) precisely at the `fdivs` (`0x70003020`) while the test expects tt 7 on the following misaligned store; microSPARC-II defers FP traps to the next FP instruction |
| PROC0 Interrupt Regs, Soft Interrupts OFF, ON | pass | |
| PROC0 User Timer | **fail** | `Address= 71d00000, exp= 80000000, obs= 7fffffff` (limit bit) |
| PROC0 Counter/Timer | **fail** | `No interrupt received, expected 0000001e` (no level-14 interrupt) |
| DMA2 E_CSR | **fail** | `Address= 10001004, exp= 78400010, obs= 00000000` (no AFAR latch on the wrong-size store) |
| NVRAM Access | pass | |
| TOD Registers | **fail** | `Address= 71201ff9, exp= 0000007f, obs= 00000000` |

With every failing test skipped the POST ends normally, but OBP reads status
`0xffffffff` ("not run") at `0xffef04b0`: QEMU's software reset clears `%g1`,
so the `'POST'` hand-off magic is lost.

## 14. ROM bugs and oddities

Found while reading the code; none of them matter on a real SS5 that passes.

1. **IOMMU SBUS Config Regs Test tests only SSCR0**: `be` instead of `bne` at
   `0x70005a9c` (§4).
2. **Soft Interrupts OFF Test tests only level 14**: the delay slot at
   `0x70005440` copies the already-zero `%l1` into `%l4` (§8.3).
3. **Wrong test names**: `post_icache_flash_clear` prints "MMU TLB RAM NTA
   Pattern Test" (`0x700050cc`); `post_dma2_d_chain` prints "FPU Misaligned
   Reg Pair Test" (`0x700041d0`). Both are uncalled.
4. **Wrong U-number**: the counter limit-bit errors print `0x7000a980+0x70`,
   which lands inside "U0302" and prints "302  " (the table has two 7-byte
   entries).
5. **Stray RAM writes** in uncalled tests: word 0 to PA `0x80`
   (`0x700048e4`, meant for the AFSR) and byte 0 to PA `0x400`
   (`0x70004ae0`, meant for the BPP OCR). `post_dma2_pport_io_loopback`
   compares an address with 0 (`0x70004a3c`) and can never pass.
6. **ESP pattern slips**: `0x70004d1c` and `0x70004e10` use `%l6` for `%l1`,
   so the transfer-count patterns are 0x80/0xaa/0x00 (low) and 0x55/0xaa/0xaa
   (high) instead of 0x55/0xaa/0x00.
7. **Error messages with wrong fields**: LANCE E_CSR failure (`0x70005934`),
   DMA2 ID (always prints `0x78000000`), P_CSR (prints the inverted mask as
   exp), `dma2_slave_err_stuck_fail` (prints the format string's address,
   then `jmp %g0`: restarts the PROM); `trap_irq06` reuses the slave-error
   message for an unrelated condition.
8. **`post_exit_soft_reset` writes NVRAM `0x71201dd8` eight times** (the
   loop at `0x7000bb18` never advances `%l3`).
9. **Watchdog path TLB entry 2**: the upper tag is written as `0x13f8` (a
   reused `%l3`) and its PTE lands in entry 4 (`0x7000c024`, `0x7000c08c`).
10. **Absolute scratch addresses**: `trap_fp_exception` uses PA `0x2100` /
    `0x2108`, the TOD test saves the clock at PA `0x2300`: both assume RAM at
    PA 0, while everything else is relative to the lowest populated bank.
11. **Memory sizing hides bad banks**: `mem_probe_bank` results 1 and 2
    ("data lines differ") are treated as empty, silently.
12. **TOD test side effects**: clears the MK48T08 calibration/sign bits,
    leaves R set on success, W (clock halted) on failure; NVRAM Access leaves
    byte 3 at 0.
13. **LED-blink timer path never armed**: `sys_timer_limit_irq_setup`
    (`0x7000b860`) is uncalled, and the `trap_irq10` blink path could not
    re-arm itself; Caps Lock is toggled synchronously by the sequencer
    instead.
14. **Timing assumptions**: the user-timer and counter tests need ≥ 500 ns
    between reads a few instructions apart, and the level-14 wait assumes
    about 4 µs per 6-instruction poll (0x80000 polls against about 2.1 s of
    counting). A core that runs the PROM much faster than an uncached SS5
    can fail them.
15. **Error paths skip cleanup** (PIL left at 15 or 0, system mask left clear,
    `%g7` left non-zero); trap-context prints use `%i0`-`%i4`, clobbering the
    interrupted routine's `%o0`-`%o4`.
16. **`kbd_send` waits for Tx-empty with no timeout** (`0x700074c4`): a stuck
    keyboard ESCC hangs the POST. `kbd_detect` leaves `%o1` unset when it calls
    `kbd_recv_timeout`.
17. The **stack is inside the second memory-test region** (lowest bank +0 to
    +0x5000, stack at +0xc00); it survives because no window spills at that
    depth (guess).

## 15. Candidate CPU test suite

Goal: a standalone bare-metal suite under `tests/cpu/`
that runs from a tiny boot stub, reports over the Zilog serial port and gives
the same answer in simulation and on the board. The POST provides the
expectations for the microSPARC-II-specific parts. The tests should be
**re-implemented from the algorithms and constants documented here**, not
copied out of the Sun image.

### Platform contract for every test

- **Boot:** PC 0 in boot mode, or loaded into RAM at PA 0 with PCR.BM=0 and the
  MMU off (data PA = VA). Stack and scratch at a fixed RAM address (the POST
  uses first-bank base + `0xc00` for `%sp` and + `0x2000`/`0x2100` for
  scratch; `trap_fp_exception` also writes PA `0x2100`/`0x2108`).
- **Trap table:** a copy of the POST convention — each vector
  `sethi/or %l4 ; jmp %l4 ; rd %psr,%l0`; a default handler that accepts the
  trap if tt = `%g5` (clear `%g5`, `jmp %l2 ; rett %l2+4`) and otherwise
  prints PSR/PC/nPC/TBR plus SFSR/SFAR and fails; window overflow/underflow
  handlers (the POST's use ASI 0x20 so they work with the MMU in any state);
  an FP-exception handler that drains the FQ (`st %fsr`, `std %fq` while
  FSR.qne).
- **Output:** Z85C30 ttya channel A, control `0x71100004`, data `0x71100006`,
  byte accesses with ASI 0x20; the POST init sequence (9600 8N1, §3.2 of the
  README) and polled transmit (RR0 bit 2). `tests/cpu/` already prints
  `PASS <name>` / `FAIL <name>` with `check <code> exp=… obs=…` lines and a
  `CPUTEST DONE` summary; the POST-derived tests should use the same format,
  with the failing address as the check code (the POST prints address, exp,
  obs, xor).
- **Result mailbox for simulation:** in addition to the serial line, write
  `0x600dc0de` or `0xbad00000 | test-number` to a fixed RAM word (e.g. PA
  `0x00000ff0`) so a testbench can stop on it without a UART model.

### Tests that can be lifted from the POST

| Suite test | From | Needs from the platform | Notes |
|---|---|---|---|
| `mmu_ctpr`, `mmu_ctx` | MMU Context Table / Context Register tests | ASI 4 only | masks `0x00ffffc0`, `0xff` |
| `mmu_tlbrc`, `mmu_sfsr_diag`, `mmu_sfar_diag` | TLB Replace Ctrl / Sync Fault Stat / Addr tests | ASI 4 VA `0x1000`, `0x1300`, `0x1400` | microSPARC-II-specific; run `mmu_tlbrc` **after** a check that VA `0x1000` does not alias the PCR, otherwise the test turns the MMU on |
| `tlb_ram`, `tlb_cam`, `tlb_lcam` | MMU TLB RAM / CAM / LCAM NTA | ASI 6 | the POST stops here on QEMU (no TLB diagnostic ASI); decide between implementing ASI 6 and accepting the failure |
| `dcache_data`, `dcache_tag`, `icache_data`, `icache_tag` | D/I-Cache RAM/TAG NTA | ASI 0xc-0xf, caches off | masks `0xffffefff` (D tag), `0xffffcfff` (I tag) |
| `fpu_regfile` | FPU Register File Test | FPU, RAM | four 64-bit patterns × 16 pairs |
| `fpu_lddf_odd_rd` | FPU Misaligned Reg Pair | FPU, RAM | `ldd [x],%f1` must load f0/f1 |
| `fpu_sp_ops`, `fpu_dp_ops` | FPU Single / Double-precision | FPU, RAM | all results 25.0 |
| `fpu_cexc_{nv,of,dz,nx}_{sp,dp}` | the eight CEXC tests | FPU, fp_exception handler | TEM = 0x1f; deferred trap on the next FP store; store blocked; cexc bit |
| `fpu_cexc_uf_{sp,dp}` | the two unused Underflow tests | same | not run by the POST, still worth running |
| `fpu_trap_prio_{sp,dp}_{gt,lt}` | Trap Priority > / < | FPU, alignment + fp handlers | QEMU fails `<` (its FP traps are precise, taken at the FPop): exactly the behaviour this test pins down |
| `irq_proc0_regs`, `softint_off`, `softint_on` | PROC0 Interrupt Regs, Soft Interrupts OFF/ON | interrupt controller `0x71e00000`/`0x71e10000` | platform, not CPU, but needed for any trap test |
| `utimer`, `ctimer` | PROC0 User Timer, Counter/Timer | counters `0x71d00000`/`0x71d10000`, level-14 interrupt | QEMU fails both |
| `mem_march` | Memory Address Pattern Test / `mem_march_test` | RAM | useful as the suite's own RAM check |
| `boot_handoff` | `post_exit_soft_reset` + `reset_entry` | system control `0x71f00000` bit 0/1 | globals must survive SW_RST; QEMU loses them |

The interrupt and timer tests depend on the Slavio interrupt controller and
counters, not on the CPU; they belong in the suite because every trap test
needs a working level-15/level-14 path, but they should be a separate group.

### What the POST does not cover

The POST checks hardware, not ISA semantics: it has **no IU test at all**
(the IU register-file / window-pointer strings have no code). The generic V8
tests in `tests/cpu/` (commit `1c4e828`) already cover: the integer ALU table,
`sethi`, `%y`; the 16 `Bicc` and `Ticc` conditions, annul and delay slots,
`call`/`jmpl`; windows (save/restore, 40-deep recursion with overflow and
underflow, WIM width); loads and stores (sign extension, byte/half merges,
`ldd`/`std`, `ldstub`/`swap`, `lda`/`sta` with ASI 0xb and bypass, misaligned
traps); traps (`ta`, illegal instruction, `rett` with ET=1, division by zero,
tag overflow, fp_disabled, cp_disabled); FPU single/double arithmetic with
`fsqrt`, conversions, `fcmp` and `FBfcc`, FSR cexc/aexc; PSR and TBR fields.

Still missing (neither in the POST nor in `tests/cpu/` yet):

- **IU:** `mulscc` step sequences; `privileged_instruction` (tt 3) from user
  mode (`rd %psr`, `lda`); `umul`/`smul`/`udiv`/`sdiv` `cc` forms at their
  edges if the ALU table does not have them; PSR/WIM/TBR write delays; ET=0
  trap → error mode → watchdog reset.
- **FPU:** deferred traps and the FP queue (`std %fq`, FSR.qne) — the POST's
  CEXC tests (§7.5) are the model; trap priority against
  `mem_address_not_aligned` (the POST's "<" tests); the four rounding modes;
  NaNs with `fcmp` vs `fcmpe`; denormal operands and results (unfinished_FPop,
  FSR.ftt=2); quad ops (unimplemented_FPop, ftt=3); `ldd` into an odd FP
  register (the POST's Misaligned Reg Pair test).
- **MMU with translation on:** 3-level table walks, level-1/2 large PTEs, ACC
  permission checks and the SFSR fault-type codes, R/M updates, probes (ASI 3
  `lda`), the flush types (ASI 3 `sta` types 0-4), context switching, the NF
  bit, SFSR/SFAR overwrite rules, instruction access exceptions.
- **Caches with translation on:** hit/miss coherence, line flush ASIs
  0x10-0x14, alternate cacheability (PCR.AC), store buffer ordering.
- **microSPARC-II boot specifics:** boot-mode fetch mapping (any PC →
  `0x70000000|VA[27:0]`), the PCR reset value (BM=1), ASI 4 decoding of
  VA[12:8] (`0x1000`, `0x1300`, `0x1400`), globals surviving SW_RST.
