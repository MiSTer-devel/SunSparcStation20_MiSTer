/* tlbbench: what a D-TLB miss costs, built apart from the suite and run in
 * the simulation, once per page count:
 *     python3 tests/cpu/build.py ss20 --main=tlbbench -DTB_PAGES=K
 *     sim/obj_ss20/Vsim_top --rom tests/cpu/out/ss20/tlbbench.rom \
 *         --stop "CPUTEST DONE" --cycles 200M
 * MMU and caches on; TB_ITER passes over TB_PAGES pages of MT_SEG
 * (identity, cacheable), one load a page. The loads hit the D-cache, so a
 * pass costs a few cycles a page while the pages fit in the D-TLB; past
 * its entries every load walks the page tables. Compare the cycle counts
 * the simulation prints at the stop for K = 1..8. -DTB_L2TLB sets MCNTL
 * bit 6 for the core's second-level TLB (with the simulation's --l2tlb). */
#include "runtime.S"
#include "mmu_setup.S"

#ifndef TB_PAGES
#define TB_PAGES        1
#endif
#ifndef TB_ITER
#define TB_ITER         4096
#endif

BEGIN(t_tlbbench, "tlbbench: TB_ITER passes, one load on each of TB_PAGES pages")
        call mmu_tables_init
        nop
        call mmu_on
        nop
#ifdef TB_L2TLB
        lda [%g0] 0x04, %o0             /* MCNTL bit 6: the core's L2 TLB */
        or %o0, 0x40, %o0               /* (also needs the OSD option: */
        sta %o0, [%g0] 0x04             /* the simulation's --l2tlb) */
        nop ; nop ; nop
#endif
        set TB_ITER, %l0
        sethi %hi(0x1000), %l4          /* the page stride */
1:      set MT_PAGE(0), %l1
        mov TB_PAGES, %l2
2:      ld [%l1], %l3
        subcc %l2, 1, %l2
        bne 2b
        add %l1, %l4, %l1
        subcc %l0, 1, %l0
        bne 1b
        nop
        call mmu_off
        nop
END

        .section .testtab, "a", @progbits
        .word 0, 0                      /* end of the test table */

        .section .romend, "a", @progbits
        .align 4
        .globl rom_end
rom_end:
