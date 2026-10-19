/* SuperSPARC cache tests on the shared MMU-on setup (mmu_setup.S): flash
 * clear (audit C-2), write hits and the write policy (from the SS20 POST's
 * "D-Cache Write Hit Special Test", post-tests.md section 3), a line flush
 * after a DTLB miss (C-3) and self-modifying code with FLUSH. */
#include "macros.h"

#if defined(TARGET_SS20)
/* A line is cached, then its memory changes behind the cache's back (a
 * bypass store, then a normal store with DE off); after a flash clear the
 * cached load must see the new value. Same for the I-cache with a patched
 * routine. STP1021UG A.5/A.6: software initialises the caches by resetting
 * the valid bits with a flash clear; OBP 2.25 obp_cache_init does so. */
BEGIN(t_flash_clear, "cache: SS20 flash clear (ASI 0x36/0x37) drops stale lines")
        call mmu_tables_init
        nop
        STPAV(0x11110000, MT_PAGE(0) + 0x100)
        STPAV(0x90102001, MT_PAGE(1))          /* mov 1, %o0 */
        STPAV(0x81c3e008, MT_PAGE(1) + 4)      /* retl */
        STPAV(0x01000000, MT_PAGE(1) + 8)      /* nop */
        call mmu_on
        nop
        set MT_PAGE(0) + 0x100, %l0
        ld [%l0], %l1                   /* cached */
        lda [%g0] 4, %l5
        set MCR_DE, %l4
        andn %l5, %l4, %o0
        sta %o0, [%g0] 4                /* D-cache off */
        set 0x22220000, %o0
        sta %o0, [%l0] 0x20             /* memory changes */
        sta %g0, [%g0] 0x37             /* flash clear D */
        sta %l5, [%g0] 4                /* D-cache on */
        ld [%l0], %l2
        ld [%l0], %o0                   /* cached again */
        andn %l5, %l4, %o0
        sta %o0, [%g0] 4
        set 0x33330000, %o0
        st %o0, [%l0]                   /* normal store, cache off */
        sta %g0, [%g0] 0x37
        sta %l5, [%g0] 4
        ld [%l0], %l3
        /* I-cache: run the routine, patch it with the cache off */
        set MT_PAGE(1), %l4
        call %l4
        nop
        mov %o0, %l6
        set MCR_IE, %o1
        andn %l5, %o1, %o0
        sta %o0, [%g0] 4                /* I-cache off */
        set 0x90102002, %o0             /* mov 2, %o0 */
        sta %o0, [%l4] 0x20
        sta %g0, [%g0] 0x36             /* flash clear I */
        sta %l5, [%g0] 4
        call %l4
        nop
        mov %o0, %l7
        call mmu_off
        nop
        EXPECT(%l1, 0x11110000, 1)
        EXPECT(%l2, 0x22220000, 2)
        EXPECT(%l3, 0x33330000, 3)
        EXPECT(%l6, 1, 4)
        EXPECT(%l7, 2, 5)
END

/* 16 KB (the whole D-cache) is filled by loads, every word is stored
 * (write hits), read back cached (new values) and through ASI 0x20: all
 * old = write-back (the POST's MB = 1 expectation), all new =
 * write-through (the core unless its WB option is on). The mode is
 * printed and kept in V_WBMODE; after a flush of every line memory holds
 * the new values in both modes. */
BEGIN(t_cache_wrhit, "cache: SS20 write hits: cached reads see the stores, memory shows the write policy")
        call mmu_tables_init
        nop
        call mmu_on
        nop
        set MT_PAGE(0), %l0
        set 0x4000, %i3                 /* the block size (no 13-bit immediate) */
        clr %l1
1:      add %l0, %l1, %o0
        sta %l1, [%o0] 0x20             /* mem[o] = o */
        add %l1, 4, %l1
        cmp %l1, %i3
        bl 1b
        nop
        clr %l1
2:      ld [%l0 + %l1], %o0             /* fill */
        add %l1, 4, %l1
        cmp %l1, %i3
        bl 2b
        nop
        set 0x80000000, %l2
        clr %l1
3:      or %l1, %l2, %o0
        st %o0, [%l0 + %l1]             /* write hits */
        add %l1, 4, %l1
        cmp %l1, %i3
        bl 3b
        nop
        clr %l3                         /* cached mismatches */
        clr %l1
4:      ld [%l0 + %l1], %o0
        or %l1, %l2, %o1
        cmp %o0, %o1
        be 5f
        nop
        add %l3, 1, %l3
5:      add %l1, 4, %l1
        cmp %l1, %i3
        bl 4b
        nop
        clr %l4                         /* memory: old */
        clr %l5                         /* memory: new */
        clr %l1
6:      add %l0, %l1, %o0
        lda [%o0] 0x20, %o0
        cmp %o0, %l1
        bne 7f
        nop
        ba 8f
        add %l4, 1, %l4
7:      or %l1, %l2, %o1
        cmp %o0, %o1
        bne 8f
        nop
        add %l5, 1, %l5
8:      add %l1, 4, %l1
        cmp %l1, %i3
        bl 6b
        nop
        mov %l0, %o0
        set 0x4000, %o1
        call mmu_flush_lines
        nop
        clr %l6                         /* memory after the flush: new */
        clr %l1
9:      add %l0, %l1, %o0
        lda [%o0] 0x20, %o0
        or %l1, %l2, %o1
        cmp %o0, %o1
        bne 10f
        nop
        add %l6, 1, %l6
10:     add %l1, 4, %l1
        cmp %l1, %i3
        bl 9b
        nop
        call mmu_off
        nop
        set 0x1000, %l7
        cmp %l5, %l7
        be 11f
        mov 1, %o1
        cmp %l4, %l7
        be 11f
        mov 2, %o1
        mov 0, %o1
11:     st %o1, [%g7 + V_WBMODE]
        set s_wbmode, %o0
        call puts
        nop
        ld [%g7 + V_WBMODE], %o0
        sll %o0, 2, %o0
        set s_wbmodes, %o1
        ld [%o1 + %o0], %o0
        call puts
        nop
        set s_nl, %o0
        call puts
        nop
        EXPECT(%l3, 0, 1)
        add %l4, %l5, %o1
        EXPECT(%o1, 0x1000, 2)
        EXPECT(%l6, 0x1000, 3)
END

        .section .rodata
        .align 4
s_wbmode: .asciz "    dcache mode: "
        .align 4
s_wbmodes: .word s_wbm0, s_wbm1, s_wbm2
s_wbm0: .asciz "mixed"
s_wbm1: .asciz "write-through"
s_wbm2: .asciz "write-back"
        .section .text
        .align 4

/* A line is cached through the alias VA (PA != VA): in write-back mode
 * it is dirtied, in write-through mode memory is changed behind it; its
 * DTLB entry is evicted by six other segments, then the line is flushed
 * by VA (ASI 0x10): memory must hold the new value (write-back) and a
 * cached load must see it (both). A flush that took PA = VA on the DTLB
 * miss (C-3) would miss the line. */
BEGIN(t_cache_flush_miss, "cache: SS20 line flush after a DTLB miss reaches the line")
        call mmu_tables_init
        nop
        STPAV(0x51510000, MT_PAGE(5) + 0x80)
        call mmu_on
        nop
        set MT_ALIAS + MT_PAGE(5) + 0x80, %l1
        ld [%l1], %l2
        ld [%g7 + V_WBMODE], %l0
        cmp %l0, 2
        bne 2f
        nop
        set 0x52520000, %o0
        st %o0, [%l1]                   /* write-back: dirty */
        ba 3f
        nop
2:      set 0x52520000, %o0             /* write-through: memory changes */
        set MT_PAGE(5) + 0x80, %o1
        sta %o0, [%o1] 0x20
3:      set 0x000000, %o0
        ld [%o0], %g0
        set 0x040000, %o0
        ld [%o0], %g0
        set 0x080000, %o0
        ld [%o0], %g0
        set 0x0c0000, %o0
        ld [%o0], %g0
        set 0x100000, %o0
        ld [%o0], %g0
        set 0x140000, %o0
        ld [%o0], %g0
        sta %g0, [%l1] 0x10             /* flush the line, by VA */
        set MT_PAGE(5) + 0x80, %o0
        lda [%o0] 0x20, %l3             /* memory */
        ld [%l1], %l4                   /* cached, after the flush */
        call mmu_off
        nop
        EXPECT(%l2, 0x51510000, 1)
        EXPECT(%l3, 0x52520000, 2)
        EXPECT(%l4, 0x52520000, 3)
END
#endif

/* ldstub and swap on a cached line, one CPU: the old value comes back,
 * only the addressed byte / word changes (checked through the bypass and
 * through cached loads), neighbours are intact. Separates a cache
 * data-path fault from an SMP race in t_smp_atomic. */
BEGIN(t_cache_atomic, "cache: ldstub and swap on a cached line change only their byte / word")
        call mmu_tables_init
        nop
        STPAV(0x11111111, MT_PAGE(9) + 0x40)
        STPAV(0x22222222, MT_PAGE(9) + 0x44)
        STPAV(0x33333333, MT_PAGE(9) + 0x48)
        STPAV(0x44444444, MT_PAGE(9) + 0x4c)
        call mmu_on
        nop
        set MT_PAGE(9) + 0x40, %l0
        ld [%l0], %g0                   /* cache the line */
        add %l0, 4, %l1
        ldstub [%l1], %l2               /* 0x22, then 0xff222222 */
        ld [%l0], %l3
        ld [%l1], %l4
        add %l0, 8, %l1
        set 0x55555555, %l5
        swap [%l1], %l5                 /* 0x33333333, then 0x55555555 */
        ld [%l1], %l6
        add %l0, 0xc, %l1
        ld [%l1], %l7
        lda [%l0] 0x20, %i0             /* memory (write-through) or the */
        add %l0, 4, %l1                 /* line after the flush below */
        lda [%l1] 0x20, %i1
        sta %g0, [%l0] 0x10             /* flush the line */
        lda [%l1] 0x20, %i2
        add %l0, 8, %l1
        lda [%l1] 0x20, %i3
        call mmu_off
        nop
        EXPECT(%l2, 0x22, 1)
        EXPECT(%l3, 0x11111111, 2)
        EXPECT(%l4, 0xff222222, 3)
        EXPECT(%l5, 0x33333333, 4)
        EXPECT(%l6, 0x55555555, 5)
        EXPECT(%l7, 0x44444444, 6)
        EXPECT(%i0, 0x11111111, 7)
        EXPECT(%i2, 0xff222222, 8)
        EXPECT(%i3, 0x55555555, 9)
END

/* A store, then an atomic on the same cached line, 512 times: the store
 * must stay. A: st word 0, ldstub byte 5; B: st word 0, swap word 2;
 * C: a lock in byte 12 taken with ldstub, word 1 stored, the lock
 * released with stb: the next ldstub must find it free. An atomic that
 * wrote the line back from a copy older than the store would undo it.
 * (Solaris 8 on the SS20, one CPU running: "recursive mutex_enter" on a
 * lock its owner had released, 2026-10-02.) */
BEGIN(t_cache_st_atomic, "cache: a store then ldstub/swap on the same line keeps the store")
        call mmu_tables_init
        nop
        set MT_PAGE(9) + 0x80, %l0
        clr %o0
1:      sta %g0, [%l0 + %o0] 0x20
        add %o0, 4, %o0
        cmp %o0, 32
        bl 1b
        nop
        call mmu_on
        nop
        ld [%l0], %g0                   /* cache the line */
        mov 1, %l1                      /* i */
        clr %l2                         /* A mismatches */
        clr %l3                         /* B mismatches */
        clr %l4                         /* C: lock found taken */
2:      st %l1, [%l0]                   /* A */
        ldstub [%l0 + 5], %o0
        stb %g0, [%l0 + 5]
        ld [%l0], %o1
        cmp %o1, %l1
        bne,a 3f
        add %l2, 1, %l2
3:      st %l1, [%l0]                   /* B */
        mov %l1, %o2
        swap [%l0 + 8], %o2
        ld [%l0], %o1
        cmp %o1, %l1
        bne,a 4f
        add %l3, 1, %l3
4:      ldstub [%l0 + 12], %o0          /* C: acquire */
        tst %o0
        bne,a 5f
        add %l4, 1, %l4
5:      st %l1, [%l0 + 4]
        stb %g0, [%l0 + 12]             /* release */
        add %l1, 1, %l1
        cmp %l1, 513
        bl 2b
        nop
        sta %g0, [%l0] 0x10             /* flush the line */
        lda [%l0] 0x20, %i0
        add %l0, 4, %o0
        lda [%o0] 0x20, %i1
        add %l0, 12, %o0
        lda [%o0] 0x20, %i2
        call mmu_off
        nop
        EXPECT(%l2, 0, 1)
        EXPECT(%l3, 0, 2)
        EXPECT(%l4, 0, 3)
        EXPECT(%i0, 512, 4)
        EXPECT(%i1, 512, 5)
        srl %i2, 24, %i2
        EXPECT(%i2, 0, 6)
END

#if defined(TARGET_SS20)
/* 32 lines of 8 distinct words each; an ldstub on every line brings it
 * into the cache modified (FILLMOD) and a line flush writes it back. The
 * memory image must match word for word: every write-back burst has to
 * reach the DDR intact. The DDR arbiter stalls write beats at will (video
 * has priority), and a stalled odd beat once overwrote the even word of
 * its 64-bit pair in a bus-to-Avalon bridge: the lock byte of a line
 * landed on its neighbour (t_smp_atomic's 0xff000000 counter). Code of a
 * failing check = the word's byte offset in the page. */
#define WB_LINES        32
#define WB_PAGE         MT_PAGE(12)
BEGIN(t_cache_wback_burst, "cache: SS20 write-backs of 32 modified lines reach memory intact")
        call mmu_tables_init
        nop
        /* word j of line i = (i+1) << 24 | (i+1) << 16 | j << 8 | j */
        set WB_PAGE, %l0
        clr %l1                         /* i */
1:      clr %l2                         /* j */
        add %l1, 1, %l3
        sll %l3, 8, %l4
        or %l4, %l3, %l3
        sll %l3, 16, %l3
2:      sll %l2, 8, %l4
        or %l4, %l2, %l4
        or %l3, %l4, %l4
        sta %l4, [%l0] 0x20
        add %l0, 4, %l0
        add %l2, 1, %l2
        cmp %l2, 8
        bl 2b
        nop
        add %l1, 1, %l1
        cmp %l1, WB_LINES
        bl 1b
        nop
        call mmu_on
        nop
        set WB_PAGE + 4, %l0
        mov WB_LINES, %l1
3:      ldstub [%l0], %l2               /* the line: cached, modified */
        sta %g0, [%l0] 0x10             /* flushed: a write-back burst */
        add %l0, 32, %l0
        subcc %l1, 1, %l1
        bne 3b
        nop
        call mmu_off
        nop
        set WB_PAGE, %l0
        clr %l1
4:      clr %l2
        add %l1, 1, %l3
        sll %l3, 8, %l4
        or %l4, %l3, %l3
        sll %l3, 16, %l3
5:      sll %l2, 8, %l4
        or %l4, %l2, %l4
        or %l3, %l4, %o2                /* expected */
        cmp %l2, 1
        bne 6f
        nop
        set 0x00ffffff, %l6
        and %o2, %l6, %o2
        set 0xff000000, %l6
        or %o2, %l6, %o2                /* word 1: ldstub set its top byte */
6:      lda [%l0] 0x20, %o1
        set WB_PAGE, %o0
        call check_eq
        sub %l0, %o0, %o0
        add %l0, 4, %l0
        add %l2, 1, %l2
        cmp %l2, 8
        bl 5b
        nop
        add %l1, 1, %l1
        cmp %l1, WB_LINES
        bl 4b
        nop
END
#endif

/* A routine in cacheable RAM is run, patched with a normal store, FLUSHed
 * and run again (V8 FLUSH: instruction memory consistency). */
BEGIN(t_selfmod, "cache: a patched instruction runs after FLUSH")
        call mmu_tables_init
        nop
        STPAV(0x90102001, MT_PAGE(2))          /* mov 1, %o0 */
        STPAV(0x81c3e008, MT_PAGE(2) + 4)      /* retl */
        STPAV(0x01000000, MT_PAGE(2) + 8)      /* nop */
        call mmu_on
        nop
        set MT_PAGE(2), %l4
        call %l4
        nop
        mov %o0, %l1
        set 0x90102002, %o0             /* mov 2, %o0 */
        st %o0, [%l4]
        flush %l4
        nop ; nop ; nop ; nop ; nop
        call %l4
        nop
        mov %o0, %l2
        call mmu_off
        nop
        EXPECT(%l1, 1, 1)
        EXPECT(%l2, 2, 2)
END
