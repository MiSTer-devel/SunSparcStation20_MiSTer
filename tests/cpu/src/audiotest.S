/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * audiotest: the SS20's CS4231 + APC (SBus slot 3) played as NetBSD's
 * audiocs driver plays it, the pace timed on the system counter. NetBSD 11
 * runs the codec at 48 kHz, 16-bit little-endian stereo (I8 = I28 = 0x5C,
 * MODE 2) in 7680-byte (40 ms) blocks, double-buffered: the next pair
 * (PNVA, PNC) loaded at trigger and again on each PI with PD; with a
 * recording track it runs capture the same way. Each test plays NBLK
 * blocks and checks that they take NBLK x 40 ms of the system counter
 * (+-2 %), printing the measured time. The same ROM runs in the
 * simulation and on the board (as boot.rom).
 *
 * Built with: python3 tests/cpu/build.py ss20 --main=audiotest
 */
#include "runtime.S"

        .text

#define AUD_PA          0x3c000000      /* ASI 0x2e: pa 0xe_3c00_0000, slot 3 + 0xc000000 */
#define SBUS_ASI        0x2e
#define CR0             0x00            /* codec: index (MCE 0x40) */
#define CR1             0x04            /*   indexed data */
#define CR2             0x08            /*   status */
#define APC_CSR         0x10
#define APC_CVA         0x20
#define APC_CC          0x24
#define APC_CNVA        0x28
#define APC_CNC         0x2c
#define APC_PVA         0x30
#define APC_PC          0x34
#define APC_PNVA        0x38
#define APC_PNC         0x3c
/* APC CSR bits */
#define A_PI            0x00400000
#define A_CI            0x00200000
#define A_IE            0x00080000
#define A_PIE           0x00040000
#define A_CIE           0x00020000
#define A_PMIE          0x00001000
#define A_PD            0x00002000
#define A_CD            0x00000400
#define A_CMIE          0x00000100
#define A_PGO           0x00000008
#define A_CGO           0x00000004
#define A_RESET         0x00000001

#define MEM_ASI         0x20
#define SITM_SET_PA     0xf1410008      /* ASI 0x2f */
#define SITM_ASI        0x2f
#define SYS_CTR         0xf1310004      /* ASI 0x2f: 500 ns ticks in bits 30:9 */
#define IOMMU_PA        0xe0000000      /* ASI 0x2f */
#define IOMMU_ASI       0x2f
#define IOPT            (SCRATCH + 0x20000)     /* IOMMU table, 16 KB aligned */
#define DVMA            0xff000000              /* DVMA of pa SCRATCH */

#define BLK             7680            /* 40 ms at 48 kHz, 4 bytes a frame */
#define NBLK            25              /* 1 s */
#define TICKS_BLK       80000           /* 40 ms of 500 ns ticks */
#define BUF_P0          0x1000          /* offsets in SCRATCH (DVMA + the same) */
#define BUF_P1          (BUF_P0 + 0x2000)
#define BUF_C0          (BUF_P0 + 0x4000)
#define BUF_C1          (BUF_P0 + 0x6000)

/* cw(reg %o0, byte %o1): a codec register; leaf */
cw:     set AUD_PA, %o2
        retl
        stba %o1, [%o2 + %o0] SBUS_ASI
/* cr(reg %o0) -> %o0; leaf */
cr:     set AUD_PA, %o2
        retl
        lduba [%o2 + %o0] SBUS_ASI, %o0
/* aw(reg %o0, word %o1): an APC register; leaf */
aw:     set AUD_PA, %o2
        retl
        sta %o1, [%o2 + %o0] SBUS_ASI
/* ar(reg %o0) -> %o0; leaf */
ar:     set AUD_PA, %o2
        retl
        lda [%o2 + %o0] SBUS_ASI, %o0

/* iw(index %o0 | MCE, value %o1): an indexed codec register */
iw:     save %sp, -96, %sp
        mov %i0, %o1
        call cw
        mov CR0, %o0
        mov %i1, %o1
        call cw
        mov CR1, %o0
        ret
        restore
/* ird(index %o0 | MCE) -> %o0 */
ird:    save %sp, -96, %sp
        mov %i0, %o1
        call cw
        mov CR0, %o0
        call cr
        mov CR1, %o0
        mov %o0, %i0
        ret
        restore

/* ticks() -> %o0: the system counter's 22-bit tick count; leaf */
ticks:  set SYS_CTR, %o1
        lda [%o1] 0x2f, %o0
        srl %o0, 9, %o0
        set 0x3fffff, %o1
        retl
        and %o0, %o1, %o0

/* setup(): interrupts masked, the IOMMU window, the codec at 48 kHz
 * 16-bit LE stereo (MODE 2, I8 = I28 = 0x5C), the APC reset */
setup:  save %sp, -96, %sp
        set SITM_SET_PA, %l0
        mov -1, %l1
        sta %l1, [%l0] SITM_ASI
        /* IOMMU entries 0-15 map pa SCRATCH + 64 KB (as scsitest) */
        set IOPT, %l0
        set SCRATCH, %l2
        clr %l3
1:      srl %l2, 4, %l4
        or %l4, 6, %l4
        sll %l3, 2, %l5
        sta %l4, [%l0 + %l5] MEM_ASI
        set 0x1000, %l6
        add %l2, %l6, %l2
        add %l3, 1, %l3
        cmp %l3, 16
        bl 1b
        nop
        set IOMMU_PA, %l1
        srl %l0, 4, %l4
        mov 4, %l5
        sta %l4, [%l1 + %l5] IOMMU_ASI
        mov 1, %l4
        sta %l4, [%l1] IOMMU_ASI
        mov 0x14, %l5
        sta %g0, [%l1 + %l5] IOMMU_ASI
        /* the APC: reset, then the codec out of power down */
        set A_RESET, %o1
        call aw
        mov APC_CSR, %o0
        clr %o1
        call aw
        mov APC_CSR, %o0
        /* wait for the codec's initialization (R0 reads 0x80) */
        set 2000000, %l0
2:      call cr
        mov CR0, %o0
        cmp %o0, 0x80
        bne 3f
        subcc %l0, 1, %l0
        bne 2b
        nop
3:      mov 0x4c, %o0                   /* MCE | I12: MODE 2 */
        call iw
        mov 0x40, %o1
        mov 0x49, %o0                   /* I9: no calibration, PEN/CEN off */
        call iw
        clr %o1
        mov 0x48, %o0                   /* I8: 48 kHz, 16-bit LE, stereo */
        call iw
        mov 0x5c, %o1
        mov 0x5c, %o0                   /* I28: the same for capture */
        call iw
        mov 0x5c, %o1
        mov 0x46, %o0                   /* I6/I7: 0 dB, unmuted */
        call iw
        clr %o1
        mov 0x47, %o0
        call iw
        clr %o1
        clr %o1                         /* MCE off */
        call cw
        mov CR0, %o0
        ret
        restore

/* play(cap %i0) -> %i0 = ticks for blocks 2..NBLK (the first one starts
 * the pipe), or -1 when a PI did not come within 4 blocks' time. With cap,
 * capture runs too (CGO, CEN; CI serviced as NetBSD's handler does). */
play:   save %sp, -96, %sp
        /* trigger_output: the first pair, then GO */
        set DVMA + BUF_P0, %o1
        call aw
        mov APC_PNVA, %o0
        set BLK, %o1
        call aw
        mov APC_PNC, %o0
        set A_IE | A_PIE | A_PMIE | A_PGO, %l5
        tst %i0
        be 1f
        nop
        /* trigger_input: the first capture pair */
        set DVMA + BUF_C0, %o1
        call aw
        mov APC_CNVA, %o0
        set BLK, %o1
        call aw
        mov APC_CNC, %o0
        set A_CIE | A_CMIE | A_CGO, %l6
        or %l5, %l6, %l5
1:      mov %l5, %o1
        call aw
        mov APC_CSR, %o0
        /* the second pairs, behind the first (PD, CD) */
        set DVMA + BUF_P1, %o1
        call aw
        mov APC_PNVA, %o0
        set BLK, %o1
        call aw
        mov APC_PNC, %o0
        tst %i0
        be 2f
        nop
        set DVMA + BUF_C1, %o1
        call aw
        mov APC_CNVA, %o0
        set BLK, %o1
        call aw
        mov APC_CNC, %o0
2:      mov 0x09, %o0                   /* I9: PEN (and CEN) */
        tst %i0
        be,a 3f
        mov 0x01, %o1
        mov 0x03, %o1
3:      call iw
        nop
        /* the blocks: wait for PI, write the CSR back, load the next pair */
        clr %l0                         /* blocks done */
        clr %l1                         /* ticks summed from block 1's PI */
        clr %l2                         /* buffer toggle */
        call ticks
        nop
        mov %o0, %l3                    /* the count at the last look */
        clr %l4                         /* ticks since the last PI */
10:     call ar
        mov APC_CSR, %o0
        mov %o0, %l6
        call ticks
        nop
        sub %o0, %l3, %o1
        mov %o0, %l3
        set 0x3fffff, %o2
        and %o1, %o2, %o1
        add %l4, %o1, %l4
        set 4 * TICKS_BLK, %o2
        cmp %l4, %o2
        bgu,a 90f
        mov -1, %i0
        set A_PI | A_CI, %o2            /* NetBSD's handler: write the CSR */
        andcc %l6, %o2, %g0             /* back (clears PI and CI) */
        be 10b
        nop
        mov %l6, %o1
        call aw
        mov APC_CSR, %o0
        set A_CI | A_CD, %o2            /* capture: the next pair on CI with CD */
        and %l6, %o2, %o3
        cmp %o3, %o2
        bne 11f
        nop
        set DVMA + BUF_C0, %o1
        call aw
        mov APC_CNVA, %o0
        set BLK, %o1
        call aw
        mov APC_CNC, %o0
11:     set A_PI, %o2
        andcc %l6, %o2, %g0
        be 10b
        nop
        tst %l0                         /* from the first PI on, count */
        bne,a 12f
        add %l1, %l4, %l1
12:     clr %l4
        add %l0, 1, %l0
        set A_PD, %o2
        andcc %l6, %o2, %g0
        be 13f
        nop
        xor %l2, 1, %l2                 /* the next block, alternating */
        set DVMA + BUF_P0, %o1
        tst %l2
        bne,a 14f
        set DVMA + BUF_P1, %o1
14:     call aw
        mov APC_PNVA, %o0
        set BLK, %o1
        call aw
        mov APC_PNC, %o0
13:     cmp %l0, NBLK
        bl 10b
        nop
        mov %l1, %i0
90:     /* stop: PEN/CEN off, GO off */
        mov 0x09, %o0
        call iw
        clr %o1
        clr %o1
        call aw
        mov APC_CSR, %o0
        ret
        restore

/* report(ticks %o0): "  <name> ticks <hex> (expected <hex>)" */
report: save %sp, -96, %sp
        set .L_ticks, %o0
        call puts
        nop
        call puthex
        mov %i0, %o0
        set .L_exp, %o0
        call puts
        nop
        set (NBLK - 1) * TICKS_BLK, %o0
        call puthex
        nop
        set .L_nl, %o0
        call puts
        nop
        ret
        restore
        .pushsection .rodata
.L_ticks: .asciz "    ticks for 24 blocks: "
.L_exp:   .asciz " expected "
.L_nl:    .asciz "\n"
        .popsection

/* check_pace(ticks %o0): within 2 % of (NBLK - 1) x 40 ms (check 1) */
check_pace:
        save %sp, -96, %sp
        call report
        mov %i0, %o0
        set (NBLK - 1) * TICKS_BLK * 98 / 100, %l0
        set (NBLK - 1) * TICKS_BLK * 102 / 100, %l1
        mov 1, %l2
        cmp %i0, %l0
        bl 1f
        nop
        cmp %i0, %l1
        bgu 1f
        nop
        clr %l2
1:      EXPECT(%l2, 0, 1)
        ret
        restore

BEGIN(t_audio_play, "audio: 48 kHz 16-bit stereo, 25 blocks of 40 ms as NetBSD plays them: the pace")
        call setup
        nop
        call play
        clr %o0
        call check_pace                 /* (a PI timeout: ticks -1) */
        nop
END

BEGIN(t_audio_duplex, "audio: the same with capture running (NetBSD's full duplex): the pace")
        call setup
        nop
        call play
        mov 1, %o0
        call check_pace
        nop
END
        .section .testtab, "a", @progbits
        .word 0, 0                      /* end of the test table */

        .section .romend, "a", @progbits
        .align 4
        .globl rom_end
rom_end:
