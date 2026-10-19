/* perfbench: CPI microbenchmarks (tests/cpu/bench/bench.c, Dhrystone and
 * small kernels) run under the suite's runtime with the MMU on, cacheable,
 * out of boot mode, the way a user program runs: built by
 *     python3 tests/cpu/build.py ss20 --main=perfbench
 * (which compiles tests/cpu/bench/*.c with clang to gen/perfbench_c.s,
 * included below) and run in the simulation with +perf (and +promlog):
 *     sim/obj_ss20/Vsim_top --rom tests/cpu/out/ss20/perfbench.rom \
 *         --cycles 400M --stop "CPUTEST DONE" +perf > out.txt
 *     python3 tools/perfsplit.py out.txt 0
 * The ROM prints "M-NAME" before each kernel and "K NAME <iterations>
 * <ticks of 500 ns>" after it (hex). docs/benchmarks/profile-20261014.md
 * has the method and the NetBSD profile these stand in for. */
#include "runtime.S"
#include "mmu_setup.S"

BEGIN(t_perfbench, "perfbench: Dhrystone and the CPI kernels, MMU on, cacheable")
        call mmu_tables_init
        nop
        call mmu_on
        nop
        rd %psr, %l0                    /* the FPU on for the FP kernel */
        set 0x1000, %l1
        or %l0, %l1, %l1
        wr %l1, %psr
        nop ; nop ; nop
        call bench_main
        nop
        wr %l0, %psr
        nop ; nop ; nop
        call mmu_off
        nop
END

        .text
#include "gen/perfbench_c.s"

        .section .testtab, "a", @progbits
        .word 0, 0                      /* end of the test table */

        .section .romend, "a", @progbits
        .align 4
        .globl rom_end
rom_end:
