/* main_chipset.S: only the chipset tests (t_chipset.S), for a quick run on
 * the whole-machine simulation: python3 tests/cpu/build.py ss20
 * --main=main_chipset → out/ss20/main_chipset.rom. */
#include "runtime.S"
        .text
#include "t_chipset.S"

        .section .testtab, "a", @progbits
        .word 0, 0                      /* end of the test table */

        .section .romend, "a", @progbits
        .align 4
        .globl rom_end
rom_end:
