/* Line fills on a memory path that does not deliver the beats of a burst
 * back to back (the MiSTer's DDR port under load: the HPS shares the SDRAM
 * with the ARM side, which is busy with the SD card during disk I/O).
 *
 * A line's tag is written valid when the fill starts; the data arrives
 * over the following cycles. The CPU side must therefore stay blocked
 * until the last beat has been written, even when the beats come with
 * gaps. A cache that drops the block on a gap lets a load, store or fetch
 * of a not yet written word of the line hit the way's previous contents:
 * Solaris 8 and NetBSD then corrupt memory under disk I/O.
 * In simulation, sim/obj_ss20/Vsim_top --ddr-gaps reproduces the board's
 * bus; without gaps the tests pass with or without the fix. */
#include "macros.h"

/* Both tests use the identity-mapped, cacheable pages 28-53 of MT_SEG. */
#define CF_BASE         MT_PAGE(28)             /* 64 KB: 2048 lines */
#define CF_SIZE         0x10000
#define CF_SEED1        0x5a5a1234
#define CF_SEED2        0xc3c3abcd
#define CI_BASE         (MT_PAGE(44) + 0x100)   /* + k * 4 KB: one I-cache set */
#define CI_ADD_O0       0x90022000              /* add %o0, k, %o0 */
#define CI_RETL         0x81c3e008
#define CI_NOP          0x01000000
#define CI_ROUNDS       64

/* CF_CHECK(reg, off): compare reg with the pattern of word %l0 + off
 * (%l2 = seed); count mismatches in %l3, keep the first bad address in
 * %l4 and the value read in %l5; %g1-%g2 */
#define CF_CHECK(reg, off)                                       \
        add %l0, off, %g1 ; xor %g1, %l2, %g2 ; cmp reg, %g2 ;   \
        be 9f ; nop ;                                            \
        add %l3, 1, %l3 ; cmp %l4, 0 ; bne 9f ; nop ;            \
        mov %g1, %l4 ; mov reg, %l5 ;                            \
9:

/* cf_fill(seed %o0): mem[a] = a ^ seed over CF_BASE..+CF_SIZE through the
 * bypass; leaf (%o1-%o3) */
cf_fill:
        set CF_BASE, %o1
        set CF_BASE + CF_SIZE, %o2
1:      xor %o1, %o0, %o3
        sta %o3, [%o1] 0x20
        add %o1, 4, %o1
        cmp %o1, %o2
        blu 1b
        nop
        retl
        nop

/* 2048 lines: a load of word 0 misses; the next instructions load words
 * 7 down to 1 of the same line (its later beats). Then, with the memory
 * changed behind the cache and the lines refilled: a load of word 0
 * misses, words 7 down to 1 are stored, a bypass read of word 0 waits
 * for the fill to end, and the words are loaded back: a beat that lands
 * after the store would put the old word over it. */
BEGIN(t_cache_fill_words, "cache: the words of a line used right after its miss are memory's")
        call mmu_tables_init
        nop
        set CF_SEED1, %o0
        call cf_fill
        nop
        call mmu_on
        nop
        /* pass 1: loads */
        set CF_BASE, %l0
        set CF_BASE + CF_SIZE, %l1
        set CF_SEED1, %l2
        clr %l3
        clr %l4
        clr %l5
1:      ld [%l0], %o0
        ld [%l0 + 28], %o1
        ld [%l0 + 24], %o2
        ld [%l0 + 20], %o3
        ld [%l0 + 16], %o4
        ld [%l0 + 12], %o5
        ld [%l0 + 8], %i0
        ld [%l0 + 4], %i1
        CF_CHECK(%o0, 0)
        CF_CHECK(%o1, 28)
        CF_CHECK(%o2, 24)
        CF_CHECK(%o3, 20)
        CF_CHECK(%o4, 16)
        CF_CHECK(%o5, 12)
        CF_CHECK(%i0, 8)
        CF_CHECK(%i1, 4)
        add %l0, 32, %l0
        cmp %l0, %l1
        blu 1b
        nop
        mov %l3, %i2
        mov %l4, %i3
        mov %l5, %i4
        /* pass 2: stores. The caches stay on: after the 64 KB walk of
         * pass 1 the 16 KB cache holds its last quarter, which this walk
         * evicts before reaching it, so every line below misses. */
        set CF_SEED2, %l6
        set CF_BASE, %l0
        set CF_BASE + CF_SIZE, %l1
        clr %l3
        clr %l4
        clr %l5
2:      ld [%l0], %o0                   /* miss: the fill starts */
        add %l0, 28, %g1
        xor %g1, %l6, %g2
        st %g2, [%l0 + 28]
        add %l0, 24, %g1
        xor %g1, %l6, %g2
        st %g2, [%l0 + 24]
        add %l0, 20, %g1
        xor %g1, %l6, %g2
        st %g2, [%l0 + 20]
        add %l0, 16, %g1
        xor %g1, %l6, %g2
        st %g2, [%l0 + 16]
        add %l0, 12, %g1
        xor %g1, %l6, %g2
        st %g2, [%l0 + 12]
        add %l0, 8, %g1
        xor %g1, %l6, %g2
        st %g2, [%l0 + 8]
        add %l0, 4, %g1
        xor %g1, %l6, %g2
        st %g2, [%l0 + 4]
        lda [%l0] 0x20, %g0             /* after the fill's last beat */
        ld [%l0 + 28], %o1
        ld [%l0 + 24], %o2
        ld [%l0 + 20], %o3
        ld [%l0 + 16], %o4
        ld [%l0 + 12], %o5
        ld [%l0 + 8], %i0
        ld [%l0 + 4], %i1
        mov %l6, %l2
        CF_CHECK(%o1, 28)
        CF_CHECK(%o2, 24)
        CF_CHECK(%o3, 20)
        CF_CHECK(%o4, 16)
        CF_CHECK(%o5, 12)
        CF_CHECK(%i0, 8)
        CF_CHECK(%i1, 4)
        add %l0, 32, %l0
        cmp %l0, %l1
        blu 2b
        nop
        set CF_BASE, %o0                /* write-back mode: the lines to memory */
        set CF_SIZE, %o1
        call mmu_flush_lines
        nop
        call mmu_off
        nop
        EXPECT(%i2, 0, 1)               /* loads: mismatches */
        EXPECT(%i3, 0, 2)               /*        first bad address */
        EXPECT(%i4, 0, 3)               /*        the value read there */
        EXPECT(%l3, 0, 4)               /* stores: mismatches */
        EXPECT(%l4, 0, 5)
        EXPECT(%l5, 0, 6)
END

/* ci_line(va %o0, word %o1, retl %o2): write a 32-byte line of code
 * through the bypass: 7 copies of word, then retl, and a line of nops
 * after it (the retl's delay slot); leaf (%o3-%o5) */
ci_line:
        mov 7, %o3
1:      sta %o1, [%o0] 0x20
        add %o0, 4, %o0
        subcc %o3, 1, %o3
        bne 1b
        nop
        sta %o2, [%o0] 0x20
        add %o0, 4, %o0
        set CI_NOP, %o4
        mov 8, %o3
2:      sta %o4, [%o0] 0x20
        add %o0, 4, %o0
        subcc %o3, 1, %o3
        bne 2b
        nop
        retl
        nop

/* Ten lines of code 4 KB apart share one I-cache set: four of nops ending
 * in retl, six of "add %o0, k, %o0" x 7 ending in retl (k = 4..9). The
 * nop lines are entered at their retl, so their fills execute only the
 * word the fetch asked for; then the six add lines are called 64 times
 * each, every call a miss (six lines, four ways), and %o0 must be 7k. A
 * fetch that hit a word of the line before its beat had landed executes
 * the evicted line's word there (a nop or another k). */
BEGIN(t_icache_fill_words, "cache: a routine fetched through its line fill runs memory's words")
        call mmu_tables_init
        nop
        set CI_BASE, %l0
        set CI_NOP, %l1
        set CI_RETL, %l2
        mov 10, %l3
        clr %l4                         /* k */
1:      mov %l0, %o0
        mov %l1, %o1                    /* k < 4: nops */
        cmp %l4, 4
        bl 2f
        mov %l2, %o2
        set CI_ADD_O0, %o1
        or %o1, %l4, %o1                /* k >= 4: add %o0, k, %o0 */
2:      call ci_line
        nop
        set 0x1000, %o3
        add %l0, %o3, %l0
        subcc %l3, 1, %l3
        bne 1b
        add %l4, 1, %l4
        call mmu_on
        nop
        /* prime the four ways with the nop lines, entered at their retl */
        set CI_BASE + 28, %l0
        mov 4, %l3
3:      call %l0
        nop
        set 0x1000, %o3
        subcc %l3, 1, %l3
        bne 3b
        add %l0, %o3, %l0
        /* the add lines, CI_ROUNDS times each */
        clr %l5                         /* mismatches */
        clr %l6                         /* first bad: k << 16 | round */
        clr %l7                         /* %o0 seen there */
        mov CI_ROUNDS, %i0
4:      set CI_BASE + 4 * 0x1000, %l0
        mov 4, %l4
5:      clr %o0
        call %l0
        nop
        sll %l4, 3, %g1
        sub %g1, %l4, %g1               /* 7k */
        cmp %o0, %g1
        be 6f
        nop
        add %l5, 1, %l5
        cmp %l6, 0
        bne 6f
        nop
        sll %l4, 16, %l6
        or %l6, %i0, %l6
        mov %o0, %l7
6:      set 0x1000, %o3
        add %l0, %o3, %l0
        add %l4, 1, %l4
        cmp %l4, 10
        bl 5b
        nop
        subcc %i0, 1, %i0
        bne 4b
        nop
        call mmu_off
        nop
        EXPECT(%l5, 0, 1)
        EXPECT(%l6, 0, 2)
        EXPECT(%l7, 0, 3)
END
