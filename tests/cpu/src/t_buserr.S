/* Bus errors (PLAN.md A3/B1; sun4m System Architecture 4.4.1-4.4.5 and
 * 6.4): a read the chipset answers with an error. On the SS20 an empty
 * SBus slot times out: slot 0 is pa 0xE_0000_0000 (OBP 2.25 cprobes slots
 * 0-3 and prints "Nothing there"; the POST's SBus time-out test reads pa
 * 0xe_0000_0010 and expects SFSR 0x816). The MMU turns the response into
 * data_access_error (tt 0x29) or instruction_access_error (tt 0x21) with
 * SFSR FT 5 (Access Bus Error), the TO bit (11), AT, FAV and the SFAR; a
 * table walk that reads the refused address is a Translation Error (FT 4,
 * L the level) and faults as one, tt 9. A store is posted and never traps
 * here: its error is the chipset's, reported asynchronously (AFSR/AFAR
 * and a level-15 interrupt, B1).
 *
 * Both tests SKIP while nothing on the machine reports bus errors (the
 * probe read comes back without a trap): the core before B1, the SS5
 * build, and QEMU, which traps unassigned accesses only with the MMU on
 * (then as tt 9, with no TO/BE bit and the physical address in the SFAR).
 *
 * AT follows the ASI's user/supervisor bit as the core derives it: a
 * bypass load through ASI 0x2e/0x20 reports AT 0 (user data), which is
 * the POST's 0x816; a supervisor load through a mapping AT 1 (0x836); an
 * ldstub is a store for the MMU (AT 4 through the bypass, 0x896). */
#include "macros.h"

#if defined(TARGET_SS20)
#  define BERR_PA       0x00000010      /* pa 0xe_0000_0010: SBus slot 0 */
#  define BERR_ASI      0x2e
#  define BERR_PTE      0xe000000e      /* PTE: pa 0xe_0000_0000, ACC 3, C 0 */
#  define BERR_PTD      0xe0000001      /* PTD: a table at pa 0xe_0000_0000 */
#else
#  define BERR_PA       0x7cc00010      /* the SS5 POST's SBus time-out address */
#  define BERR_ASI      0x20
#  define BERR_PTE      PTE(0x7cc00000, 0, 3)
#  define BERR_PTD      PTD(0x7cc00000)
#endif

/* berr_probe: a bypass load of BERR_PA with the trap catcher armed;
 * %o0 = 1 when it trapped tt 0x29, 0 when it came back. Clears the SFSR
 * before and after, leaves the catcher disarmed. Uses %o0-%o1 and %g1. */
berr_probe:
        mov 0x300, %o0
        lda [%o0] 4, %g0
        mov -1, %o0
        st %o0, [%g7 + V_TRAP_SEEN]
        set TT_DACC_ERR, %o0
        st %o0, [%g7 + V_TRAP_EXPECT]
        set BERR_PA, %o1
        lda [%o1] BERR_ASI, %g1
        ld [%g7 + V_TRAP_SEEN], %o1
        mov -1, %o0
        st %o0, [%g7 + V_TRAP_EXPECT]
        mov 0x300, %o0
        lda [%o0] 4, %g0                /* the probe's own record */
        cmp %o1, TT_DACC_ERR
        be,a 1f
        mov 1, %o0
        mov 0, %o0
1:      retl
        nop

BEGIN(t_buserr_load, "buserr: a bypass load of an empty SBus slot traps tt 0x29; SFSR TO/AT/FT 5/FAV and SFAR, read clears, ldstub, OW, NF; a store is posted")
        call berr_probe
        nop
        tst %o0
        bne 1f
        nop
        SKIP_TEST
1:      mov 0x300, %l6
        mov 0x400, %l7
        set BERR_PA, %l0
        set 0x5a5a1234, %l1
        EXPECT_TRAP(TT_DACC_ERR)
        lda [%l0] BERR_ASI, %l1
        CHECK_TRAPPED(TT_DACC_ERR, 1)
        EXPECT(%l1, 0x5a5a1234, 2)      /* the destination is unchanged */
        lda [%l6] 4, %l2
        EXPECT(%l2, 0x816, 3)           /* TO, AT 0, FT 5, FAV */
        lda [%l7] 4, %l2
        EXPECT_R(%l2, %l0, 4)           /* SFAR = the VA */
        lda [%l6] 4, %l2
        EXPECT(%l2, 0, 5)               /* the read cleared it */
        /* ldstub: its read half traps, as a store-type access */
        set 0x5a5a5678, %l1
        EXPECT_TRAP(TT_DACC_ERR)
        ldstuba [%l0] BERR_ASI, %l1
        CHECK_TRAPPED(TT_DACC_ERR, 6)
        EXPECT(%l1, 0x5a5a5678, 7)
        lda [%l6] 4, %l2
        EXPECT(%l2, 0x896, 8)           /* TO, AT 4, FT 5, FAV */
        /* two bus errors without a read in between: OW, SFAR the last */
        add %l0, 4, %l3
        EXPECT_TRAP(TT_DACC_ERR)
        lda [%l0] BERR_ASI, %l1
        CHECK_TRAPPED(TT_DACC_ERR, 9)
        EXPECT_TRAP(TT_DACC_ERR)
        lda [%l3] BERR_ASI, %l1
        CHECK_TRAPPED(TT_DACC_ERR, 10)
        lda [%l6] 4, %l2
        EXPECT(%l2, 0x817, 11)
        lda [%l7] 4, %l2
        EXPECT_R(%l2, %l3, 12)
        /* a byte load traps too */
        EXPECT_TRAP(TT_DACC_ERR)
        lduba [%l0] BERR_ASI, %l1
        CHECK_TRAPPED(TT_DACC_ERR, 13)
        lda [%l6] 4, %g0
        /* NF: recorded, not trapped */
        lda [%g0] 4, %l4
        or %l4, MCR_NF, %l5
        sta %l5, [%g0] 4
        EXPECT_TRAP(TT_DACC_ERR)
        lda [%l0] BERR_ASI, %l1
        CHECK_NOT_TRAPPED(14)
        sta %l4, [%g0] 4
        lda [%l6] 4, %l2
        EXPECT(%l2, 0x816, 15)
        /* a store to the slot is posted: no synchronous trap */
        EXPECT_TRAP(TT_DACC_ERR)
        sta %g0, [%l0] BERR_ASI
        CHECK_NOT_TRAPPED(16)
        lda [%l6] 4, %l2
        EXPECT(%l2, 0, 17)
END

/* MMU on: the slot behind a page of MT_SEG (MT_P_REMAP, uncacheable). A
 * load through it, a jump into it (the fetch's error traps when the IU
 * executes it; the SFSR records the first of the fetch unit's errors, with
 * no fault address), then the segment's level-3 table moved into the slot:
 * the walk's read is refused, a translation error at level 3. */
BEGIN(t_buserr_mapped, "buserr: through a mapping: load tt 0x29 (AT 1, SFAR), fetch tt 0x21 (FT 5, no FAV), a table in the slot: tt 9 with FT 4, L 3, TO")
        call berr_probe
        nop
        tst %o0
        bne 1f
        nop
        SKIP_TEST
1:      call mmu_tables_init
        nop
        STPAV(BERR_PTE, MT_L3 + MT_P_REMAP * 4)
        call mmu_on
        nop
        mov 0x300, %l6
        mov 0x400, %l7
        lda [%l6] 4, %g0
        set MT_PAGE(MT_P_REMAP) + 0x10, %l0
        set 0x5a5a1234, %l1
        EXPECT_TRAP(TT_DACC_ERR)
        ld [%l0], %l1
        CHECK_TRAPPED(TT_DACC_ERR, 1)
        EXPECT(%l1, 0x5a5a1234, 2)
        lda [%l6] 4, %l2
        EXPECT(%l2, 0x836, 3)           /* TO, AT 1, FT 5, FAV */
        lda [%l7] 4, %l2
        EXPECT_R(%l2, %l0, 4)
        /* a fetch from the slot */
        set MT_PAGE(MT_P_REMAP) + 0x20, %l0
        set 2f, %o0
        st %o0, [%g7 + V_TRAP_RESUME]
        EXPECT_TRAP(TT_IACC_ERR)
        jmpl %l0, %g0
        nop
2:      CHECK_TRAPPED(TT_IACC_ERR, 5)
        st %g0, [%g7 + V_TRAP_RESUME]
        ld [%g7 + V_TRAP_PC], %l1
        EXPECT_R(%l1, %l0, 6)
        lda [%l6] 4, %l2
        EXPECT(%l2, 0x874, 7)           /* TO, AT 3, FT 5, no FAV */
        lda [%l6] 4, %l2
        EXPECT(%l2, 0, 8)
        /* the level-3 table of MT_SEG in the slot: a walk reads it */
        STPAV(BERR_PTD, MT_L2 + MT_SEG_IDX * 4)
        set 0x400, %o0
        sta %g0, [%o0] 3                /* flush entire */
        set MT_PAGE(0) + 0x30, %l0
        set 0x5a5a1234, %l1
        EXPECT_TRAP(TT_DACC)
        ld [%l0], %l1
        CHECK_TRAPPED(TT_DACC, 9)
        EXPECT(%l1, 0x5a5a1234, 10)
        lda [%l6] 4, %l2
        EXPECT(%l2, 0xb32, 11)          /* TO, L 3, AT 1, FT 4, FAV */
        lda [%l7] 4, %l2
        EXPECT_R(%l2, %l0, 12)
        STPAV(PTD(MT_L3), MT_L2 + MT_SEG_IDX * 4)
        set 0x400, %o0
        sta %g0, [%o0] 3
        call mmu_off
        nop
END
