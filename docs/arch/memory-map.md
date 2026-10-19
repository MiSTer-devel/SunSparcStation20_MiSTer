# Physical address map (SPARCstation 20)

From the *Sun-4M System Architecture* spec 950-1373-01 Rev 50 §3.2, QEMU
`hw/sparc/sun4m.c` (`ss20_hwdef`), and the OBP 2.25 analysis in
[rom-disassembly/ss20-obp-2.25/](../rom-disassembly/ss20-obp-2.25/).
36-bit physical addresses; PA[35:32] selects a 4 GB space.

| PA[35:32] | Space |
|---|---|
| `0x0` | main memory (up to 512 MB here) |
| `0x1`-`0x8` | reserved: MBus time-out |
| `0x9`-`0xD` | VME (none on an SS20) |
| `0xE` | SBus: slot N at `0xE_N000_0000`, 256 MB each; on-board devices in slot F |
| `0xF` | control space |

## SBus (`0xE`)

| PA | Device | Block |
|---|---|---|
| `0xE_0000_0000` .. `0xE_3FFF_FFFF` | expansion slots 0-3 (empty: time-out, requirement B1) | `msi` |
| `0xE_2000_0000` | TCX framebuffer (slot 2 in QEMU's SS-20; the OBP probes the slot's FCode) | `tcx` |
| `0xE_3000_0000` | CS4231 + APC with our FCode (slot 3) | `cs4231` |
| `0xE_E000_0000` | slot e: the `dbri-absent` FCode node (DEC-4) | `msi` |
| `0xE_F000_0000` | MACIO id register (`fe 81 01 03`) | `msi` |
| `0xE_F040_0000` | DMA2: ESP DMA at +0, LANCE DMA at +0x10, parallel at +0x20 | `dma2` |
| `0xE_F080_0000` | ESP (53C9x), byte registers at 4-byte strides | `esp` |
| `0xE_F0C0_0000` | LANCE (Am7990): RDP +0, RAP +2 | `lance` |

## Control space (`0xF`)

| PA | What | Block |
|---|---|---|
| `0xF_0000_0000` | EMC: ECC memory enable, fault status/address, diagnostic; `+0x1000` the 4 diagnostic message bytes | `memctl` |
| `0xF_E000_0000` | MSI: IOMMU control, base, flush-all, address flush; `+0x100` tag diagnostics, `+0x200` translation-cache diagnostics | `msi` |
| `0xF_E000_1000` | MSI: M-to-S AFSR/AFAR, `+8` arbiter enable, `+0x10 + 4N` SBus slot N configuration | `msi` |
| `0xF_E000_2000` | MID register | `msi` |
| `0xF_F000_0000` | boot PROM, 512 KB, mirrored through the 16 MB; also at PA 0 in boot mode | `memctl` |
| `0xF_F100_0000` | keyboard (A) / mouse (B) ESCC: B ctrl +0, B data +2, A ctrl +4, A data +6 | `escc` |
| `0xF_F110_0000` | ttya (A) / ttyb (B) ESCC, same layout | `escc` |
| `0xF_F120_0000` | M48T08 TOD/NVRAM, 8 KB: IDPROM at +0x1FD8, clock at +0x1FF8 | `m48t08` |
| `0xF_F130_0000` | counter/timers: processor N at `+N*0x1000`, system at `+0x10000` | `slavio_timer` |
| `0xF_F140_0000` | interrupts: processor N at `+N*0x1000`, system at `+0x10000` | `slavio_intctl` |
| `0xF_F160_0000` | diagnostic LEDs (16-bit, write) | `slavio_misc` |
| `0xF_F170_0000` | floppy controller (82077) | `fdc` |
| `0xF_F180_0000` | Auxiliary I/O register 0 (floppy density/TC, LED) | `slavio_misc` |
| `0xF_F1A0_1000` | power control register | `slavio_misc` |
| `0xF_F1F0_0000` | system control/status (SW_RST, SW_RST_STAT, DIAG.SW, RST.SW) | `slavio_misc` |
| `0xF_F8xx_xxxx` .. `0xF_FFxx_xxxx` | MBus module control space, MID 8-F; `+0xFF_FFFC` the MBus Port Address register | `cpu` |

Registers that no device answers read 0 (DEC-3); the unassigned spaces
above time out (A3/B1).

## Processor-local (ASI, not PA)

| ASI | What |
|---|---|
| `0x2` | SuperSPARC control space / MXCC (not implemented: MBus mode, no MXCC) |
| `0x3` | SRMMU flush/probe |
| `0x4` | SRMMU registers: control (0), CTPR (0x100), context (0x200), SFSR (0x300), SFAR (0x400), AFSR (0x500), AFAR (0x600), reset (0x700) |
| `0x6` | SuperSPARC TLB diagnostic image, 64 entries (MMU-2) |
| `0x8`-`0xB` | user/supervisor instruction/data |
| `0xC`-`0xF` | cache tag/data diagnostics (A4) |
| `0x10`-`0x14` | cache flush by page/segment/region/context/user |
| `0x20`-`0x2F` | MMU bypass, PA[35:32] = ASI[3:0] |
| `0x36`, `0x37` | I-cache and D-cache flash clear |
