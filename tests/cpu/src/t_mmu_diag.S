/* The SuperSPARC TLB diagnostic image (ASI 6, audit MMU-2), as the SS20
 * POST exercises it (docs/rom-disassembly/ss20-obp-2.25/post-tests.md,
 * "MMU TLB Bit Pattern Tests" and "MMU Flush Tests"). Address entry << 12
 * | SEL << 8: SEL0 the VA tag (bits 31:12), SEL1 the context (16 bits),
 * SEL2 the PTE (V in bit 5, the level in bits 1:0), SEL3 lock (bit 0) and
 * RBO (bit 1). An ASI 3 demap clears V in the entries the TLB flush rules
 * match: page (type 0, VA[31:12], level 3), segment (1, VA[31:18], levels
 * 2-3), region (2, VA[31:24], levels 1-3), context (3, the context
 * register), entire (4). MMU off, as in the POST. */
#include "macros.h"

#if defined(TARGET_SS20)
#define DG_STA(reg, e, sel)  sll e, 12, %o5 ; or %o5, (sel) << 8, %o5 ; sta reg, [%o5] 6
#define DG_LDA(e, sel, dst)  sll e, 12, %o5 ; or %o5, (sel) << 8, %o5 ; lda [%o5] 6, dst

        .section .rodata
        .align 4
dg_pat: .word 0xaaaaa000, 0xaaaa, 0xaaaaaaaa, 0
        .word 0x55555000, 0x5555, 0x55555555, 1
        .word 0xfffff000, 0xffff, 0xffffffff, 1
        .word 0, 0, 0, 0
        .text

/* dg_cmp(exp %o1, obs %o2): count a mismatch in %g2, keep the first in
 * %g3/%g4 (exp/obs) and its ASI 6 address in %g5 */
dg_cmp: cmp %o1, %o2
        be 1f
        nop
        tst %g2
        bne 2f
        inc %g2
        mov %o1, %g3
        mov %o2, %g4
        mov %o5, %g5
2:      inc %g2
1:      retl
        nop

/* dg_mode(sel0 shift %i0 or -1 for 0, SEL1 = entry %i1, SEL2 %i2, flush
 * type %i3, mode %i4: 1 = context := step, 2 = entire, else plain): fill
 * the 64 entries, then step j = 0..63: flush (j << %i0 | type << 8), entry
 * j must read SEL2 & ~0x20 and entry j + 1 SEL2 unchanged; the entire mode
 * fills SEL2 = 0x20 | (e & 3), flushes once and every entry reads e & 3 */
dg_mode:
        save %sp, -96, %sp
        clr %l0
1:      cmp %i0, -1
        be 2f
        mov 0, %o1
        sll %l0, %i0, %o1
2:      DG_STA(%o1, %l0, 0)
        tst %i1
        be 3f
        mov 0, %o1
        mov %l0, %o1
3:      DG_STA(%o1, %l0, 1)
        cmp %i4, 2
        bne 4f
        mov %i2, %o1
        and %l0, 3, %o1
        or %o1, 0x20, %o1
4:      DG_STA(%o1, %l0, 2)
        DG_STA(%g0, %l0, 3)
        inc %l0
        cmp %l0, 64
        bne 1b
        nop
        cmp %i4, 2
        bne 5f
        nop
        set 0x400, %o5                  /* entire */
        sta %g0, [%o5] 3
        clr %l0
6:      DG_LDA(%l0, 2, %o2)
        call dg_cmp
        and %l0, 3, %o1
        inc %l0
        cmp %l0, 64
        bne 6b
        nop
        ret
        restore
5:      clr %l0
7:      cmp %i4, 1
        bne 8f
        mov 0x200, %o5
        sta %l0, [%o5] 4                /* context := j */
8:      cmp %i0, -1
        be 9f
        mov 0, %o5
        sll %l0, %i0, %o5
9:      sll %i3, 8, %o1
        or %o5, %o1, %o5
        sta %g0, [%o5] 3                /* the demap */
        DG_LDA(%l0, 2, %o2)
        call dg_cmp
        andn %i2, 0x20, %o1             /* V cleared, the level kept */
        cmp %l0, 63
        be 10f
        add %l0, 1, %l1
        DG_LDA(%l1, 2, %o2)
        call dg_cmp
        mov %i2, %o1                    /* the next one untouched */
10:     inc %l0
        cmp %l0, 64
        bne 7b
        nop
        ret
        restore

BEGIN(t_mmu_diag_pattern, "mmu: SS20 ASI 6 TLB image: 64 entries x SEL0-3 hold the POST's bit patterns")
        clr %g2
        clr %g3
        clr %g4
        clr %g5
        set dg_pat, %l7
        mov 4, %l6                      /* pattern sets */
1:      clr %l4                         /* entries */
2:      ld [%l7], %o1
        DG_STA(%o1, %l4, 0)
        ld [%l7 + 4], %o1
        DG_STA(%o1, %l4, 1)
        ld [%l7 + 8], %o1
        DG_STA(%o1, %l4, 2)
        ld [%l7 + 12], %o1
        DG_STA(%o1, %l4, 3)
        DG_LDA(%l4, 0, %o2)
        call dg_cmp
        ld [%l7], %o1
        DG_LDA(%l4, 1, %o2)
        call dg_cmp
        ld [%l7 + 4], %o1
        DG_LDA(%l4, 2, %o2)
        call dg_cmp
        ld [%l7 + 8], %o1
        DG_LDA(%l4, 3, %o2)
        call dg_cmp
        ld [%l7 + 12], %o1
        inc %l4
        cmp %l4, 64
        bne 2b
        nop
        subcc %l6, 1, %l6
        bne 1b
        add %l7, 16, %l7
        EXPECT_R(%g4, %g3, 1)           /* the first mismatch, if any */
        EXPECT_R(%g2, %g0, 2)           /* mismatches */
        mov %g5, %l0
        EXPECT_R(%l0, %g0, 3)           /* its address */
END

BEGIN(t_mmu_diag_flush, "mmu: SS20 ASI 6 TLB image: ASI 3 demaps (context, region, segment, page, entire) clear V by the flush rules")
        mov 0x200, %l5
        lda [%l5] 4, %l6                /* the context register, kept */
        clr %g2
        clr %g3
        clr %g4
        clr %g5
        mov -1, %o0                     /* context: SEL0 0, SEL1 = e, level 0 */
        mov 1, %o1
        mov 0x20, %o2
        mov 3, %o3
        call dg_mode
        mov 1, %o4
        EXPECT_R(%g2, %g0, 0x10)
        sta %g0, [%l5] 4                /* context 0 */
        clr %g2
        mov 24, %o0                     /* region: SEL0 = e << 24, level 1 */
        mov 0, %o1
        mov 0x21, %o2
        mov 2, %o3
        call dg_mode
        mov 0, %o4
        EXPECT_R(%g2, %g0, 0x11)
        clr %g2
        mov 18, %o0                     /* segment: SEL0 = e << 18, level 2 */
        mov 0, %o1
        mov 0x22, %o2
        mov 1, %o3
        call dg_mode
        mov 0, %o4
        EXPECT_R(%g2, %g0, 0x12)
        clr %g2
        mov 12, %o0                     /* page: SEL0 = e << 12, level 3 */
        mov 0, %o1
        mov 0x23, %o2
        mov 0, %o3
        call dg_mode
        mov 0, %o4
        EXPECT_R(%g2, %g0, 0x13)
        clr %g2
        mov 12, %o0                     /* entire: SEL0 = e << 12, SEL1 = e */
        mov 1, %o1
        mov 0x20, %o2
        mov 4, %o3
        call dg_mode
        mov 2, %o4
        EXPECT_R(%g2, %g0, 0x14)
        EXPECT_R(%g4, %g3, 0x15)        /* the first mismatch of the five */
        mov %g5, %l0
        EXPECT_R(%l0, %g0, 0x16)
        clr %l4                         /* every entry 0 again */
1:      DG_STA(%g0, %l4, 0)
        DG_STA(%g0, %l4, 1)
        DG_STA(%g0, %l4, 2)
        DG_STA(%g0, %l4, 3)
        inc %l4
        cmp %l4, 64
        bne 1b
        nop
        sta %l6, [%l5] 4
END
#else
BEGIN(t_mmu_diag_pattern, "mmu: SS20 ASI 6 TLB image: 64 entries x SEL0-3 hold the POST's bit patterns")
        SKIP_TEST
END
BEGIN(t_mmu_diag_flush, "mmu: SS20 ASI 6 TLB image: ASI 3 demaps (context, region, segment, page, entire) clear V by the flush rules")
        SKIP_TEST
END
#endif
