/* mousetest: the Sun mouse as the machine sees it, built apart from the
 * suite (python3 tests/cpu/build.py ss20 --main=mousetest) and driven from
 * the MiSTer with a virtual mouse (scripts/board/uinput_mouse.py): its
 * moves and clicks reach the core as PS/2 packets through Main, go through
 * sun_mouse and arrive on the keyboard ESCC's channel B (the mouse port),
 * which this ROM polls.
 *
 * It prints "MS?", then every byte received, in hex, until 3 s pass with
 * nothing (the first within 30 s), at most 400 bytes. A Sun (Mouse Systems)
 * packet is 5 bytes: 0x80 | ~{L,M,R} (0x87 with no button down), dx1, dy1,
 * dx2, dy2. There is nothing to check in simulation (no PS/2 mouse there). */
#include "runtime.S"

        .text

#define MS_CTRL         0xf1000000      /* ASI 0x2f: pa 0xf_f100_0000, channel B */
#define MS_DATA         (MS_CTRL + 2)
/* waits timed on the system counter (pa 0xf_f131_0004, 500 ns ticks in bits
 * 30:9): this ROM runs in boot mode, where loops are no measure of time */
#define SYS_CTR         0xf1310004
#define TICKS_1S        2000000

/* write mouse channel register %o0 with %o1 */
mwr:    set MS_CTRL, %o2
        stba %o0, [%o2] IO_ASI
        retl
        stba %o1, [%o2] IO_ASI

/* %o0 = the next byte from the mouse, or -1 after %o0 counter ticks */
mget:   set MS_CTRL, %o2
        set SYS_CTR, %o3
        lda [%o3] IO_ASI, %o4
1:      lduba [%o2] IO_ASI, %o1         /* RR0 */
        andcc %o1, 1, %g0
        bne 2f
        nop
        lda [%o3] IO_ASI, %o5
        sub %o5, %o4, %o1
        mov %o5, %o4
        srl %o1, 9, %o1
        set 0x3fffff, %o5
        and %o1, %o5, %o1
        subcc %o0, %o1, %o0
        bg 1b
        nop
        retl
        mov -1, %o0
2:      set MS_DATA, %o2
        retl
        lduba [%o2] IO_ASI, %o0

/* print %o0's low byte as two hex digits */
puthex8: save %sp, -96, %sp
        srl %i0, 4, %o0
        and %o0, 0xf, %o0
        cmp %o0, 10
        bl 1f
        add %o0, '0', %l0
        add %o0, 'a' - 10, %l0
1:      call putc
        mov %l0, %o0
        and %i0, 0xf, %o0
        cmp %o0, 10
        bl 2f
        add %o0, '0', %l0
        add %o0, 'a' - 10, %l0
2:      call putc
        mov %l0, %o0
        ret
        restore

BEGIN(t_mouse_dump, "mouse: the bytes the mouse port receives")
        mov 0xc1, %o1                   /* WR3: 8 bits, receiver on */
        call mwr
        mov 3, %o0
        mov 0x68, %o1                   /* WR5: 8 bits, transmitter on */
        call mwr
        mov 5, %o0
        clr %o1                         /* WR1: no interrupts */
        call mwr
        mov 1, %o0
1:      call mget                       /* drop anything already there */
        mov 100, %o0
        tst %o0
        bge 1b
        nop
        set s_ask, %o0
        call puts
        nop
        clr %l0                         /* bytes printed */
        set 30 * TICKS_1S, %l1          /* the first byte's wait */
2:      call mget
        mov %l1, %o0
        tst %o0
        bl 9f
        nop
        call puthex8
        nop
        set s_sp, %o0
        call puts
        nop
        add %l0, 1, %l0
        and %l0, 15, %o0
        tst %o0
        bne 3f
        nop
        set s_nl, %o0
        call puts
        nop
3:      set 3 * TICKS_1S, %l1
        cmp %l0, 400
        bl 2b
        nop
9:      set s_nl, %o0
        call puts
        nop
END

        .section .rodata
s_ask:  .asciz "MS?\n"
s_sp:   .asciz " "

        .section .testtab, "a", @progbits
        .word 0, 0                      /* end of the test table */

        .section .romend, "a", @progbits
        .align 4
        .globl rom_end
rom_end:
