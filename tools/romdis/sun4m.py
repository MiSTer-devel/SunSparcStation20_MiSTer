"""sun4m machine knowledge for the ROM disassembler: ASI names, MMU and
MXCC register names, and the SS5 / SS20 physical address maps.

Physical addresses are 36 bits. With the MMU off (or through the MMU bypass
ASIs 0x20-0x2F) bits 35:32 of the physical address come from ASI[3:0], so
`sta %x, [0xf1400000] 0x2f` on an SS20 is physical 0xf_f140_0000.

Sources: Sun-4M System Architecture; microSPARC-II User's Manual;
SuperSPARC / MXCC documentation; the Linux sparc32 asi.h / mxcc.h; QEMU
hw/sparc/sun4m.c machine tables. Entries marked (?) are unverified and
should be checked against the scratch/ manuals before they are relied on.
Extend these tables as the ROM analysis finds more.
"""

# ---------------------------------------------------------------- ASIs ----
ASI_COMMON = {
    0x01: "ASI_PTE/unassigned",
    0x02: "ASI_MXCC (SuperSPARC MXCC regs) / control space",
    0x03: "ASI_FLUSH_PROBE",
    0x04: "ASI_MMUREGS",
    0x05: "ASI_TLBDIAG",
    0x06: "ASI_DIAGS (TLB/MMU diag)",
    0x07: "ASI_IODIAG",
    0x08: "ASI_USERTXT",
    0x09: "ASI_KERNELTXT",
    0x0a: "ASI_USERDATA",
    0x0b: "ASI_KERNELDATA",
    0x0c: "ASI_ICACHE_TAG",
    0x0d: "ASI_ICACHE_DATA",
    0x0e: "ASI_DCACHE_TAG",
    0x0f: "ASI_DCACHE_DATA",
    0x10: "ASI_FLUSH_PAGE",
    0x11: "ASI_FLUSH_SEG",
    0x12: "ASI_FLUSH_REGION",
    0x13: "ASI_FLUSH_CTX",
    0x14: "ASI_FLUSH_USER",
    0x17: "ASI_BCOPY",
    0x18: "ASI_IFLUSH_PAGE",
    0x19: "ASI_IFLUSH_SEG",
    0x1a: "ASI_IFLUSH_REGION",
    0x1b: "ASI_IFLUSH_CTX",
    0x1c: "ASI_IFLUSH_USER",
    0x1f: "ASI_BFILL",
    0x30: "ASI 0x30 (SuperSPARC store buffer tags)",
    0x31: "ASI_FLUSH_IWHOLE (Ross) / store buffer data (SuperSPARC)",
    0x32: "ASI 0x32 (SuperSPARC store buffer control)",
    0x36: "ASI_IC_FLCLEAR (I-cache flash clear)",
    0x37: "ASI_DC_FLCLEAR (D-cache flash clear)",
    0x38: "ASI 0x38 (SuperSPARC MMU breakpoint regs; SS20 POST keeps "
          "the MID at va 0)",
    0x39: "ASI_DCDR (D-cache diag)",
    0x40: "ASI_VIKING_TMP1 / emulation temp (?)",
    0x41: "ASI_VIKING_TMP2 (?)",
    0x48: "ASI 0x48 (SuperSPARC-II counter A)",
    0x49: "ASI 0x49 (SuperSPARC-II counter B)",
    0x4a: "ASI 0x4a (SuperSPARC-II counter breakpoint control)",
    0x4b: "ASI 0x4b (SuperSPARC-II counter breakpoint status)",
    0x4c: "ASI_ACTION (Viking breakpoint action)",
}
for _a in range(0x20, 0x30):
    ASI_COMMON[_a] = f"ASI_BYPASS pa[35:32]=0x{_a & 0xf:x}"

# ASI 0x04 register offsets (SRMMU reference MMU)
MMUREGS = {
    0x000: "MMU control (PCR/MCNTL)",
    0x100: "context table pointer",
    0x200: "context",
    0x300: "sync fault status (SFSR)",
    0x400: "sync fault address (SFAR)",
    0x500: "async fault status (AFSR) (?)",
    0x600: "async fault address (AFAR) (?)",
    0x700: "reset / breakpoint (?)",
    0x1000: "MMU/cache control extension (?); HyperSPARC root pointer",
    0x1100: "HyperSPARC instruction pointer (?)",
    0x1200: "HyperSPARC data pointer (?)",
    0x1300: "HyperSPARC index tag (?)",
    0x1400: "HyperSPARC TLB replacement (?)",
    0x1500: "SuperSPARC shadow SFSR (emulation) (?)",
}

# ASI 0x04 on microSPARC-II (User's Manual Table 54: VA[12:8] selects)
MMUREGS_SWIFT = {
    0x000: "PCR (MMU control)",
    0x100: "context table pointer",
    0x200: "context",
    0x300: "SFSR (clears on read)",
    0x400: "SFAR (clears on read)",
    0x1000: "TLB replacement control",
    0x1300: "SFSR diag (writable)",
    0x1400: "SFAR diag (writable)",
}


def swift_tlb_diag(ea):
    """ASI 0x06 on microSPARC-II: 64 TLB entries; layout inferred from the
    SS5 PROM (tlb_init_clear, TLB NTA tests): 0x000+4n PTE, 0x100+4n lower
    tag (permissions), 0x300+4n upper tag (VA tag, context, V, level)."""
    part = {0x000: "PTE", 0x100: "lower tag", 0x300: "upper tag/CAM"}.get(
        ea & 0x300)
    if part is None or ea >= 0x400:
        return None
    return f"TLB entry {(ea & 0xff) >> 2} {part}"


# ASI 0x02 on SuperSPARC with MXCC (Linux asm/mxcc.h)
MXCC = {
    0x01000000: "MXCC E-cache data diag (+ line<<7 + sb<<5 + dw<<3)",
    0x01800000: "MXCC E-cache tag diag (+ line<<7)",
    0x01c00000: "MXCC stream data",
    0x01c00100: "MXCC stream source",
    0x01c00200: "MXCC stream destination",
    0x01c00300: "MXCC reference/miss count",
    0x01c00a00: "MXCC control (hi)",
    0x01c00a04: "MXCC control register (CREG)",
    0x01c00b00: "MXCC status register (SREG)",
    0x01c00c00: "MXCC reset (hi)",
    0x01c00c04: "MXCC reset register (RREG)",
    0x01c00e00: "MXCC error register (EREG)",
    0x01c00f00: "MXCC port (hi)",
    0x01c00f04: "MXCC module port register (PREG)",
}

# ------------------------------------------------------- address maps ----
# (start, end_exclusive, name). 36-bit physical addresses.
SS5_MAP = [
    (0x0_00000000, 0x0_10000000, "RAM"),
    # IOMMU: control +0, base +4, flush all +0x14, address flush +0x18
    (0x0_10000000, 0x0_10001000, "IOMMU"),
    # AFSR +0, AFAR +4, SSCR0-4 +0x10..+0x20, MFSR +0x50, MFAR +0x54
    (0x0_10001000, 0x0_10002000, "SBus controller"),
    (0x0_10002000, 0x0_10003000, "MID register / SBus arbitration enable"),
    (0x0_10003000, 0x0_10004000, "performance counter trigger enables"),
    (0x0_20000000, 0x0_30000000, "SBus slot 0 (?)"),
    (0x0_30000000, 0x0_40000000, "SBus slot 1 (?)"),
    (0x0_40000000, 0x0_50000000, "SBus slot 2 (?)"),
    (0x0_50000000, 0x0_60000000, "TCX (SBus slot 3)"),
    (0x0_6a000000, 0x0_6a100000, "APC power/audio DMA"),
    (0x0_6c000000, 0x0_6c100000, "CS4231 audio codec"),
    (0x0_6e000000, 0x0_6e100000, "AFX (?)"),
    (0x0_70000000, 0x0_71000000, "boot PROM"),
    (0x0_71000000, 0x0_71100000, "ESCC0 keyboard/mouse (Z85C30)"),
    (0x0_71100000, 0x0_71200000, "ESCC1 serial A/B (Z85C30)"),
    (0x0_71200000, 0x0_71300000, "NVRAM/TOD (MK48T08)"),
    (0x0_71400000, 0x0_71500000, "floppy (82077)"),
    (0x0_71900000, 0x0_71910000, "aux1 (LED/floppy aux)"),
    (0x0_71910000, 0x0_71920000, "aux2 (power/modem)"),
    (0x0_71d00000, 0x0_71e00000, "counter/timers"),
    (0x0_71e00000, 0x0_71f00000, "interrupt controller"),
    # bit 0 SW reset (W), bit 1 SW-reset status, bit 4 watchdog (per the ROM)
    (0x0_71f00000, 0x0_72000000, "system control/status"),
    (0x0_78000000, 0x0_78400000, "SBus slot 5 base / DMA2 ID register"),
    (0x0_78400000, 0x0_78800000, "DMA2 (ESP/LANCE DMA)"),
    (0x0_78800000, 0x0_78c00000, "ESP 53C9x SCSI"),
    (0x0_78c00000, 0x0_79000000, "LANCE Am7990 Ethernet"),
    # DMA2 P_CSR +0, P_ADDR +4, P_BCNT +8; BPP registers +0x10..+0x18
    (0x0_7c800000, 0x0_7c900000, "DMA2 parallel / BPP"),
    (0x0_7c000000, 0x0_80000000, "other onboard (?)"),
]

# SS20 (and SS10, "Campus-2"): Sun-4M System Architecture 950-1373-01
# sections 3.2.x and Appendix A.II, checked against the accesses the SS20
# OBP 2.25 ROM makes (docs/rom-disassembly/ss20-obp-2.25/) and QEMU's SS-20
# machine table. Memory: 8 SIMM sockets on 64 MB boundaries (512 MB).
SS20_MAP = [
    (0x0_00000000, 0x0_20000000, "RAM (8 SIMM slots x 64 MB)"),
    (0x0_80000000, 0x0_90000000, "VSIMM frame buffer (?)"),
    (0x0_90000000, 0x0_a0000000, "VSIMM/MDI control, SIMM slot 4-7 "
     "at +0x4000000*(n-4)"),
    (0xe_00000000, 0xe_10000000, "SBus slot 0"),
    (0xe_10000000, 0xe_20000000, "SBus slot 1"),
    (0xe_20000000, 0xe_30000000, "SBus slot 2"),
    (0xe_30000000, 0xe_40000000, "SBus slot 3"),
    (0xe_e0000000, 0xe_f0000000, "SBus slot 14 onboard (DBRI audio)"),
    (0xe_f0000000, 0xe_f0400000, "SBus slot 15 base (DMA2 internal/ID?)"),
    (0xe_f0400000, 0xe_f0800000, "DMA2 (SCSI DMA +0, ENET DMA +0x10)"),
    (0xe_f0800000, 0xe_f0c00000, "ESP 53C9x SCSI"),
    (0xe_f0c00000, 0xe_f1000000, "LANCE Am7990 Ethernet"),
    (0xe_f4800000, 0xe_f4900000, "parallel port (DMA2 PP)"),
    (0xf_00000000, 0xf_00001000, "EMC ECC memory controller"),
    (0xf_00001000, 0xf_10000000, "memory control space (message regs, "
     "not on Campus-2)"),
    (0xf_80000000, 0xf_c0000000, "SX graphics (?)"),
    (0xf_e0000000, 0xf_e0001000, "IOMMU"),
    (0xf_e0001000, 0xf_e0002000, "MSI M-to-S regs (AFSR/AFAR/arbiter/"
     "slot cfg)"),
    (0xf_e0002000, 0xf_e0003000, "MSI MID register"),
    (0xf_f0000000, 0xf_f1000000, "boot PROM (EPROM)"),
    (0xf_f1000000, 0xf_f1100000, "ESCC0 keyboard/mouse (Z85C30)"),
    (0xf_f1100000, 0xf_f1200000, "ESCC1 serial A/B (Z85C30)"),
    (0xf_f1200000, 0xf_f1300000, "NVRAM/TOD (MK48T08)"),
    (0xf_f1300000, 0xf_f1400000, "counter/timers"),
    (0xf_f1400000, 0xf_f1500000, "interrupt controller"),
    (0xf_f1500000, 0xf_f1600000, "audio/ISDN (optional)"),
    (0xf_f1600000, 0xf_f1700000, "diagnostic LEDs (not on Campus-2)"),
    (0xf_f1700000, 0xf_f1800000, "floppy (82077)"),
    (0xf_f1800000, 0xf_f1900000, "AUXIO0 (LED/floppy/serial-B mux)"),
    (0xf_f1a00000, 0xf_f1b00000, "generic 8-bit / AUXIO1 power at "
     "+0x1000"),
    (0xf_f1f00000, 0xf_f2000000, "system control/status"),
    (0xf_f8000000, 0x10_00000000, "MBus module control space (MID 8-F)"),
]

PROFILES = {
    "ss5": {"map": SS5_MAP, "cpu": "microSPARC-II (Swift, MB86904)"},
    "ss20": {"map": SS20_MAP, "cpu": "SuperSPARC (Viking) +/- MXCC, HyperSPARC"},
}


def device(profile, pa):
    for lo, hi, name in PROFILES[profile]["map"]:
        if lo <= pa < hi:
            return name, pa - lo
    return None, None


def asi_name(asi):
    return ASI_COMMON.get(asi, f"ASI 0x{asi:02x}")


def describe_asi_access(profile, asi, ea):
    """One-line description of an alternate-space access to effective
    address ea (None when unknown)."""
    name = asi_name(asi)
    if ea is None:
        return name
    if 0x20 <= asi <= 0x2f:
        pa = ((asi & 0xf) << 32) | ea
        dev, off = device(profile, pa)
        if dev:
            return f"pa 0x{pa:09x} {dev} +0x{off:x}"
        return f"pa 0x{pa:09x}"
    if asi == 0x04:
        regs = MMUREGS_SWIFT if profile == "ss5" else MMUREGS
        reg = regs.get(ea & 0xffff if ea < 0x10000 else ea)
        return f"{name} {reg or hex(ea)}"
    if asi == 0x06 and profile == "ss5" and swift_tlb_diag(ea):
        return f"{name} {swift_tlb_diag(ea)}"
    if asi == 0x02 and ea in MXCC:
        return f"{name}: {MXCC[ea]}"
    return f"{name} [0x{ea:08x}]"
