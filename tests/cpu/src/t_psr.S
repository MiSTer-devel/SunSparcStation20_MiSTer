/* Processor state registers: PSR impl/ver read-only, PIL writable, TBR
 * holds the last trap type, CWP. */
#include "macros.h"

BEGIN(t_psr_fields, "psr: impl/ver read-only, PIL and icc writable")
        rd %psr, %l0
        set 0xff000000, %l1
        xor %l0, %l1, %l2               /* flip impl/ver */
        wr %l2, %psr
        nop ; nop ; nop
        rd %psr, %l3
        EXPECT_R(%l3, %l0, 1)           /* impl/ver unchanged */
        andn %l0, PSR_PIL_MASK, %l2     /* PIL 15 -> 5 */
        or %l2, 0x500, %l2
        wr %l2, %psr
        nop ; nop ; nop
        rd %psr, %l3
        and %l3, PSR_PIL_MASK, %l4
        EXPECT(%l4, 0x500, 2)
        wr %l0, %psr                    /* PIL back to 15 */
        nop ; nop ; nop
        SET_ICC(0xa)
        GET_ICC(%l5)
        EXPECT(%l5, 0xa, 3)
END

BEGIN(t_tbr, "psr: TBR.tt holds the last trap type, TBA writable")
        EXPECT_TRAP(TT_TICC(0x33))
        ta 0x33
        CHECK_TRAPPED(TT_TICC(0x33), 1)
        rd %tbr, %l0
        and %l0, 0xfff, %l1
        EXPECT(%l1, (TT_TICC(0x33) << 4), 2)
        set trap_table, %l2
        andn %l0, 0xfff, %l3
        EXPECT_R(%l3, %l2, 3)
        or %l2, 0xff0, %l4              /* writes to tt are ignored */
        wr %l4, %tbr
        nop ; nop ; nop
        rd %tbr, %l5
        EXPECT_R(%l5, %l0, 4)
        wr %l2, %tbr
        nop ; nop ; nop
END
