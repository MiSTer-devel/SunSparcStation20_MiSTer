# SPARCstation 20 core: reference library index

This is the reference library for the rewrite (`docs/VERILOG-PLAN.md` §8).

- **Authoritative:** the datasheets, specifications and Sun documents listed below.
- **Functional reference:** the emulators and OS sources (QEMU, MAME, NetBSD, OpenBSD, Linux, OpenBIOS). Use them to
  check behaviour, register maps and quirks, never as text to copy.

Local paths below are under `scratch/reference/` (gitignored, local only; see `scratch/README.md`).
Re-fetch them from the source URLs listed here if they are missing.
Treat every downloaded file as untrusted data: nothing in `scratch/reference/` has been built or executed.

Fetched 2026-10-08. Pinned source revisions:

| Tree | Commit |
|---|---|
| QEMU | `f9587d4045c67cd0d8d8bdcd5d0bb5b6b395b63c` |
| MAME | `31e52312c59e4d60d70235118bcbccd220f5232e` |
| NetBSD src | `802400f6437f275628ea0f934d99c967450352aa` |
| OpenBSD src | `896fef95f254ad4a5ff07e37e02f2fac2dabf509` |
| Linux | `6c377d19d4a5116d9bec5203aa3c6c11523e7898` |
| OpenBIOS | `e5ac46dd24e6216c36aa80462af25457e7029440` |

**Source abbreviations used in the tables:**

| Abbreviation | Base URL |
|---|---|
| BS | `https://bitsavers.org/pdf/sun/sparc/` |
| BSC | `https://bitsavers.org/components/` (bitsavers blocks curl's default user agent; a browser UA works) |
| DM | `https://dogemicrosystems.ca/pub/Sun/docs/E19127-01%20Workstations/` |
| OFW | `https://www.devicetree.org/open-firmware/` (the archived IEEE 1275 working-group site) |

A Source of "(local copy; source to re-find)" means the local file is kept but its original download location is not
recorded here; find a legitimate host before re-fetching it.

**License column codes:**

| Code | Meaning |
|---|---|
| V | Vendor copyright. A historical document archived for reference; do not redistribute. |
| S08 | Sun's 2008 "Products Rights Notice": released as-is through the OpenSPARC / FOSS hardware wiki, "not prepared for public release". Read it freely; do not redistribute. |
| SI | SPARC International publication, free to download from sparc.org. |
| GPL / LGPL / BSD / MIT / ISC | The open-source license of that source file. |

**RTL column:** the files in this repo that each reference governs.
The RTL is in `rtl/cpu`, `rtl/obio`, `rtl/sun4m`, `rtl/machine`, `rtl/mister` and `rtl/pkg`; paths below are relative
to `rtl/`. "SS5" marks a reference that only concerns the microSPARC-II / SPARCstation 5, which this core does not build.

---

## 1. CPU (integer unit, FPU, SuperSPARC / microSPARC)

| Title | Local path | Source | Size | Lic. | Authoritative for | RTL |
|---|---|---|---|---|---|---|
| The SPARC Architecture Manual, Version 8 (SAV080SI9308) | `scratch/reference/cpu/sparcv8.pdf` | https://sparc.org/wp-content/uploads/2014/01/v8.pdf.gz (gunzipped) | 1.1 MB | SI | **Primary ISA spec.** Instructions, traps, PSR/WIM/TBR, ASIs, the memory model (TSO/PSO), the FP chapter, and **Appendix H, the SPARC Reference MMU (SRMMU)** | `cpu/iu*.sv`, `cpu/fpu.sv`, `cpu/fp_*.sv`, `cpu/cpu_module.sv` (ASIs), `cpu/srmmu.sv` (App. H) |
| The Viking Microprocessor (TI TMS390Z50) User Documentation, 800-4510-02, Nov 1990 | `scratch/reference/cpu/800-4510-02_The_Viking_Microprocessor_TI_TMS390Z50_User_Documentation_Nov1990.pdf` | BS | 20.9 MB | V | SuperSPARC (Viking) IU pipeline, MMU/cache control registers (MCNTL, ASIs), MBus and CC (MXCC) modes, BIST. **This is the closest available stand-in for the SuperSPARC User's Guide.** | `cpu/cpu_module.sv`, `cpu/srmmu.sv`, `cpu/l1cache.sv`, `machine/ss20_mbus.sv` |
| STP1020A SuperSPARC data sheet | `scratch/reference/SuperSparc.pdf` | (local copy; source to re-find) | 1.5 MB | V | SuperSPARC pinout, modes, and a summary of the MMU and cache | `cpu/cpu_module.sv`, `cpu/srmmu.sv`, `cpu/l1cache.sv` |
| STP1021A SuperSPARC-II data sheet | `scratch/reference/SuperSPARC2.pdf` | (local copy; source to re-find) | 1.3 MB | V | SuperSPARC-II differences and the STP1091 MXCC system view | as above |
| SuperSPARC II user's guide appendix (STP1021UG) | `scratch/reference/STP1021UG.pdf` | (local copy; source to re-find) | 219 KB | V | SuperSPARC-II IU pipeline, register file, PSR, trap handling | `cpu/iu.sv`, `cpu/cpu_module.sv` |
| STP5022B SuperSPARC MBus module data sheet | `scratch/reference/STP50_DataSheet.pdf` | (local copy; source to re-find) | 1.7 MB | V | SS20 MBus module: SuperSPARC plus STP1090 MXCC, Level-2 MBus | `cpu/cpu_module.sv`, `machine/ss20_mbus.sv` |
| The SuperSPARC Microprocessor technical white paper (1992) | `scratch/reference/supersparcwhitepaper.pdf` | (local copy; source to re-find) | 107 KB | V | An architectural overview of the superscalar issue, caches and MBus | background |
| microSPARC-II User's Manual, Rev 1.1, Jul 1994 (text PDF, 231 pp) | `scratch/reference/microSPARC-II-UsersManual2.pdf` | (local copy; source to re-find) | 8.4 MB | S08 | microSPARC-II (SS5) IU, MMU, caches, memory controller and SBus controller. | SS5 |
| microSPARC-II User's Manual (scan) | `scratch/reference/microSPARC-II-UsersManual.pdf` | (local copy; source to re-find) | 68.8 MB | V | Same manual as a scan. **The PDF xref is damaged** and poppler has to rebuild it; use the text version above. | as above |
| STP1012 microSPARC-II data sheet, Jul 1997 | `scratch/reference/MicroSparcII.pdf` | (local copy; source to re-find) | 192 KB | V | The microSPARC-II summary and its MMU/cache parameters | SS5 |
| microSPARC-IIep User's Manual, 802-7100-01, Apr 1997 | `scratch/reference/cpu/802-7100-01_microSPARC-IIep_Users_Manual.pdf` | https://www.ece.lsu.edu/ee4720/microsparc-IIep.pdf | 972 KB | V | microSPARC-II core details (IIep is a PCI variant). The `msiiepreg.h` / `timer_msiiep.c` files are the matching driver side. | SS5 |
| SPARCclassic Engine OEM Tech. Manual, Part 2: microSPARC reference (App. K, L) | `scratch/reference/cpu/801-3137-10_SPARCclassic_Engine_OEM_Technical_Manual_Part_Two_microSPARC_Reference_Apr1993.pdf` | BS | 22.3 MB | V | microSPARC-I (TMS390S10) IU, MMU and caches. The ancestor of microSPARC-II. | SS5 |
| IEEE 1754 implementation characteristics (SPARC Intl, 1999) | `scratch/reference/cpu/v8.ieee.p1754.pdf` | (local copy; source to re-find) | 72 KB | SI | Implementation-dependent V8 choices (IEEE 1754 = SPARC V8) | `cpu/iu.sv`, `cpu/fpu.sv` |
| SPARC-V8E embedded supplement v1.0 | `scratch/reference/cpu/v8e.pdf` | (local copy; source to re-find) | 186 KB | SI | Optional V8E instructions (SMUL/UMAC etc.). Useful for knowing what *not* to implement. | `cpu/iu_decode.sv` |
| SPARC Compliance Definition 2.4.1 (ABI) | `scratch/reference/cpu/SCD.2.4.1.pdf` | https://sparc.org/wp-content/uploads/2014/01/SCD.2.4.1.pdf.gz (gunzipped) | 1.4 MB | SI | The SPARC V8/V9 ABI (calling convention, ELF). Optional; for test software. | tests/ |

### 1a. FPU / IEEE 754 (`scratch/reference/cpu/fpu/`; local copies, sources to re-find)

| Title | Local path | Size | Lic. | Notes | RTL |
|---|---|---|---|---|---|
| IEEE 754r base document draft | `scratch/reference/cpu/fpu/754.pdf` | 50 KB | draft | IEEE 754-1985 is not freely available. This draft restates its technical content. | `cpu/fpu.sv`, `cpu/fp_*.sv`, `pkg/fpu_pkg.sv` |
| IEEE 754 tutorial notes | `scratch/reference/cpu/fpu/ieee754.pdf` | 685 KB | V | Formats, rounding, exceptions | same |
| Goldberg, "What Every Computer Scientist Should Know About FP" (Sun reprint) | `scratch/reference/cpu/fpu/goldberg.pdf` | 256 KB | V | Background; includes Sun's SPARC appendix | same |
| Sun Numerical Computation Guide: "SPARC Behavior and Implementation" | `scratch/reference/cpu/fpu/SPARC_Behavior_and_Implementation.htm` | 45 KB | V | SPARC FP trap behaviour, FSR, the unimplemented-FPop cases that kernels emulate | `cpu/fpu.sv` |
| Paranoia (Kahan) and a reference output | `scratch/reference/cpu/fpu/paranoia.c`, `paranoia.out` | 58 + 7 KB | PD | FP correctness test (validation suite) | tests |
| IeeeCC754 test suite | `scratch/reference/cpu/fpu/IeeeCC754.tgz` | 655 KB | research | IEEE compliance vectors | tests |
| Berkeley TestFloat-2a / SoftFloat-2b | `scratch/reference/cpu/fpu/TestFloat-2a.zip`, `SoftFloat-2b.zip` | 99 + 112 KB | BSD-like (Hauser) | A bit-exact reference model and test generator | tests, sim |
| UCBTEST (Sun/Berkeley FP tests) | `scratch/reference/cpu/fpu/ucbtest.tgz` | 998 KB | research | libm/FP tests | tests |
| systemBugs.txt | `scratch/reference/cpu/fpu/systemBugs.txt` | 16 KB | ? | Known FP bugs in various systems | — |

---

## 2. MMU / cache / bus

| Title | Local path | Source | Size | Lic. | Authoritative for | RTL |
|---|---|---|---|---|---|---|
| **SPARC Reference MMU**: Appendix H of the V8 manual | `scratch/reference/cpu/sparcv8.pdf` (App. H) | see §1 | — | SI | PTD/PTE format, context table, table walk, fault status/address registers, ASI 0x3/0x4 probe and flush | `cpu/srmmu.sv`, `pkg/mmu_pkg.sv`, `sun4m/ss20_msi.sv` (the IOMMU shares the PTE flavour) |
| SPARC MBus Interface Specification, Rev 1.2, Apr 1991 | `scratch/reference/mmu-cache-bus/SPARC_MBus_Interface_Specification_Rev_1.2_199104.pdf` | BS | 3.0 MB | V | MBus Level 1/2 transactions, the coherency (MOESI-style) protocol, arbitration, the module ID / address map | `machine/ss20_mbus.sv`, `cpu/cpu_module.sv`, `cpu/l1cache.sv` |
| MBus Interface Spec / MBus Module Design Guide (SPARC Intl, 1997) | `scratch/reference/mmu-cache-bus/MBUS.pdf` | (local copy; source to re-find) | 597 KB | SI | A later edition of the MBus spec plus the module design guide | as above |
| SBus Specification B.0, 800-5922-10, Dec 1990 | `scratch/reference/mmu-cache-bus/800-5922-10_SBus_Specification_B.0_Dec90.pdf` | BS | 6.6 MB | V | SBus cycles, DVMA, interrupts, slot address map, FCode PROM requirements (an early form of IEEE 1496) | `sun4m/ss20_msi.sv`, `sun4m/dma2.sv`, `machine/ss20_iobridge.sv`, `pkg/sbus_pkg.sv`, `sun4m/*_fcode.sv` |
| STP2000 Master I/O (MACIO) data sheet | `scratch/reference/mmu-cache-bus/stp2000.pdf` | (local copy; source to re-find) | 164 KB | V | MACIO: DMA2, ESP, LANCE, parallel port | `sun4m/dma2.sv`, `sun4m/esp.sv`, `sun4m/lance.sv` |
| STP2001 Slave I/O (SLAVIO) data sheet | `scratch/reference/mmu-cache-bus/stp2001.pdf` | (local copy; source to re-find) | 237 KB | V | SLAVIO: SCC, keyboard/mouse, floppy, timers, interrupts, EPROM and NVRAM interface | `obio/escc.sv`, `sun4m/fdc82077.sv`, `obio/slavio_timer.sv`, `obio/slavio_intctl.sv`, `obio/slavio_misc.sv` |
| SuperSPARC MXCC (TMS390Z55 / STP1090/1091) | — | **not found** (see Gaps) | — | — | Use the Viking doc's CC-mode chapter, the STP1021A/5022B data sheets and `scratch/reference/emulators/linux/arch/sparc/include/asm/mxcc.h` | the MXCC (not modelled) |

---

## 3. sun4m chipset

| Title | Local path | Source | Size | Lic. | Authoritative for | RTL |
|---|---|---|---|---|---|---|
| **Sun-4M System Architecture**, spec 950-1373-01 Rev 50 | `scratch/reference/Sun4M_SystemArchitecture_edited2.pdf` | (local copy; source to re-find) | 786 KB | S08 | **Primary sun4m spec.** The physical address map, the IOMMU, interrupt controller (processor and system), counter/timers, ECC memory, MSI/MBus-SBus, Aux registers, the reset model | `sun4m/ss20_msi.sv`, `obio/slavio_intctl.sv`, `obio/slavio_timer.sv`, `obio/slavio_misc.sv` (Aux), `sun4m/emc.sv`, `machine/ss20_*.sv` (address map) |
| sun4m Architecture Porting Guide (H. Stern) | `scratch/reference/chipset/sun4m-guide.pdf` | (local copy; source to re-find) | 36 KB | V | A short software-view overview of sun4m vs sun4c | background |
| SLAVIO-1 (NCR89C105) chip specification | `scratch/reference/chipset/slavio-1_NCR89C105.pdf` | (local copy; source to re-find) | 28.7 MB | S08 | **SLAVIO registers:** interrupt controller, counters/timers, SCC wrapper, keyboard/mouse, floppy (82077 core), EPROM/NVRAM decode, Aux1/Aux2, system control/reset | `obio/slavio_intctl.sv`, `obio/slavio_timer.sv`, `obio/slavio_misc.sv`, `obio/escc.sv`, `sun4m/sun_kbd.sv`, `sun4m/sun_mouse.sv`, `sun4m/fdc82077.sv`, `obio/m48t08.sv` |
| NCR89C105 text extract | `scratch/reference/chipset/NCR89C105.txt` | (local copy; source to re-find) | 71 KB | S08 | Greppable text of the SLAVIO spec | same |
| MACIO-1 (NCR89C100) chip specification | `scratch/reference/chipset/macio-1_NCR89C100.pdf` | (local copy; source to re-find) | 23.3 MB | S08 | **MACIO:** the SBus interface, DMA2 core, ESP (53C9x) core, LANCE core and parallel port | `sun4m/dma2.sv`, `sun4m/esp.sv`, `sun4m/lance.sv` |
| NCR89C100 text extract | `scratch/reference/chipset/NCR89C100.txt` | (local copy; source to re-find) | 31 KB | S08 | Greppable text | same |
| **DMA2 core** specification (text) | `scratch/reference/chipset/dma2.txt` | (local copy; source to re-find) | 147 KB | S08 | **DMA2 / DMA+ registers** (D_CSR, D_ADDR, D_BCNT, E_CSR, burst modes, the ENET cache, the SCSI FIFO, the parallel port). Compatible with L64854. | **`sun4m/dma2.sv`** (plus the DMA side of the ESP and the LANCE) |
| LSI L64853A SBus DMA (DMA+) data sheet | `scratch/reference/chipset/L64853A.pdf` | (local copy; source to re-find) | 10.1 MB | V | The DMA+ ancestor of DMA2 (default compatibility mode) | `sun4m/dma2.sv` |
| LSI L64853 SBus DMA Controller Technical Manual, 1989 | `scratch/reference/chipset/LSI_Logic_L64853_SBus_DMA_Controller_Technical_Manual_1989.pdf` | BSC `lsiLogic/sparc/` | 3.9 MB | V | The original SBus DMA (sun4c) | `sun4m/dma2.sv` |
| SPARCclassic OEM Tech. Manual, Part 3: I/O chipset (App. M) | `scratch/reference/chipset/801-3137-10_SPARCclassic_Engine_OEM_Technical_Manual_Part_Three_IO_Chipset_Apr1993.pdf` | BS | 31.6 MB | V | The sun4m (Classic/LX) I/O chipset reference: MACIO/SLAVIO-era DMA, ESP, LANCE, SCC, interrupt and timer registers. A good scan cross-check for the S08 specs. | `obio/*.sv`, `sun4m/*.sv` |
| SPARCclassic OEM Tech. Manual, Part 1 | `scratch/reference/chipset/801-3137-10_SPARCclassic_Engine_OEM_Technical_Manual_Part_One_Apr1993.pdf` | BS | 11.8 MB | V | sun4m board-level address map, boot, OBP environment | `machine/ss20_*.sv` |
| SPARCstation 20 Service Manual, 801-6189-12 | `scratch/reference/chipset/801-6189-12_SPARCstation_20_Service_Manual.pdf` | DM `SPARCstation%2020%20Workstation/...` | 2.8 MB | V | SS20 configuration: slots, MBus modules, memory, jumpers, NVRAM, POST/OBP diagnostics | `machine/ss20_machine.sv`, `mister/nvram_sd.sv` |
| SS10SX / SS20 System Configuration Guide, 806-2222-10 | `scratch/reference/chipset/806-2222-10_SS10SX_SS20_System_Configuration_Guide.pdf` | DM `SPARCstation%2010%20Workstation/...` | 248 KB | V | Valid CPU-module, memory and SBus combinations | `machine/ss20_machine.sv`, `cpu/cpu_module.sv` |
| SPARCstation 5 Service Manual, 801-6396-11 | `scratch/reference/chipset/SS5_801-6396-11.pdf` | (local copy; source to re-find) | 2.2 MB | V | SS5 configuration | SS5 |
| Sun-4D Architecture, Jun 1992 | `scratch/reference/chipset/Sun4D_Architecture_Jun1992.pdf` | BS | 18.4 MB | V | sun4d (not sun4m). Useful only for its XBus/MBus SMP background. | — |

---

## 4. SCSI

| Title | Local path | Source | Size | Lic. | Authoritative for | RTL |
|---|---|---|---|---|---|---|
| NCR 53C90A/53C90B Advanced SCSI Controller, 1991 | `scratch/reference/scsi/53C90A-53C90B_Advanced_SCSI_Controller_1991.pdf` | BSC `ncr_symbios/scsi/53C90/` | 4.2 MB | V | **The ESP register set and command set** (the 53C90 family) | **`sun4m/esp.sv`**, `sun4m/scsi_targets.sv` |
| NCR 53C90 A/B (data manual, alternate scan) | `scratch/reference/scsi/NCR53C90ab.pdf` | BSC `ncr_symbios/scsi/53C90/NCR53C90ab.pdf` | 3.2 MB | V | same | same |
| NCR 53C94/95/96 Data Sheet, Feb 1990 | `scratch/reference/scsi/NCR_53C94_53C95_53C96_Data_Sheet_Feb90.pdf` | BSC `ncr_symbios/scsi/53C94/` | 2.9 MB | V | ESP-236 class: Config 2/3, the FIFO, DMA handshake | `sun4m/esp.sv` |
| NCR 53CF94/96-2 Fast SCSI Data Manual, Apr 1993 | `scratch/reference/scsi/53CF94_96-2_Fast_SCSI_Controller_Data_Manual_Apr1993.pdf` | BSC `ncr_symbios/scsi/53CF94/` | 7.8 MB | V | FAS216/236-class Fast SCSI, Config 3 and the chip ID (the ESP version probed by drivers) | `sun4m/esp.sv` |
| NCR 53CF9x-2 (alternate scan) | `scratch/reference/scsi/NCR53CF9x-2.pdf` | BSC `ncr_symbios/scsi/53CF94/NCR53CF9x-2.pdf` | 8.5 MB | V | same | same |
| AMD Am53C94/96 data sheet | `scratch/reference/scsi/am53c94.pdf` | (local copy; source to re-find) | 437 KB | V | Second source for the 53C94 | `sun4m/esp.sv` |
| Emulex FAS216 data sheet | `scratch/reference/scsi/Emulex_FAS216.pdf` | (local copy; source to re-find) | 1.1 MB | V | FAS216 (ESP family). Also the FAS236/366 lineage used in Sun ESP/FAS. | `sun4m/esp.sv` |
| Emulex ESP SCSI processor data sheet | `scratch/reference/scsi/Emulex_ESP_SCSI_processor.pdf` | (local copy; source to re-find) | 1.9 MB | V | The original Emulex ESP | `sun4m/esp.sv` |
| ANSI X3.131-1994 SCSI-2 (published standard, scan) | `scratch/reference/scsi/SCSI-2_Standard_1994.pdf` | BSC `ncr_symbios/scsi/SCSI-2_Standard_1994.pdf` | 34.5 MB | V (ANSI) | **SCSI-2 phases, messages and the command sets** (disk, CD-ROM group 1/2). Used instead of draft rev 10L. | `sun4m/scsi_targets.sv`, `rtl/mister` SCSI HPS side |

---

## 5. Ethernet

| Title | Local path | Source | Size | Lic. | Authoritative for | RTL |
|---|---|---|---|---|---|---|
| Am7990 LANCE Technical Manual, 1986 | `scratch/reference/ethernet/1986_Am7990_Local_Area_Network_Controller_LANCE_Technical_Manual.pdf` | BSC `amd/Am7990/` | 3.6 MB | V | **The LANCE register set (CSR0-3, RAP/RDP), init block, descriptor rings and their semantics** | **`sun4m/lance.sv`**, `sun4m/wish7990_*.sv`, `mister/eth_hps.sv` |
| Am7990 data sheet | `scratch/reference/ethernet/Am7990.pdf` | BSC `amd/Am7990/Am7990.pdf` | 1.7 MB | V | same, data-sheet form | same |
| Am7990 Reference Guide 08496A, 1986 | `scratch/reference/ethernet/08496A_Am7990_Reference_Guide_Aug1986.pdf` | BSC `amd/Am7990/` | 3.1 MB | V | Software and design considerations | same |
| Am79C90 C-LANCE data sheet (bitsavers) | `scratch/reference/ethernet/Am79c90.pdf` | BSC `amd/Am7990/Am79c90.pdf` | 431 KB | V | The CMOS LANCE (NCR92C990 in MACIO is compatible) | same |
| Am79C90 C-LANCE data sheet (second copy) | `scratch/reference/ethernet/LANCE.pdf` | (local copy; source to re-find) | 437 KB | V | Same document, a different file | same |
| STP2002 FEPS user's guide, 1996 | `scratch/reference/ethernet/STP2002QFP-FEPs_UG.pdf` | (local copy; source to re-find) | 493 KB | V | Later Sun SBus Fast Ethernet / Parallel / SCSI ASIC. Background only. | — |

---

## 6. Serial, keyboard, mouse

| Title | Local path | Source | Size | Lic. | Authoritative for | RTL |
|---|---|---|---|---|---|---|
| AMD Am8530H/Am85C30 SCC Technical Manual, 1992 (text PDF) | `scratch/reference/serial-kbd-mouse/85c30.pdf` | (local copy; source to re-find) | 799 KB | V | **SCC WR0-WR15 / RR0-RR15, interrupt vectoring, async mode, BRG** | **`obio/escc.sv`**, `obio/escc_chan.sv` |
| Am85C30 data sheet | `scratch/reference/serial-kbd-mouse/85c30-amd.pdf` | (local copy; source to re-find) | 528 KB | V | Timing and pinout | same |
| Zilog SCC/ESCC User's Manual (Z8530/Z85C30/Z85230/Z85233) | `scratch/reference/serial-kbd-mouse/z85233.pdf` | (local copy; source to re-find) | 3.1 MB | V | The Zilog-authored SCC programming manual | same |
| Zilog PS0117 Z80C30/Z85C30 Product Specification | `scratch/reference/serial-kbd-mouse/Zilog_PS0117_Z80C30_Z85C30_Product_Spec.pdf` | (local copy; source to re-find) | 5.0 MB | V | Current Zilog data sheet | same |
| SPARC Keyboard Specification, Version 1 (SPARC Intl) | `scratch/reference/serial-kbd-mouse/SPARC_Keyboard_Specification_Ver_1_1999.pdf` | BS | 163 KB | SI | **Sun Type-5 keyboard serial protocol:** 1200 baud, commands (reset/bell/click/LED/layout), responses, key codes | **`sun4m/sun_kbd.sv`**, `sun4m/kbd_beep.sv` |
| Sun Type-5c keyboard code table (chart) | `scratch/reference/serial-kbd-mouse/keyboard.pdf` | (local copy; source to re-find) | 1.8 MB | ? | The power-up/reset sequence and a key-code layout chart | `sun4m/sun_kbd.sv` |
| Sun mouse protocol | — | no standalone doc; see `scratch/reference/emulators/netbsd/sys/dev/sun/sunms.c`, `ms.c` and `scratch/reference/emulators/mame/src/devices/bus/sunmouse/hlemouse.cpp` | — | BSD | The 5-byte Mouse Systems-style protocol at 1200 baud | `sun4m/sun_mouse.sv` |

---

## 7. RTC / NVRAM / IDPROM

| Title | Local path | Source | Size | Lic. | Authoritative for | RTL |
|---|---|---|---|---|---|---|
| ST M48T08/M48T08Y/M48T18 TIMEKEEPER SRAM, Doc 2411 | `scratch/reference/rtc-nvram/m48t08.pdf` | (local copy; source to re-find) | 513 KB | V | **The clock registers at 0x1FF8-0x1FFF, the W/R/stop bits, calibration** | **`obio/m48t08.sv`**, `mister/nvram_sd.sv` |
| ST M48T02/M48T12 TIMEKEEPER SRAM | `scratch/reference/rtc-nvram/m48t02.pdf` | (local copy; source to re-find) | 200 KB | V | The 2 KB part (sun4c-era) | `obio/m48t08.sv` |
| ST AN923, TIMEKEEPER and Y2K | `scratch/reference/rtc-nvram/AN_TimeKeeper.pdf` | (local copy; source to re-find) | 20 KB | V | Century handling | `obio/m48t08.sv` |
| Sun IDPROM notes (bitsavers, one handwritten page) | `scratch/reference/rtc-nvram/IDPROMS.pdf` | https://bitsavers.org/pdf/sun/IDPROMS.pdf | 44 KB | V | Historical machine-type bytes only. For the real format see `scratch/reference/emulators/linux/arch/sparc/include/asm/idprom.h` and the OpenBIOS sources. | `obio/m48t08.sv`, `mister/nvram_sd.sv` (IDPROM at 0x1FD8) |

---

## 8. Audio

| Title | Local path | Source | Size | Lic. | Authoritative for | RTL |
|---|---|---|---|---|---|---|
| Crystal CS4231A data sheet | `scratch/reference/audio/CS4231A.pdf` | BSC `crystalSemiconductor/_dataSheets/CS4231A.pdf` | 2.5 MB | V | **Indirect registers I0-I31, mode 2, the capture/playback formats** | **`sun4m/cs4231.sv`**, `sun4m/cs4231_fcode.sv` |
| APC DMA (SS5/SS20 "SUNW,CS4231" APC) | — | no Sun spec found; see `scratch/reference/emulators/netbsd/sys/dev/ic/apcdmareg.h`, `scratch/reference/emulators/netbsd/sys/dev/sbus/cs4231_sbus.c`, `scratch/reference/emulators/openbsd/sys/dev/sbus/cs4231.c`, `scratch/reference/emulators/linux/sound/sparc/cs4231.c` | — | BSD / ISC / GPL | APC CSR / CVA / CC / CNVA / CNC registers and pipelining | `sun4m/cs4231.sv` |

---

## 9. Video

| Title | Local path | Source | Size | Lic. | Authoritative for | RTL |
|---|---|---|---|---|---|---|
| Brooktree 1991 Product Databook (includes **Bt458**, Bt459, Bt463, Bt468) | `scratch/reference/video/1991_Brooktree_Product_Databook.pdf` | BSC `brooktree/_dataBooks/` | 50.6 MB | V | **The Bt458 RAMDAC used by TCX (8-bit) and CG6:** address/colour-map/overlay/control registers | **`sun4m/tcx.sv`** (DAC side), `sun4m/tcx_scan.sv`, `video/video_timing.sv` |
| LSI L64845 SGX SBus Graphics Accelerator Technical Manual, 1992 | `scratch/reference/video/M14015_L64845_SGX_SBus_Graphics_Accelerator_Technical_Manual_1992.pdf` | BSC `lsiLogic/sparc/GX/` | 6.4 MB | V | CG6 / GX (FBC, TEC, THC). TCX reuses a THC-like block. | `sun4m/tcx.sv` (THC regs) |
| Sun GX FBC spec, 1988 | `scratch/reference/video/Sun_GX_FBC_Jan1988.pdf` | BSC `lsiLogic/sparc/GX/` | 2.2 MB | V | The GX framebuffer controller (an accelerator model for TCX blit/stip) | `sun4m/tcx.sv` |
| Sun GX TEC spec, 1988 | `scratch/reference/video/Sun_GX_TEC_Jan1988.pdf` | BSC `lsiLogic/sparc/GX/` | 1.6 MB | V | The GX transform engine | — |
| TCX / S24 register maps | — | no Sun doc found; see `scratch/reference/emulators/netbsd/sys/dev/sbus/tcxreg.h`, `tcx.c`, `scratch/reference/emulators/qemu/hw/display/tcx.c`, `scratch/reference/emulators/linux/drivers/video/fbdev/tcx.c` | — | BSD / MIT / GPL | TCX THC/TEC/DHC/ALT/blit/stip space. Notes that the S24 uses an AT&T 20C567 DAC. | `sun4m/tcx*.sv` |
| CG3 / CG6 register maps | — | `scratch/reference/emulators/qemu/hw/display/cg3.c`, `scratch/reference/emulators/mame/src/devices/bus/sbus/cgthree.cpp`, `cgsix.cpp`, `scratch/reference/emulators/netbsd/sys/dev/sun/cgthreereg.h`, `cgsixreg.h`, `btreg.h` | — | MIT / BSD | An alternative framebuffer target | — |

---

## 10. Floppy

| Title | Local path | Source | Size | Lic. | Authoritative for | RTL |
|---|---|---|---|---|---|---|
| Intel 82077AA CHMOS Single-Chip FDC, 290166-007 | `scratch/reference/floppy/290166-007_82077AA_Floppy_Controller_Datasheet.pdf` | https://mirror.cs.msu.ru/oldlinux.org/Linux.old/study/hardware/Floppy/82077AA_FloppyControllerDatasheet.pdf | 586 KB | V | **SRA/SRB/DOR/TDR/MSR/DSR/FIFO/DIR/CCR, the command set, PS/2 vs AT modes** (the SLAVIO FDC core) | **`sun4m/fdc82077.sv`** |
| Intel 82077SL data sheet, 290410-001 | `scratch/reference/floppy/290410-001_82077SL_Floppy_Disk_Controller_May91.pdf` | BSC `intel/_dataSheets/` | 4.4 MB | V | The power-managed variant | `sun4m/fdc82077.sv` |
| Intel 82078 data sheet, Jan 1994 | `scratch/reference/floppy/82078_CHMOS_Single-Chip_Floppy_Disk_Controller_Jan94.pdf` | BSC `intel/_dataSheets/` | 7.5 MB | V | The successor, with a fuller command-set description | `sun4m/fdc82077.sv` |

---

## 11. Firmware (OpenBoot / IEEE 1275 / OpenBIOS)

| Title | Local path | Source | Size | Lic. | Authoritative for | RTL |
|---|---|---|---|---|---|---|
| IEEE 1275.1 SPARC binding, draft 14a | `scratch/reference/firmware/IEEE1275.1_SPARC_binding_d14a.ps` | OFW `bindings/sparc/d14a/12751d1a.ps` | 174 KB | draft | The SPARC client interface and properties | `bios/`, `sun4m/*_fcode.sv` |
| IEEE 1275.2 SBus binding, draft 14a | `scratch/reference/firmware/IEEE1275.2_SBus_binding_d14a.ps` | OFW `bindings/sbus/d14a/12752d1a.ps` | 107 KB | draft | SBus FCode PROM probing, `reg`/`intr` properties | `sun4m/tcx_fcode.sv`, `sun4m/cs4231_fcode.sv`, `sun4m/slote_fcode.sv` |
| IEEE 1275 core errata, draft 4 | `scratch/reference/firmware/IEEE1275.7_core_errata_d4.ps` | OFW `bindings/errata/12757d4.ps` | 527 KB | draft | Corrections to the core standard | — |
| OF Device Support Extensions 1.0a | `scratch/reference/firmware/OF_Device_Support_Extensions_1.0a.ps` | OFW `practice/devicex/dse1_0a.ps` | 207 KB | WG | Network, RTC, keyboard and sound device types | — |
| OF Generic Names 1.4a | `scratch/reference/firmware/OF_Generic_Names_v14a.ps` | OFW `practice/gnames/` | 118 KB | WG | Node naming | — |
| OF SCSI-3 SPI binding 1.0 | `scratch/reference/firmware/OF_SCSI3_SPI_Binding_1.0.ps` | OFW `practice/spi/` | 95 KB | WG | SCSI node properties | — |
| OF 8-bit graphics practice, d1.2 | `scratch/reference/firmware/OF_Graphics_Practice_d1_2.pdf` | OFW `practice/graphics/` | 21 KB | WG | Framebuffer `display` package | `sun4m/tcx_fcode.sv` |
| OF Interrupt Mapping 0.9d | `scratch/reference/firmware/OF_Interrupt_Mapping_0.9d.pdf` | OFW `practice/imap/` | 36 KB | WG | `interrupt-map` | — |
| OF recommended-practices index (HTML) | `scratch/reference/firmware/OF_recommended_practices_index.html` | OFW `practice/` | 12 KB | WG | Index of further practices | — |
| OpenBoot 2.x Command Reference, 802-3241-10 | `scratch/reference/firmware/OpenBOOT_2.x.pdf` | (local copy; source to re-find) | 350 KB | V | The SS20 OBP (2.x) user interface and NVRAM variables | `mister/nvram_sd.sv`, `pkg/obp_nvram_pkg.sv` |
| OpenBoot 4.x Command Reference | `scratch/reference/firmware/OpenBOOT_4.x.pdf` | (local copy; source to re-find) | 836 KB | V | Later OBP; Forth words | — |
| OpenBIOS upstream README and COPYING | `scratch/reference/firmware/openbios-upstream/` | https://github.com/openbios/openbios | 22 KB | GPL-2.0 | Background on OpenBIOS | `bios/` |

---

## 12. Emulators and OS sources (functional references)

All of these are individual raw files fetched at the pinned commits. No repository was cloned.

### QEMU: `scratch/reference/emulators/qemu/` (40 files, 895 KB)
Source: `https://raw.githubusercontent.com/qemu/qemu/<commit>/<path>`. Device models are mostly MIT; `target/sparc` is LGPL-2.1+.
The QEMU `LICENSE` and `COPYING` files are included.

| File | Maps to |
|---|---|
| `hw/sparc/sun4m.c` | Machine map and IRQ wiring: SS5/SS10/SS20 address maps, NVRAM/IDPROM layout. Maps to `machine/ss20_*.sv`, `pkg/sun4m_pkg.sv`, `obio/m48t08.sv`, `mister/nvram_sd.sv`. |
| `hw/sparc/sun4m_iommu.c`, `include/hw/sparc/sun4m_iommu.h` | The IOMMU: `sun4m/ss20_msi.sv` |
| `hw/intc/slavio_intctl.c` | `obio/slavio_intctl.sv` |
| `hw/timer/slavio_timer.c` | `obio/slavio_timer.sv` |
| `hw/misc/slavio_misc.c` | Aux1/Aux2, system control, modem, LED, power. Maps to `obio/slavio_misc.sv`. |
| `hw/misc/eccmemctl.c` | The SS10/SS20 ECC memory controller: `sun4m/emc.sv` |
| `hw/dma/sparc32_dma.c`, `include/hw/sparc/sparc32_dma.h` | `sun4m/dma2.sv` |
| `hw/scsi/esp.c`, `include/hw/scsi/esp.h` | `sun4m/esp.sv` |
| `hw/net/lance.c`, `hw/net/pcnet.c`, `hw/net/pcnet.h` | `sun4m/lance.sv` |
| `hw/char/escc.c`, `include/hw/char/escc.h` | `obio/escc.sv`, plus the Sun keyboard/mouse emulation inside escc.c (`sun4m/sun_kbd.sv`, `sun4m/sun_mouse.sv`) |
| `hw/rtc/m48t59.c`, `hw/rtc/m48t59-internal.h` | `obio/m48t08.sv` |
| `hw/display/tcx.c` | `sun4m/tcx.sv` |
| `hw/display/cg3.c` | alternative framebuffer |
| `hw/block/fdc.c`, `fdc-sysbus.c`, `fdc-internal.h` | `sun4m/fdc82077.sv` (`sun4m` "SUNW,fdtwo" variant) |
| `hw/audio/cs4231.c` | `sun4m/cs4231.sv`. **This is only a register stub in QEMU.** |
| `hw/nvram/fw_cfg.c`, `hw/sparc/trace-events` | Firmware config and trace points |
| `target/sparc/cpu.c`, `cpu.h` | CPU models (TI SuperSPARC II = TMS390Z55 IU ID, Fujitsu MB86904 = microSPARC-II, MMU IDs). Maps to `cpu/cpu_module.sv`, `cpu/iu.sv`. |
| `target/sparc/translate.c`, `insns.decode` | IU semantics: `cpu/iu*.sv` |
| `target/sparc/ldst_helper.c`, `asi.h` | ASI decoding and MMU/cache ASIs: `cpu/cpu_module.sv`, `cpu/srmmu.sv`, `cpu/l1cache.sv` |
| `target/sparc/mmu_helper.c` | SRMMU table walk: `cpu/srmmu.sv` |
| `target/sparc/fop_helper.c` | FPU ops and FSR: `cpu/fpu.sv`, `cpu/fp_*.sv` |
| `target/sparc/helper.c`, `int32_helper.c`, `win_helper.c` | Traps, interrupts, register windows: `cpu/iu.sv`, `cpu/iu_regfile.sv` |
| `docs/system/target-sparc.rst` | QEMU sparc32 machine notes |

### MAME: `scratch/reference/emulators/mame/` (27 files, 773 KB, BSD-3-Clause; `COPYING` included)
Source: `https://raw.githubusercontent.com/mamedev/mame/<commit>/<path>`.

| File | Maps to |
|---|---|
| `src/mame/sun/sun4.cpp` | The sun4/sun4c driver. **MAME has no sun4m driver.** |
| `src/devices/cpu/sparc/{sparc.cpp,sparc.h,sparcdefs.h,sparcdasm.cpp,sparc_intf.h}` | A SPARC V7/V8 interpreter (cycle-ish) and disassembler. Cross-check for `cpu/iu*.sv`. |
| `src/devices/machine/ncr53c90.{cpp,h}` | `sun4m/esp.sv` (an independent ESP model) |
| `src/devices/machine/am79c90.{cpp,h}` | `sun4m/lance.sv` |
| `src/devices/machine/z80scc.{cpp,h}` | `obio/escc.sv` |
| `src/devices/machine/timekpr.{cpp,h}` | `obio/m48t08.sv` (M48T02/08) |
| `src/devices/machine/upd765.cpp` | `sun4m/fdc82077.sv` (includes an 82077AA model) |
| `src/devices/machine/sun4c_mmu.{cpp,h}` | The sun4c MMU (not SRMMU), for contrast |
| `src/devices/bus/sbus/{sbus,cgthree,cgsix}.*` | The SBus slot model and framebuffers |
| `src/devices/bus/sunkbd/hlekbd.*`, `src/devices/bus/sunmouse/hlemouse.*` | The Sun keyboard and mouse protocol: `sun4m/sun_kbd.sv`, `sun4m/sun_mouse.sv` |

### NetBSD: `scratch/reference/emulators/netbsd/sys/...` (58 files, 844 KB, BSD)
Source: `https://raw.githubusercontent.com/NetBSD/src/<commit>/<path>`.

| Files | Maps to |
|---|---|
| `arch/sparc/include/ctlreg.h`, `pte.h` | ASIs, SRMMU control registers, SuperSPARC/microSPARC MCNTL bits: `cpu/cpu_module.sv`, `cpu/srmmu.sv`, `pkg/mmu_pkg.sv` |
| `arch/sparc/sparc/iommureg.h`, `iommu.c` | The IOMMU: `sun4m/ss20_msi.sv` |
| `arch/sparc/sparc/intreg.h`, `intr.c` | `obio/slavio_intctl.sv` |
| `arch/sparc/sparc/timerreg.h`, `timer_sun4m.c`, `timer_msiiep.c`, `clock.c` | `obio/slavio_timer.sv` |
| `arch/sparc/sparc/auxreg.h` | AuxIO: `obio/slavio_misc.sv` |
| `arch/sparc/sparc/memreg.h`, `cache.h`, `cpu.c`, `cpuvar.h`, `asm.h`, `vaddrs.h`, `autoconf.c`, `msiiepreg.h` | CPU/cache identification, memory-error registers, how a real OS drives the MMU and caches |
| `arch/sparc/dev/fdreg.h`, `fd.c` | `sun4m/fdc82077.sv` |
| `arch/sparc/dev/obio.c`, `sbusreg.h`, `kbd_pckbport.c` | obio/SBus attachment |
| `arch/sparc/include/eeprom.h`, `oldmon.h`, `dev/sun/eeprom.h` | NVRAM/eeprom layout |
| `dev/ic/ncr53c9xreg.h`, `ncr53c9x.c`, `dev/sbus/esp_sbus.c` | `sun4m/esp.sv` |
| `dev/ic/lsi64854reg.h`, `lsi64854.c`, `dev/sbus/dma_sbus.c` | DMA2: `sun4m/dma2.sv` |
| `dev/ic/lancereg.h`, `am7990reg.h`, `dev/sbus/be.c`, `qec.c` | `sun4m/lance.sv` |
| `dev/ic/z8530reg.h` | `obio/escc.sv` |
| `dev/ic/mk48txxreg.h` | `obio/m48t08.sv` |
| `dev/ic/cs4231reg.h`, `ad1848reg.h`, `apcdmareg.h`, `dev/sbus/cs4231_sbus.c` | `sun4m/cs4231.sv` |
| `dev/sbus/tcxreg.h`, `tcx.c` | `sun4m/tcx.sv` |
| `dev/sun/cgthreereg.h`, `cgsixreg.h`, `bwtworeg.h`, `btreg.h`, `fbio.h` | Framebuffers and Brooktree DAC registers |
| `dev/sun/kbd.c`, `kbd_reg.h`, `kbd_tables.c`, `sunkbd.c`, `kbdsunvar.h`, `sunms.c`, `ms.c`, `event_var.h` | Sun keyboard/mouse protocol: `sun4m/sun_kbd.sv`, `sun4m/sun_mouse.sv` |

### OpenBSD: `scratch/reference/emulators/openbsd/sys/...` (4 files, 53 KB, ISC/BSD)
- `dev/sbus/cs4231.c`, `cs4231var.h`, `dev/ic/cs4231reg.h`, `ad1848reg.h`: the APC DMA plus CS4231 driver, with comments on the APC register semantics. Maps to `sun4m/cs4231.sv`.

### Linux: `scratch/reference/emulators/linux/...` (24 files, 254 KB, GPL-2.0)

| Files | Maps to |
|---|---|
| `arch/sparc/include/asm/viking.h`, `mxcc.h`, `swift.h`, `ross.h`, `mbus.h` | SuperSPARC MCNTL, **MXCC registers**, microSPARC-II (Swift) registers: `cpu/cpu_module.sv`, `cpu/srmmu.sv`, `cpu/l1cache.sv` |
| `arch/sparc/include/asm/pgtsrmmu.h`, `arch/sparc/mm/srmmu.c`, `viking.S` | SRMMU usage, Viking/MXCC cache flush sequences |
| `arch/sparc/include/asm/iommu_32.h` | The IOMMU: `sun4m/ss20_msi.sv` |
| `arch/sparc/include/asm/timer_32.h`, `obio.h`, `arch/sparc/kernel/sun4m_irq.c`, `sun4m_smp.c` | `obio/slavio_timer.sv`, `obio/slavio_intctl.sv`, SMP (`machine/ss20_mbus.sv`) |
| `arch/sparc/include/asm/dma.h`, `auxio_32.h` | `sun4m/dma2.sv`, `obio/slavio_misc.sv` |
| `arch/sparc/include/asm/idprom.h` | **IDPROM format**: `obio/m48t08.sv`, `mister/nvram_sd.sv` |
| `arch/sparc/include/asm/psr.h` | `cpu/iu.sv`, `pkg/cpu_pkg.sv` |
| `drivers/scsi/sun_esp.c`, `esp_scsi.h` | `sun4m/esp.sv` |
| `drivers/tty/serial/sunzilog.h`, `suncore.c` | `obio/escc.sv` |
| `drivers/video/fbdev/tcx.c` | `sun4m/tcx.sv` |
| `sound/sparc/cs4231.c` | `sun4m/cs4231.sv` (APC) |
| `drivers/sbus/char/openprom.c` | OBP device-tree access |

### Not fetched (links only)

| Project | Link | Notes |
|---|---|---|
| TME (The Machine Emulator) | https://people.csail.mit.edu/fredette/tme/ | Emulates sun2, sun3 and sun4c (SS2) only; no sun4m. Not fetched. |
| GRLIB / LEON3 (GPL SPARC V8 RTL) | https://www.gaisler.com/getgrlib | Package `https://download.gaisler.com/products/GRLIB/bin/grlib-gpl-2026.2-b4300.tar.gz`; manuals `.../GRLIB/doc/grlib.pdf` (user's manual) and `.../GRLIB/doc/grip.pdf` (IP cores incl. LEON3, SRMMU, GRFPU). **An important alternative V8 + SRMMU implementation.** The download server is behind a browser check, so the README and license could not be fetched with curl; download them manually. GPL-2.0. |
| OpenSPARC T1 | https://www.oracle.com/servers/technologies/opensparc-t1-page.html | SPARC V9 (Niagara) RTL. Reference only, not V8. GPL-2.0. |
| Paranoia (netlib) | https://www.netlib.org/paranoia/ | Already local as `scratch/reference/cpu/fpu/paranoia.c` |
| Berkeley TestFloat/SoftFloat (current) | http://www.jhauser.us/arithmetic/TestFloat.html | Version 3 supersedes the local 2a/2b |
| Leon3 / GRLIB test benches | inside the GRLIB package (`designs/leon3-*`, `software/leon3/`) | These include the SPARC V8 systest |

---

## 13. MiSTer framework (links only)

| Link | Notes |
|---|---|
| https://github.com/MiSTer-devel/Template_MiSTer | The `sys/` framework, `emu` module interface, `hps_io`, ascal, video/audio. Source of this repo's `sys/`. |
| https://github.com/MiSTer-devel/Template_MiSTer/blob/master/sys/hps_io.sv | Full HPS↔FPGA protocol, directly from the source |
| https://github.com/MiSTer-devel/Main_MiSTer | The ARM-side Main binary (OSD, file I/O, CD/SCSI/eth helpers used by `rtl/mister`) |
| https://github.com/MiSTer-devel/Main_MiSTer/wiki | The developer wiki (core configuration strings, DDR3 layout, `CONF_STR`) |

---

## Gaps (not found from a legitimate host, or not fetched)

1. **SuperSPARC (TMS390Z50) User's Guide (TI/Sun, 1992-94), full edition.** Not found. Substitutes: the Viking 1990 user documentation, the STP1020A/STP1021A data sheets, STP1021UG and the white paper.
2. **SuperSPARC MXCC (TMS390Z55 / STP1090 / STP1091) cache-controller spec or data sheet.** Not found standalone. The Viking doc covers CC mode; register layout is in Linux `asm/mxcc.h`.
3. **SS20 "Kodiak" system-board engineering spec.** Not found, nor the specs for the SS10/SS20 **MSI** (MBus-SBus interface) and **EMC** (ECC memory controller) ASICs. Use Sun-4M System Architecture, the service manual and QEMU `eccmemctl.c`.
4. **TCX / S24 hardware manual and the AT&T 20C567 DAC data sheet.** Not found. Use NetBSD `tcxreg.h`, QEMU and Linux `tcx.c`, and the Brooktree Bt458 data sheet.
5. **CG3 / CG6 Sun hardware manuals.** Not found. Only the GX (L64845, FBC, TEC) docs and emulator sources exist.
6. **Sun APC DMA chip spec.** Not found. Driver sources only (NetBSD `apcdmareg.h`, OpenBSD/Linux cs4231).
7. **IEEE 1275-1994 core standard (final).** Not freely available: IEEE sells it and it is withdrawn. An unofficial copy at https://people.freebsd.org/~nwhitehorn/1275.pdf was not downloaded because its authorization is unverified. Only the drafts of the SPARC (1275.1) and SBus (1275.2) bindings were fetched.
8. **IEEE 754-1985 standard text.** Not free. Only drafts and tutorials (754r base document, Goldberg).
9. **SCSI-2 draft X3T9.2 rev 10L.** Not fetched. The T10 archive (https://t10.org/x3t9_2.htm) serves WordPerfect/ASCII files with restrictions. The bitsavers scan of the final ANSI X3.131-1994 is used instead.
10. **MMC / SCSI CD-ROM command references (MMC-1/2).** Not found freely: T10 drafts need membership. The SCSI-2 CD-ROM chapter (group 1/2 commands) in the ANSI scan covers the basics.
11. **The ST M48T08 data sheet direct from st.com.** Blocked to scripted downloads. A local copy (ST Doc 2411) is used. A **Mostek MK48T08** original was not found.
12. **A Type-4-specific Sun keyboard document.** Not found. The SPARC Keyboard Spec (Type 5) and NetBSD `kbd_tables.c` cover it.
13. **A proper Sun IDPROM format document.** The bitsavers `IDPROMS.pdf` is one handwritten page. Use Linux `asm/idprom.h`, QEMU `sun4m.c` (`nvram_init`) and OpenBIOS. NetBSD `sparc/include/idprom.h` does not exist at the pinned revision.
14. **GRLIB README and license.** Not fetched: the Gaisler download server sits behind a JavaScript browser check. Links are given in §12.
15. **The TME sun4m model.** None exists (TME covers sun2, sun3 and sun4c).
16. **The microSPARC-II User's Manual scan** (`microSPARC-II-UsersManual.pdf`, 69 MB) has a damaged xref. Use `microSPARC-II-UsersManual2.pdf`.
17. **Sun "Writing FCode 2.x Programs" / "OpenBoot 2.x Command Reference for SS20".** The FCode writer's guide was not fetched (Oracle docs reorganized). The OpenBoot 2.x Command Reference is present.
