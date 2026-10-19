/* Chipset registers after a power-on reset, and the address decode of the
 * PROM, the NVRAM IDPROM and the frame buffer's FCode. Not CPU tests: they
 * check the core's chipset behaviour (AUX-1, DMA-2, INT-1, TOD-5) with the
 * suite's plumbing.
 * Physical addresses through the MMU bypass ASIs: 0x20 for pa[35:32] = 0,
 * 0x2e/0x2f for 0xe/0xf. */
#include "macros.h"

#if defined(TARGET_SS20)
#  define SYSCON_PA     0xf1f00000      /* ASI 0x2f: pa 0xf_f1f0_0000 */
#  define SYSCON_ASI    0x2f
#  define NVRAM_PA      0xf1200000      /* ASI 0x2f: pa 0xf_f120_0000 */
#  define NVRAM_ASI     0x2f
#  define TCX_PA        0x20000000      /* ASI 0x2e: pa 0xe_2000_0000 */
#  define TCX_ASI       0x2e
#  define EBASE_PA      0xf040001c      /* ASI 0x2e: DMA2 E_BASE_ADDR */
#  define EBASE_ASI     0x2e
#  define MACHINE_TYPE  0x72
#  define FDC_PA        0xf1700000      /* ASI 0x2f: pa 0xf_f170_0000 */
#  define FDC_ASI       0x2f
#  define SIPR_PA       0xf1410000      /* system interrupt pending */
#  define SIPR_ASI      0x2f
#else
#  define SYSCON_PA     0x71f00000
#  define SYSCON_ASI    0x20
#  define NVRAM_PA      0x71200000
#  define NVRAM_ASI     0x20
#  define TCX_PA        0x50000000      /* SBus slot 3 */
#  define TCX_ASI       0x20
#  define EBASE_PA      0x7840001c
#  define EBASE_ASI     0x20
#  define MACHINE_TYPE  0x80
#  define FDC_PA        0x71400000
#  define FDC_ASI       0x20
#  define SIPR_PA       0x71e10000
#  define SIPR_ASI      0x20
#endif

BEGIN(t_syscon, "chipset: system control reads 0 after power-on (RS, WD clear)")
        set SYSCON_PA, %l0
        lda [%l0] SYSCON_ASI, %l1
        and %l1, 0x13, %l1              /* SR (reads 0), RS, WD */
        EXPECT(%l1, 0, 1)
END

BEGIN(t_idprom, "chipset: NVRAM IDPROM format 1, machine type, checksum")
        set NVRAM_PA + 0x1fd8, %l0
        lduba [%l0] NVRAM_ASI, %l1
        EXPECT(%l1, 1, 1)               /* format */
        add %l0, 1, %l2
        lduba [%l2] NVRAM_ASI, %l1
        EXPECT(%l1, MACHINE_TYPE, 2)
        clr %l3                         /* XOR of all 16 bytes is 0 */
        clr %l4
1:      lduba [%l0 + %l4] NVRAM_ASI, %l1
        xor %l3, %l1, %l3
        add %l4, 1, %l4
        cmp %l4, 16
        bl 1b
        nop
        EXPECT(%l3, 0, 3)
        /* Sun's convention: the Ethernet address ends with the hostid's
           serial (bytes 5-7 = 12-14) */
        clr %l4
2:      add %l4, 5, %l2
        lduba [%l0 + %l2] NVRAM_ASI, %l1
        add %l4, 12, %l2
        lduba [%l0 + %l2] NVRAM_ASI, %l3
        EXPECT_R(%l1, %l3, 4)
        add %l4, 1, %l4
        cmp %l4, 3
        bl 2b
        nop
END

/* NVRAM offset 0x100: byte stores reach their own lanes, a word store
 * reads back as bytes. The word is restored, so a saved NVRAM image (the
 * core writes the NVRAM back to the SD card, TOD-6) keeps its content. */
BEGIN(t_nvram, "chipset: NVRAM byte and word stores read back (restored)")
        set NVRAM_PA + 0x100, %l0
        lda [%l0] NVRAM_ASI, %l5        /* the original word */
        mov 0x5a, %l1
        stba %l1, [%l0] NVRAM_ASI
        mov 0xa5, %l1
        add %l0, 1, %l2
        stba %l1, [%l2] NVRAM_ASI
        mov 0x3c, %l1
        add %l0, 2, %l2
        stba %l1, [%l2] NVRAM_ASI
        mov 0xc3, %l1
        add %l0, 3, %l2
        stba %l1, [%l2] NVRAM_ASI
        lda [%l0] NVRAM_ASI, %l1
        EXPECT(%l1, 0x5aa53cc3, 1)
        set 0x12345678, %l1
        sta %l1, [%l0] NVRAM_ASI
        lduba [%l0] NVRAM_ASI, %l1
        EXPECT(%l1, 0x12, 2)
        add %l0, 3, %l2
        lduba [%l2] NVRAM_ASI, %l1
        EXPECT(%l1, 0x78, 3)
        sta %l5, [%l0] NVRAM_ASI        /* restore */
        lda [%l0] NVRAM_ASI, %l1
        EXPECT_R(%l1, %l5, 4)
END

BEGIN(t_fcode, "chipset: frame buffer slot starts with FCode (0xf1 header)")
        set TCX_PA, %l0
        lduba [%l0] TCX_ASI, %l1
        EXPECT(%l1, 0xf1, 1)            /* FCode start byte */
        add %l0, 4, %l0
        lda [%l0] TCX_ASI, %l1          /* image length */
        cmp %l1, 16
        bl 2f
        mov 0, %l2
        set 0x10000, %l3
        cmp %l1, %l3
        bg 2f
        nop
        mov 1, %l2
2:      EXPECT(%l2, 1, 2)               /* 16 <= length <= 64 KiB */
END

BEGIN(t_ebase, "chipset: DMA2 E_BASE_ADDR resets to 0xff")
        set EBASE_PA, %l0
        lda [%l0] EBASE_ASI, %l1
        srl %l1, 24, %l1
        EXPECT(%l1, 0xff, 1)
END

#if defined(TARGET_SS5_QEMU)
BEGIN(t_prom70, "chipset: the PROM answers at pa 0x7000_0000")
        set 0x70000000, %l0             /* pa of the SS5 boot PROM */
        lda [%l0] 0x20, %l1
        set trap_table, %l2             /* the running image's first word */
        ld [%l2], %l3
        EXPECT_R(%l1, %l3, 1)
END
#endif

/* 82077 floppy controller, no drive (fdc82077). Leaf routines; each gives
 * up after about 100000 status reads, so a missing controller fails the
 * test instead of hanging the suite. */
/* write %o0 to the FIFO once the controller asks for a byte (RQM, !DIO) */
fdc_put:
        set FDC_PA + 4, %o1
        set 100000, %o3
1:      subcc %o3, 1, %o3
        be 2f
        nop
        lduba [%o1] FDC_ASI, %o2
        and %o2, 0xc0, %o2
        cmp %o2, 0x80
        bne 1b
        nop
        add %o1, 1, %o1                 /* FIFO */
        stba %o0, [%o1] FDC_ASI
2:      retl
        nop
/* %o0 = the next result byte (RQM, DIO), -1 when the result phase is over,
 * -2 when the controller never asks */
fdc_get:
        set FDC_PA + 4, %o1
        set 100000, %o3
1:      subcc %o3, 1, %o3
        be 3f
        nop
        lduba [%o1] FDC_ASI, %o2
        andcc %o2, 0x80, %g0
        be 1b
        nop
        andcc %o2, 0x40, %g0
        be 2f
        mov -1, %o0
        add %o1, 1, %o1                 /* FIFO */
        retl
        lduba [%o1] FDC_ASI, %o0
2:      retl
        nop
3:      retl
        mov -2, %o0

BEGIN(t_fdc, "chipset: 82077 floppy, no drive: reset, VERSION, RECALIBRATE, IRQ")
        set FDC_PA + 2, %l0             /* DOR */
        mov 0x0c, %l1                   /* out of reset, DMAGATE */
        stba %l1, [%l0] FDC_ASI
        clr %l2                         /* 4 polled-drive interrupts */
1:      call fdc_put
        mov 8, %o0                      /* SENSE INTERRUPT STATUS */
        call fdc_get
        nop
        mov %o0, %l3
        call fdc_get                    /* PCN */
        nop
        add %l2, 0xc0, %l4
        EXPECT_R(%l3, %l4, 1)           /* ST0 = 0xC0 + drive */
        add %l2, 1, %l2
        cmp %l2, 4
        bl 1b
        nop
        call fdc_put
        mov 8, %o0
        call fdc_get
        nop
        EXPECT(%o0, 0x80, 2)            /* nothing pending: invalid */
        call fdc_get
        nop
        EXPECT(%o0, -1, 3)              /* one result byte only */
        call fdc_put
        mov 0x10, %o0                   /* VERSION */
        call fdc_get
        nop
        EXPECT(%o0, 0x90, 4)            /* 82077AA */
        call fdc_put
        mov 7, %o0                      /* RECALIBRATE drive 1 */
        call fdc_put
        mov 1, %o0
        set SIPR_PA, %l5
        lda [%l5] SIPR_ASI, %l6
        srl %l6, 22, %l6
        and %l6, 1, %l6
        EXPECT(%l6, 1, 5)               /* floppy interrupt (level 11) */
        call fdc_put
        mov 8, %o0
        call fdc_get
        nop
        EXPECT(%o0, 0x71, 6)            /* abnormal, SE, EC: no drive */
        call fdc_get
        nop
        lda [%l5] SIPR_ASI, %l6
        srl %l6, 22, %l6
        and %l6, 1, %l6
        EXPECT(%l6, 0, 7)               /* cleared by SENSE INTERRUPT */
        stba %g0, [%l0] FDC_ASI         /* DOR: back in reset */
END

#if defined(TARGET_SS20)
/* TCX acceleration as Xsun's tcx module uses it for text and copies
 * (QEMU hw/display/tcx.c, NetBSD tcxreg.h): a doubleword store into the
 * STIP space (+0x0400_0000) writes the colour (first word) into the 32
 * pixels whose mask bits (second word) are set, at pixel = offset/8; one
 * into the BLIT space (+0x0600_0000) copies len = bits 28:24 + 1 pixels
 * from source pixel = bits 23:0 to pixel = offset/8. The 8-bit VRAM is at
 * +0x0080_0000. Under Solaris Xsun the first xterm froze the machine. */
#  define TCX_VRAM8     (TCX_PA + 0x00800000)
#  define TCX_STIP      (TCX_PA + 0x04000000)
#  define TCX_BLIT      (TCX_PA + 0x06000000)
BEGIN(t_tcx_accel, "chipset: TCX stipple and blit doubleword stores")
        set TCX_VRAM8, %l0
        sta %g0, [%l0] TCX_ASI          /* pixels 0-3 */
        add %l0, 4, %l1
        sta %g0, [%l1] TCX_ASI          /* pixels 4-7 */
        add %l0, 64, %l2
        sta %g0, [%l2] TCX_ASI          /* pixels 64-67 */
        set TCX_STIP, %l3
        set 0xab, %o2                   /* colour */
        set 0xf0000000, %o3             /* pixels 0-3 */
        stda %o2, [%l3] TCX_ASI
        lda [%l0] TCX_ASI, %l4
        EXPECT(%l4, 0xabababab, 1)
        lda [%l1] TCX_ASI, %l4
        EXPECT(%l4, 0, 2)
        set TCX_BLIT + 64*8, %l3
        clr %o2
        set 0x03000000, %o3             /* 4 pixels from pixel 0 */
        stda %o2, [%l3] TCX_ASI
        /* The copy may finish after the store is accepted (a TCX may ack
           first; a 55 MHz CPU's next load gets there before it):
           read until the pixels arrive, a few hundred tries at most. */
        set 512, %l5
1:      lda [%l2] TCX_ASI, %l4
        subcc %l4, %o2, %g0             /* (%o2 = 0: nonzero means arrived) */
        bne 2f
        subcc %l5, 1, %l5
        bne 1b
        nop
2:      EXPECT(%l4, 0xabababab, 3)
        sta %g0, [%l0] TCX_ASI          /* leave the corner black */
        sta %g0, [%l2] TCX_ASI
END
#endif
