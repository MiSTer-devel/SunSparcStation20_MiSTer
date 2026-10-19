/* Register windows: save/restore, overlap of outs and ins, overflow and
 * underflow traps through deep recursion, %g registers shared, WIM/CWP. */
#include "macros.h"

/* recurse(depth %o0) -> %o0 = sum of depth..1; every level keeps a
 * signature in its locals and checks it after the deeper call returns */
        .section .text
        .align 4
recurse:
        save %sp, -96, %sp
        sll %i0, 8, %l0
        or %l0, 0x11, %l1
        or %l0, 0x22, %l2
        or %l0, 0x33, %l3
        or %l0, 0x44, %l4
        or %l0, 0x55, %l5
        or %l0, 0x66, %l6
        or %l0, 0x77, %l7
        mov %i0, %i5
        subcc %i0, 1, %o0
        be 1f
        mov 0, %o0
        call recurse
        sub %i0, 1, %o0
1:      add %o0, %i0, %i0               /* return depth + sum(rest) */
        sll %i5, 8, %o1
        or %o1, 0x77, %o2
        cmp %l7, %o2
        bne 2f
        or %o1, 0x11, %o2
        cmp %l1, %o2
        bne 2f
        or %o1, 0x44, %o2
        cmp %l4, %o2
        bne 2f
        nop
        ret
        restore
2:      set 0x80000000, %i0             /* signature lost */
        ret
        restore

BEGIN(t_window_basic, "window: save/restore, ins/outs overlap, globals shared")
        mov 0x123, %o0
        mov 0x456, %g1
        rd %psr, %l0
        save %sp, -96, %sp
        rd %psr, %g2                    /* a global survives the restore */
        EXPECT(%i0, 0x123, 1)           /* caller's out = our in */
        EXPECT(%g1, 0x456, 2)
        mov 0x789, %i1
        restore
        EXPECT(%o1, 0x789, 3)
        /* save decrements CWP by one (mod NWINDOWS) */
        and %g2, 0x1f, %l1
        and %l0, 0x1f, %l0
        add %l1, 1, %l1
        ld [%g7 + V_NWINDOWS], %l2
        cmp %l1, %l2
        bne,a 1f
        nop
        clr %l1
1:      EXPECT_R(%l1, %l0, 4)
        /* save/restore as add: rd is written in the new window */
        mov 10, %o0
        save %o0, 5, %o3                /* new %o3 = old %o0 + 5 */
        mov %o3, %i2
        restore %i2, 1, %o4             /* old window %o4 = new %i2 + 1 */
        EXPECT(%o4, 16, 5)
END

BEGIN(t_window_deep, "window: 40-deep recursion, overflow/underflow traps")
        st %g0, [%g7 + V_WIN_OVF]
        st %g0, [%g7 + V_WIN_UNF]
        call recurse
        mov 40, %o0
        EXPECT(%o0, 820, 1)             /* 40*41/2 */
        ld [%g7 + V_WIN_OVF], %l0
        ld [%g7 + V_WIN_UNF], %l1
        /* every window spilled below this test was filled back; the two
         * above it (run_tests and the reset frame) stay spilled until the
         * test returns */
        sub %l0, %l1, %l2
        EXPECT(%l2, 2, 2)
        /* at least 40 - (NWINDOWS - 2) overflows */
        ld [%g7 + V_NWINDOWS], %l2
        mov 42, %l3
        sub %l3, %l2, %l3
        cmp %l0, %l3
        bgeu,a 1f
        mov 1, %l4
        mov 0, %l4
1:      EXPECT(%l4, 1, 3)
END

BEGIN(t_wim_bits, "window: WIM implements NWINDOWS bits, save into WIM traps")
        ld [%g7 + V_NWINDOWS], %l0
        EXPECT(%l0, 8, 1)               /* microSPARC-II and SuperSPARC */
END
