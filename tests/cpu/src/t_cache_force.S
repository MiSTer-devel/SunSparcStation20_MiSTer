/* Main memory is cached even where the PTE says C = 0 (PLAN.md A4 item 5,
 * E3): the Sun OBP 2.25 maps everything it gives a client program
 * uncacheable on a module without an E-cache, so boot loaders ran uncached
 * (NetBSD's install CD 899 s to its installer). The SS20 MMU
 * sets C in a TLB entry whose page is in main memory (pa[35:32] = 0)
 * while snooping is on (MCNTL.SE), whatever the PTE's C bit. What keeps
 * that safe is checked too: the OSes keep their page tables uncached on
 * this module type, so with them cached the table walker's own R/M
 * writes must reach the CPU's cached copy of the PTE (the walk's write
 * invalidates the line through the snoop port), or an OS reads M = 0 for
 * a page it dirtied. The page tables of the suite are mapped cacheable
 * (mmu_setup.S), so that part holds on any configuration. */
#include "macros.h"

#if defined(TARGET_SS20)
BEGIN(t_cache_force, "cache: SS20 a C=0 page of main memory is cached; the walker's R/M writes reach the cached PTE")
        call mmu_tables_init
        nop
        STPAV(0x11110000, MT_PAGE(MT_P_NC) + 0x40)
        call mmu_on
        nop
        set MT_L3 + MT_P_NC * 4, %l6    /* the PTE, mapped cacheable */
        ld [%l6], %l3                   /* R = M = 0, now cached */
        set MT_PAGE(MT_P_NC) + 0x40, %l0
        ld [%l0], %l1                   /* the walk sets R; the page is cached */
        ld [%l6], %l4                   /* must see R: the line went */
        set 0x22220000, %o0
        sta %o0, [%l0] 0x20             /* memory changes behind the cache */
        ld [%l0], %l2                   /* 0x11110000: cached */
        set 0x33330000, %o0
        st %o0, [%l0]                   /* the walk sets M */
        ld [%l6], %l5                   /* must see R and M */
        lda [%l0] 0x20, %l7             /* memory: write-through, unless WB */
        ld [%g7 + V_WBMODE], %o1
        cmp %o1, 2
        bne 1f
        nop
        set 0x33330000, %l7             /* WB: the line is dirty, memory old */
1:      call mmu_off
        nop
        EXPECT(%l1, 0x11110000, 1)
        EXPECT(%l2, 0x11110000, 2)      /* cached although C = 0 */
        EXPECT(%l7, 0x33330000, 3)      /* write-through to memory */
        set PTE(MT_PAGE(MT_P_NC), 0, 3), %o3
        EXPECT_R(%l3, %o3, 4)
        or %o3, 0x20, %o3
        EXPECT_R(%l4, %o3, 5)           /* R set by the walk, seen through the cache */
        or %o3, 0x60, %o3
        EXPECT_R(%l5, %o3, 6)           /* M set by the walk, seen through the cache */
END
#else
BEGIN(t_cache_force, "cache: SS20 a C=0 page of main memory is cached; the walker's R/M writes reach the cached PTE")
        SKIP_TEST
END
#endif
