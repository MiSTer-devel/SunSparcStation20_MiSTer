/* wdtest: error mode and the watchdog reset (docs/impl-gaps/cpu.md IU-1,
 * PLAN.md B3), built apart from the suite
 * (python3 tests/cpu/build.py ss20 --main=wdtest, out/ss20/wdtest.rom)
 * because the test ends in a reset of the whole machine, which the suite
 * would not survive.
 *
 * A trap taken with PSR.ET = 0 puts a SPARC V8 IU in error mode: it stops
 * for good. On sun4m the module turns that into a watchdog reset: the
 * system resets with memory, caches and TLBs kept, the system status
 * register (pa 0xf_f1f0_0000 on the SS20, 0x7_1f00_0000 on the SS5) reads
 * WD (bit 4), and a SuperSPARC reports it in SFSR bit 17 (EM, "Error Mode
 * Reset Taken", cleared when the SFSR is read; Sun-4M B.I.4.4). OBP 2.25
 * tests EM first thing at its reset entry and prints "Watchdog Reset".
 *
 * The ROM runs twice. First boot (EM clear on the SS20, WD clear on the
 * SS5): it leaves a marker in SCRATCH, prints "WD?", clears ET and does a
 * ta; the CPU is now in error mode and prints nothing more (the line
 * after the ta is a failure). The watchdog reset restarts the machine and
 * the ROM: second boot (EM set / WD set): EM and WD are checked, the
 * marker shows memory was kept, a read of the SFSR clears EM, PASS and
 * CPUTEST DONE.
 *
 * Simulation: sim/obj_ss20/Vsim_top --rom tests/cpu/out/ss20/wdtest.rom
 *                 --stop 'CPUTEST DONE' --fail 'ran on' --cycles 20M
 * Without the chipset's watchdog reset the run stops after "WD?" (the
 * CPU is in error mode; on the board, pcdump shows halterror 1 on CPU 0
 * with hetrap tt ff) and never prints CPUTEST DONE. */
#include "runtime.S"

        .text

#if defined(TARGET_SS20)
#  define SYSCON_PA     0xf1f00000      /* ASI 0x2f: pa 0xf_f1f0_0000 */
#  define SYSCON_ASI    0x2f
#else
#  define SYSCON_PA     0x71f00000
#  define SYSCON_ASI    0x20
#endif
#define WD_MARK         (SCRATCH + 0x1000)
#define WD_MAGIC        0x57444f47      /* 'WDOG' */
#define SFSR_EM         0x00020000

BEGIN(t_wdog, "wdog: error mode (a trap with ET = 0) comes back as a watchdog reset: SFSR EM, system status WD, memory kept, EM cleared by the read")
#if defined(TARGET_SS20)
        set 0x1300, %l0
        lda [%l0] 4, %l1                /* the SFSR through its non-clearing alias (Viking §4.11.11.3) */
        set SFSR_EM, %l2
        andcc %l1, %l2, %g0
        be first_boot
        nop
#else
        set SYSCON_PA, %l0
        lda [%l0] SYSCON_ASI, %l1
        andcc %l1, 0x10, %g0            /* WD */
        be first_boot
        nop
#endif
        /* second boot, after the watchdog reset */
        set SYSCON_PA, %l0
        lda [%l0] SYSCON_ASI, %l1
        and %l1, 0x10, %l1
        EXPECT(%l1, 0x10, 1)            /* system status WD */
        set WD_MARK, %l0
        ld [%l0], %l1
        EXPECT(%l1, WD_MAGIC, 2)        /* memory kept across the reset */
        st %g0, [%l0]
#if defined(TARGET_SS20)
        mov 0x300, %l0
        lda [%l0] 4, %l1                /* the read clears the SFSR */
        set SFSR_EM, %l2
        and %l1, %l2, %l1
        EXPECT(%l1, SFSR_EM, 3)         /* EM was set */
        set 0x1300, %l0
        lda [%l0] 4, %l1
        and %l1, %l2, %l1
        EXPECT(%l1, 0, 4)               /* and the read cleared it */
#endif
        END

first_boot:
        set WD_MARK, %l0
        set WD_MAGIC, %l1
        st %l1, [%l0]
        set s_wd, %o0
        call puts
        nop
        rd %psr, %l0
        andn %l0, PSR_ET, %l0
        wr %l0, %psr                    /* traps off */
        nop ; nop ; nop
        ta 0x7f                         /* a trap with ET = 0: error mode */
        nop
        /* not reached: the CPU is stopped until the watchdog reset */
        or %l0, PSR_ET, %l0
        wr %l0, %psr
        nop ; nop ; nop
        set s_ranon, %o0
        call puts
        nop
        EXPECT(%g0, 1, 5)               /* ran on after the trap */
        END

        .section .rodata
s_wd:   .asciz "WD? error mode on CPU 0 (ta with ET = 0): expecting the watchdog reset\n"
s_ranon: .asciz "the CPU ran on after the trap with ET = 0\n"
        .text

        .section .testtab, "a", @progbits
        .word 0, 0

        .section .romend, "a", @progbits
        .align 4
        .globl rom_end
rom_end:
