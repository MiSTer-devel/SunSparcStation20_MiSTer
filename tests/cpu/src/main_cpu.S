/* main_cpu.S: the phase-3 build of the suite for sim/cpu: everything in
 * main.S except the chipset, MSI and SMP tests (no chipset or second CPU
 * in the harness). Tests run in the order they are included. */
#include "runtime.S"
#include "gen/cond_tab.S"
#include "gen/alu_vec.S"
#include "t_alu.S"
#include "t_ldst.S"
#include "t_branch.S"
#include "t_traps.S"
#include "t_window.S"
#include "t_psr.S"
#include "t_mmu_swift.S"
#include "t_cache.S"
#include "t_fpu.S"
#include "mmu_setup.S"
#include "t_mmu.S"
#include "t_cache2.S"
#include "t_cache3.S"
#include "t_iu2.S"
#include "t_dcti.S"
#include "t_mmu_diag.S"
#include "t_mmu_l2.S"
#include "t_cache_diag.S"
#include "t_cache_force.S"
#include "t_buserr.S"
#include "t_dma.S"

        .section .testtab, "a", @progbits
        .word 0, 0                      /* end of the test table */

        .section .romend, "a", @progbits
        .align 4
        .globl rom_end
rom_end:
