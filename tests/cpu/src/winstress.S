/* winstress: OpenBIOS's register-window spill and fill handlers
 * (bios/openbios/arch/sparc32/wof.S, wuf.S: the same instructions) under
 * deep recursion, with the MMU and the caches on, each pair placed at all
 * 8 word offsets of a 32-byte I-cache line. Written after OpenBIOS hung
 * in its overflow handler's trap return when its code moved by 16 bytes
 * (scratch/handoff/fable-layout-hang.md). Built apart from the suite:
 *     python3 tests/cpu/build.py ss20 --main=winstress
 *     sim/obj_ss20/Vsim_top --rom tests/cpu/out/ss20/winstress.rom \
 *         --stop "CPUTEST DONE" --cycles 400M
 * The overflow and underflow vectors (tt 5, 6) are rewritten in the
 * shadow copy of the PROM (pa 0, before the caches go on) to jump through
 * a pointer, which selects the handler copy.
 * 2026-10-03: passes in the simulation and on the board (-DWS_ITER=65536,
 * every option below, alone and together): this alone does not reproduce
 * the hang. */
#include "runtime.S"
#include "mmu_setup.S"

#ifndef WS_ITER
#define WS_ITER         64              /* recursions per handler copy */
#endif
#ifndef WS_DEPTH
#define WS_DEPTH        20              /* call depth: 8 windows */
#endif
#define WS_SPILL        (SCRATCH + 0xf0000)   /* handler pointers, clear */
#define WS_FILL         (SCRATCH + 0xf0004)   /* of mmu_setup's tables */
#define WS_STOP         (SCRATCH + 0xf0008)   /* -DWS_BUS: CPUs 1-2 stop */
#define WS_NOP          0x01000000
/* -DWS_SPREAD: every handler copy on a page of its own (I-TLB misses in
 * the handlers); -DWS_DTLB: every recursion level loads from one of 8
 * pages first (D-TLB misses around the spills and fills); -DWS_BUS: CPUs
 * 1 and 2 load and store over 256 KB each, caches on, meanwhile (bus and
 * snoop traffic) */
#ifdef WS_SPREAD
#define WS_ALIGN        4096
#else
#define WS_ALIGN        32
#endif

/* the vector: 4 instructions, %l0 = PSR as OpenBIOS's own vector */
#define WS_VEC(ptr)                                              \
        sethi %hi(ptr), %l4 ;                                    \
        ld [%l4 + %lo(ptr)], %l4 ;                               \
        jmp %l4 ;                                                \
        rd %psr, %l0

/* one handler pair, k nop words into a fresh line; the entry reads %wim
 * (OpenBIOS's vector does), then wof.S / wuf.S for 8 windows */
#define WS_PAIR(k)                                               \
        .align WS_ALIGN ;                                        \
        .fill k, 4, WS_NOP ;                                     \
ws_spill_##k:                                                    \
        rd %wim, %l3 ;                                           \
        mov %g5, %l5 ;                                           \
        mov %g6, %l6 ;                                           \
        srl %l3, 1, %l4 ;                                        \
        sll %l3, 7, %g5 ;                                        \
        or %g5, %l4, %g5 ;                                       \
        and %g5, 0xff, %g5 ;                                     \
        save %g0, %g0, %g0 ;                                     \
        wr %g5, 0, %wim ;                                        \
        nop ; nop ; nop ;                                        \
        std %l0, [%sp + 0x00] ;                                  \
        std %l2, [%sp + 0x08] ;                                  \
        std %l4, [%sp + 0x10] ;                                  \
        std %l6, [%sp + 0x18] ;                                  \
        std %i0, [%sp + 0x20] ;                                  \
        std %i2, [%sp + 0x28] ;                                  \
        std %i4, [%sp + 0x30] ;                                  \
        std %i6, [%sp + 0x38] ;                                  \
        restore %g0, %g0, %g0 ;                                  \
        mov %l5, %g5 ;                                           \
        mov %l6, %g6 ;                                           \
        wr %l0, 0, %psr ;                                        \
        nop ; nop ; nop ;                                        \
        jmp %l1 ;                                                \
        rett %l2 ;                                               \
        .align WS_ALIGN ;                                        \
        .fill k, 4, WS_NOP ;                                     \
ws_fill_##k:                                                     \
        rd %wim, %l3 ;                                           \
        sll %l3, 1, %l4 ;                                        \
        srl %l3, 7, %l5 ;                                        \
        or %l4, %l5, %l4 ;                                       \
        and %l4, 0xff, %l4 ;                                     \
        wr %l4, 0, %wim ;                                        \
        nop ; nop ; nop ;                                        \
        restore %g0, %g0, %g0 ;                                  \
        restore %g0, %g0, %g0 ;                                  \
        nop ; nop ; nop ;                                        \
        ldd [%sp + 0x00], %l0 ;                                  \
        ldd [%sp + 0x08], %l2 ;                                  \
        ldd [%sp + 0x10], %l4 ;                                  \
        ldd [%sp + 0x18], %l6 ;                                  \
        ldd [%sp + 0x20], %i0 ;                                  \
        ldd [%sp + 0x28], %i2 ;                                  \
        ldd [%sp + 0x30], %i4 ;                                  \
        ldd [%sp + 0x38], %i6 ;                                  \
        save %g0, %g0, %g0 ;                                     \
        save %g0, %g0, %g0 ;                                     \
        wr %l0, 0, %psr ;                                        \
        nop ; nop ; nop ;                                        \
        jmp %l1 ;                                                \
        rett %l2

        .section .text
        .align 4
/* the two vectors, copied over tt 5 and tt 6 of the shadow trap table */
ws_vectors:
        WS_VEC(WS_SPILL)
        WS_VEC(WS_FILL)

        WS_PAIR(0)
        WS_PAIR(1)
        WS_PAIR(2)
        WS_PAIR(3)
        WS_PAIR(4)
        WS_PAIR(5)
        WS_PAIR(6)
        WS_PAIR(7)

ws_table:
        .word ws_spill_0, ws_fill_0, ws_spill_1, ws_fill_1
        .word ws_spill_2, ws_fill_2, ws_spill_3, ws_fill_3
        .word ws_spill_4, ws_fill_4, ws_spill_5, ws_fill_5
        .word ws_spill_6, ws_fill_6, ws_spill_7, ws_fill_7

#ifdef WS_BUS
/* ws_hammer(VA %o0), on CPU 1 or 2 through mp_post: MMU and caches on,
 * one load and one store per 32-byte line over 256 KB, again and again
 * until CPU 0 sets WS_STOP; no window traps (the vectors are CPU 0's
 * test). %l6 belongs to mp_park. */
ws_hammer:
        mov %o7, %l7
        mov %o0, %l0
        call mmu_on
        nop
1:      mov %l0, %o0
        sethi %hi(0x40000), %o1
        add %o0, %o1, %o1
2:      ld [%o0], %o2
        add %o2, 1, %o2
        st %o2, [%o0 + 16]
        add %o0, 32, %o0
        cmp %o0, %o1
        blu 2b
        nop
        set WS_STOP, %o2
        lda [%o2] 0x20, %o2
        tst %o2
        be 1b
        nop
        call mmu_off
        nop
        jmp %l7 + 8
        mov 0, %o0
#endif

/* ws_recurse(depth %o0) -> %o0 = depth + ... + 1, or bit 31 if a level's
 * locals did not survive the deeper call (as t_window.S's recurse) */
ws_recurse:
        save %sp, -96, %sp
        sll %i0, 8, %l0
        or %l0, 0x11, %l1
        or %l0, 0x22, %l2
        or %l0, 0x33, %l3
        or %l0, 0x44, %l4
        or %l0, 0x55, %l5
        or %l0, 0x66, %l6
        or %l0, 0x77, %l7
#ifdef WS_DTLB
        and %i0, 7, %o1                 /* a load from page depth & 7 */
        sll %o1, 12, %o1
        set MT_PAGE(0), %o2
        ld [%o2 + %o1], %g0
#endif
        mov %i0, %i5
        subcc %i0, 1, %o0
        be 1f
        mov 0, %o0
        call ws_recurse
        sub %i0, 1, %o0
1:      add %o0, %i0, %i0
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
2:      set 0x80000000, %i0
        ret
        restore

BEGIN(t_winstress, "winstress: OpenBIOS's spill/fill handlers at 8 line offsets, MMU and caches on")
        /* the vectors over tt 5 and 6 of the shadow trap table (pa 0) */
        set ws_vectors, %l0
        mov 0x50, %l1
        mov 8, %l2
1:      ld [%l0], %o0
        sta %o0, [%l1] 0x20
        add %l0, 4, %l0
        subcc %l2, 1, %l2
        bne 1b
        add %l1, 4, %l1
        call mmu_tables_init
        nop
        set ws_table, %l7
        set WS_SPILL, %o1               /* copy 0 before any trap can come */
        ld [%l7], %o0
        sta %o0, [%o1] 0x20
        ld [%l7 + 4], %o0
        add %o1, 4, %o1
        sta %o0, [%o1] 0x20
#ifdef WS_BUS
        set WS_STOP, %o0
        sta %g0, [%o0] 0x20
        mov 1, %o0
        set ws_hammer, %o1
        set 0x40400000, %o2             /* the cacheable alias of pa 4 MB */
        call mp_post
        mov 0, %o3
        mov 2, %o0
        set ws_hammer, %o1
        set 0x40600000, %o2
        call mp_post
        mov 0, %o3
#endif
        call mmu_on
        nop
        mov 0, %l5                      /* bad results */
        mov 0, %l6                      /* handler copy k */
2:      ld [%l7], %o0                   /* select copy k */
        set WS_SPILL, %o1
        st %o0, [%o1]
        ld [%l7 + 4], %o0
        st %o0, [%o1 + 4]
        set WS_ITER, %l4
3:      call ws_recurse
        mov WS_DEPTH, %o0
        cmp %o0, (WS_DEPTH * (WS_DEPTH + 1)) / 2
        be 4f
        nop
        inc %l5
4:      subcc %l4, 1, %l4
        bne 3b
        nop
        inc %l6
        cmp %l6, 8
        bne 2b
        add %l7, 8, %l7
        call mmu_off
        nop
#ifdef WS_BUS
        set WS_STOP, %o0
        mov 1, %o1
        sta %o1, [%o0] 0x20
        call mp_wait
        mov 1, %o0
        mov %o1, %l3                    /* CPU 1 timed out */
        call mp_wait
        mov 2, %o0
        add %l3, %o1, %l3
        EXPECT(%l3, 0, 2)
#endif
        EXPECT(%l5, 0, 1)
END

        .section .testtab, "a", @progbits
        .word 0, 0                      /* end of the test table */

        .section .romend, "a", @progbits
        .align 4
        .globl rom_end
rom_end:
