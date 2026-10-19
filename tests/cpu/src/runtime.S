/* Runtime of the bare-metal CPU test suite: trap table, reset, window
 * spill/fill, trap catcher, ttya output, test runner.
 *
 * Output (ttya, 9600 8N1):
 *     CPUTEST <target> psr=<hex> nwindows=<n> fpu=<0|1>
 *     PASS <name> | FAIL <name> | SKIP <name>
 *         check <code> exp=<hex> obs=<hex>        (under a FAIL, up to 16)
 *         unexpected trap tt=<hex> pc=<hex>
 *     CPUTEST DONE pass=<n> fail=<n> skip=<n>
 */
#include "platform.h"
#include "macros.h"

#ifndef DETAIL_LIMIT
#define DETAIL_LIMIT 16     /* detail lines per failing test */
#endif

        .section .text
        .globl trap_table
trap_table:
        /* tt 0x00: reset. Execution starts here, in boot mode. */
        sethi %hi(reset), %l4
        jmp %l4 + %lo(reset)
        nop
        nop
        /* tt 0x01-0xff: every vector goes to trap_common, which reads the
         * trap type back from %tbr */
        .rept 255
        sethi %hi(trap_common), %l4
        jmp %l4 + %lo(trap_common)
        rd %psr, %l0
        nop
        .endr

/* ------------------------------------------------------------------ */
reset:
#if defined(TARGET_SS20)
        /* Every CPU leaves reset and starts here: the core has no MP
         * start/stop control yet. Only CPU 0 runs the suite; the others
         * park. The core reports the CPU number in MMU control register
         * bits 3:2 (reserved on a real SuperSPARC).
         * QEMU starts the secondary CPUs halted, and CPU 0 reads 0 there. */
        lda [%g0] 4, %l0
        srl %l0, 2, %l0
        andcc %l0, 3, %l0
        bne mp_park
        nop
#endif
        wr %g0, (PSR_S | PSR_PS | PSR_PIL_MASK), %psr   /* ET=0 CWP=0 */
        nop ; nop ; nop
        wr %g0, 0, %wim
        nop ; nop ; nop
        set trap_table, %g1
        wr %g1, %tbr
        nop ; nop ; nop

#if SHADOW_ROM
        /* copy the PROM image to RAM at pa 0 so its constants can be read
         * at their link addresses (see platform.h) */
        set ROM_PA_LOW, %g1
        set rom_end, %g2
        clr %g3
1:      lda [%g1 + %g3] IO_ASI, %g4
        st %g4, [%g3]
        add %g3, 4, %g3
        cmp %g3, %g2
        blu 1b
        nop
#endif

        set VARS, %g7
        clr %g1
2:      st %g0, [%g7 + %g1]
        add %g1, 4, %g1
        cmp %g1, V_SIZE
        bl 2b
        nop
        mov -1, %g1
        st %g1, [%g7 + V_TRAP_EXPECT]
        st %g1, [%g7 + V_TRAP_SEEN]
        st %g1, [%g7 + V_UNEXP_TT]
        rd %psr, %g1
        st %g1, [%g7 + V_PSR0]

        /* number of windows: WIM bits that stick */
        wr %g0, -1, %wim
        nop ; nop ; nop
        rd %wim, %g1
        clr %g2
3:      andcc %g1, 1, %g0
        bne,a 4f
        add %g2, 1, %g2
4:      srl %g1, 1, %g1
        tst %g1
        bne 3b
        nop
        st %g2, [%g7 + V_NWINDOWS]
        wr %g0, 2, %wim                 /* CWP=0, window 1 invalid */
        nop ; nop ; nop

        /* FPU present if PSR.EF sticks */
        rd %psr, %g1
        set PSR_EF, %g2
        or %g1, %g2, %g1
        wr %g1, %psr
        nop ; nop ; nop
        rd %psr, %g1
        andcc %g1, %g2, %g0
        be 5f
        nop
        mov 1, %g3
        st %g3, [%g7 + V_FPU]
        ld [%g7 + V_SKIP], %fsr         /* FSR = 0 (V_SKIP is 0 here) */
5:
        set STACK_TOP, %sp
        clr %fp
        rd %psr, %g1
        or %g1, PSR_ET, %g1             /* traps on, PIL stays 15 */
        wr %g1, %psr
        nop ; nop ; nop

        call uart_init
        nop
        call run_tests
        nop
halt:   ba halt
        nop

#if defined(TARGET_SS20)
/* CPU n (1-3, in %l0) parks here. Forever, it copies the MSI MID register
 * into MP_MID + 4n and increments MP_COUNT + 4n, uncached (MMU off, caches
 * off), so every iteration is MBus traffic (t_msi.S watches it), and it
 * polls its mailbox MP_CMD + 0x10n: a non-zero FN word is a function to
 * call with ARG0/ARG1 in %o0/%o1; its %o0 goes to RES and FN is cleared
 * last. The function runs in boot mode with the MMU off, PSR.ET = 0 and
 * no stack: leaf code, any register but %g7, a trap is error mode. It may
 * turn its own MMU and caches on (mmu_on/mmu_off in mmu_setup.S). The
 * loop recomputes its pointers from the CPU number every iteration, so
 * the function may clobber them. */
mp_park:
1:      lda [%g0] 4, %l0                /* MCNTL bits 3:2: the CPU number */
        srl %l0, 2, %l0
        and %l0, 3, %l0
        sll %l0, 2, %l0                 /* 4n */
        set MP_MID, %l1
        add %l1, %l0, %l1
        set MP_COUNT, %l2
        add %l2, %l0, %l2
        set MSI_MID_PA, %l3
        lda [%l3] 0x2f, %l4
        sta %l4, [%l1] 0x20
        lda [%l2] 0x20, %l4
        add %l4, 1, %l4
        sta %l4, [%l2] 0x20
        sll %l0, 2, %l5                 /* 16n */
        set MP_CMD, %l6
        add %l6, %l5, %l6
        lda [%l6] 0x20, %l7             /* FN */
        tst %l7
        be 1b
        nop
        add %l6, MP_CMD_ARG0, %l1
        lda [%l1] 0x20, %o0
        add %l6, MP_CMD_ARG1, %l1
        lda [%l1] 0x20, %o1
        call %l7
        nop
        add %l6, MP_CMD_RES, %l1
        sta %o0, [%l1] 0x20
        sta %g0, [%l6] 0x20             /* done */
        ba 1b
        nop

/* CPU 0 side of the dispatcher. Leaf routines, %o0-%o5 only. */
/* mp_post(n %o0, fn %o1, arg0 %o2, arg1 %o3): post a call to CPU n */
        .globl mp_post
mp_post:
        sll %o0, 4, %o0
        set MP_CMD, %o4
        add %o4, %o0, %o4
        add %o4, MP_CMD_ARG0, %o5
        sta %o2, [%o5] 0x20
        add %o4, MP_CMD_ARG1, %o5
        sta %o3, [%o5] 0x20
        retl
        sta %o1, [%o4] 0x20             /* FN last: starts the call */

/* mp_wait(n %o0): wait until CPU n has cleared FN, MP_WAIT_POLLS at most.
 * Returns %o0 = RES, %o1 = 0, or %o1 = 1 when it timed out. */
        .globl mp_wait
mp_wait:
        sll %o0, 4, %o0
        set MP_CMD, %o4
        add %o4, %o0, %o4
        set MP_WAIT_POLLS, %o3
1:      lda [%o4] 0x20, %o2
        tst %o2
        be 2f
        mov 0, %o1
        subcc %o3, 1, %o3
        bne 1b
        nop
        mov 1, %o1
2:      add %o4, MP_CMD_RES, %o4
        retl
        lda [%o4] 0x20, %o0

/* mp_alive(n %o0): %o0 = 1 when CPU n's park counter moves during a short
 * delay (QEMU keeps the secondary CPUs halted: 0 there) */
        .globl mp_alive
mp_alive:
        sll %o0, 2, %o0
        set MP_COUNT, %o1
        add %o1, %o0, %o1
        lda [%o1] 0x20, %o2
        set 2000, %o3
1:      subcc %o3, 1, %o3
        bne 1b
        nop
        lda [%o1] 0x20, %o0
        sub %o0, %o2, %o0
        subcc %g0, %o0, %g0             /* carry = moved */
        retl
        addx %g0, 0, %o0
#endif

/* ------------------------------------------------------------------ */
/* Trap entry: %l0 = PSR, %l1 = PC, %l2 = nPC, ET = 0, in the trap
 * window. Only locals and %g7 are used: the trap window can be the
 * invalid window, whose outs are the ins of the oldest live window. */
trap_common:
        rd %tbr, %l3
        srl %l3, 4, %l3
        and %l3, 0xff, %l3
        cmp %l3, TT_WIN_OVF
        be window_overflow
        nop
        cmp %l3, TT_WIN_UNF
        be window_underflow
        nop
        cmp %l3, TT_TICC(SVC_SUPER)
        be trap_svc_super
        nop
        ld [%g7 + V_IRQ_MODE], %l4
        tst %l4
        be 1f
        cmp %l3, 0x11
        bl 1f
        cmp %l3, 0x1f
        bg 1f
        nop
        /* a counted interrupt: acknowledge the harness source (pa
         * 0xe_0000_101c), resume the interrupted instruction */
        ld [%g7 + V_IRQ_COUNT], %l4
        add %l4, 1, %l4
        st %l4, [%g7 + V_IRQ_COUNT]
        set 0x101c, %l4
        sta %g0, [%l4] 0x2e
        wr %l0, %psr
        nop ; nop ; nop
        jmp %l1
        rett %l2
1:      ld [%g7 + V_TRAPS], %l4
        add %l4, 1, %l4
        st %l4, [%g7 + V_TRAPS]
        ld [%g7 + V_TRAP_EXPECT], %l4
        cmp %l4, %l3
        bne trap_unexpected
        nop
        st %l3, [%g7 + V_TRAP_SEEN]
        st %l1, [%g7 + V_TRAP_PC]
        st %l2, [%g7 + V_TRAP_NPC]
        st %l0, [%g7 + V_TRAP_PSR]
        mov -1, %l4
        st %l4, [%g7 + V_TRAP_EXPECT]
        ld [%g7 + V_TRAP_RESUME], %l4
        tst %l4
        be trap_skip
        nop
        /* an instruction fault: the next instruction is on the same
         * page, so resume where the test asked (V_TRAP_RESUME) */
        st %g0, [%g7 + V_TRAP_RESUME]
        wr %l0, %psr
        nop ; nop ; nop
        jmp %l4
        rett %l4 + 4
trap_svc_super:
        /* ta SVC_SUPER: resume after it in supervisor mode. The rett below
         * restores S from PS, so set PS. */
        or %l0, PSR_PS, %l0
        ba trap_skip
        nop
trap_unexpected:
        st %l3, [%g7 + V_UNEXP_TT]
        st %l1, [%g7 + V_UNEXP_PC]
        ld [%g7 + V_TEST_FAILS], %l4
        add %l4, 1, %l4
        st %l4, [%g7 + V_TEST_FAILS]
        /* an interrupt arrives between instructions: resume at PC */
        cmp %l3, 0x11
        bl trap_skip
        nop
        cmp %l3, 0x1f
        bg trap_skip
        nop
        wr %l0, %psr
        nop ; nop ; nop
        jmp %l1
        rett %l2
trap_skip:
        /* resume after the trapping instruction (restores the icc) */
        wr %l0, %psr
        nop ; nop ; nop
        jmp %l2
        rett %l2 + 4

/* Window overflow (tt 5) and underflow (tt 6), 8 windows. The classic
 * handlers (as in RTEMS): rotate WIM, spill/fill the 16 registers of the
 * window at its %sp, re-execute the save/restore. */
window_overflow:
        mov %wim, %l3
        mov %g1, %l7
        srl %l3, 1, %g1
        sll %l3, 7, %l4
        or %l4, %g1, %g1
        and %g1, 0xff, %g1
        mov %g0, %wim
        nop ; nop ; nop
        save
        std %l0, [%sp + 0x00]
        std %l2, [%sp + 0x08]
        std %l4, [%sp + 0x10]
        std %l6, [%sp + 0x18]
        std %i0, [%sp + 0x20]
        std %i2, [%sp + 0x28]
        std %i4, [%sp + 0x30]
        std %i6, [%sp + 0x38]
        restore
        mov %g1, %wim
        nop ; nop ; nop
        mov %l7, %g1
        ld [%g7 + V_WIN_OVF], %l4
        add %l4, 1, %l4
        st %l4, [%g7 + V_WIN_OVF]
        wr %l0, %psr
        nop ; nop ; nop
        jmp %l1
        rett %l2

window_underflow:
        mov %wim, %l3
        sll %l3, 1, %l4
        srl %l3, 7, %l5
        or %l5, %l4, %l5
        and %l5, 0xff, %l5
        mov %l5, %wim
        nop ; nop ; nop
        restore
        restore
        ldd [%sp + 0x00], %l0
        ldd [%sp + 0x08], %l2
        ldd [%sp + 0x10], %l4
        ldd [%sp + 0x18], %l6
        ldd [%sp + 0x20], %i0
        ldd [%sp + 0x28], %i2
        ldd [%sp + 0x30], %i4
        ldd [%sp + 0x38], %i6
        save
        save
        ld [%g7 + V_WIN_UNF], %l4
        add %l4, 1, %l4
        st %l4, [%g7 + V_WIN_UNF]
        wr %l0, %psr
        nop ; nop ; nop
        jmp %l1
        rett %l2

/* ------------------------------------------------------------------ */
/* ttya: Z85C30 channel A, 9600 8N1 x16 from the BRG, PCLK 4.9152 MHz */
        .globl uart_init
uart_init:
        set TTYA_CTRL, %o1
        set uart_init_seq, %o2
1:      ldub [%o2], %o3
        cmp %o3, 0xff
        be 3f
        nop
        stba %o3, [%o1] IO_ASI
        mov 64, %o4                     /* Z8530 write recovery time */
2:      subcc %o4, 1, %o4
        bne 2b
        nop
        ba 1b
        add %o2, 1, %o2
3:      retl
        nop

        .globl putc
putc:   /* %o0 = character; waits for Tx buffer empty (RR0 bit 2), with a
         * timeout so a missing model cannot hang the suite */
        set TTYA_CTRL, %o1
        set 200000, %o3
1:      lduba [%o1] IO_ASI, %o2
        andcc %o2, 4, %g0
        bne 2f
        nop
        subcc %o3, 1, %o3
        bne 1b
        nop
2:      set TTYA_DATA, %o1
        retl
        stba %o0, [%o1] IO_ASI

        .globl puts
puts:   /* %o0 = NUL-terminated string; "\n" is sent as CR LF */
        save %sp, -96, %sp
1:      ldub [%i0], %l0
        tst %l0
        be 3f
        nop
        cmp %l0, 10
        bne 2f
        nop
        call putc
        mov 13, %o0
2:      call putc
        mov %l0, %o0
        ba 1b
        add %i0, 1, %i0
3:      ret
        restore

        .globl puthex
puthex: /* %o0 = value, printed as 8 hex digits */
        save %sp, -96, %sp
        mov 28, %l0
1:      srl %i0, %l0, %l1
        and %l1, 0xf, %l1
        cmp %l1, 10
        bl 2f
        add %l1, '0', %o0
        add %l1, 'a' - 10, %o0
2:      call putc
        nop
        subcc %l0, 4, %l0
        bge 1b
        nop
        ret
        restore

        .globl putdec
putdec: /* %o0 = unsigned value in decimal, by repeated subtraction so it
         * does not depend on the divide instructions under test */
        save %sp, -96, %sp
        set pow10, %l0
        clr %l2                         /* a digit has been printed */
1:      ld [%l0], %l1
        tst %l1
        be 4f
        nop
        clr %l3
2:      cmp %i0, %l1
        blu 3f
        nop
        sub %i0, %l1, %i0
        ba 2b
        add %l3, 1, %l3
3:      orcc %l3, %l2, %g0
        be 5f
        nop
        mov 1, %l2
        call putc
        add %l3, '0', %o0
5:      ba 1b
        add %l0, 4, %l0
4:      call putc
        add %i0, '0', %o0
        ret
        restore

/* check_eq(code %o0, obs %o1, exp %o2): count and report a mismatch */
        .globl check_eq
check_eq:
        save %sp, -96, %sp
        cmp %i1, %i2
        be 1f
        nop
        ld [%g7 + V_TEST_FAILS], %l0
        add %l0, 1, %l0
        st %l0, [%g7 + V_TEST_FAILS]
        ld [%g7 + V_DETAILS], %l0
        cmp %l0, DETAIL_LIMIT
        bge 1f
        add %l0, 1, %l0
        st %l0, [%g7 + V_DETAILS]
        set s_check, %o0
        call puts
        nop
        call puthex
        mov %i0, %o0
        set s_exp, %o0
        call puts
        nop
        call puthex
        mov %i2, %o0
        set s_obs, %o0
        call puts
        nop
        call puthex
        mov %i1, %o0
        set s_nl, %o0
        call puts
        nop
1:      ret
        restore

/* ------------------------------------------------------------------ */
run_tests:
        save %sp, -96, %sp
        set s_banner, %o0
        call puts
        nop
        set s_target, %o0
        call puts
        nop
        set s_psr, %o0
        call puts
        nop
        call puthex
        ld [%g7 + V_PSR0], %o0
        set s_nwin, %o0
        call puts
        nop
        call putdec
        ld [%g7 + V_NWINDOWS], %o0
        set s_fpu, %o0
        call puts
        nop
        call putdec
        ld [%g7 + V_FPU], %o0
        set s_nl, %o0
        call puts
        nop

        set test_table, %l0
1:      ld [%l0], %l1                   /* name */
        tst %l1
        be 9f
        nop
        ld [%l0 + 4], %l2               /* entry */
        st %g0, [%g7 + V_TEST_FAILS]
        st %g0, [%g7 + V_DETAILS]
        st %g0, [%g7 + V_SKIP]
        mov -1, %l3
        st %l3, [%g7 + V_TRAP_EXPECT]
        st %l3, [%g7 + V_TRAP_SEEN]
        st %l3, [%g7 + V_UNEXP_TT]
        call %l2
        nop
        ld [%g7 + V_SKIP], %l3
        tst %l3
        bne 6f
        nop
        ld [%g7 + V_TEST_FAILS], %l3
        tst %l3
        bne 5f
        nop
        set s_pass, %o0
        ld [%g7 + V_PASS], %l3
        add %l3, 1, %l3
        ba 7f
        st %l3, [%g7 + V_PASS]
5:      set s_fail, %o0
        ld [%g7 + V_FAIL], %l3
        add %l3, 1, %l3
        ba 7f
        st %l3, [%g7 + V_FAIL]
6:      set s_skip, %o0
        ld [%g7 + V_SKIP_COUNT], %l3
        add %l3, 1, %l3
        st %l3, [%g7 + V_SKIP_COUNT]
7:      call puts
        nop
        call puts
        mov %l1, %o0
        set s_nl, %o0
        call puts
        nop
        ld [%g7 + V_UNEXP_TT], %l3
        cmp %l3, -1
        be 8f
        nop
        set s_unexp, %o0
        call puts
        nop
        call puthex
        mov %l3, %o0
        set s_at, %o0
        call puts
        nop
        call puthex
        ld [%g7 + V_UNEXP_PC], %o0
        set s_nl, %o0
        call puts
        nop
8:      ba 1b
        add %l0, 8, %l0

9:      set s_done, %o0
        call puts
        nop
        call putdec
        ld [%g7 + V_PASS], %o0
        set s_dfail, %o0
        call puts
        nop
        call putdec
        ld [%g7 + V_FAIL], %o0
        set s_dskip, %o0
        call puts
        nop
        call putdec
        ld [%g7 + V_SKIP_COUNT], %o0
        set s_nl, %o0
        call puts
        nop
        ret
        restore

        .section .rodata
        .align 4
pow10:  .word 1000000000, 100000000, 10000000, 1000000, 100000, 10000
        .word 1000, 100, 10, 0
uart_init_seq:
        /* register, value pairs for WR0 pointer writes; 0xff ends */
        .byte 9, 0x80                   /* channel A reset */
        .byte 4, 0x44                   /* x16 clock, 1 stop, no parity */
        .byte 3, 0xc0                   /* Rx 8 bits, disabled */
        .byte 5, 0x60                   /* Tx 8 bits, disabled */
        .byte 10, 0x00                  /* NRZ */
        .byte 11, 0x50                  /* Rx/Tx clocks from the BRG */
        .byte 12, 14, 13, 0             /* time constant: 9600 baud */
        .byte 14, 0x02                  /* BRG source PCLK */
        .byte 14, 0x03                  /* BRG on */
        .byte 3, 0xc1                   /* Rx on */
        .byte 5, 0xea                   /* Tx on, 8 bits, DTR, RTS */
        .byte 0xff
s_banner: .asciz "\nCPUTEST "
#if defined(TARGET_SS5_QEMU)
s_target: .asciz "ss5-qemu"
#else
s_target: .asciz "ss20"
#endif
s_psr:  .asciz " psr="
s_nwin: .asciz " nwindows="
s_fpu:  .asciz " fpu="
s_nl:   .asciz "\n"
s_pass: .asciz "PASS "
s_fail: .asciz "FAIL "
s_skip: .asciz "SKIP "
s_check: .asciz "    check "
s_exp:  .asciz " exp="
s_obs:  .asciz " obs="
s_unexp: .asciz "    unexpected trap tt="
s_at:   .asciz " pc="
s_done: .asciz "CPUTEST DONE pass="
s_dfail: .asciz " fail="
s_dskip: .asciz " skip="

        .section .testtab, "a", @progbits
        .align 4
        .globl test_table
test_table:
