/* bmbench: how fast boot-mode instruction fetch is, for the Sun POST's
 * timing assumptions (PLAN.md A4). Built apart from the suite (python3
 * tests/cpu/build.py ss20 --main=bmbench, out/ss20/bmbench.rom). It runs
 * the POST's counter-test poll loop (post-tests.md section 8: 6
 * instructions, "tst %g5; be; nop; subcc; bne; nop", 0x80000 passes while
 * the counter climbs 2.1 s) a number of times and prints the system
 * counter's ticks (500 ns each) it took, then the same for a line of 32
 * nops. Not a regression test: the numbers depend on the DDR. */
#include "runtime.S"

        .text
#define SYSCNT_PA       0xf1310004      /* the system counter, ASI 0x2f */
#define POLLS           0x4000

        .section .rodata
s_polls: .asciz "poll loop passes="
s_ticks: .asciz " ticks="
s_nops:  .asciz "nop line passes="
        .text
        .align 4

/* %o0 = the system counter's count (bits 30:9) */
rdcnt:  set SYSCNT_PA, %o1
        lda [%o1] 0x2f, %o0
        sll %o0, 1, %o0
        retl
        srl %o0, 10, %o0

BEGIN(t_bmfetch, "bmbench: boot-mode fetch rate (not a check)")
        set s_polls, %o0
        call puts
        nop
        set POLLS, %o0
        call putdec
        nop
        call rdcnt
        nop
        mov %o0, %l0
        mov 0x1e, %g5
        set POLLS, %l3
1:      tst %g5
        be 2f
        nop
        subcc %l3, 1, %l3
        bne 1b
        nop
2:      call rdcnt
        nop
        sub %o0, %l0, %l1
        set s_ticks, %o0
        call puts
        nop
        call putdec
        mov %l1, %o0
        set s_nl, %o0
        call puts
        nop
        /* a line of 32 nops, POLLS/4 times */
        set s_nops, %o0
        call puts
        nop
        set POLLS / 4, %o0
        call putdec
        nop
        call rdcnt
        nop
        mov %o0, %l0
        set POLLS / 4, %l3
3:      nop ; nop ; nop ; nop ; nop ; nop ; nop ; nop
        nop ; nop ; nop ; nop ; nop ; nop ; nop ; nop
        nop ; nop ; nop ; nop ; nop ; nop ; nop ; nop
        nop ; nop ; nop ; nop ; nop ; nop ; nop ; nop
        subcc %l3, 1, %l3
        bne 3b
        nop
        call rdcnt
        nop
        sub %o0, %l0, %l1
        set s_ticks, %o0
        call puts
        nop
        call putdec
        mov %l1, %o0
        set s_nl, %o0
        call puts
        nop
        EXPECT(%g0, 0, 1)
END

        .section .testtab, "a", @progbits
        .word 0, 0

        .section .romend, "a", @progbits
        .align 4
        .globl rom_end
rom_end:
