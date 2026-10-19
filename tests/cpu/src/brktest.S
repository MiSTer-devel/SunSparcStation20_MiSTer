/* brktest: a BREAK on ttya, the ESCC's side (PLAN.md B2), built apart from
 * the suite (python3 tests/cpu/build.py ss20 --main=brktest,
 * out/ss20/brktest.rom) because something must send the BREAK: the test
 * prints "BRK?" and waits; the simulation sends one with
 *   sim/obj_ss20/Vsim_top --rom tests/cpu/out/ss20/brktest.rom \
 *       --send 'BRK?=>\B' --stop 'CPUTEST DONE' --cycles 60M
 * and on the board a tcsendbreak() on the MiSTer's /dev/ttyS1 does.
 *
 * The core shows a BREAK to the ESCC: RR0
 * bit 7, an External/Status interrupt on each edge when WR15 bit 7 and
 * WR1 bit 0 are set (RR3 bit 3 for channel A, vector code 101), RR0 bit 7
 * latched while it is pending, and a NUL received when the BREAK starts.
 * PIL stays 15: the interrupt is only looked at, never taken. */
#include "runtime.S"

        .text

#define TTYB_CTRL       (ESCC_BASE + 0)
#define BRK_POLLS       4000000         /* > 0.3 s on the board */

/* write ESCC channel A register %o0 with %o1 */
wr_a:   set TTYA_CTRL, %o2
        stba %o0, [%o2] IO_ASI          /* WR0: the pointer (0x08|n for 8-15) */
        retl
        stba %o1, [%o2] IO_ASI

/* read channel A's RR%o0 into %o0 */
rd_a:   set TTYA_CTRL, %o2
        stba %o0, [%o2] IO_ASI
        retl
        lduba [%o2] IO_ASI, %o0

/* wait until (RR%o0 & %o1) == %o2 on channel A; %o0 = 0 if it came, 1 if
 * not within BRK_POLLS */
wait_a: save %sp, -96, %sp
        set BRK_POLLS, %l0
1:      call rd_a
        mov %i0, %o0
        and %o0, %i1, %o0
        cmp %o0, %i2
        be 2f
        subcc %l0, 1, %l0
        bne 1b
        nop
        ret
        restore %g0, 1, %o0
2:      ret
        restore %g0, 0, %o0

/* ---------------------------------------------------------------- */

BEGIN(t_brk_escc, "brk: a BREAK on ttya: RR0 bit 7, the ext/status interrupt, a NUL")
        mov 0xc1, %o1
        call wr_a                       /* WR3: 8 bits, receiver on */
        mov 3, %o0
        mov 0, %o1
        call wr_a                       /* WR2: vector 0 */
        mov 2, %o0
        mov 0x80, %o1
        call wr_a                       /* WR15: Break/Abort IE */
        mov 0x0f, %o0
        mov 0x01, %o1
        call wr_a                       /* WR1: ext/status IE only */
        mov 1, %o0
        mov 0x10, %o1
        call wr_a                       /* WR0: reset ext/status */
        mov 0, %o0
        call rd_a                       /* RR15 reads WR15's bit 7 back */
        mov 15, %o0
        EXPECT(%o0, 0x80, 1)
        /* drop anything received so far */
1:      call rd_a
        clr %o0
        andcc %o0, 1, %g0
        be 2f
        set TTYA_DATA, %o0
        ba 1b
        lduba [%o0] IO_ASI, %g0
2:      set s_ask, %o0                  /* the BREAK, please */
        call puts
        nop
        /* the BREAK starts: ext/status pending (RR3 bit 3) */
        mov 3, %o0
        mov 0x08, %o1
        call wait_a
        mov 0x08, %o2
        EXPECT(%o0, 0, 2)
        call rd_a                       /* RR0: Break/Abort, a char (NUL) */
        clr %o0
        and %o0, 0x81, %o0
        EXPECT(%o0, 0x81, 3)
        set TTYB_CTRL, %o0              /* RR2 on channel B: vector code 101 */
        mov 2, %o1
        stba %o1, [%o0] IO_ASI
        lduba [%o0] IO_ASI, %o0
        and %o0, 0x0e, %o0
        EXPECT(%o0, 0x0a, 4)
        set TTYA_DATA, %o0              /* the NUL */
        lduba [%o0] IO_ASI, %o0
        EXPECT(%o0, 0, 5)
        mov 0x10, %o1
        call wr_a                       /* reset ext/status: still in BREAK */
        mov 0, %o0
        call rd_a
        mov 3, %o0
        and %o0, 0x08, %o0
        EXPECT(%o0, 0, 6)
        /* the BREAK ends: pending again, RR0 bit 7 latched at 0 */
        mov 3, %o0
        mov 0x08, %o1
        call wait_a
        mov 0x08, %o2
        EXPECT(%o0, 0, 7)
        call rd_a
        clr %o0
        and %o0, 0x81, %o0
        EXPECT(%o0, 0, 8)               /* no more characters */
        mov 0x10, %o1
        call wr_a
        mov 0, %o0
        call rd_a
        mov 3, %o0
        EXPECT(%o0, 0, 9)
        mov 0, %o1
        call wr_a                       /* WR1, WR15 back to 0 */
        mov 1, %o0
        mov 0, %o1
        call wr_a
        mov 0x0f, %o0
END

        .section .rodata
s_ask:  .asciz "BRK?\n"

        .section .testtab, "a", @progbits
        .word 0, 0                      /* end of the test table */

        .section .romend, "a", @progbits
        .align 4
        .globl rom_end
rom_end:
