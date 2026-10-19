/* SS20 MSI (MBus-to-SBus interface): the IOMMU's IMPL/VER, the MID
 * register (the MBus ID of the master doing the access) and the arbiter
 * enable register, which the Sun OBP 2.25 uses to identify, park and
 * release CPUs (docs/impl-gaps/chipset.md IOM-1, IOM-2; cpu.md SMP-1,
 * SMP-2; Sun-4M System Architecture 5.1.2, 5.4.3). The secondary CPUs run
 * mp_park (runtime.S); QEMU keeps them halted, so the MP test skips there.
 * Physical addresses through ASI 0x2f (pa 0xf_xxxx_xxxx) and 0x20 (RAM). */
#include "macros.h"

#if defined(TARGET_SS20)

BEGIN(t_msi_regs, "chipset: SS20 MSI: IOMMU IMPL/VER 0x13, MID 8, arbiter enable")
        set IOMMU_CTRL_PA, %l0
        lda [%l0] 0x2f, %l1
        srl %l1, 24, %l1
        EXPECT(%l1, 0x13, 1)
        set MSI_MID_PA, %l0
        lda [%l0] 0x2f, %l1
        and %l1, 0xf, %l1               /* QEMU also returns SBus bits */
        EXPECT(%l1, 8, 2)
        set MSI_ARB_PA, %l0
        lda [%l0] 0x2f, %l5             /* keep the reset value */
        set 0x801f000e, %l1             /* bit 0 (master 8) reads 1 */
        sta %l1, [%l0] 0x2f
        lda [%l0] 0x2f, %l1
        set 0x801f000f, %l2
        EXPECT_R(%l1, %l2, 3)
        mov 0xf, %l1
        sta %l1, [%l0] 0x2f
        lda [%l0] 0x2f, %l1
        EXPECT(%l1, 0xf, 4)
        sta %l5, [%l0] 0x2f
END

/* %o0 = how far CPU n's counter (MP_COUNT + 4n, n in %o0) moves during a
 * delay; leaf routine */
msi_moved:
        sll %o0, 2, %o0
        set MP_COUNT, %o1
        add %o1, %o0, %o1
        lda [%o1] 0x20, %o2
        set 2000, %o3
1:      subcc %o3, 1, %o3
        bne 1b
        nop
        lda [%o1] 0x20, %o0
        retl
        sub %o0, %o2, %o0

BEGIN(t_msi_mp, "chipset: SS20 MSI: each CPU reads its own MID; the arbiter parks CPU 1")
        call msi_moved
        mov 1, %o0
        tst %o0
        bne 1f
        nop
        SKIP_TEST                       /* CPU 1 is not running */
1:      set MP_MID + 4, %l0
        lda [%l0] 0x20, %l1
        and %l1, 0xf, %l1
        EXPECT(%l1, 9, 1)
        call msi_moved                  /* CPU 2: absent from a 2-CPU build */
        mov 2, %o0
        mov %o0, %l5
        tst %l5
        be 2f
        nop
        set MP_MID + 8, %l0
        lda [%l0] 0x20, %l1
        and %l1, 0xf, %l1
        EXPECT(%l1, 10, 2)
2:
        set MSI_ARB_PA, %l3             /* disable master 9 (CPU 1) */
        mov 0xd, %l4
        sta %l4, [%l3] 0x2f
        call msi_moved                  /* it stalls on its next access */
        mov 1, %o0
        call msi_moved
        mov 1, %o0
        EXPECT(%o0, 0, 3)               /* CPU 1 stopped */
        tst %l5
        be 3f
        nop
        call msi_moved
        mov 2, %o0
        subcc %g0, %o0, %g0             /* carry = moved */
        addx %g0, 0, %l1
        EXPECT(%l1, 1, 4)               /* CPU 2 still runs */
3:
        mov 0xf, %l4                    /* enable it again */
        sta %l4, [%l3] 0x2f
        call msi_moved
        mov 1, %o0
        subcc %g0, %o0, %g0
        addx %g0, 0, %l1
        EXPECT(%l1, 1, 5)               /* CPU 1 runs again */
END

/* SIMM slot 7 (pa 0x1C00_0000-0x1FFF_FFFF): the top 48 MB of the core's
 * DDR hold the PROM image, the VRAM and the scaler buffers, so the slot
 * is a 16 MB SIMM that repeats every 16 MB (glue G6). Skips unless the
 * core's configuration register (ASI 4 va 0xd00, RAMSIZE in MB in bits
 * 31:20; 0 under QEMU) says the memory reaches slot 7. */
BEGIN(t_mem_slot7, "chipset: SS20 SIMM slot 7 is 16 MB, aliased every 16 MB")
        set 0xd00, %l0
        lda [%l0] 4, %l0
        srl %l0, 20, %l0
        cmp %l0, 0x1c0
        bgu 1f
        nop
        SKIP_TEST
1:      set 0x1c000000, %l0
        set 0x1d000000, %l1
        set 0x1e000000, %l2
        set 0x1f000000, %l3
        set 0x55555555, %l4
        sta %l4, [%l0] 0x20
        set 0xaaaaaaaa, %l5
        sta %l5, [%l1] 0x20             /* +16 MB lands on the base */
        lda [%l0] 0x20, %l6
        EXPECT_R(%l6, %l5, 1)
        set 0xdeadbeef, %l5
        sta %l5, [%l3] 0x20
        lda [%l2] 0x20, %l6
        EXPECT_R(%l6, %l5, 2)
        set ROM_PA_LOW, %l0             /* the PROM image is untouched */
        lda [%l0] IO_ASI, %l6
        lda [%g0] 0x20, %l7             /* its shadow copy at pa 0 */
        EXPECT_R(%l6, %l7, 3)
END

#endif
