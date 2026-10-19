/* The integer-unit subset of the suite (docs/VERILOG-PLAN.md phase 1), for
 * the IU harness sim/iu/: the tests that need no MMU, caches, FPU or
 * chipset beyond ttya. Built with build.py --main=main_iu. */
#include "runtime.S"
#include "gen/cond_tab.S"
#include "gen/alu_vec.S"
#include "t_alu.S"
#include "t_ldst.S"
#include "t_branch.S"
#include "t_traps.S"
#include "t_window.S"
#include "t_psr.S"
#include "t_fpu.S"
#include "mmu_setup.S"              /* not a test: the MMU-on setup t_dcti and t_iu2 use */
#include "t_iu2.S"
#include "t_dcti.S"
        .section .testtab, "a", @progbits
        .word 0, 0                      /* end of the test table */
        .section .romend, "a", @progbits
        .align 4
        .globl rom_end
rom_end:
