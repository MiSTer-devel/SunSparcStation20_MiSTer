/* Loads and stores: widths, sign extension, byte order, doublewords,
 * atomics, alternate space, alignment traps. */
#include "macros.h"

BEGIN(t_ld_widths, "ldst: byte/half/word loads, sign extension, big-endian")
        set SCRATCH, %l0
        set 0x8091a2b3, %l1
        st %l1, [%l0]
        ldub [%l0], %l2
        EXPECT(%l2, 0x80, 1)
        ldub [%l0 + 3], %l2
        EXPECT(%l2, 0xb3, 2)
        ldsb [%l0], %l2
        EXPECT(%l2, 0xffffff80, 3)
        ldsb [%l0 + 1], %l2
        EXPECT(%l2, 0xffffff91, 4)
        ldsb [%l0 + 3], %l2
        EXPECT(%l2, 0xffffffb3, 5)
        lduh [%l0], %l2
        EXPECT(%l2, 0x8091, 6)
        lduh [%l0 + 2], %l2
        EXPECT(%l2, 0xa2b3, 7)
        ldsh [%l0], %l2
        EXPECT(%l2, 0xffff8091, 8)
        set 0x7f017f02, %l1
        st %l1, [%l0]
        ldsb [%l0], %l2
        EXPECT(%l2, 0x7f, 9)
        ldsh [%l0 + 2], %l2
        EXPECT(%l2, 0x7f02, 10)
        ld [%l0], %l2
        EXPECT(%l2, 0x7f017f02, 11)
        /* register + register addressing */
        mov 2, %l3
        lduh [%l0 + %l3], %l2
        EXPECT(%l2, 0x7f02, 12)
END

BEGIN(t_st_widths, "ldst: byte/half stores merge into the word")
        set SCRATCH, %l0
        set 0x11223344, %l1
        st %l1, [%l0]
        mov 0xaa, %l2
        stb %l2, [%l0 + 1]
        ld [%l0], %l3
        EXPECT(%l3, 0x11aa3344, 1)
        set 0xbbcc, %l2
        sth %l2, [%l0 + 2]
        ld [%l0], %l3
        EXPECT(%l3, 0x11aabbcc, 2)
        set 0x123456dd, %l2             /* only the low byte is stored */
        stb %l2, [%l0]
        ld [%l0], %l3
        EXPECT(%l3, 0xddaabbcc, 3)
        clrh [%l0 + 2]
        ld [%l0], %l3
        EXPECT(%l3, 0xddaa0000, 4)
        clrb [%l0]
        ld [%l0], %l3
        EXPECT(%l3, 0x00aa0000, 5)
END

BEGIN(t_ldd_std, "ldst: ldd/std register pairs")
        set SCRATCH, %l0
        set 0x01234567, %l2
        set 0x89abcdef, %l3
        std %l2, [%l0 + 8]
        ld [%l0 + 8], %l4
        EXPECT(%l4, 0x01234567, 1)
        ld [%l0 + 12], %l4
        EXPECT(%l4, 0x89abcdef, 2)
        clr %l4
        clr %l5
        ldd [%l0 + 8], %l4
        EXPECT(%l4, 0x01234567, 3)
        EXPECT(%l5, 0x89abcdef, 4)
        /* ldd into %g0/%g1: %g0 stays zero, %g1 gets the odd word */
        mov 0, %g1
        ldd [%l0 + 8], %g0
        EXPECT(%g0, 0, 5)
        EXPECT(%g1, 0x89abcdef, 6)
END

BEGIN(t_atomics, "ldst: ldstub and swap")
        set SCRATCH, %l0
        set 0x12345678, %l1
        st %l1, [%l0]
        ldstub [%l0 + 1], %l2
        EXPECT(%l2, 0x34, 1)
        ld [%l0], %l3
        EXPECT(%l3, 0x12ff5678, 2)
        ldstub [%l0 + 1], %l2
        EXPECT(%l2, 0xff, 3)
        set 0xcafef00d, %l4
        swap [%l0], %l4
        EXPECT(%l4, 0x12ff5678, 4)
        ld [%l0], %l3
        EXPECT(%l3, 0xcafef00d, 5)
END

BEGIN(t_alt_space, "ldst: lda/sta with ASI 0xb (supervisor data) and bypass")
        set SCRATCH, %l0
        set 0x5a5aa5a5, %l1
        sta %l1, [%l0] 0x0b
        ld [%l0], %l2
        EXPECT(%l2, 0x5a5aa5a5, 1)
        set 0x0f1e2d3c, %l1
        st %l1, [%l0]
        lda [%l0] 0x0b, %l2
        EXPECT(%l2, 0x0f1e2d3c, 2)
        lduba [%l0] 0x0b, %l2
        EXPECT(%l2, 0x0f, 3)
        ldsha [%l0 + %g0] 0x0b, %l2
        EXPECT(%l2, 0x0f1e, 4)
#ifndef TARGET_SS20
        /* MMU bypass to the same physical RAM (pa[35:32] = 0) */
        lda [%l0] 0x20, %l2
        EXPECT(%l2, 0x0f1e2d3c, 5)
#endif
END

BEGIN(t_align_traps, "ldst: misaligned accesses trap (tt 0x07)")
        set SCRATCH, %l0
        set 0x0badf00d, %l1
        st %l1, [%l0]
        mov 0x77, %l2

        EXPECT_TRAP(TT_ALIGN)
        ld [%l0 + 2], %l2
        CHECK_TRAPPED(TT_ALIGN, 1)
        EXPECT(%l2, 0x77, 2)            /* destination not written */

        EXPECT_TRAP(TT_ALIGN)
        lduh [%l0 + 1], %l2
        CHECK_TRAPPED(TT_ALIGN, 3)

        EXPECT_TRAP(TT_ALIGN)
        ldd [%l0 + 4], %l2
        CHECK_TRAPPED(TT_ALIGN, 4)

        EXPECT_TRAP(TT_ALIGN)
        st %l1, [%l0 + 1]
        CHECK_TRAPPED(TT_ALIGN, 5)
        ld [%l0], %l3
        EXPECT(%l3, 0x0badf00d, 6)      /* memory not written */

        EXPECT_TRAP(TT_ALIGN)
        sth %l1, [%l0 + 3]
        CHECK_TRAPPED(TT_ALIGN, 7)

        EXPECT_TRAP(TT_ALIGN)
        std %l2, [%l0 + 4]
        CHECK_TRAPPED(TT_ALIGN, 8)

        EXPECT_TRAP(TT_ALIGN)
        swap [%l0 + 2], %l2
        CHECK_TRAPPED(TT_ALIGN, 9)

        /* the trap PC is the faulting instruction */
        EXPECT_TRAP(TT_ALIGN)
10:     ld [%l0 + 1], %l2
        set 10b, %l4
        ld [%g7 + V_TRAP_PC], %l5
        EXPECT_R(%l5, %l4, 10)
        mov -1, %o0
        st %o0, [%g7 + V_TRAP_EXPECT]

        /* aligned accesses of every width do not trap */
        EXPECT_TRAP(TT_ALIGN)
        ldub [%l0 + 3], %l2
        lduh [%l0 + 2], %l2
        ld [%l0], %l2
        ldd [%l0], %l2
        CHECK_NOT_TRAPPED(11)
END
