/* SRMMU tests on the shared page tables of mmu_setup.S: the SS20's 16-bit
 * context register and contexts above 255 (audit MMU-3), TLB flush
 * scopes, ASI 3 probes (MMU-5) and the synchronous fault registers
 * (MMU-8). References: SPARC V8 appendix H (probe table H-4, SFSR
 * fields), microSPARC-II User's Manual 5.5.2 (probe returns 0 on an
 * invalid or reserved entry) and 5.6.4 (OW rules), Sun-4M System
 * Architecture 4.4, the SS20 POST "MMU Context Table Reg" / "MMU Context
 * Register" tests (post-tests.md section 4) and QEMU target/sparc. */
#include "macros.h"

#if defined(TARGET_SS20)
/* Walking one over the context register (SuperSPARC: 16 bits, QEMU
 * mmu_cxr_mask 0xffff; the POST checks 12) and over CTPR bits 31:6 (POST
 * mask 0xfffffc00, QEMU 0xffffffc0; bits 5:0 are not checked). MMU off. */
BEGIN(t_mmu_ctx_bits, "mmu: SS20 context register has 16 bits, CTPR bits 31:6 stick")
        mov 0x200, %l0
        lda [%l0] 4, %l6                /* save CXR */
        mov 0x100, %l1
        lda [%l1] 4, %l7                /* save CTPR */
        mov 1, %l2
        clr %l3
1:      sta %l2, [%l0] 4
        lda [%l0] 4, %o1
        set 0xffff, %o2
        and %l2, %o2, %o2
        call check_eq
        add %l3, 0x100, %o0             /* codes 0x100 + bit */
        add %l3, 1, %l3
        cmp %l3, 32
        bl 1b
        sll %l2, 1, %l2
        set 0x5a5a5a5a, %l2
        sta %l2, [%l0] 4
        lda [%l0] 4, %l4
        EXPECT(%l4, 0x5a5a, 0x140)
        set 0xa5a5a5a5, %l2
        sta %l2, [%l0] 4
        lda [%l0] 4, %l4
        EXPECT(%l4, 0xa5a5, 0x141)
        mov 0x40, %l2
        mov 6, %l3
2:      sta %l2, [%l1] 4
        lda [%l1] 4, %o1
        set 0xffffffc0, %o2
        and %o1, %o2, %o1
        mov %l2, %o2
        call check_eq
        add %l3, 0x200, %o0             /* codes 0x200 + bit */
        add %l3, 1, %l3
        cmp %l3, 32
        bl 2b
        sll %l2, 1, %l2
        sta %l6, [%l0] 4
        sta %l7, [%l1] 4
END

/* mt_ctx_switch(ctx %o0): context register, TLB flush; leaf */
mt_ctx_switch:
        mov 0x200, %o1
        sta %o0, [%o1] 4
        mov 0x400, %o1
        retl
        sta %g0, [%o1] 3

/* Contexts 1, 0x101 and 0x8001 map MT_CTXVA to three pages; with an 8-bit
 * register 0x101 and 0x8001 alias context 1 (MMU-3). */
BEGIN(t_mmu_ctx_hi, "mmu: SS20 contexts 1, 0x101, 0x8001 translate the same VA differently")
        call mmu_tables_init
        nop
        STPAV(0xa0000001, MT_PAGE(MT_P_CTX0 + 0))
        STPAV(0xb0000101, MT_PAGE(MT_P_CTX0 + 1))
        STPAV(0xc0008001, MT_PAGE(MT_P_CTX0 + 2))
        call mmu_on
        nop
        set MT_CTXVA, %l0
        call mt_ctx_switch
        mov 1, %o0
        ld [%l0], %l1
        set 0x101, %o0
        call mt_ctx_switch
        nop
        ld [%l0], %l2
        set 0x8001, %o0
        call mt_ctx_switch
        nop
        ld [%l0], %l3
        call mt_ctx_switch
        mov 1, %o0
        ld [%l0], %l4
        call mmu_off                    /* back to context 0, MMU off */
        nop
        EXPECT(%l1, 0xa0000001, 1)
        EXPECT(%l2, 0xb0000101, 2)
        EXPECT(%l3, 0xc0008001, 3)
        EXPECT(%l4, 0xa0000001, 4)
END
#endif

/* The PTE of page MT_P_REMAP is changed in memory (normal stores, as an
 * OS does; the core's SS5 walker reads the tables through its D-cache, so
 * a bypass store would stay invisible) while the TLB holds its
 * translation: the old page is read until the flush that covers the
 * entry (page, then segment, region, context, entire). Pages 22-27 carry
 * markers; the D-cache line of the VA is flushed with each change (SS5:
 * virtually tagged cache). (A page flush of another page is not checked: QEMU, which maps
 * the segment-level entries as large pages, flushes its whole TLB on any
 * page flush inside their range.) */
/* The SS5's D-cache is virtually tagged (as the microSPARC-II's): a load
 * of the remapped VA would hit the old page's data without consulting the
 * TLB, so the line is flushed by VA after every change, as an OS does. */
#define SET_PTE(val, pa)  set val, %o4 ; set pa, %o5 ; st %o4, [%o5] ; \
        sta %g0, [%l0] 0x10
BEGIN(t_mmu_tlb_flush, "mmu: a changed PTE is seen after the matching ASI 3 flush, not before")
        call mmu_tables_init
        nop
        STPAV(0x7a000016, MT_PAGE(22))
        STPAV(0x7a000017, MT_PAGE(23))
        STPAV(0x7a000018, MT_PAGE(24))
        STPAV(0x7a000019, MT_PAGE(25))
        STPAV(0x7a00001a, MT_PAGE(26))
        STPAV(0x7a00001b, MT_PAGE(27))
        call mmu_on
        nop
        set MT_PAGE(MT_P_REMAP), %l0
        ld [%l0], %l1                   /* 22: the TLB now holds it */
        SET_PTE(PTE_C3(MT_PAGE(23)), MT_L3 + MT_P_REMAP * 4)
        ld [%l0], %l2                   /* still 22 */
        sta %g0, [%l0] 0x10             /* that load refilled the line: the
                                           SS5's D-cache is virtually
                                           tagged, so it would serve page
                                           22 after the remap */
        sta %g0, [%l0] 3                /* page flush (type 0) */
        ld [%l0], %l4                   /* 23 */
        SET_PTE(PTE_C3(MT_PAGE(24)), MT_L3 + MT_P_REMAP * 4)
        set MT_SEG | 0x100, %o0         /* segment */
        sta %g0, [%o0] 3
        ld [%l0], %l5                   /* 24 */
        SET_PTE(PTE_C3(MT_PAGE(25)), MT_L3 + MT_P_REMAP * 4)
        set 0x200, %o0                  /* region 0 */
        sta %g0, [%o0] 3
        ld [%l0], %l6                   /* 25 */
        SET_PTE(PTE_C3(MT_PAGE(26)), MT_L3 + MT_P_REMAP * 4)
        set 0x300, %o0                  /* context */
        sta %g0, [%o0] 3
        ld [%l0], %l7                   /* 26 */
        SET_PTE(PTE_C3(MT_PAGE(27)), MT_L3 + MT_P_REMAP * 4)
        set 0x400, %o0                  /* entire */
        sta %g0, [%o0] 3
        ld [%l0], %i0                   /* 27 */
        SET_PTE(PTE_C3(MT_PAGE(22)), MT_L3 + MT_P_REMAP * 4)
        call mmu_off
        nop
        EXPECT(%l1, 0x7a000016, 1)
        EXPECT(%l2, 0x7a000016, 2)
        EXPECT(%l4, 0x7a000017, 4)
        EXPECT(%l5, 0x7a000018, 5)
        EXPECT(%l6, 0x7a000019, 6)
        EXPECT(%l7, 0x7a00001a, 7)
        EXPECT(%i0, 0x7a00001b, 8)
END

/* ASI 3 probes walk the tables from CTPR/CTX, MMU off. R and M are set
 * beforehand in the entries probed, so the words are known constants.
 * A probe that finds an invalid or reserved entry, or a PTE above the
 * level asked for, returns 0 (manual 5.5.2; V8 H-4); the core returns the
 * raw word on the error paths (MMU-5). QEMU returns a PTE found above the
 * level asked for (check 10). */
#define PTE_RM(pa)  (PTE_C3(pa) | 0x60)
BEGIN(t_mmu_probe, "mmu: ASI 3 probes page/segment/region/context/entire; 0 on invalid, reserved")
        call mmu_tables_init
        nop
        STPAV(PTE_RM(MT_PAGE(0)), MT_L3)
        STPAV(PTE_RM(VARS & 0xfffc0000), MT_L2 + (VARS >> 18) * 4)
        call mmu_ctx_set
        nop
        set MT_PAGE(0), %l0
        lda [%l0] 3, %l1                /* page */
        EXPECT(%l1, PTE_RM(MT_PAGE(0)), 1)
        set MT_PAGE(0) | 0x100, %l0
        lda [%l0] 3, %l1                /* segment: the PTD to L3 */
        EXPECT(%l1, PTD(MT_L3), 2)
        set MT_SEG | 0x200, %l0
        lda [%l0] 3, %l1                /* region: the PTD to L2 */
        EXPECT(%l1, PTD(MT_L2), 3)
        set 0x300, %l0
        lda [%l0] 3, %l1                /* context: the PTD to L1 */
        EXPECT(%l1, PTD(MT_L1), 4)
        set MT_PAGE(0) | 0x400, %l0
        lda [%l0] 3, %l1                /* entire: the level-3 PTE */
        EXPECT(%l1, PTE_RM(MT_PAGE(0)), 5)
        set VARS | 0x400, %l0
        lda [%l0] 3, %l1                /* entire: a level-2 PTE */
        EXPECT(%l1, PTE_RM(VARS & 0xfffc0000), 6)
        set VARS | 0x100, %l0
        lda [%l0] 3, %l1                /* segment probe of the same */
        EXPECT(%l1, PTE_RM(VARS & 0xfffc0000), 7)
        set MT_PAGE(MT_P_INVALID), %l0
        lda [%l0] 3, %l1                /* invalid level-3 entry */
        EXPECT(%l1, 0, 8)
        set 0x80000000, %l0
        lda [%l0] 3, %l1                /* invalid level-1 entry */
        EXPECT(%l1, 0, 9)
        set MT_PAGE(MT_P_RESERVED), %l0
        lda [%l0] 3, %l1                /* reserved entry (ET 3) */
        EXPECT(%l1, 0, 10)
        set VARS, %l0
        lda [%l0] 3, %l1                /* page probe, PTE at level 2 */
        EXPECT(%l1, 0, 11)
END

/* SFSR = EBE[17:10] L[9:8] AT[7:5] FT[4:2] FAV[1] OW[0]; AT 1 = supervisor
 * data load, 5 = supervisor data store, 0 = user data load; FT 1 invalid,
 * 2 protection, 3 privilege, 4 translation. L is the level of the entry
 * that faulted, protection and privilege faults included (MMU-8). SFAR =
 * the fault VA (compared per page: QEMU records the page address). OW is
 * set when a data fault overwrites an unread data fault (manual table 28).
 * NF: a supervisor data fault is recorded but not trapped. */
BEGIN(t_mmu_fault_regs, "mmu: SFSR L/AT/FT/FAV/OW and SFAR on invalid, reserved, protection, privilege faults; NF")
        call mmu_tables_init
        nop
        call mmu_on
        nop
        mov 0x300, %l6
        mov 0x400, %l7
        lda [%l6] 4, %g0                /* clear */
        /* invalid level-3 entry */
        set MT_PAGE(MT_P_INVALID), %l0
        EXPECT_TRAP(TT_DACC)
        ld [%l0], %l1
        CHECK_TRAPPED(TT_DACC, 1)
        lda [%l6] 4, %l1
        EXPECT(%l1, 0x326, 2)
        lda [%l7] 4, %l1
        set 0xfffff000, %l2
        and %l1, %l2, %l1
        EXPECT(%l1, MT_PAGE(MT_P_INVALID), 3)
        lda [%l6] 4, %l1
        EXPECT(%l1, 0, 4)               /* read clears */
        /* invalid level-1 entry */
        set 0x80000000, %l0
        EXPECT_TRAP(TT_DACC)
        ld [%l0], %l1
        CHECK_TRAPPED(TT_DACC, 5)
        lda [%l6] 4, %l1
        EXPECT(%l1, 0x126, 6)
        lda [%l7] 4, %l1
        and %l1, %l2, %l1
        EXPECT(%l1, 0x80000000, 7)
        /* reserved entry: translation error */
        set MT_PAGE(MT_P_RESERVED), %l0
        EXPECT_TRAP(TT_DACC)
        ld [%l0], %l1
        CHECK_TRAPPED(TT_DACC, 8)
        lda [%l6] 4, %l1
        EXPECT(%l1, 0x332, 9)
        /* protection: a store to a read-only page */
        set MT_PAGE(MT_P_RDONLY), %l0
        EXPECT_TRAP(TT_DACC)
        st %g0, [%l0]
        CHECK_TRAPPED(TT_DACC, 10)
        lda [%l6] 4, %l1
        EXPECT(%l1, 0x3aa, 11)
        /* privilege: a user load from a supervisor-only page; ta SVC_SUPER
         * brings the test back to supervisor mode */
        set MT_PAGE(MT_P_SUPER), %l0
        EXPECT_TRAP(TT_DACC)
        rd %psr, %l3
        andn %l3, PSR_S, %l4
        wr %l4, %psr
        nop ; nop ; nop
        ld [%l0], %l1
        ta SVC_SUPER
        CHECK_TRAPPED(TT_DACC, 12)
        lda [%l6] 4, %l1
        EXPECT(%l1, 0x30e, 13)
        /* two data faults without a read in between: OW */
        set MT_PAGE(MT_P_INVALID), %l0
        EXPECT_TRAP(TT_DACC)
        ld [%l0], %l1
        CHECK_TRAPPED(TT_DACC, 14)
        EXPECT_TRAP(TT_DACC)
        ld [%l0], %l1
        CHECK_TRAPPED(TT_DACC, 15)
        lda [%l6] 4, %l1
        EXPECT(%l1, 0x327, 16)
        /* NF: recorded, not trapped */
        lda [%g0] 4, %l3
        or %l3, MCR_NF, %l4
        sta %l4, [%g0] 4
        EXPECT_TRAP(TT_DACC)
        ld [%l0], %l1
        CHECK_NOT_TRAPPED(17)
        lda [%l6] 4, %l1
        andn %l1, 1, %l1                /* OW: QEMU reports it twice */
        EXPECT(%l1, 0x326, 18)
        sta %l3, [%g0] 4
        call mmu_off
        nop
END

/* One instruction access fault sets the SFSR once: FT 1 (invalid), L 3,
 * AT 3 (supervisor instruction), FAV, and no OW. The jump lands mid-page
 * in the invalid page, so the fetch unit's next fetch (the same page)
 * faults too; a core that records that second fault sets OW, and Solaris
 * 8 (sun4m get_fault_type) then takes the status as overwritten, never
 * pages the text in and loops on the fault (seen on the board,
 * 2026-10-01: SFSR 0x347 for a user text fault). The trap returns to 1:
 * through V_TRAP_RESUME. */
BEGIN(t_mmu_ifault, "mmu: an instruction access fault sets the SFSR once (FAV, no OW)")
        call mmu_tables_init
        nop
        call mmu_on
        nop
        mov 0x300, %l6
        lda [%l6] 4, %g0                /* clear */
        set MT_PAGE(MT_P_INVALID) + 0x8b8, %l0
        set 1f, %o0
        st %o0, [%g7 + V_TRAP_RESUME]
        EXPECT_TRAP(TT_IACC)
        jmpl %l0, %g0
        nop
1:      CHECK_TRAPPED(TT_IACC, 1)
        ld [%g7 + V_TRAP_PC], %l1
        EXPECT_R(%l1, %l0, 2)
        lda [%l6] 4, %l1
        EXPECT(%l1, 0x366, 3)
        lda [%l6] 4, %l1
        EXPECT(%l1, 0, 4)               /* read clears */
        st %g0, [%g7 + V_TRAP_RESUME]
        call mmu_off
        nop
END

/* An annulled delay slot whose fetch faults takes no trap (V8: it is not
 * executed); the next instruction's fetch, on the same unmapped page, must
 * then fault and trap. The IU held all fetches after a faulted one until
 * its trap, and the annulled slot never trapped: the pipe drained and the
 * machine froze for good — no instruction, so no interrupt either
 * (Solaris at Xsun's first client, 2026-10-12). Here: an untaken bne,a in
 * the last word of page MT_P_INVALID - 1, its slot the first word of the
 * invalid page; the trap must come at the slot + 4. */
BEGIN(t_mmu_annul_ifault, "mmu: an annulled delay slot on an unmapped page takes no trap; the next fetch does (no hang)")
        call mmu_tables_init
        nop
        call mmu_on
        nop
        mov 0x300, %l6
        lda [%l6] 4, %g0                /* clear the SFSR */
        set MT_PAGE(MT_P_INVALID) - 8, %l0
        set 0x80a00000, %o0             /* cmp %g0, %g0 (Z = 1) */
        st %o0, [%l0]
        set 0x32800002, %o0             /* bne,a .+8: not taken, slot annulled */
        st %o0, [%l0 + 4]
        flush %l0
        flush %l0 + 4
        set 1f, %o0
        st %o0, [%g7 + V_TRAP_RESUME]
        EXPECT_TRAP(TT_IACC)
        jmpl %l0, %g0
        nop
1:      CHECK_TRAPPED(TT_IACC, 1)
        ld [%g7 + V_TRAP_PC], %l1
        set MT_PAGE(MT_P_INVALID) + 4, %l2
        EXPECT_R(%l1, %l2, 2)           /* the slot + 4, not the slot */
        st %g0, [%g7 + V_TRAP_RESUME]
        lda [%l6] 4, %g0
        call mmu_off
        nop
END

/* A store to a page whose TLB entry has M = 0 (the page was only read so
 * far): the walk sets M in the PTE and the entry is updated in place — one
 * entry for the page, not two. The SRMMU inserted the walk's result into a
 * fresh slot and left the stale M = 0 entry matching first; every hit kept
 * it in use, so each store walked again forever (NetBSD hung at init, its
 * first store to a page it had only read, 2026-10-11). Here the stores must
 * complete, M must be set in memory, and the ASI 6 image must hold exactly
 * one valid entry for the page. */
#define MW_PAGE         56
#define MW_VA           MT_PAGE(MW_PAGE)

BEGIN(t_mmu_store_m, "mmu: a store after a load to a page sets M in the PTE and updates the one TLB entry (no duplicate, no endless walk)")
        call mmu_tables_init
        nop
        call mmu_on                     /* flushes the TLB */
        nop
        set MW_VA, %l0
        clr %l4
        ld [%l0], %g0                   /* the entry: R set, M clear */
        set 0x1234abcd, %o0
        st %o0, [%l0]                   /* M = 0 in the entry: walk, set M */
        st %o0, [%l0 + 4]
        ld [%l0], %l1
        /* count the valid entries of the page in the ASI 6 image */
        clr %l2
        mov 0, %o1
1:      sll %o1, 12, %o2
        lda [%o2] 6, %o3                /* SEL0: the tag */
        cmp %o3, %l0
        bne 2f
        or %o2, 0x200, %o2
        lda [%o2] 6, %o3                /* SEL2: {ppn, c, m, v, acc, lvl} */
        andcc %o3, 0x20, %g0            /* V */
        be 2f
        nop
        add %l2, 1, %l2
        and %o3, 0x40, %l4              /* the entry's M */
2:      add %o1, 1, %o1
        cmp %o1, 64
        bl 1b
        nop
        call mmu_off
        nop
        set MT_L3 + MW_PAGE * 4, %o0
        lda [%o0] 0x20, %l3             /* the PTE in memory */
        and %l3, 0x60, %l3              /* R | M */
        EXPECT(%l1, 0x1234abcd, 1)
        EXPECT(%l2, 1, 2)
        EXPECT(%l3, 0x60, 3)
        EXPECT(%l4, 0x40, 4)            /* the one entry has M */
        END

/* A trap in W must not let the access of the instruction behind it start.
 * wo_rec recurses deeper than the register windows; every level does a
 * SAVE immediately followed by a load from a page not yet in the TLB (the
 * TLB is flushed first), so window-overflow traps meet loads that need a
 * table walk. The IU presented the load while the SAVE trapped (two
 * cycles in W); the walk ran on, and its answer was delivered to the
 * overflow handler's first spill store — a spill lost, or, for a fault,
 * a data access exception with ET = 0 (NetBSD at init, 2026-10-11). The
 * sum of the loaded words and the depths must come out right. Runs from
 * cached RAM so that the load issues right behind the SAVE. */

/* wo_rec(n %o0, page %o1) -> %o0 = sum over the levels of
 * (word at the level's page + its n); each level uses the next page */
wo_rec:
        save %sp, -96, %sp
        ld [%i1], %l0                   /* right behind the SAVE: a walk */
        add %l0, %i0, %l0               /* word + n */
        subcc %i0, 1, %o0               /* n - 1 */
        bl 1f                           /* n == 0: the leaf */
        mov %l0, %i0
        set 0x1000, %o3
        call wo_rec                     /* PC-relative: works in the copy */
        add %i1, %o3, %o1
        add %l0, %o0, %i0
1:      ret
        restore
wo_rec_end:

/* wo_frec(n %o0, va %o1): the same shape, but the load behind the SAVE
 * faults (an invalid page): each level arms the trap catcher for tt 9
 * first; the catcher records the fault and skips the load */
wo_frec:
        mov TT_DACC, %g1
        st %g1, [%g7 + V_TRAP_EXPECT]
        save %sp, -96, %sp
        ld [%i1], %l0                   /* right behind the SAVE: walks, faults */
        subcc %i0, 1, %o0
        bl 1f
        nop
        call wo_frec
        mov %i1, %o1
1:      ret
        restore
wo_frec_end:

#define WO_DEPTH        12              /* > NWINDOWS */
#define WO_RAM          MT_PAGE(53)
#define WO_PAGES        MT_PAGE(0)      /* pages 0-12: identity, cacheable */

BEGIN(t_mmu_trap_squash, "mmu: a window trap in W squashes the walk of the load behind the SAVE before it starts (deep recursion, cold TLB)")
        call mmu_tables_init
        nop
        /* the word at each page: 0x100 * (page index + 1), through the bypass */
        set WO_PAGES, %l0
        mov 0, %l1
1:      add %l1, 1, %o0
        sll %o0, 8, %o0
        sta %o0, [%l0] 0x20
        set 0x1000, %o1
        add %l0, %o1, %l0
        cmp %l1, WO_DEPTH
        bl 1b
        add %l1, 1, %l1
        call mmu_on
        nop
        set wo_rec, %l0
        set wo_rec_end, %l1
        set WO_RAM, %l2
2:      ld [%l0], %o0
        st %o0, [%l2]
        add %l0, 4, %l0
        cmp %l0, %l1
        blu 2b
        add %l2, 4, %l2
        /* the copied code's call is PC-relative within the copy */
        set WO_RAM, %l5
        mov 2, %o0                      /* fill the I-cache (shallow) */
        set WO_PAGES, %o1
        jmpl %l5, %o7
        nop
        mov 0x400, %o0                  /* flush the TLB: every page cold */
        sta %g0, [%o0] 0x03
        mov WO_DEPTH, %o0
        set WO_PAGES, %o1
        jmpl %l5, %o7
        nop
        mov %o0, %l6
        /* the faulting recursion, from RAM as well */
        set wo_frec, %l0
        set wo_frec_end, %l1
        set WO_RAM + 0x400, %l2
3:      ld [%l0], %o0
        st %o0, [%l2]
        add %l0, 4, %l0
        cmp %l0, %l1
        blu 3b
        add %l2, 4, %l2
        set WO_RAM + 0x400, %l5
        mov 2, %o0                      /* warm the I-cache: a valid page, no fault */
        set WO_PAGES, %o1
        jmpl %l5, %o7
        nop
        st %g0, [%g7 + V_TRAPS]
        mov -1, %o0
        st %o0, [%g7 + V_TRAP_SEEN]
        mov 0x400, %o0
        sta %g0, [%o0] 0x03             /* cold TLB */
        mov WO_DEPTH, %o0
        set MT_PAGE(MT_P_INVALID), %o1
        jmpl %l5, %o7
        nop
        mov -1, %o0
        st %o0, [%g7 + V_TRAP_EXPECT]
        ld [%g7 + V_TRAPS], %l4         /* one fault a level */
        ld [%g7 + V_TRAP_SEEN], %l3
        mov 0x300, %o0
        lda [%o0] 4, %g0                /* clear the SFSR */
        call mmu_off
        nop
        EXPECT(%l3, TT_DACC, 2)
        EXPECT(%l4, WO_DEPTH + 1, 3)
        /* sum over k = 0..DEPTH of (0x100*(k+1) + (DEPTH-k)) */
        set ((WO_DEPTH + 1) * (WO_DEPTH + 2) / 2) * 0x100 + (WO_DEPTH * (WO_DEPTH + 1) / 2), %l7
        EXPECT_R(%l6, %l7, 1)
        END
