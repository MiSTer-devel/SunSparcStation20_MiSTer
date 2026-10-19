/* MMU-on setup shared by the MMU, cache and SMP tests, for every target.
 *
 * Page tables in SCRATCH (built through the bypass ASI, never read or
 * written through the cache), an identity map of the first 16 MB (code:
 * the SS20 runs from the shadow copy of the PROM at pa 0 once boot mode
 * is off, the SS5 maps its PROM region as well; VARS, the stack, the
 * tables; all cacheable, ACC 3) with one page-mapped segment MT_SEG whose
 * 64 level-3 entries the tests use (roles below), a cacheable alias of
 * RAM at VA 0x4000_0000, and on the SS20 three extra contexts (1, 0x101,
 * 0x8001) that map VA 0x0400_0000 to three different pages.
 *
 * The context table is 256 KB aligned (OBP 2.25 allocates it so for 65536
 * contexts); only the entries the tests use are written. I/O is not
 * mapped: the suite prints through the bypass ASIs, which translate
 * nothing.
 *
 * Entry formats (SPARC V8 appendix H): PTD = (pa >> 4) | 1; PTE =
 * ((pa >> 4) & ~0xff) | C << 7 | ACC << 2 | 2, R (bit 5) and M (bit 6)
 * set by the hardware.
 *
 * mmu_on / mmu_off are leaf routines (%o0-%o5), usable by the parked SS20
 * CPUs too. mmu_off flushes the lines the suite may have dirtied in
 * write-back mode (VARS, the stack top, the first 16 pages of MT_SEG),
 * turns the caches and the MMU off, boot mode on, flash-clears the SS20
 * caches (ASI 0x36/0x37), clears every tag through ASI 0x0c/0x0e as
 * the core decodes them (index VA[11:5]) and flushes the TLB, so the
 * rest of the suite, which runs uncached, cannot meet a stale line. */
#include "macros.h"

#define MT_L1           (SCRATCH + 0x30000)     /* context 0 level 1 */
#define MT_L2           (SCRATCH + 0x30400)     /* region 0 level 2 */
#define MT_L3           (SCRATCH + 0x30800)     /* MT_SEG level 3 */
#define MT_L1X(k)       (SCRATCH + 0x34000 + (k) * 0x1000) /* SS20 ctx k */
#define MT_L2X(k)       (MT_L1X(k) + 0x400)
#define MT_L3X(k)       (MT_L1X(k) + 0x800)
#define MT_CTX          (SCRATCH + 0x40000)     /* context table, 256 KB */
#define MT_SEG          (SCRATCH + 0x80000)     /* the page-mapped segment */
#define MT_SEG_IDX      ((MT_SEG >> 18) & 0x3f) /* its level-2 index */
#define MT_PAGE(i)      (MT_SEG + (i) * 0x1000)
#define MT_ALIAS        0x40000000              /* VA alias of pa 0 */
#define MT_CTXVA        0x04000000              /* mapped only in ctx 1.. */

/* MT_SEG pages: 0-15 identity, cacheable (cache and SMP test data);
 * 16 invalid; 17 reserved entry (ET 3); 18 ACC 0 (read-only); 19 ACC 6
 * (supervisor only); 20 identity, non-cacheable; 21 maps page 22 (the
 * TLB test moves it over 22-27); 28-63 identity, cacheable; 32-34 are
 * also the targets of the SS20 contexts 1, 0x101, 0x8001. */
#define MT_P_INVALID    16
#define MT_P_RESERVED   17
#define MT_P_RDONLY     18
#define MT_P_SUPER      19
#define MT_P_NC         20
#define MT_P_REMAP      21
#define MT_P_CTX0       32

#define PTD(pa)             (((pa) >> 4) | 1)
#define PTE(pa, c, acc)     ((((pa) >> 4) & 0xffffff00) | ((c) << 7) | ((acc) << 2) | 2)
#define PTE_C3(pa)          PTE(pa, 1, 3)
#define MT_RESERVED_WORD    0x00abcd03

#if defined(TARGET_SS20)
#  define MCR_EN        0x0001
#  define MCR_NF        0x0002
#  define MCR_DE        0x0100
#  define MCR_IE        0x0200
#  define MCR_BM        0x2000
#  define MCR_SE        0x4000
#  define MCR_ON        (MCR_SE | MCR_IE | MCR_DE | MCR_EN)
#else
#  define MCR_EN        0x0001
#  define MCR_NF        0x0002
#  define MCR_DE        0x0100
#  define MCR_IE        0x0200
#  define MCR_BM        0x4000
#  define MCR_ON        (MCR_IE | MCR_DE | MCR_EN)
#endif

/* sta_pa(reg, pa): store reg at physical pa through the bypass; %o5 */
#define STPA(reg, pa)   set pa, %o5 ; sta reg, [%o5] 0x20
#define STPAV(val, pa)  set val, %o4 ; STPA(%o4, pa)

        .section .text
        .align 4

/* mmu_tables_init: build the tables; leaf-ish (uses %o0-%o5 and %g1) */
        .globl mmu_tables_init
mmu_tables_init:
        mov %o7, %g1
        /* clear L1, L2, L3 and the first 512 context entries */
        set MT_L1, %o0
        set 0x400, %o1
        call mt_clear
        nop
        set MT_L2, %o0
        set 0x100, %o1
        call mt_clear
        nop
        set MT_L3, %o0
        set 0x100, %o1
        call mt_clear
        nop
        set MT_CTX, %o0
        set 0x800, %o1
        call mt_clear
        nop
        /* context 0 -> L1; L1[0] -> L2; L1[0x40] = alias of pa 0 */
        STPAV(PTD(MT_L1), MT_CTX)
        STPAV(PTD(MT_L2), MT_L1)
        STPAV(PTE_C3(0), MT_L1 + 0x40 * 4)
#if !defined(TARGET_SS20)
        STPAV(PTE_C3(ROM_BASE), MT_L1 + (ROM_BASE >> 24) * 4)
#endif
        /* L2: identity segments, MT_SEG_IDX -> L3 */
        set MT_L2, %o0
        clr %o1
1:      sll %o1, 18, %o2
        srl %o2, 4, %o2
        or %o2, 0x8e, %o2               /* C, ACC 3, PTE */
        cmp %o1, MT_SEG_IDX
        bne 2f
        nop
        set PTD(MT_L3), %o2
2:      sta %o2, [%o0] 0x20
        add %o1, 1, %o1
        cmp %o1, 64
        bl 1b
        add %o0, 4, %o0
        /* L3: identity pages, then the special ones */
        set MT_L3, %o0
        set MT_SEG, %o1
        clr %o2
        set 0x1000, %o4                 /* no 13-bit immediate: see 4096 */
1:      srl %o1, 4, %o3
        or %o3, 0x8e, %o3
        sta %o3, [%o0] 0x20
        add %o2, 1, %o2
        add %o1, %o4, %o1
        cmp %o2, 64
        bl 1b
        add %o0, 4, %o0
        STPAV(0, MT_L3 + MT_P_INVALID * 4)
        STPAV(MT_RESERVED_WORD, MT_L3 + MT_P_RESERVED * 4)
        STPAV(PTE(MT_PAGE(MT_P_RDONLY), 0, 0), MT_L3 + MT_P_RDONLY * 4)
        STPAV(PTE(MT_PAGE(MT_P_SUPER), 0, 6), MT_L3 + MT_P_SUPER * 4)
        STPAV(PTE(MT_PAGE(MT_P_NC), 0, 3), MT_L3 + MT_P_NC * 4)
        STPAV(PTE_C3(MT_PAGE(MT_P_REMAP + 1)), MT_L3 + MT_P_REMAP * 4)
#if defined(TARGET_SS20)
        /* contexts 1, 0x101, 0x8001: region 0 shared, VA MT_CTXVA ->
         * page MT_P_CTX0 + k */
        set MT_L1X(0), %o0
        set 0xc00, %o1                  /* L1 + L2 + L3 of context 0 */
        call mt_clear
        nop
        set MT_L1X(1), %o0
        set 0xc00, %o1
        call mt_clear
        nop
        set MT_L1X(2), %o0
        set 0xc00, %o1
        call mt_clear
        nop
        STPAV(PTD(MT_L1X(0)), MT_CTX + 1 * 4)
        STPAV(PTD(MT_L1X(1)), MT_CTX + 0x101 * 4)
        STPAV(PTD(MT_L1X(2)), MT_CTX + 0x8001 * 4)
        STPAV(PTD(MT_L2), MT_L1X(0))
        STPAV(PTD(MT_L2), MT_L1X(1))
        STPAV(PTD(MT_L2), MT_L1X(2))
        STPAV(PTD(MT_L2X(0)), MT_L1X(0) + (MT_CTXVA >> 24) * 4)
        STPAV(PTD(MT_L2X(1)), MT_L1X(1) + (MT_CTXVA >> 24) * 4)
        STPAV(PTD(MT_L2X(2)), MT_L1X(2) + (MT_CTXVA >> 24) * 4)
        STPAV(PTD(MT_L3X(0)), MT_L2X(0))
        STPAV(PTD(MT_L3X(1)), MT_L2X(1))
        STPAV(PTD(MT_L3X(2)), MT_L2X(2))
        STPAV(PTE_C3(MT_PAGE(MT_P_CTX0 + 0)), MT_L3X(0))
        STPAV(PTE_C3(MT_PAGE(MT_P_CTX0 + 1)), MT_L3X(1))
        STPAV(PTE_C3(MT_PAGE(MT_P_CTX0 + 2)), MT_L3X(2))
#endif
        jmp %g1 + 8
        nop

/* mt_clear(pa %o0, bytes %o1): zero through the bypass; leaf */
mt_clear:
        add %o0, %o1, %o1
1:      sta %g0, [%o0] 0x20
        add %o0, 4, %o0
        cmp %o0, %o1
        blu 1b
        nop
        retl
        nop

/* mmu_ctx_set: CTPR = MT_CTX, context 0, flush the TLB; leaf */
        .globl mmu_ctx_set
mmu_ctx_set:
        set (MT_CTX >> 4), %o1
        mov 0x100, %o0
        sta %o1, [%o0] 0x04
        mov 0x200, %o0
        sta %g0, [%o0] 0x04
        mov 0x400, %o0
        retl
        sta %g0, [%o0] 0x03

/* mmu_on: tables assumed built; MMU, both caches (and SE on the SS20)
 * on, boot mode off; leaf */
        .globl mmu_on
mmu_on:
        set (MT_CTX >> 4), %o1
        mov 0x100, %o0
        sta %o1, [%o0] 0x04
        mov 0x200, %o0
        sta %g0, [%o0] 0x04
        mov 0x400, %o0
        sta %g0, [%o0] 0x03
        lda [%g0] 0x04, %o2
        set MCR_BM, %o3
        andn %o2, %o3, %o2
        set MCR_ON, %o3
        or %o2, %o3, %o2
        sta %o2, [%g0] 0x04
        nop ; nop ; nop ; nop
        retl
        nop

/* mmu_flush_lines(va %o0, bytes %o1): flush (write back and invalidate)
 * every 32-byte line of the range, ASI 0x10 (I&D line, page type); leaf */
        .globl mmu_flush_lines
mmu_flush_lines:
        add %o0, %o1, %o1
1:      sta %g0, [%o0] 0x10
        add %o0, 32, %o0
        cmp %o0, %o1
        blu 1b
        nop
        retl
        nop

/* mmu_off: see the header; leaf (uses %o0-%o5 and %g1) */
        .globl mmu_off
mmu_off:
        mov %o7, %g1
        set VARS, %o0
        call mmu_flush_lines
        mov V_SIZE, %o1
        set STACK_TOP - 0x2000, %o0
        set 0x2000, %o1
        call mmu_flush_lines
        nop
        set MT_SEG, %o0
        set 0x10000, %o1
        call mmu_flush_lines
        nop
        /* caches and MMU off, boot mode on */
        lda [%g0] 0x04, %o2
        set MCR_ON | MCR_NF, %o3
        andn %o2, %o3, %o2
        set MCR_BM, %o3
        or %o2, %o3, %o2
        sta %o2, [%g0] 0x04
        nop ; nop ; nop ; nop
#if defined(TARGET_SS20)
        sta %g0, [%g0] 0x37             /* D-cache flash clear */
        sta %g0, [%g0] 0x36             /* I-cache flash clear */
#endif
        clr %o0
        set 0x1000, %o1
1:      sta %g0, [%o0] 0x0e             /* D tag, every way at this index */
        sta %g0, [%o0] 0x0c             /* I tag */
        add %o0, 32, %o0
        cmp %o0, %o1
        blu 1b
        nop
        mov 0x200, %o0
        sta %g0, [%o0] 0x04             /* context 0 */
        mov 0x400, %o0
        sta %g0, [%o0] 0x03             /* flush the TLB */
        jmp %g1 + 8
        nop
