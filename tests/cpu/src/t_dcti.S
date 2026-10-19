/* Delayed control transfer couples (SPARC V8 B.?): a JMPL or RETT in the
 * delay slot of a JMPL. The trap return `jmp %l1; rett %l2` is one, and
 * its target is whatever instruction trapped or was interrupted. In the
 * IU a JMPL/RETT in DEC is exempt from the stall otherwise applied while
 * a JMPL/RETT is in EXE, so that the couple flows; but the fetch unit's
 * pc is advanced only when the EXE JMPL/RETT completes, so while the RETT
 * is held in EXE (a store before it still waiting for the bus) its
 * target can reach DEC first, and a JMPL target then took the RETT's own
 * address as its pc: it linked %o7 there, and the callee's retl landed 8
 * bytes after the RETT. OpenBIOS's level-14 handler (st; jmp; rett)
 * returning to Forth's `call %g1` fell into the window spill handler that
 * follows it in memory (2026-10-03, scratch/handoff/fable-layout-hang.md).
 *
 * dc_try_N: a trap return built by hand: save (the trap window), ET off,
 * N stores, jmp/rett to the caller's `jmpl %g1, %o7`, whose leaf callee
 * returns through %o7. The 8 bytes after the rett are where a retl through
 * a wrong %o7 lands; they record the link seen and go to the check. */
#include "macros.h"

#define DC_BUF  (SCRATCH + 0x8000)

#define DC_TRY(n)                                                \
dc_try_##n:                                                      \
        save %sp, -96, %sp ;                                     \
        add %i7, 8, %l1 ;               /* the jmpl after the call */ \
        add %i7, 12, %l2 ;                                       \
        rd %psr, %l0 ;                                           \
        or %l0, PSR_PS, %l0 ;           /* rett: S <- PS */      \
        andn %l0, PSR_ET, %l0 ;                                  \
        wr %l0, %psr ;                                           \
        nop ; nop ; nop ;                                        \
        set DC_BUF, %l4 ;                                        \
        .rept n ;                                                \
        st %l4, [%l4] ;                                          \
        .endr ;                                                  \
        jmp %l1 ;                                                \
        rett %l2 ;                                               \
        mov %o7, %l3 ;                  /* here through a wrong %o7 */ \
        jmp %g3 ;                                                \
        nop

        .text
        .align 4
dc_leaf:
        retl
        nop

        DC_TRY(0)
        DC_TRY(1)
        DC_TRY(2)
        DC_TRY(4)
        DC_TRY(8)

/* %l6 iterations of dc_try_n: %o7 after the jmpl must be the jmpl's address */
#define DC_RUN(n, code)                                          \
        mov 16, %l6 ;                                            \
3:      set 2f, %g3 ;                                            \
        call dc_try_##n ;                                        \
        nop ;                                                    \
1:      jmpl %g1, %o7 ;                                          \
        nop ;                                                    \
        mov %o7, %l3 ;                                           \
2:      set 1b, %l5 ;                                            \
        EXPECT_R(%l3, %l5, code) ;                               \
        subcc %l6, 1, %l6 ;                                      \
        bne 3b ;                                                 \
        nop

/* MMU and caches on (mmu_setup.S): the target's fetch is then an I-cache
 * hit, 2 cycles, while the stores queue up for the bus; with the MMU off
 * the uncached fetch always loses the race and the IU is never caught. */
BEGIN(t_rett_jmpl, "iu: jmp/rett to a jmpl %g1,%o7 (0, 1, 2, 4, 8 stores before the rett), caches on: %o7 is the jmpl's address")
        call mmu_tables_init
        nop
        call mmu_on
        nop
        set dc_leaf, %g1
        DC_RUN(0, 0x10)
        DC_RUN(1, 0x11)
        DC_RUN(2, 0x12)
        DC_RUN(4, 0x14)
        DC_RUN(8, 0x18)
        call mmu_off
        nop
END
