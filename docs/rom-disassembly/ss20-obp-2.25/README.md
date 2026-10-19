# SPARCstation 10/20 boot PROM (OBP 2.25, 525-1377-08) — machine-code side

This folder documents the
SPARCstation 10/20 OpenBoot PROM that the core's SS20 build is meant to run:
its image map, how a SuperSPARC enters it, the reset flow up to the first
Forth word, multiprocessor start-up, trap handling and the power-on self-test
(POST VRV3.45). Companion files:

| File | Contents |
|---|---|
| [`listing.s`](listing.s) | full annotated disassembly (generated, do not edit) |
| [`romdis.json`](romdis.json) | the disassembler configuration: entries, labels, block comments, regions |
| [`post-tests.md`](post-tests.md) | catalogue of every POST test, plus the candidate CPU test suite |
| [`hardware-access.md`](hardware-access.md) | every physical address and ASI the machine code touches, by device |
| `qemu-console.txt`, `qemu-trace.json` | console output and executed-address trace of this ROM under `qemu-system-sparc -M SS-20` (from `tools/romdis/qemu_trace.py`) |
| `forth.json`, `forth-dictionary.txt`, `device-tree.md` | the Forth side (written by the Forth-dictionary pass) |

Addresses are **image offsets** (the image is linked at 0). The PROM sits at
physical `0xf_f000_0000`; the same offset is also reached at VA `0x0000xxxx`
and `0xf000xxxx` in boot mode and at VA `0xffd0xxxx` once OBP has mapped it.
Physical addresses are written with the 36-bit space prefix, e.g.
`pa 0xf_f110_0004` (ttya control), which is what `sta %x,[0xf1100004] 0x2f`
reaches.

## 1. The image

| Property | Value |
|---|---|
| File | `scratch/SparcStation/SparcSTATION 20 SunOBP2-25_525-1377-08.ROM` (not in the repository) |
| Size | 524 288 bytes (512 KiB); bytes `0x6fec0-0x7ffff` are erased (`0xff`) |
| MD5 | `910bd7306fcec38361fc4c3a2be50fa0` |
| Firmware | OpenBoot 2.25, part 525-1377-08, build stamp `95/09/15` (string at `0x627d3`); Forthmacs kernel ("Forthmacs version ... Copyright (c) 1988 by Bradley Forthware", `0x410b5`) |
| POST | "SMCC SPARCstation 10/20 UP/MP POST version VRV3.45 (09/11/95)" (`0x25ec8`) |
| CPUs | SuperSPARC TMS390Z50 (no MXCC) / TMS390Z55 (with MXCC), SuperSPARC-II STP1021(A), Ross HyperSPARC RT620/625/626; Ross 605/604 is detected and refused ("NO POST run") |
| Checksum | none found: the "EPROM Checksum Test" name (`0x156c2`) and its message (`0x135a5`) are not referenced by any code, and no stored sum matches the image |

### Image map

| Offset range | Contents | Classified by |
|---|---|---|
| `0x00000-0x00fff` | trap table 0: tt 0 `ba reset_entry`; every other vector `sethi/or %l4 ; jmp %l4 ; rd %psr,%l0` to a POST handler | this pass |
| `0x01000-0x03fff` | trap tables 1-3 (for `%tbr` = `(MID-8)<<12`); identical to table 0 except tt 0 = `ba post_entry` | this pass |
| `0x04000-0x047cf` | `post_entry`: IU register-file and window tests (run before any RAM), slave idle loop | this pass |
| `0x047d0-0x0624f` | POST trap handlers (`trap_*`, `irq_level_1..15`), IU-test and unexpected-trap reports; pattern table `0x6200` | this pass |
| `0x06250-0x0e6df` | test code: SuperSPARC-II endian/TLB helpers, D-cache, DMA2/PPORT, ECC, EMC, ESP, cache flush, FPU (`0x9f00-0xc3bf`), HyperSPARC helpers, I-cache, interrupts, LANCE, IOMMU/MSI | this pass |
| `0x0e6e0-0x0ec97` | accessor-stub library (`retl; lda/sta [..] asi` for most ASIs, `get_psr`, ...), `get_mid`, NVRAM word access | this pass |
| `0x0ec98-0x11a1f` | MMU TLB/context tests, MBus timeout tests, counter/timer tests, NVRAM/TOD tests, HyperSPARC cache helpers | this pass |
| `0x11a20-0x127ff` | console: `post_printf`, ttya/keyboard I/O, hex input; memory probe (`mem_probe_simm_config`) and tables | this pass |
| `0x12800-0x163bf` | POST strings: messages, test names in 32-byte slots from `0x14202`, control/menu strings, pin-name table `0x16120` | this pass |
| `0x163c0-0x16d53` | **`post_main`** (the per-CPU test sequence) and its failure exits | this pass |
| `0x16d54-0x17dbf` | memory pattern-test engines, MMU pattern tables (`0x17a44`, `0x17d68`) | this pass |
| `0x17dc0-0x1878f` | Z85C30 init tables (`0x17ea0`), U-number / part-name tables (`0x17f00`, `0x18540`) | this pass |
| `0x18790-0x19723` | keyboard detect, MCNTL/EMC helpers, ASI-indexed access tables, LED helpers | this pass |
| `0x19724-0x1c5c7` | MXCC / E-cache suite and its strings (`0x1bc00`) | this pass |
| `0x1c5c8-0x1de87` | MMU flush, cache flash-clear and D-cache write-hit tests (compiled C) and strings | this pass |
| `0x1de88-0x1eb97` | LANCE internal/external loopback (compiled C, dead) | this pass |
| `0x1eb98-0x1fb83` | MP control (`mpcntl`, `mp_dispatch`, `mp_probe_slaves`), CPU banner and identification, strings | this pass |
| `0x1fb84-0x2173f` | SuperSPARC-II ("module type 0x42") MMU / I-TLB / endian suite and strings | this pass |
| `0x21740-0x25f17` | HyperSPARC suite (strings interleaved) | this pass |
| `0x25f18-0x27857` | **`post_exit_to_obp`**, **`reset_entry`**, the reset paths, OBP start, boot-time Z85C30 routines, SRMMU boot page tables, their messages | this pass |
| `0x27858-0x2999f` | OBP help: compressed word list (`0x27858`) and help texts | this pass (region only) |
| `0x299a0-0x29adb` | FCode image (header `f1 03`, 0x13c bytes): DBRI audio/ISDN probe | this pass (region only) |
| `0x29ae0-0x2e67f` | FCode image, 0x4ba0 bytes: on-board SBus slot f (espdma/esp, ledma/le, bpp) | this pass (region only) |
| `0x2e680-0x3aa3b` | FCode image, 0xc3bc bytes: `cgfourteen` (SX / VSIMM frame buffer) | this pass (region only) |
| `0x3aa3c-0x3ac47` | 64×64 1 bpp bitmap (guess: Sun logo) | this pass |
| `0x3ac48-0x3d11f` | console font (`"font"` header: 12×22, first char 0x20, 0xe0 glyphs × 42 bytes) | this pass |
| `0x3d120-0x3e5ff` | compiled C / assembler linked before the kernel: `obp_flush_user_ctx`, `obp_cache_init` (called from `obp_start`), 64-bit memory test with SIMM (`J0201`..`J0305`) error reports, `c_printf`, and the **romvec** (the V3 PROM interface an OS calls: `struct linux_romvec` at `0x3d580`, node ops at `0x3d568`, C wrappers `romvec_*`, `romvec_cpustart` 0x3dc68) | this pass |
| `0x3e600-0x6febf` | Forthmacs kernel (origin `0x3e600`: `ba,a cold`, token scale 16) and the dictionary; machine-code words inside it, among them `rom-cold-code` (`0x55d54`) | Forth pass (`forth.json`) |
| `0x6fec0-0x7ffff` | erased (`0xff`) | this pass |

37 723 instructions are decoded (31 571 in the trap tables / POST /
reset area, 1 150 in the C support code, 5 002 in machine-code words of the
Forth kernel, `rom-cold-code` included); outside the Forth pass's span every
byte is classified as code, data, string, FCode or padding (§9).

## 2. How a CPU enters the PROM

- sun4m resets every MBus module together. A SuperSPARC comes out of reset in
  **boot mode** (MCNTL.BM, bit 13 = 1) with the MMU off: every instruction
  fetch goes to the boot PROM (pa `0xf_f000_0000` + low address bits), whatever
  the VA, so VA `0x0000xxxx` and `0xf000xxxx` both run image offset `xxxx`.
  Data accesses with the MMU off go to pa `0x0_xxxx_xxxx` (memory), so the POST
  reaches devices only through the bypass ASIs (0x20 memory, 0x2e SBus, 0x2f
  control space) and reads its own tables either with ASI 9 (instruction space,
  i.e. the PROM) or through ASI 0x2f at `0xf00xxxxx`.
- The **MSI arbiter enable register** (pa `0xf_e000_1008`, Sun4M §5.1.2) comes
  out of power-on with MBus masters 0x8 and 0x9 enabled and 0xA/0xB disabled; a
  disabled module stalls on its first MBus access. The ROM uses this register
  as its multiprocessor start/stop mechanism (§5).
- The trap table is at `0x0000` (`%tbr` = 0 at reset). tt 0 = `ba reset_entry`
  (`0x26220`). The POST later gives each CPU its own copy of the table,
  `%tbr = (MID & 3) << 12`, so the MID can be recovered from `%tbr`
  (`get_mid_from_tbr` 0xe794); the copies at `0x1000/0x2000/0x3000` have
  tt 0 = `ba post_entry`.

## 3. Reset flow, instruction by instruction

All CPUs run this code. Line references are to [`listing.s`](listing.s).

### 3.1 `reset_entry` (0x26220)

1. `0x26220-0x26230`: arbiter enable `pa 0xf_e000_1008 |= 0xf` — enable
   arbitration for MBus masters 0x9-0xB (bit 0 reads as 1).
2. `0x26234-0x26240`: MCNTL (ASI 4 va 0) `>> 28`: IMPL 1 (Ross) →
   `reset_ross_mid_setup` 0x2629c: reset register (ASI 4 va 0x700) bit 2 = watchdog
   → `reset_watchdog`; else copy the MSI MID register (pa `0xf_e000_2000`) into
   MCNTL[18:15] (the HyperSPARC CID field).
3. Viking (IMPL 0), `0x26248-0x26294`: SFSR (ASI 4 va 0x300) bit 17 set →
   error-mode (watchdog) reset → `reset_watchdog` 0x26710. Otherwise clear the
   four 64-bit ASI 0x38 registers (va 0, 0x100, 0x200, 0x300 — the SuperSPARC
   MMU breakpoint registers) and store the MSI MID register value in ASI 0x38
   va 0. **A no-MXCC SuperSPARC later reads its MID back from ASI 0x38 va 0**, so
   this 64-bit register must hold what was written.
4. `reset_find_mid` 0x262d4: `l6 = arbiter & ~0xe` (value with 0x9-0xB off).
   The MID: if the IOMMU control register (pa `0xf_e000_0000`) reports
   IMPL != 0, from the MSI MID register; with IOMMU IMPL 0 (the first MSI,
   whose MID register is broken, Sun4M §5.4.3) from the CPU: Ross MCNTL[18:15],
   Viking without MXCC (MCNTL.MB = bit 11 = 1) ASI 0x38 va 0, Viking with
   MXCC the MXCC port register (`ldda [0x01c00f00] 0x02`, low word bits 27:24).
   The same four-way lookup is repeated at `obp_prep`, `obp_start` and in
   `rom-cold-code`; POST uses `get_mid` (0xe7b0).
5. `reset_mid_known` 0x26344: the master (MID <= 8) stores `l6` (disables
   0x9-0xB), lights the LED (AUXIO0 pa `0xf_f180_0000` |= 1), sets the four
   per-CPU **release flags** NVRAM `0x0f..0x12` = 0xff, and enables 0x9-0xB
   again (`|= 0xf`, stored twice around six `nop`s). Slaves skip this.
6. `reset_check_sysctl` 0x263c8: system control/status (pa `0xf_f1f0_0000`):
   bit 3 (switch reset) or bit 1 (software reset) → `obp_start` directly (no
   POST). For a power-on reset: `%tbr = 0`, `%psr = 0xfe0` (PIL 15, S, PS, ET),
   `%wim = 0`. If the IOMMU IMPL is 0 → `reset_power_on`. Otherwise write
   `0x1f0000` to the arbiter (SBus slots 0-3 and on-board on, CPUs off) and read
   it back; if bits 3:1 are clear (the register works) reset the on-board SCSI
   (ESP pa `0xe_f080_0020 = 8`, `+0x28 = 1`, `+0 = 0x20`, `+0 = 0`, `+0xc = 0xa2`;
   DMA2 D_CSR/`+8`/`+4` sequence at pa `0xe_f040_0000`) and write `0x1f000f`
   (everything on) three times.

### 3.2 `reset_power_on` (0x25f88)

1. Clear `%g1-%g7`. A CPU whose MSI MID register reads > 8 goes to
   `reset_goto_post` at once.
2. Master: `rzs_init_9600(0xf1100004)` — ttya, Z8530 WR9=02 WR4=44 WR3=c0
   WR5=60 WR14=82 WR11=55 WR12=0e WR13=00 WR3=c1 WR5=68 WR14=83 WR0=10: async,
   ×16 clock, 8N1, **9600 baud** from the 4.9152 MHz PCLK. `rputs_if_diag`
   prints "Power-ON Reset" — every boot-time message is printed only when
   **diag-switch?** (NVRAM byte 1) is non-zero, and reads the string from the
   PROM through ASI 0x2f at `0xf0000000 | offset`.
3. Keyboard port (pa `0xf_f100_0004`): same init, then 1200 baud (WR12 0x7e).
4. Processor 0 counter: user-timer start/stop `0xf_f130_000c = 0`, timer
   configuration `0xf_f131_0010 = 1` (processor 0 counter becomes a user
   timer), `0xf_f130_0000/4 = 0`, start (`0xf_f130_000c = 1`). The 64-bit user
   timer is the time base for `rkbd_getc_timeout` (`0x3d090000` added to the low
   word).
5. `0x2603c-0x260b8`: drain the keyboard, send the Sun keyboard reset command
   0x01 and read the reply. No reply → `reset_goto_post` (no keyboard: POST
   always runs). The reply is `0xff`, the type byte, then the make codes of keys
   held down: 0x01 (Stop, "L1") sets `%g6` bit 0, 0x4f ('d') sets bit 1.
6. `reset_kbd_decide` 0x260bc:
   - Stop alone → "Skipping POST because of L1 keyboard command." →
     `reset_skip_post` (0x25f4c: clear NVRAM 0x1cd8..0x1cdf, go to `obp_prep`).
   - Stop-D → unless NVRAM byte 0x4e is 1 or 2 (guess: security mode), write
     0xff to NVRAM byte 1 (diag-switch? true), print "Setting diag-switch?
     because of L1-D keyboard command.", run POST.
   - neither → POST only if diag-switch? is set, else `reset_skip_post`.
7. `reset_goto_post` 0x2613c: a Ross 605/604-style module (MCNTL.IMPL != 0
   and MCNTL bit 27) skips POST. Otherwise LED on and `jmp 0xf0001000`: the
   boot-mode fetch hits trap table 1 tt 0 = `ba post_entry` (0x4000).

### 3.3 POST start (0x4000)

See §6 and [`post-tests.md`](post-tests.md). Every CPU runs `post_entry`:
arbiter = `0xf` (all MBus masters on, **all SBus arbitration off**), `%tbr` 0,
`%wim` 0, `%psr` 0xe0, jump to the low alias `0x403c`, `get_module_type`
(a dead SuperSPARC-II BIST check follows at 0x4050), then `get_mid`: MID != 8
→ `post_slave_idle_loop` (§5.1). The master runs the IU tests, sets up the MMU
registers (TLB flush, flash clear, CTX 1, CTPR `0x40000` → context table at pa
`0x400000`), and continues in `post_master_start` (0x6a00) → `post_main`
(0x163c0) → `post_exit_to_obp`.

### 3.4 From POST to OBP

1. `post_exit_to_obp(code, msg, arg...)` 0x25f18 packs the result in the
   globals: `%g1 = 0x504f5354` ('POST'), `%g2 = code` (0 pass, 2 hardware
   failure, 3 unexpected trap / watchdog, 0xff "NO POST run"),
   `%g3 = 0xffd00010 + (msg & 0x7ffff)` (the message in OBP's mapping of the
   PROM, plus 0x10), `%g4..%g7 = %o2..%o5`; clears NVRAM 0x1cd8..0x1cdf and
   jumps through the low alias to `obp_prep`.
2. `obp_prep` 0x26530: find the MID; the master writes 1 to pa
   `0xf_f1f0_0000` (**SW_RST, a software reset**). The machine resets; every CPU
   comes back through `reset_entry` → `reset_check_sysctl` (bit 1 set) →
   `obp_start` with the POST result still in `%g1-%g7` (SPARC reset does not
   clear the registers). A slave, or a master whose reset request is ignored,
   falls through into `obp_start` directly.
3. `obp_start` 0x265bc: LED on, AUXIO0 |= 4, CWP 0, `%wim = 2`; if `%g1 ==
   'POST'` copy `%g2..%g7` to `%i1..%fp`, else `%i1 = -1`. Flush the TLB (ASI 3
   va 0x400); `obp_cache_init` (0x3d178): SuperSPARC — flash-clear I and D
   caches (ASI 0x36/0x37 va 0 and 0x80000000), clear I-cache tags (ASI 0x0c at
   0x40000000 + 64n), D-cache tags (ASI 0x0e), store-buffer tags (ASI 0x30 va
   0..0x38) and control (ASI 0x32); with an MXCC: error register (ASI 2
   0x01c00e00) = all ones, clear 0x2000 E-cache tags (ASI 2 `0x01800000 +
   (n << 7)`), MXCC control (0x01c00a04) = 0x38, MCNTL |= 0x11000 (PE, TC);
   always MCNTL |= 0x4000 (SE, bus snooping) and ACTION register (ASI 0x4c) =
   0. Restore `%g1-%g6`.
4. The master jumps to the Forth code word **`rom-cold-code` (0x55d54)**. A
   slave clears its release flag NVRAM `0x0f + (MID & 3)` and spins until OBP
   writes it non-zero (`obp_slave_wait_loop` 0x266f0), then also enters
   `rom-cold-code`.

### 3.5 `rom-cold-code` (0x55d54) to the first Forth word

`rom-cold-code` is machine code inside the Forth dictionary (its header is at
`0x55d40`); the Forth pass names the word, this pass labels its inside.

1. `%psr = 0xfa0`, `%wim = 0`, POST result to `%i0..%fp`, MID to `%g6`.
2. Slave (`cold_mid_known` 0x55e28, MID > 8): its context-table pointer comes
   from the DMA2 D_ADDR register (pa `0xe_f040_0004`, `<< 12`) — the master
   uses that register as a mailbox — `srmmu_set_ctp_ctx0` (0x2747c), NVRAM
   flag `0x0f + (MID & 3)` = 0x99, continue at `cold_mmu_on`.
3. Master (`cold_master_size_memory` 0x55e84): EMC delay register pa
   `0xf_0000_0004 = 0x20a0`, then probe the SIMM slots from the top (0x1c000000
   down in 64 MB steps). A slot whose VSIMM control byte (`0x9c001000` − n·64 MB)
   is 0xf1/f2/f3/fd, or whose byte at +1 holds 0xa0/0x50, is skipped; otherwise
   0x55555555 / 0xaaaaaaaa / 0xdeadbeef / 0xfeedc0ed must read back. Aliasing
   writes at base, +32 MB, +16 MB give the size. NVRAM 0x0f = 0x80.
4. `srmmu_setup_initial_map` (0x271dc), MMU still off, allocating downwards
   from the top of memory in `%g2`: context table (size 0x40000 on a SuperSPARC,
   0x4000 on Ross), CTX 0, CTPR, 64 KB of RAM for OBP and a level-1 table; maps
   RAM 64 KB at VA `0xffef0000`, the PROM (pa `0xf_f000_0000`, 512 KB) at
   `0xffd00000` and again at `0x00000000`. With diag-switch? set it prints each
   step ("Available Memory 0x...", "Mapping RAM @ 0x..." — see
   `qemu-console.txt`). PTEs are `pa>>4 | 0x1e` (ACC 7, not cacheable).
5. `cold_mmu_on` 0x56014: MCNTL |= ME, BM cleared (bit 13 Viking, bit 14
   Ross); **`%tbr = 0xffeff000`** (OBP's trap table in RAM); `call 0xffd56044`
   moves the PC into the `0xffd00000` mapping; `%g2` = relocation base
   (origin `0xffd3e600`).
6. Master: copy 0xa00 bytes from PROM `0x6f4c0` to `0xffef0000` (the user
   area, which starts with NEXT), clear `0xffef0a00..0xffef2160`, store the POST
   result at `0xffef04a4..04b4`, memory base/size at `0xffef04bc/04c0`, cache
   type flags at `0xffef04f0..04fc`, stacks (return `0xffefec00`, data
   `0xffefebe0`), `%g5` (Forth IP) = `%g2 + 0x6b32`. Slave: flag 0x90, IP =
   `%g2 + 0x163f2`.
7. `cold_jump_forth_next` 0x561fc: `jmp %g3` (`%g3 = 0xffef0000`, NEXT in
   RAM). From here on it is Forth. The master's IP is `0xffd3e600 + 0x6b32` =
   image `0x45132`, the body of the colon word **`cold`** (`decimal init-io
   do-init ['] init-environment guarded ['] cold-hook guarded quit`); a
   slave's is `0xffd3e600 + 0x163f2` = `0x549f2`, the body of
   **`>idle-cpu-loop`** (`(idle-cpu-loop)` forever). See
   `forth-dictionary.txt`.

### 3.6 Watchdog reset (`reset_watchdog` 0x26710)

An error-mode reset while OBP runs: write 0x8000 to this CPU's interrupt
clear-pending register (pa `0xf_f140_n004`), keep the context register, then
- SuperSPARC: MCNTL &= ~0x4301 (MMU, caches, snooping off); unless MCNTL bit
  27, save PTP0, PTP2, the PTP2 tag and all 64 D-TLB entries (ASI 6, SEL 0-6,
  address `entry << 12 | SEL << 8`) byte by byte into NVRAM `0x1cd8..`
  (`reset_watchdog_save_tlb_loop`), for OBP's post-mortem; flush the TLB and
  lock two entries mapping VA `0x26000/0x27000` to the PROM (`reset_watchdog_
  lock_tlb`: ASI 6, and ASI 5 on SuperSPARC-II), leave boot mode, MMU on, jump
  to `0xffd26ba8` and on to the Forth watchdog handler `0xffd54c44`.
- Ross: flush, clear registers 0x1100-0x1700, write TLB entries mapping the
  PROM (ASI 6 va 0..0x18), continue at `0x54ff4` with the MMU on.

## 4. Module identification

`get_module_type` (0x1f22c) combines PSR[31:24] and MCNTL[31:24]:

| PSR impl/ver | MCNTL[31:24] | type | banner (`post_print_cpu_id` 0x1edb4) |
|---|---|---|---|
| 0x40 | 0..7 | 0x40 | MXCC: `TI, TMS390Z55(3.5)` (MCNTL byte 4), `(4.x)` (2), `(5.x)` (3), else `(3.0)`, + E-cache size; no MXCC: `TI, TMS390Z50(3.x) 0Mb External cache` |
| 0x41 | 0..7 | 0x41 | `TI, TMS390Z55(2.x)` / `TMS390Z50(2.x)` |
| any | 8..15 | 0x42 | `TI, STP1021PGA(1.x)` (byte 8) / `STP1021APGA(2.x)` + E-cache size |
| any | 0x17 | 0x17 | `HyperSPARC ROSS RT620/RT625/623/626 0x.. Bytes ECache` |
| any | 0x10, 0x1f | 0x13 | `ROSS605/604 module installed, NO POST run` |
| other | | -1 | `Unknown module_type, NO POST run` |

"MXCC present" is MCNTL.MB (bit 11) = 0. The banner code also ORs NVRAM
0x1ff1 with 1 (no MXCC) or 2 (MXCC); `post_main` refuses a mix (value 3:
"TMS390Z55 and TMS390Z50 Modules can NOT be mixed").

A CPU that reports PSR impl/ver 0x40 with MCNTL.MB = 1 is type 0x40 without
MXCC ("TMS390Z50(3.x) 0Mb External cache"), and the ROM skips the MXCC and
SuperSPARC-II suites. With an IOMMU that reports IMPL 0 the reset path takes
the MID from the CPU — for a no-MXCC SuperSPARC that is ASI 0x38 va 0, which
`reset_entry` loaded from the MSI MID register — and POST's `get_mid` reads
the MSI MID register directly; if that register (`0xf_e000_2000`) reads 0,
**every CPU identifies as MID 8 and runs the master path**. QEMU's default
SS-20 CPU (TI SuperSparc II, MCNTL byte 8) is type 0x42 with an MXCC: "TI, STP1021PGA(1.x)
1Mb External cache".

## 5. Multiprocessor start-up

### 5.1 During POST: arbiter + NVRAM mailboxes

- Every CPU reaches `post_entry`; the master (MID 8) runs the tests, the
  others park in **`post_slave_idle_loop`** (0x4698).
- Mailboxes (`mpcntl` 0x1f2d0), per CPU n = MID & 3, in the NVRAM (pa
  `0xf_f120_xxxx`, byte wide): status byte `0x1e00 + 5n`, command word
  `0x1e01 + 5n` (4 bytes, big endian), argument block `0x1f00 + 16n` (4 words);
  console spin lock byte `0x1e20` (`ldstuba`).
- The slave writes 3 ("idle") to its command word, then **clears its own bit
  (1 << n) in the arbiter enable register** — it stops on its next MBus access.
  When it runs again it polls the command word until bits 1:0 are 0 (a
  function address), fetches four arguments, sets `%tbr = n << 12`, enables
  traps and calls the function; then back to the top (idle, arbitration off).
- `mp_dispatch(mid, func, a0..a3)` 0x1f104 writes the arguments and the address,
  then sets arbiter bits 3:0 to `1 << n`: the parked CPU resumes.
  `mp_wait_idle(mid)` 0x1f198 waits for the command word to end in 3 and for the
  slave's arbiter bit to drop, then clears bits 3:1.
- `mp_probe_slaves` 0x1f56c (from `post_run`): statuses = 0xff, master's = 8;
  for MID 9..11 whose command word reads 3 it dispatches `mpcntl(4, mid, mid)`
  and polls (50000 times) for status == MID. A CPU that never answers has its
  arbiter bit cleared and is reported "CPU_#n ******* NOT installed *******".
- `post_print_cpu_banner` dispatches `post_print_cpu_id` and
  `mp_slave_setup_mmu` (CTX = n, CTPR `0x40000`, `%tbr = n << 12`) to each slave.
- At the end of `post_main` the master dispatches **`post_main` itself** to each
  slave in turn (`mp_run_with_target`, which first points the interrupt target
  register pa `0xf_f141_0010` at that CPU), so every CPU runs the full CPU and
  system test list, one at a time.

A core that lets all CPUs run freely from reset still passes this protocol
only if writing a CPU's arbiter bit to 0 really stops it: otherwise the slave
spins on the mailbox while the master is running tests (harmless for the
mailbox, but the slave's own MBus traffic then runs concurrently with the
master's cache and memory tests).

### 5.2 After POST: release flags, idle loop, romvec cpustart

1. After the software reset every CPU passes `obp_start`; slaves wait on their
   release flag NVRAM `0x0f + n` (cleared by the slave, set non-zero by OBP).
2. Released, a slave runs `rom-cold-code`: context-table pointer from the DMA2
   D_ADDR register (§3.5), MMU on, flag 0x99/0x90, then the Forth word
   `>idle-cpu-loop`, which spins in the code word `(idle-cpu-loop)` (0x548b0).
3. An OS starts a CPU through the romvec (`struct linux_romvec` at 0x3d580,
   V3 entries at +0x108..+0x114): **`romvec_cpustart(node, &ctxtbl, ctx, pc)`**
   (0x3dc68) takes the PROM lock (swap on VA 0xffef2058), posts CTPR
   (`[0xffef204c]`), context (`[0xffef2048]`) and PC (`[0xffef2050]`), sets the
   target's bit in the started mask and waits up to 100000 loops for the
   target's state byte (`[0xffef04dc] + index`) to become 0xf0.
4. The idle loop sees the request and jumps (via `jmp 0xffd274ac`) to
   **`cpu_enter_client`** (0x274ac): context and CTPR from the posted values,
   TLB and cache flush, all registers cleared, `jmp` to the OS's PC.
   `romvec_cpustop/idle/resume` (0x3dda4/0x3de70/0x3df48) use the same state
   words.

### 5.3 QEMU

With `-smp 2` QEMU 8.2.2 still prints "CPU_#1 ******* NOT installed *******":
QEMU keeps secondary CPUs halted until they receive an interrupt and does not
model the arbiter-enable start/stop, so this ROM's MP code cannot be
exercised under QEMU.

## 6. POST

### 6.1 Flow

| Step | Where | What |
|---|---|---|
| 1 | `post_entry` 0x4000 | arbiter 0xf, `%tbr/%wim/%psr`, module type, slaves park |
| 2 | 0x40b8 | master: delay 0x20000, interrupt target = 0, `%psr = 0x10e0` (EF, S, PS, ET), init ttya/ttyb (`post_zs_init_serial`, 9600 8N1) |
| 3 | `post_iu_globals_test` 0x40fc, `post_iu_window_test` 0x41dc | IU register file and window tests (no RAM) |
| 4 | `post_iu_done` 0x45a0 | `%wim = 2`; HyperSPARC or SuperSPARC MMU register set-up; watchdog-reset check |
| 5 | `post_master_start` 0x6a00 | NVRAM 0x1ff1 = 0, 0x1ff2 = 2 (print test names); `%sp = 0x1fba0`; keyboard: Stop-D, detect; decide whether to run |
| 6 | `post_run` 0x6b30 | `mp_probe_slaves`, banner, `post_main` |
| 7 | `post_main` 0x163c0 | CPU suites, then system tests (order in [`post-tests.md`](post-tests.md)) |
| 8 | `post_main_run_slaves` 0x16b68 | `post_main` on each slave |
| 9 | `post_main_passed` 0x16bf4 | `post_exit_to_obp(0, "STATUS : Power-On SelfTest PASSED")` |

Whether POST runs at all: the reset path runs it on power-on when diag-switch?
(NVRAM byte 1) is set, when Stop-D is held, or when there is no keyboard;
Stop alone skips it. `post_master_start` checks again: with a keyboard,
POST runs only with diag-switch? set or Stop-D; without a keyboard it runs
anyway, and quietly (NVRAM 0x1ff2 = 0, no test names) when diag-switch? is
clear.

### 6.2 Output

- All POST output goes to **ttya** (ESCC1 channel A, control pa `0xf_f110_0004`,
  data `0xf_f110_0006`), 9600 8N1, through `post_printf` (0x11a20): `%1`..`%5`
  print the argument as 8 hex digits, the rest is copied verbatim; the console
  is MP-locked through NVRAM byte 0x1e20.
- Test names ("MMU ICACHE_TLB bit pattern Test", ...) are printed only when
  NVRAM 0x1ff2 == 2, i.e. `%g4` bit 1 in `post_main`. Errors are always
  printed: "ERROR : ...", the CPU/slot ("<<< CPU_n on MBus Slot_m >>>"), a
  U-number (chip location, table at `0x17f00`/`0x18540`) and a pin name
  (table at `0x16120`).
- Progress is shown on the **keyboard LEDs**: `kbd_send(0x0e)` (Sun keyboard
  LED command) followed by a mask brackets groups of tests (8 = Caps Lock on,
  0 = off); failure exits leave mask 4/9/1/0xc/2 depending on the class. The
  single system LED (AUXIO0 bit 0) is lit by the reset path.
- The result reaches OBP through `%g1-%g7` (§3.4) and the Forth side reports
  it.

### 6.3 What QEMU shows

[`qemu-console.txt`](qemu-console.txt): "Power-ON Reset", the banner, CPU_#0
"TI, STP1021PGA(1.x) 1Mb External cache", "No Keyboard Detected", then the
first SuperSPARC-II test fails — "MMU ICACHE_TLB bit pattern Test / Case 0xf:
I_TLB mis-matched exp=55555000 obs=00000000" — because QEMU does not model the
TLB diagnostic ASIs. POST exits with the failure, OBP builds its page tables
(the "Mapping ..." lines, printed because diag-switch? is set) and stops at
"Cpu #0 Data Access Error".

## 7. Trap handling in POST

`%psr` has ET = 1 during most of POST. Handlers (all reached through
`sethi/or %l4 ; jmp %l4 ; rd %psr,%l0`, so `%l0` = PSR, `%l1` = PC,
`%l2` = nPC):

| tt | Handler | Action |
|---|---|---|
| 1, 2-4, 7, 9, 0x0a-0x10, 0x20-0x7f (not 0x2b), 0x82-0xff | `trap_expected_skip` 0x47d0 and its variants 0x4804, 0x4920, 0x4954 | if tt == `%g5` (the trap the test announced): clear `%g5`, resume **after** the trapping instruction (`jmp %l2; rett %l2+4`); else `trap_unexpected_sync` |
| 5 | `trap_window_overflow` 0x4838 | rotate WIM right, save the window to `[%sp]` with `stda` through ASI 0x20, retry |
| 6 | `trap_window_underflow` 0x48ac | rotate WIM left, reload the window through ASI 0x20, retry |
| 8 | `trap_fp_exception` 0x5884 | expected check; store `%fsr` to pa 0x600010 and drain the FP queue (`std %fq` to 0x600018) while FSR.qne; skip the instruction |
| 0x11-0x1f | `irq_level_1..15` 0x49c0.. | expected level in `%g5` (or `%g6`); acknowledge the soft interrupt by writing bit 16+level to this CPU's clear-pending register pa `0xf_f140_n004` and reading `0xf_f140_n000`; `%g7` selects device acknowledges (parallel port, DMA2, counters, EMC) for the device tests; retry the interrupted instruction |
| 0x2b | `trap_data_store_error` 0x57d4 | read SFSR (clears it), expected check, retry |
| 0x80 (`ta 0`) | `trap_ta0_error_mode` 0x5810 | `ta 0x7f` with traps disabled → error mode → watchdog reset |
| 0x81 (`ta 1`) | `trap_ta1_to_supervisor` 0x5838 | set PSR.PS so `rett` returns in supervisor mode |

A trap nobody expected is reported by `trap_unexpected_sync` 0x5ee0 /
`trap_unexpected_async` 0x5d08 (MSI async fault registers pa
`0xf_e000_1000/1004`, "Unexpected Synchronous/Asynchronous Trap Taken, Trap
Type = tt", PSR/PC/TBR, SFSR/SFAR as "Viking Fault Status/Address Reg") and
ends POST with `post_exit_to_obp(3, "FAILED ... Unexpected Trap")`. An
unexpected watchdog reset found at `post_iu_done` (SFSR bit 17 / Ross reset
register bit 2) is reported by `trap_unexpected_watchdog` 0x6184.

## 8. Bring-up contract for the core (summary)

What the machine code needs before any Forth runs, in order of use (details in
[`hardware-access.md`](hardware-access.md)):

1. Boot-mode instruction fetch from the PROM at any VA; MMU-off data accesses
   to memory; bypass ASIs 0x20/0x2e/0x2f; ASI 9 reads of the PROM.
2. MCNTL (IMPL/VER, MB, BM), PSR impl/ver, SFSR bit 17 on error-mode reset;
   64-bit ASI 0x38 va 0 scratch register (no-MXCC SuperSPARC).
3. A per-CPU MID: the MSI MID register (`0xf_e000_2000`) must return the
   MBus ID of the CPU that reads it (and/or ASI 0x38 va 0 must keep a 64-bit
   value, or an MXCC port register must exist); the MSI arbiter enable
   (`0xf_e000_1008`) with the CPU stop/start semantics of the MP protocol;
   IOMMU control IMPL field (`0xf_e000_0000`); system control/status
   (`0xf_f1f0_0000`) with SW_RST and the SW-reset status bit.
4. Z8530 ESCC at `0xf_f110_0000` (ttya) and `0xf_f100_0000` (keyboard, 1200
   baud, Sun keyboard reset/LED/layout commands), NVRAM/TOD at `0xf_f120_0000`
   (byte wide, `ldstuba` on 0x1e20), AUXIO0 LED.
5. Processor counter 0 as a 64-bit user timer (`0xf_f131_0010` bit 0,
   `0xf_f130_000c` start/stop) for keyboard time-outs.
6. For OBP start-up: EMC delay register (`0xf_0000_0004`), memory aliasing on
   64 MB slots, VSIMM control space reads that do not fault, DMA2 D_ADDR as a
   read/write mailbox, MXCC error/control/tag space (if MB = 0), flash-clear
   ASIs 0x36/0x37 and tag ASIs 0x0c/0x0e/0x30/0x32 (writes may be ignored),
   ACTION ASI 0x4c.

## 9. Coverage and classification

Byte classification of the image by the generated listing (`romdis.json`
plus `forth.json`); "zero" is 1-15-byte alignment padding between routines
that has no region of its own.

| Area | Bytes | Code | String | Data | FCode | Padding | Forth pass |
|---|---|---|---|---|---|---|---|
| `0x00000-0x27857` trap tables, POST, reset | 161 880 | 126 284 | 32 577 | 1 144 | – | 1 716 + 159 zero | – |
| `0x27858-0x3d11f` help, FCode, font | 88 264 | – | – | 18 476 | 69 784 | 4 | – |
| `0x3d120-0x3e5ff` C support, romvec | 5 344 | 4 600 | 208 | 336 | – | 176 + 24 zero | – |
| `0x3e600-0x6febf` Forth kernel, dictionary | 203 968 | 20 020 | – | 2 528 | – | – | 177 950 dictionary; 2 446 undecoded |
| `0x6fec0-0x7ffff` erased | 65 856 | – | – | – | – | 65 856 | – |

Names: 1 013 labels, 250 block comments and 486 end-of-line comments in
`romdis.json` (the Forth pass adds 4 747 word labels). POST test code that no
caller reaches (33 dead tests, dead runners and error blocks) is entered
explicitly (`entries` with empty names) so it is decoded and labelled; so are
the few dead instructions after unconditional branches. The 2 446
undecoded bytes are the Forth pass's gaps (see the header of
`forth-dictionary.txt`).

## 10. Open items

1. **MP start/stop hardware semantics.** The POST relies on a CPU stopping
   when its bit in the arbiter enable register is cleared and resuming when it
   is set (Sun4M §5.1.2 describes arbitration, not stalls, and warns that a
   parked master may keep the bus). Not observable under QEMU (secondaries stay
   halted). Needs a real-hardware trace or the MSI specification.
2. **CPU identification** (README §4, post-tests §11.2): if the MSI MID
   register reads 0 and ASI 0x38 va 0 does not hold its value, every CPU of
   an MP build takes the master path. Confirm in simulation before trying the
   Sun PROM with more than one CPU.
3. **`post_exit_to_obp` message pointer** `%g3 = 0xffd00010 + (msg & 0x7ffff)`:
   the `+0x10` is unexplained; check how the Forth side prints it.
4. **NVRAM byte 0x4e** (Stop-D ignored when it is 1 or 2) — guessed to be
   the security mode; check against the Forth `security-mode` option offset.
5. **SFSR bit 17** as "error-mode (watchdog) reset" and **ASI 0x38 va 0** as a
   64-bit scratch register come from how the code uses them; the SuperSPARC
   datasheet that would confirm them (`SuperSparc.pdf`) is an image-only scan
   and was not OCRed.
6. **MXCC control value** `0x38` written by `obp_cache_init` (parity, multiple
   command, prefetch) does not include the E-cache enable bit 2 as the MXCC
   group reads the bits; who enables the E-cache later (Forth?) is not traced.
7. **`%sp` in POST** is the keyboard type after `post_master_start`; the POST
   depends on never spilling a window (WIM 0/2). A core that takes a window
   trap earlier than expected would corrupt memory through `[%sp]`.
8. **Timing**: the counter/timer tests assume roughly 0.7 µs per uncached PROM
   instruction (system group); a fast core may see "No interrupt received".
9. **Unreferenced tables** `0x121c0-0x1226b` (IOPTE-like) and
   `0x12324-0x123bf` (`0xff00n000` words) have no code reference; their users
   were probably removed with the interactive POST menu.
10. **FCode images and help texts** are classified as regions only; decoding
    them (tokenizer, `device-tree.md`) belongs to the Forth pass.
11. **Keyboard commands other than Stop / Stop-D** (Stop-A, Stop-N, Stop-F)
    are not in the machine code; they are handled by Forth after the reset.
12. **HyperSPARC** paths are mapped and named but only briefly documented
    (post-tests §10); a few HyperSPARC register bit names come from Linux
    `ross.h` and are unconfirmed.
13. **QEMU** reports IOMMU version 0x13 and SuperSPARC-II. IOMMU IMPL 0 and
    a SuperSPARC-I MCNTL take different branches in `reset_find_mid`,
    `get_module_type` and `post_main`, so the QEMU trace does not cover those
    paths (POST-core and 0x40 paths are reached only by static analysis).

## 11. Regenerating

```
python3 tools/romdis/romdis.py docs/rom-disassembly/ss20-obp-2.25/romdis.json \
    -o docs/rom-disassembly/ss20-obp-2.25/listing.s --db /tmp/ss20-analysis.json
```

The config `include`s `forth.json` (Forth pass) and `qemu-trace.json` (every
PC QEMU executed). Anonymous entries (trace PCs, dead-code starts) are walked
after the named ones so the constant tracking of the real flow wins.
