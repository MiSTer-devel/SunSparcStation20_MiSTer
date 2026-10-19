# SPARCstation 5 boot PROM (`ss5.bin`) — machine-code side

This folder documents the
SPARCstation 5 OpenBoot PROM: its
image map, how the CPU enters it, the reset flow up to the first Forth word,
trap handling, and the power-on self-test (POST). Companion files:

| File | Contents |
|---|---|
| [`listing.s`](listing.s) | full annotated disassembly (generated, do not edit) |
| [`romdis.json`](romdis.json) | the disassembler configuration: entries, labels, block comments, regions |
| [`post-tests.md`](post-tests.md) | catalogue of every POST test, plus the candidate CPU test suite |
| [`hardware-access.md`](hardware-access.md) | every physical address and ASI the machine code touches |
| `qemu-console.txt`, `qemu-trace.json` | console and executed-address trace of this ROM under `qemu-system-sparc -M SS-5` |
| `forth.json`, `forth-dictionary.txt`, `device-tree.md` | the Forth side (written by the Forth-dictionary pass) |

Addresses in this folder are **link addresses** (physical PROM address
`0x70000000` + image offset) unless marked otherwise. A value like
"`0x7000bd98`" in the text is the instruction at image offset `0xbd98`.

## 1. The image

| Property | Value |
|---|---|
| File | `scratch/SparcStation/ss5.bin` (not in the repository) |
| Size | 262 144 bytes (256 KiB, one 27C020-class EPROM) |
| MD5 | `6364e9a6f5368e2ecc4e9c1d915a93ae` |
| Firmware | **OpenBoot 2.15**. The banner prints `ROM Rev. 2.15` (seen under QEMU, [`qemu-console.txt`](qemu-console.txt)); the version is assembled by the Forth word `.version` (header at `0x700311e1`). |
| Build stamp | `95/03/29 14:21:55` (string at `0x700311a3`) |
| Forth kernel | "Forthmacs", Bradley Forthware (string at `0x70017ebd`) |
| CPU | microSPARC-II ("Swift", Fujitsu MB86904). OBP prints `Probing CPU FMI,MB86904`. The POST blames failures on the "Swift Module". |
| Checksum | the last halfword (`0x7003fffe`) is `0xb8d8` = the 16-bit sum of all bytes `0x00000`-`0x3fffd`. The POST in this ROM does **not** verify it (the "EPROM Checksum Test" name and message exist, but no code references them). |

### Image map

| Offset range | Size | Contents | Classified by |
|---|---|---|---|
| `0x00000-0x00fff` | 4 KiB | trap table, 256 × 16 bytes. Entry 0 = reset (`ba reset_entry`); every other entry is `sethi/or %l4 ; jmp %l4 ; rd %psr,%l0` to a POST handler | this pass |
| `0x01000-0x02127` | | `post_entry` and the POST trap handlers (`trap_*`, `report_*`) | this pass |
| `0x02140-0x07843` | | `post_main`, FPU, DMA2/ESP/PPORT, cache, interrupt, LANCE, IOMMU, MMU, timer, NVRAM/TOD tests; `post_printf`, ttya/keyboard I/O, memory sizing | this pass |
| `0x07844-0x0789f` | 92 | memory sizing tables | this pass |
| `0x078a0-0x098bf` | 8 KiB | POST messages; POST test names in 32-byte slots (`0x70008a00` + 32·n) | this pass |
| `0x098c0-0x0a91f` | | `post_sequencer`, failure paths, march tests (`nta_march_test`, `mem_march_test`) | this pass |
| `0x0a920-0x0aa4f` | | Z85C30 init tables, U-number (chip location) strings | this pass |
| `0x0aa60-0x0bd0f` | | keyboard detect, PCR/PSR/TBR/WIM accessor library, ASI dispatch stubs, block copy/fill, NVRAM and LED helpers, `post_exit_soft_reset` | this pass |
| `0x0bd10-0x0bd97` | | boot messages (`Power-ON Reset`, L1 / L1-D messages) | this pass |
| `0x0bd98-0x0c11f` | | **`reset_entry`** and the three reset paths; TLB / cache init | this pass |
| `0x0c120-0x0c3df` | | boot-time Z85C30 routines (ttya, keyboard) and `boot_puts` | this pass |
| `0x0c3e0-0x0c90f` | | compiled C used by the Forth kernel: 64-bit memory test, `printf`, data (pointers into the kernel) | this pass |
| `0x0c910-0x0ce9f` | | SRMMU boot page-table builder (`mmu_build_boot_tables`, `mmu_map_range`) | this pass |
| `0x0cea0-0x0d09f` | 512 | `sun-logo`, 64×64 1 bpp bitmap | this pass |
| `0x0d0a0-0x0f57f` | 9.4 KiB | console font: 32-byte header (`"font"`, 12×22, 2 bytes/row, first 0x20, 0xe0 glyphs) + 224 glyphs × 42 bytes | this pass |
| `0x0f580-0x0f6ff` | | C `get-unum` (bank → SIMM J-number) and memory-error report, their tables and strings | this pass |
| `0x0f700-0x3c6db` | 181 KiB | Forth: compressed help-text word list (`0x0f700`), kernel, dictionary; machine-code primitives inside it (e.g. `obp_cold_entry` at `0x2a86c`, trap entry at `0x27c9c`); the initial RAM image `0x3bd60-0x3c6df` | Forth pass (`forth.json`) |
| `0x3c6dc-0x3fffd` | 14 KiB | erased (`0xff`) | this pass |
| `0x3fffe-0x3ffff` | 2 | checksum `0xb8d8` | this pass |

Every byte of `0x00000-0x0f6ff` and `0x3c6dc-0x3ffff` is classified in
[`romdis.json`](romdis.json) as code, data, string or padding (43 200 bytes of
code, 10 504 data, 9 124 string, 404 padding, plus the 14 KiB erased tail and
the checksum). The span in between belongs to the Forth pass (`forth.json`);
until that file exists the listing shows it as raw words, with the code the
QEMU trace found inside it decoded.

## 2. How the CPU enters the ROM

microSPARC-II reset (microSPARC-II User's Manual §5.6.1, Table 40):

- The IU starts at PC `0`, nPC `4`, supervisor, traps disabled (ET=0).
- The MMU Processor Control Register (PCR, ASI 4 VA 0) comes up with **BM=1**
  (boot mode, bit 14) and EN (bit 0), DE (bit 8), IE (bit 9) = 0.
- In boot mode every instruction fetch (ASI 8/9) is sent to
  **PA[30:28]=7, PA[27:0]=VA[27:0]**: whatever the PC, the fetch reads the
  PROM at `0x70000000`. Data accesses pass through (PA = VA[30:0]) because the
  MMU is off; ASI 0x20 (MMU bypass) always gives PA = VA[30:0].

So the ROM runs at three PC aliases:

| PC range | When | Why |
|---|---|---|
| `0x0000xxxx` | reset, reset paths, `obp_cold_entry` until it switches | reset PC is 0; boot-mode fetch maps it to the PROM |
| `0x7000xxxx` | the POST (`jmp 0x70001000` at `0x7000bce4`) | the link address; also a boot-mode fetch |
| `0xffd0xxxx`–`0xffd3xxxx` | the Forth kernel | OBP maps the PROM at `0xffd00000` (`mmu_build_boot_tables`) |

Addresses of ROM data that the reset code passes around are built as
`0xffd0xxxx & 0x7ffff` (a ROM *offset*), and `boot_puts` ORs `0x70000000`
back in; this is why many constants in the listing show `= ROM 0x...`.
The listing therefore declares two aliases in `romdis.json`: `0xffd00000`
(code and data) and `0x00000000` (flow only).

## 3. Reset flow, instruction by instruction

### 3.1 Reset entry — classify the reset (`0x70000000`, `0x7000bd98`)

| Addr | Instruction | Effect |
|---|---|---|
| `0x70000000` | `ba reset_entry` / `rd %psr,%l0` | trap-table slot 0 |
| `0x7000bd98` | `mov %g1,%l3` | save `%g1` (it carries the POST hand-off magic, §3.4) |
| `0x7000bda0` | `lda [0x71f00000] 0x20, %g1` | read the **system control/status register** |
| `0x7000bda4` | `andcc %g1,0x10` → `reset_watchdog` | bit 4 set: watchdog reset (the POST reports the same bit as "Watch Dog Reset", `0x70001058`). Bit 4 is not in the generic Sun-4M definition (§5.1.1); this meaning is inferred from the code. |
| `0x7000bdb0` | `andcc %g1,2` → `reset_sw_reset` | bit 1 (Sun-4M SW_RST_STAT) set: software reset, i.e. the POST just finished (§3.4) |
| `0x7000bdbc` | `wr %g0,%tbr` ; `wr 0xfe0,%psr` ; `wr %g0,%wim` | power-on: TBR=0, PSR = PIL 15, S, PS, ET=1, CWP 0; WIM=0 |
| `0x7000bde0` | `ba reset_power_on` | |

The ROM never writes the status register except to request a software reset
(`sta 1,[0x71f00000]` at `0x7000bea8` and `0x7000a7d0`).

### 3.2 Power-on path (`reset_power_on`, `0x7000bb48`)

1. `0x7000bb48`: clear `%g1`-`%g7`.
2. `0x7000bb64`: `escc_init_9600_8n1(0x71100004)` — ttya = Z85C30 at
   `0x71100000`, channel A control `+4`, data `+6`. Register writes (reg, value)
   via `escc_wr_reg` (`0x7000c120`: writes the register number, then the
   value, as bytes to the control port): WR9=0x02, WR4=0x44 (×16 clock, 1
   stop, no parity), WR3=0xc0, WR5=0x60, WR14=0x82, WR11=0x55 (clocks from the
   BRG), WR12=0x0e, WR13=0x00, WR3=0xc1 (Rx enable, 8 bit), WR5=0x68 (Tx
   enable, 8 bit), WR14=0x83 (BRG on), WR0=0x10. With the SS5's 4.9152 MHz
   PCLK, time constant 14 gives 4 915 200 / (2·16·(14+2)) = **9600 baud, 8N1**.
3. `0x7000bb70`: `boot_puts("\n\rPower-ON Reset\n\r")`. `boot_puts`
   (`0x7000c28c`) prints only if NVRAM byte `0x71200001` (the
   **`diag-switch?`** NVRAM parameter) is non-zero; it reads the string with
   `lduba [0x7000xxxx] 0x20` and sends each byte with `ttya_putc_boot`
   (`0x7000c240`: poll RR0 bit 2 = Tx empty, write data, then poll RR1 bit 0 =
   all sent).
4. `0x7000bb88`: `escc_init_9600_8n1(0x71000004)` then `escc_set_1200_baud`
   (WR12=0x7e, WR13=0): keyboard = ESCC0 channel A at `0x71000004`, **1200 baud**.
5. `0x7000bb9c`-`0x7000bbe4`: counters. `0x71d0000c`←0 (user-timer stop),
   `0x71d10010`←1 (timer configuration: processor 0 counter = **user
   timer**), `0x71d00000`/`0x71d00004`←0, `0x71d0000c`←1 (run), then MSW/LSW←0
   again. `kbd_getc_timeout` (`0x7000c354`) uses `ldda [0x71d00000] 0x20` and
   times out after `0x3d090000` LSW units; the count is in bits 31:9 (500 ns
   per bit 9), so that is 2 000 000 × 500 ns = **1 s**.
6. `0x7000bbe8`: drain the keyboard until 1 s of silence, then
   `kbd_putc_boot(0x01)` (Sun keyboard *reset* command).
7. `0x7000bc08`: read the answer. **Timeout → no keyboard → run the POST**
   (`0x7000bc1c` → `0x7000bce0`). Otherwise loop until silence: byte `0x01`
   (the **Stop/L1** key, key-down code) sets `%g6` bit 0, byte `0x4f` (the
   **d** key) sets `%g6` bit 1; `0xff` (reset acknowledge) is skipped.
8. Decision (`0x7000bc60`):
   - `%g6`=1 (Stop held): `boot_puts("Skipping POST because of L1 keyboard command.")`
     and go to 3.4 without running the POST (`soft_reset_via_boot_space`).
   - `%g6`=3 (Stop-d held): if NVRAM `0x7120004e` (the `security-mode`
     parameter, offset from its Forth header) is 1 or 2 the `d` is ignored
     (treated as Stop alone). Otherwise write `0xff` to `0x71200001`
     (`diag-switch?` = true), print "Setting diag-switch? because of L1-D
     keyboard command." and run the POST.
   - otherwise: run the POST if `diag-switch?` (`0x71200001`) ≠ 0, else skip it.
9. "Run the POST" is `sethi %hi(0x70001000),%l3 ; jmp %l3` (`0x7000bce0`) →
   `post_entry` at the link address.

These rules are the service manual's (SS5 Model 110 SM, "After Power Is
Switched On"): POST runs if `diag-switch?` is true, if Stop-d is held, or if
no keyboard is attached; Stop alone skips it.

### 3.3 POST (`post_entry` `0x70001000`, `post_main` `0x70002140`)

1. `0x70001000`: `sta %g0,[0x10002000] 0x20` — the microSPARC-II **MID
   register** (SBAE bits = 0: no SBus master may arbitrate).
2. PSR=`0x10e0` (EF=1, S, PS, ET=1, PIL 0), TBR=0, WIM=0; `escc_init_ttya(0x71100000)`
   (table-driven init, `0x7000a860`, same values as above); PSR again, TBR=0,
   WIM=2.
3. `0x7000105c`: status register bit 4 set → `report_watchdog_reset`.
4. `0x7000106c`: `sta %g0,[0x400] 0x3` (flush the entire TLB),
   `dcache_clear_tags` (512 × `sta 0,[16·n] 0xe`), `icache_clear_tags`
   (512 × `sta 0,[32·n] 0xc`), context=0, context-table pointer=0.
5. `post_main`: PSR=`0x10e0`, **TBR=`0x70000000`**, WIM=2, globals cleared.
   `mem_size_banks` (`0x7000769c`) sizes the eight 32 MB SIMM banks
   (`0x00000000`, `0x02000000`, … `0x0e000000`) and returns the configuration
   in `%g2` (bit 31 = nothing found yet, bit 30 = memory found, bits 27:25 =
   base of the lowest populated bank, read back with mask `0x0f000000`, and a
   3-bit size code per bank in bits 23:0; details in
   [`post-tests.md`](post-tests.md) §6.2).
6. `0x700021b4`: **`%sp` = (first bank base) + `0xc00`**, or `0xc00` if no
   memory was found. All POST scratch memory is relative to that base
   (`base+0x2000`, `base+0x2100` …); the window handlers use ASI 0x20, so the
   stack is physical.
7. Re-initialise ttya and the keyboard channel, read the keyboard 11 times
   (`kbd_recv_timeout`) looking for 0x01 and 0x4f, `kbd_detect`
   (`0x7000aa60`: reset, 0xff, keyboard type, layout).
8. Mode (`0x70002224`): Stop-d seen, or `diag-switch?` set → **diagnostic
   mode** (`%g4` |= 2: test names are printed); no keyboard → silent POST
   (`%g4` &= ~2); keyboard present and not diag → `post_exit_soft_reset(-1)`
   (POST skipped).
9. `post_sequencer` (`0x700098c0`) runs the tests (order in
   [`post-tests.md`](post-tests.md)). A failing test makes the sequencer set
   a keyboard LED pattern and call `post_exit_soft_reset(2, message)`; if all
   pass it calls `post_exit_soft_reset(0, "Power-On Selftest PASSED")`.

### 3.4 Leaving the POST: a software reset carries the result (`post_exit_soft_reset`, `0x7000bac0`)

The POST never jumps into OBP. It resets the machine and passes its result in
the global registers, which survive the reset:

| Register | Value |
|---|---|
| `%g1` | `0x504f5354` = ASCII `'POST'` (hand-off magic) |
| `%g2` | status: `0` passed, `2` failed, `-1` not run |
| `%g3` | `0xffd00010 + (message & 0x7ffff)`: OBP virtual address of the result message **plus 16** (why +16 is not visible from the machine code; the Forth word `show-post-results` consumes it) |
| `%g4`-`%g7` | the caller's `%o2`-`%o5` |

Then it prints `"\r\n"`, writes 0 eight times to NVRAM byte `0x71201dd8`
(the loop does not advance the address), and jumps through the boot-mode
alias (`jmp 0xbb40` → `ba sysctl_soft_reset`) to
`sta 1,[0x71f00000] 0x20` (`0x7000beb0`): **SW_RST**. If the reset does not
happen, execution falls through into `obp_start_after_sw_reset` at
`0x7000bec4` anyway, so a core without the reset bit still reaches OBP.

After the reset `reset_entry` sees status bit 1 and goes to
`obp_start_after_sw_reset` (`0x7000bec4`):

1. PSR=`0xfe0`, WIM=0; `escc_init_9600_8n1(ttya)`.
2. `%g1 == 'POST'`? then `%i1..%i5,%fp` = `%g2..%g7`; else `%i1` = -1.
3. `boot_puts("initializing TLB")`, `tlb_init_clear` (`0x7000be70`): zero TLB
   diagnostic words `[0x000..0x1fc] 6` (PTE and lower tag of the 64 entries)
   and `[0x300..0x3fc] 6` (upper tag / CAM), and the TLB replacement control
   register (`[0x1000] 4`).
4. `boot_puts("initializing cache")`, `cache_init_enable` (`0x7000be18`): zero
   the I-cache tags (`[0..0x3fe0] 0xc`, 32-byte steps) and D-cache tags
   (`[0..0x1ff0] 0xe`, 16-byte steps), then **PCR |= 0x300** (IE | DE: caches
   on; they cache nothing until the MMU is on because AC=0), `flush`, 8 nops.
5. `%g1..%g6` = saved results; `ba obp_cold_entry` (`0x7002a86c`).

Under QEMU 8.2.2 the hand-off is lost: after the (failed) POST the Forth
side reads status `0xffffffff` at `0xffef04b0` (`h# ffef04b0 l@ .` at the
`ok` prompt), because QEMU's system reset clears `%g1`. Real hardware keeps
the globals.

### 3.5 Kernel start (`obp_cold_entry`, `0x7002a86c`)

This is machine code inside the Forth region; it is the last step before the
first Forth word.

1. `0x7002a86c`: PSR=`0xfa0` (PIL 15, S, ET=1, EF=0), WIM=0; `%i1..%i5` =
   `%g1..%g5` (the POST results).
2. **Find memory, top down** (`0x7002a8b0`): `%l0` = `0x10000000`; loop:
   `%l0` -= 32 MB, store `0x55555555`, `0xaaaaaaaa`, `0xdeadbeef`,
   `0xfeedc0ed` at `%l0+0..0xc`, read back `+0` and `+8`; stop at the first
   (highest) bank where both match. With no memory at all this loop never ends.
3. **Size that bank** (`0x7002a908`): store `0x11111111` at `+0`,
   `0x22222222` at `+2 MB`, `0x33333333` at `+4 MB`, `0x44444444` at `+8 MB`,
   `0x55555555` at `+16 MB`, then decide from which writes aliased:
   `[+0]`=0x11111111 → 32 MB; `[+0]`=0x44444444 → 8 MB at base+16 MB;
   `[+8 MB]`=0x44444444 → 16 MB; `[+2 MB]`=0x22222222 → 8 MB if
   `[+4 MB]`=0x33333333 else 4 MB; else `[+4 MB]`=0x33333333 → 2 MB at
   base+4 MB, else 2 MB. Result: `%fp` = region base, `%i7` = size.
4. `0x7002aa28`: `mmu_build_boot_tables(top = base + size, 0x1000)`
   (`0x7000c984`, stackless: it keeps its return address in `%sp`): allocates
   downwards from the top of that region with `mmu_alloc_clear` (zeroed via
   ASI 0x20) and prints its progress with `boot_puts`:
   - "Allocating SRMMU Context Table": 4 KiB context table; "Setting SRMMU
     Context Register": context=0; "Setting SRMMU Context Table Pointer
     Register": CTPR = table >> 4.
   - a 64 KiB block for the kernel's RAM; "Allocating SRMMU Level 1 Table":
     1 KiB, context 0 entry = PTD.
   - "Mapping RAM": `mmu_map_range(pa = the 64 KiB block, va = 0xffef0000, 64 KiB)`.
   - "Mapping ROM": `mmu_map_range(0x70000000, va 0xffd00000, 512 KiB)` and
     `mmu_map_range(0x70000000, va 0x00000000, 512 KiB)` (keeps the boot-mode
     PCs valid once translation starts).
   - `mmu_map_range` (`0x7000cbd0`) builds 3-level SRMMU tables (L2/L3 tables
     of 256 bytes allocated on demand) and writes 4 KiB PTEs
     `((pa >> 4) & 0x0fffff00) | 0x1e`: ET=2, ACC=7 (supervisor RWX),
     **not cacheable** (C=0; the cacheable variant `0x9e` is selected only if
     `mmu_ret_zero` returned non-zero, and it always returns 0).
5. `0x7002aa40`: **PCR |= EN, PCR &= ~BM** (`0x4000`), `flush`, 5 nops: the MMU
   is on, boot mode is off; the PC (`0x0002aa5c`…) now translates through the
   VA-0 mapping. TBR=`0xffeff000`.
6. `0x7002aa7c`: `call 0xffd2aa80` — encoded as a PC-relative call from PC
   `0x0002aa7c` (the listing shows it as `0x6fd2aa80` relative to the link
   address), it moves execution to the `0xffd00000` alias. `call .+4` then
   gives the PC; **`%g2` = PC − `0x15084` = `0xffd15a00`**, the Forth token
   origin (PROM `0x70015a00`).
7. Copy the initial RAM image `0xffd3bd60..0xffd3c6df` (PROM
   `0x7003bd60`, 0x980 bytes) to **`0xffef0000`**, zero `0xffef0980..0xffef1fff`.
8. Store for the Forth side (all in the RAM image): `[0xffef04bc]` = region
   base >> 12, `[0xffef04b8]` = (lowest address allocated by
   `mmu_build_boot_tables` − base + 0x10000) >> 12 (`0x7002aa34`-`0x7002aa3c`:
   the RAM left below the tables plus the 64 KiB kernel block, in pages),
   `[0xffef04b0..04a0]` = POST
   status, message, `%g4`..`%g6` of the hand-off, `[0xffef0034]`=0xffef0000,
   `[0xffef0040]`=0xffeff000, `[0xffef0078]`=0xffefec00,
   `[0xffef003c]`=0xffefebe0, `[0xffef00a8]`= end of the copied image.
9. Registers at the jump: `%g2`=`0xffd15a00` (origin), `%g3`=`0xffef0000`,
   `%g5`=`0xffd1b33a` (origin + `0x593a`), `%g6`=`0xffeff000`,
   `%g7`=`0xffefebe4`; **`jmp %g3`** → `0xffef0000`.

The code at `0xffef0000` (PROM `0x7003bd60`) is the Forth inner interpreter
("NEXT"):

```
lduh [%g5], %l1        ! 16-bit token at IP
sll  %l1, 2, %l1
add  %l1, %g2, %l1     ! token*4 + origin
lduh [%l1], %l0        ! code field (16 bit)
sll  %l0, 2, %l0
jmp  %l0 + %g2         ! execute
add  %g5, 2, %g5       ! IP += 2
```

So tokens are 16-bit word offsets from the origin `%g2`, `%g5` is the Forth
IP, and **the first Forth word executed is the token at `0xffd1b33a`**
(PROM `0x7001b33a`). The roles of `%g6` and `%g7` (return / data stack
pointers?) are a guess; the Forth pass documents them. The QEMU trace shows the
RAM trap table at TBR `0xffeff000` in use later (vectors `0x09`, `0x1e`, `0x29`).

### 3.6 Watchdog path (`reset_watchdog` `0x7000bdf4`, `watchdog_reenter_obp` `0x7000bf80`)

Used when a watchdog reset happens while OBP or an OS owns the machine; it goes
back to OBP without the POST and without rebuilding the page tables:

1. MID/SBAE=0 (`0x10002000`); flush the whole TLB (`[0x400] 3`); clear the
   level-15 pending bit (`sta 0x8000,[0x71e00004]`).
2. Save the context register in `%l7`, set context 0.
3. Load three TLB entries through ASI 6 (upper tag at `0x300+4n`, lower tag at
   `0x100+4n`, PTE at `0x000+4n`):
   entry 0: tag `0x0000c008` (VA `0x0000c000`, ctx 0, valid), lower `0x3f8`,
   PTE `0xe7000c2c` (PA `0x7000c000`); entry 1: tag `0x00027008`, lower
   `0x3f8`, PTE `0xe700272c` (PA `0x70027000`); a third tag is written as
   `0x000013f8` at `0x308` while its PTE `0xe700282c` goes to `0x010`
   (entry 4) — a register-reuse slip, harmless because entry 2 has no PTE.
   Entry 0 maps the page this code runs in at its boot-mode VA.
4. PCR: clear BM (`0x4000`), set EN, `flush`, 8 nops; `jmp 0xffd0c0d8`
   (translated with the context table the crashed system left in CTPR), then
   `jmp 0xffd27c9c` with `%l0` = -1 and `%l3` = old context: the Forth kernel's
   trap/state-save entry, which reports the watchdog reset.

## 4. Trap handling during POST

TBR is 0 (then `0x70000000`), so traps vector through the PROM trap table. Each
entry is `sethi %hi(H),%l4 ; or %l4,%lo(H),%l4 ; jmp %l4 ; rd %psr,%l0`.

| tt | Handler | Behaviour |
|---|---|---|
| 0x01 | `trap_inst_access_exc` | like the default |
| 0x05 | `trap_window_overflow` | standard 8-window spill: new WIM = ror(WIM,1); `save`; 8 × `stda [%sp+n] 0x20` (bypass); `restore`; `jmp %l1 ; rett %l2` |
| 0x06 | `trap_window_underflow` | WIM = rol(WIM,1); `restore;restore`; 8 × `ldda [%sp+n] 0x20`; `save;save`; retry |
| 0x07 | `trap_mem_not_aligned` | default |
| 0x08 | `trap_fp_exception` | must be expected (`%g5`=8); drains the FP queue: loop `st %fsr,[0x2100]`, while FSR.qne (bit 13) `std %fq,[0x2108]`; clears `%g5`; returns **past** the trapping FP instruction. Note the absolute address `0x2100`: memory at PA 0 is assumed. |
| 0x09 | `trap_data_access_exc` | default |
| 0x11-0x1f | `trap_irq01`..`trap_irq15` | expected interrupt (`%g6`) or expected trap (`%g5`), then per-level acknowledge (soft interrupt clear bit `1<<(16+level)` in `0x71e00004`, then a read of `0x71e00000`) and sub-test work selected by `%g7` (0x99 soft-interrupt tests; 0x69 counter limit bits; 0x155/0x166/0x177/0x188/0x199 DMA2 interrupts; 0x94/0x96/0x98 level-15 cases; 0x11/0x22/0x33/0x44 level 10 system timer). Unexpected → `report_async_trap`. |
| 0x29 | `trap_data_access_error` | default, plus: `%g7`=0x96 → PCR &= ~0x8100 (AC, DE) |
| 0x2b | `trap_data_store_error` | expected (`%g5`) → return to `%l1` (re-execute, the error is asynchronous); else `report_async_trap` |
| 0x80 | `trap_sw_0x80` | if expected, executes `ta 0x80` again inside the handler (ET=0 → error mode → watchdog reset). No POST code issues `ta 0x80`; it matches the unused "Trigger Soft Reset Test" name. |
| 0x81 | `trap_sw_0x81` | if expected, returns past the `ta` (it sets PS in the current PSR, which the following `wr %l0,%psr` overwrites). Unused. |
| all others | `trap_unexpected_or_skip` | default |

"Default" (`0x7000109c`): tt (from `%tbr`) equal to `%g5` → clear `%g5`,
restore PSR from `%l0`, `jmp %l2 ; rett %l2+4` (skip the instruction that
trapped); otherwise `report_sync_trap` (`0x70001f80`): read SFAR/SFSR (ASI 4
`0x400`/`0x300`), print "ERROR : Sync Trap, PSR= %1, PC= %2, TBR= %3", the
SFSR and SFAR, and exit with "Power-On Selftest FAILED ... Replace CPU Board"
(status 2). `report_async_trap` (`0x70001f1c`) reads AFAR/AFSR
(`0x10001004`/`0x10001000`), clears AFSR, and prints the async variant.

The convention every test uses: set `%g5` to the trap type it expects, do the
operation, check that `%g5` came back 0 ("No trap taken, expected %1"
otherwise). `%g6` is the same for interrupts, `%g7` a sub-test selector for
the interrupt handlers, `%g4` bit 1 the diagnostic-mode flag, `%g3` a sticky
error flag, `%g2` the memory configuration.

## 5. POST output

- **ttya only** (Z85C30 at `0x71100000`, channel A, 9600 8N1). There is no
  frame-buffer output during POST. The boot-time messages (`boot_puts`) need
  `diag-switch?`; POST test names need diagnostic mode (`%g4` bit 1); **error
  messages are always printed** (every error path calls `post_printf`
  unconditionally).
- `post_printf` (`0x700070e0`) reads the format with `lduba [..] 0x9` (from the
  PROM) and expands `%1`..`%4` into 8 hex digits of `%o1`..`%o4`
  (`post_printf_nosave` uses `%i1`..`%i4`, for trap context). Errors end with
  "UNUMBER: Uxxxx" (chip location) and a "WARNING: Suspect Swift / Macio /
  Slavio Module" line.
- **Keyboard LEDs** (Sun type 4/5 command `0x0e` + mask, `kbd_send`): the
  sequencer shows progress by toggling LED bit 8 (Caps Lock) between test groups;
  on failure it lights 1 (Num Lock: CPU board), 4 (Scroll Lock: NVRAM) or 2
  (Compose: SIMM), matching the service manual's table ("Interpreting the
  Keyboard Diagnostic LEDs"). A second code set is used when `kbd_detect`
  returned 5 or 9 (unknown keyboard kinds). The exact codes per failure path
  are in [`post-tests.md`](post-tests.md) §11.2.
- Keyboard: Stop (L1, code `0x01`) skips POST; Stop-d (`0x01`+`0x4f`) forces
  diagnostic mode and sets `diag-switch?`. Stop-n (reset NVRAM defaults) and
  Stop-a are handled by the Forth side, not by this code.
- A dormant ttya command poller exists (`post_poll_ttya_command`,
  `0x7000a7a0`; `r` = software reset, `l`/`p`/`b`/`a` change the `%g4` mode
  bits; `p` consults NVRAM byte `0x71200000`) but nothing calls it; neither
  does the interactive menu code
  whose strings are in the image ("Select Options for Memory Tests", …).

## 6. Where to start reading the listing

| Label | Addr | What |
|---|---|---|
| `reset_entry` | `0x7000bd98` | first instruction after the reset branch |
| `reset_power_on` | `0x7000bb48` | keyboard scan and POST decision |
| `post_entry`, `post_main`, `post_sequencer` | `0x70001000`, `0x70002140`, `0x700098c0` | the POST |
| `post_exit_soft_reset` | `0x7000bac0` | result hand-off |
| `obp_start_after_sw_reset`, `obp_cold_entry` | `0x7000bec4`, `0x7002a86c` | kernel start |
| `mmu_build_boot_tables`, `mmu_map_range` | `0x7000c984`, `0x7000cbd0` | first page tables |
| `trap_*`, `report_*` | `0x7000109c`-`0x70002124` | POST trap handlers |

## 7. Regenerating

```
python3 tools/romdis/romdis.py docs/rom-disassembly/ss5-obp/romdis.json \
    -o docs/rom-disassembly/ss5-obp/listing.s --db /tmp/ss5-analysis.json
```

`romdis.json` includes `forth.json` (Forth pass, skipped while it does not
exist) and `qemu-trace.json` (3 687 addresses QEMU executed; every one is a
code seed). Features this pass added to `tools/romdis/romdis.py`: address
**aliases** (`"aliases"`: other VAs the image runs at, `"flow": true` for
aliases that only apply to jump/call targets).

## 8. Open items

1. **Status register bit 4.** The ROM treats `0x71f00000` bit 4 as "watchdog
   reset". The Sun-4M spec defines only bits 0-3; confirm on SS5 (Slavio)
   documentation or hardware.
2. **`%g3` = message VA + 16** in the hand-off: check how `show-post-results`
   uses it (Forth side).
3. **Tests present but never called**: FPU SP/DP underflow CEXC, D-cache and
   I-cache flash-clear (the I-cache one prints the wrong name, "MMU TLB RAM NTA
   Pattern Test"), DMA2 ID/D_NBCNT/chain, PPORT slave-error and loopback tests,
   system counter, TOD kickstart. The strings for IU register-file, window
   pointer, EPROM checksum, audio (DBRI/CS4231), SBus/EBus write timeout,
   memory MATS/checker/parity and the interactive menu exist **without any
   code**; this POST is a subset of a larger Sun POST library.
4. The PCR bit names used here (EN 0, NF 1, SA 7, DE 8, IE 9, RC 13:10, BM 14,
   AC 15) come from the microSPARC-I guide's figure 4.10 and the
   microSPARC-II text; the II manual's bit-position figure did not survive
   text extraction. Confirm against the PDF.
5. TLB diagnostic (ASI 6) layout (`0x000+4n` PTE, `0x100+4n` lower tag,
   `0x300+4n` upper tag/CAM, 64 entries) is inferred from `tlb_init_clear`,
   the TLB NTA tests' masks and the watchdog path; Table 41 of the manual
   did not survive extraction.
6. `obp_cold_entry`'s memory search loops forever if no bank answers, and it
   puts the kernel's RAM in the **highest** bank, while the POST uses the
   **lowest** bank for its stack and scratch.
7. QEMU fails "MMU TLB RAM NTA Pattern Test" (no TLB diagnostic ASI), so under
   QEMU the unmodified POST stops after the MMU register tests. With failing
   calls patched out of a scratch copy of the image the rest was observed:
   QEMU also fails IOMMU Control Reg, FPU SP Trap Priority <, both timer
   tests, DMA2 E_CSR (and, by construction, the other slave-error tests) and
   TOD Registers ([`post-tests.md`](post-tests.md) §13).
8. The microSPARC-II ASI 4 registers at `0x1000` (TLB replacement control),
   `0x1300` and `0x1400` (SFSR/SFAR diagnostic) need the full VA decoded: a
   decoder that looks only at VA[11:8] aliases them onto the PCR, SFSR and
   SFAR. The PROM writes `0` to `[0x1000] 4` in `tlb_init_clear` while still
   in boot mode, which on such a decoder would clear PCR.BM and move
   instruction fetch from the PROM to RAM. Without ASI 5/6/7 (TLB
   diagnostics) the POST fails at test 6 as under QEMU. This image reads
   itself at PA `0x7000xxxx` with ASI 0x20 and OBP maps the PROM from PA
   `0x70000000`, so running it needs the PROM decoded there
   ([`hardware-access.md`](hardware-access.md) §5).
