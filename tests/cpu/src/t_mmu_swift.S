/* microSPARC-II (Swift) MMU registers, lifted from the SS5 OBP 2.15 POST
 * (docs/rom-disassembly/ss5-obp/post-tests.md 3.1, mmu_reg_walk_test at
 * 0x70006148): write 0x5a5a5a5a, 0xa5a5a5a5 and 0x5a5a5a5a << k (k=0..30)
 * ORed with the forced bits, read back, compare under the mask of
 * implemented bits. SS5 targets only. */
#include "macros.h"

#if defined(TARGET_SS5_QEMU)

/* mmu_walk(va %o0, mask %o1, orbits %o2, code base %o3): check_eq for
 * every pattern; code = base + pattern index. The context table pointer
 * and the other registers are restored by the caller. */
        .section .text
        .align 4
mmu_walk:
        save %sp, -96, %sp
        set 0x5a5a5a5a, %l0
        clr %l1                         /* pattern index */
        mov 0, %l3                      /* phase: 0 = 5a, 1 = a5, 2 = walk */
1:      or %l0, %i2, %l2                /* value written */
        sta %l2, [%i0] 0x04
        lda [%i0] 0x04, %l4
        and %l4, %i1, %o1               /* observed, masked */
        and %l0, %i1, %o2
        or %o2, %i2, %o2                /* expected */
        call check_eq
        add %i3, %l1, %o0
        add %l1, 1, %l1
        cmp %l3, 0
        bne 2f
        nop
        set 0xa5a5a5a5, %l0             /* phase 1 */
        ba 1b
        mov 1, %l3
2:      cmp %l3, 1
        bne 3f
        nop
        set 0x5a5a5a5a, %l0             /* phase 2 starts at k = 0 */
        ba 1b
        mov 2, %l3
3:      addcc %l0, %l0, %l0             /* next walking pattern */
        bne 1b
        nop
        ret
        restore

BEGIN(t_mmu_ctpr_ctx, "mmu: context table pointer and context registers")
        mov 0x100, %l0
        lda [%l0] 0x04, %l6             /* save CTPR */
        mov 0x200, %l1
        lda [%l1] 0x04, %l7             /* save CXR */
        mov 0x100, %o0
        set 0x00ffffc0, %o1
        mov 0, %o2
        call mmu_walk
        mov 0x100, %o3                  /* codes 0x100.. */
        mov 0x200, %o0
        mov 0xff, %o1
        mov 0, %o2
        call mmu_walk
        mov 0x200, %o3                  /* codes 0x200.. */
        sta %l6, [%l0] 0x04
        sta %l7, [%l1] 0x04
END

/* 0x1000 (TLB replacement control), 0x1300 / 0x1400 (writable diagnostic
 * aliases of SFSR / SFAR) are microSPARC-II registers. A core that decodes
 * only VA[11:8] maps them onto the PCR, SFSR and SFAR: probe for that
 * first, because a walking pattern with bit 0 set would turn the MMU on.
 * 0x500 / 0x600 are the sun4m AFSR / AFAR: no asynchronous fault is
 * pending (they read 0 on QEMU and on the core, and not as the PCR). */
BEGIN(t_mmu_swift_regs, "mmu: Swift TLB replacement control, SFSR/SFAR diag")
        lda [%g0] 0x04, %l6             /* PCR */
        set 0x1000, %l0
        lda [%l0] 0x04, %l5             /* save TLB replacement control */
        mov 0x40, %l1
        sta %l1, [%l0] 0x04
        lda [%g0] 0x04, %l2
        sta %l6, [%g0] 0x04             /* restore the PCR in any case */
        EXPECT_R(%l2, %l6, 1)           /* the PCR did not change */
        mov 0x500, %l0
        lda [%l0] 0x04, %l1
        EXPECT(%l1, 0, 2)               /* AFSR */
        mov 0x600, %l0
        lda [%l0] 0x04, %l1
        EXPECT(%l1, 0, 3)               /* AFAR */
        cmp %l2, %l6
        bne 9f                          /* aliased: do not walk */
        nop
        set 0x1000, %o0
        set 0x0011ffff, %o1
        mov 0x40, %o2
        call mmu_walk
        mov 0x100, %o3
        sta %l5, [%l0] 0x04
        set 0x1300, %o0
        set 0x00016fff, %o1
        mov 0, %o2
        call mmu_walk
        mov 0x200, %o3
        set 0x1400, %o0
        set 0xffffffff, %o1
        mov 0, %o2
        call mmu_walk
        mov 0x300, %o3
        mov 0x300, %l0                  /* clear the SFSR (read clears) */
        lda [%l0] 0x04, %g0
9:
END

#endif
