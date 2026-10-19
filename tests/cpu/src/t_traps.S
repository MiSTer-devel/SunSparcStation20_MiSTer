/* Synchronous traps: software traps, illegal/unimplemented instructions,
 * division by zero, tag overflow, rett in supervisor mode, FP disabled. */
#include "macros.h"

BEGIN(t_ticc_tt, "trap: ta n -> tt 0x80+n, trap PC/nPC, register+imm number")
        EXPECT_TRAP(TT_TICC(0x10))
1:      ta 0x10
        CHECK_TRAPPED(TT_TICC(0x10), 1)
        set 1b, %l0
        ld [%g7 + V_TRAP_PC], %l1
        EXPECT_R(%l1, %l0, 2)
        add %l0, 4, %l0
        ld [%g7 + V_TRAP_NPC], %l1
        EXPECT_R(%l1, %l0, 3)
        /* trap number = (rs1 + imm) & 0x7f */
        mov 0x75, %l2
        EXPECT_TRAP(TT_TICC(0x7f))
        ta %l2 + 0x0a
        CHECK_TRAPPED(TT_TICC(0x7f), 4)
        mov 0x81, %l2                   /* 0x81 & 0x7f = 1 */
        EXPECT_TRAP(TT_TICC(0x01))
        ta %l2
        CHECK_TRAPPED(TT_TICC(0x01), 5)
END

BEGIN(t_illegal, "trap: unimp and invalid opcodes -> illegal_instruction")
        EXPECT_TRAP(TT_ILLEGAL)
        unimp 0x1234
        CHECK_TRAPPED(TT_ILLEGAL, 1)
        /* op=2 op3=0x09 is not a V8 instruction (V9 mulx) */
        EXPECT_TRAP(TT_ILLEGAL)
        .word 0x82480000 | (1 << 25)
        CHECK_TRAPPED(TT_ILLEGAL, 2)
        /* op=3 op3=0x08 is unassigned */
        EXPECT_TRAP(TT_ILLEGAL)
        .word 0xc0400000 | (0x08 << 19)
        CHECK_TRAPPED(TT_ILLEGAL, 3)
END

BEGIN(t_rett_supervisor, "trap: rett with traps enabled -> illegal_instruction")
        /* the rett sits in the delay slot of a jmp: the trap's nPC must be
         * the jmp target (1f), not the rett's own target (1f + 4) */
        set 1f, %l0
        EXPECT_TRAP(TT_ILLEGAL)
        jmp %l0
        rett %l0 + 4
1:      nop                             /* harmless if skipped (QEMU) */
        /* If the rett executed instead of trapping, we are now one window
         * up (CWP+1) with ET=1: a save restores exactly this test's window
         * (its %sp was the caller's %sp - 96), so the suite can go on. */
        ld [%g7 + V_TRAP_SEEN], %g1
        cmp %g1, -1
        bne 2f
        nop
        save %sp, -96, %sp
2:      CHECK_TRAPPED(TT_ILLEGAL, 1)
        ld [%g7 + V_TRAP_NPC], %l1
        EXPECT_R(%l1, %l0, 2)
END

BEGIN(t_rett_user, "trap: rett in user mode -> privileged_instruction (0x03)")
        /* PSR.S = 0 with ET = 1. With the MMU off, user mode still reads and
         * writes everything; only privileged instructions and ASIs trap.
         * ta SVC_SUPER (runtime.S) brings the test back to supervisor mode. */
        EXPECT_TRAP(TT_PRIV)
        set 1f, %l2
        rd %psr, %l0
        andn %l0, PSR_S, %l1
        wr %l1, %psr
        nop ; nop ; nop
3:      rett %l2                        /* traps; PC = 3b, nPC = 1f */
1:      ta SVC_SUPER
        /* If the rett executed instead (a regression), CWP is one window
         * up: a save restores this test's window. */
        ld [%g7 + V_TRAP_SEEN], %g1
        cmp %g1, -1
        bne 2f
        nop
        save %sp, -96, %sp
2:      CHECK_TRAPPED(TT_PRIV, 1)
        set 3b, %l3
        ld [%g7 + V_TRAP_PC], %l1
        EXPECT_R(%l1, %l3, 2)
        ld [%g7 + V_TRAP_PSR], %l1      /* the trap came from user mode */
        and %l1, PSR_PS, %l1
        EXPECT(%l1, 0, 3)
        rd %psr, %l1                    /* and the test is back in S = 1 */
        and %l1, PSR_S, %l1
        EXPECT(%l1, PSR_S, 4)
END

BEGIN(t_div_zero, "trap: udiv/sdiv by zero -> division_by_zero (0x2a)")
        wr %g0, %y
        nop ; nop ; nop
        mov 5, %l0
        mov 0x77, %l1
        EXPECT_TRAP(TT_DIV_ZERO)
        udiv %l0, %g0, %l1
        CHECK_TRAPPED(TT_DIV_ZERO, 1)
        EXPECT(%l1, 0x77, 2)
        EXPECT_TRAP(TT_DIV_ZERO)
        sdivcc %l0, 0, %l1
        CHECK_TRAPPED(TT_DIV_ZERO, 3)
END

BEGIN(t_tag_overflow, "trap: taddcctv/tsubcctv -> tag_overflow (0x0a)")
        mov 1, %l0
        mov 4, %l1
        mov 0x55, %l2
        EXPECT_TRAP(TT_TAG_OVF)
        taddcctv %l0, %l1, %l2
        CHECK_TRAPPED(TT_TAG_OVF, 1)
        EXPECT(%l2, 0x55, 2)
        EXPECT_TRAP(TT_TAG_OVF)
        taddcctv %l1, %l1, %l2          /* tags clear, no overflow */
        CHECK_NOT_TRAPPED(3)
        EXPECT(%l2, 8, 4)
        set 0x7ffffffc, %l3             /* arithmetic overflow traps too */
        EXPECT_TRAP(TT_TAG_OVF)
        taddcctv %l3, %l1, %l2
        CHECK_TRAPPED(TT_TAG_OVF, 5)
        EXPECT_TRAP(TT_TAG_OVF)
        tsubcctv %l1, 2, %l2
        CHECK_TRAPPED(TT_TAG_OVF, 6)
END

BEGIN(t_fp_disabled, "trap: FPop with PSR.EF=0 -> fp_disabled (0x04)")
        rd %psr, %l0
        set PSR_EF, %l1
        andn %l0, %l1, %l2
        wr %l2, %psr
        nop ; nop ; nop
        EXPECT_TRAP(TT_FP_DISABLED)
        fmovs %f0, %f1
        CHECK_TRAPPED(TT_FP_DISABLED, 1)
        EXPECT_TRAP(TT_FP_DISABLED)
        ld [%g7], %f2
        CHECK_TRAPPED(TT_FP_DISABLED, 2)
        EXPECT_TRAP(TT_FP_DISABLED)
        fbne 1f
        nop
1:      CHECK_TRAPPED(TT_FP_DISABLED, 3)
        wr %l0, %psr                    /* restore EF */
        nop ; nop ; nop
END

BEGIN(t_cp_disabled, "trap: coprocessor ops -> cp_disabled (0x24)")
        EXPECT_TRAP(0x24)
        .word 0x81b00000                /* cpop1 */
        CHECK_TRAPPED(0x24, 1)
        EXPECT_TRAP(0x24)
        cb1 1f
        nop
1:      CHECK_TRAPPED(0x24, 2)
END
