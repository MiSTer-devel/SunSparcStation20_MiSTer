/* memstress: a board-only memory stress for the SS20, built apart from the
 * suite (python3 tests/cpu/build.py ss20 --main=memstress, out/ss20/
 * memstress.rom; it runs for minutes, far too long for the simulation).
 *
 * pa 0x0100_0000-0x1C00_0000 (432 MB: all of RAM above the suite's first
 * 16 MB, below the SIMM slot 7 fold) is mapped cacheable at VA pa +
 * 0x4000_0000 with level-1 PTEs, and split in three: CPUs 0, 1 and 2 each
 * test 144 MB at the same time, with their caches on (write-through on the
 * board), while the video scanout reads DDR. Each CPU writes a pattern
 * derived from the address and a seed, then reads every word back:
 *   pass 1  word stores                     pass 3  word stores, new seed
 *   pass 2  doubleword stores (std)         pass 4  byte stores (first 16 MB)
 * The CPU and DDR path alone (caches, smpmux, the DDR bridge and arbiter),
 * without an OS, MMU table changes or DMA. Written after Solaris and NetBSD
 * corrupted memory under disk I/O. */
#include "runtime.S"
#include "mmu_setup.S"

#if defined(TARGET_SS20)

#define MS_VA       0x40000000          /* VA = pa + MS_VA */
#define MS_LO       0x01000000
#ifndef MS_SPAN
#define MS_SPAN     0x09000000          /* 144 MB per CPU */
#endif
#ifndef MS_BYTES
#define MS_BYTES    0x01000000          /* the byte pass covers 16 MB */
#endif
#define MS_WAIT     40000               /* x 65536 polls before giving up */

/* ms_write(lo %o0, hi %o1, seed %o2, mode %o3): fill [lo, hi) with
 * va ^ seed; mode 0 words, 1 doublewords, 2 bytes; leaf, %g1-%g4 */
ms_write:
        mov %o0, %g1
        cmp %o3, 1
        be 2f
        nop
        cmp %o3, 2
        be 3f
        nop
1:      xor %g1, %o2, %g3
        st %g3, [%g1]
        add %g1, 4, %g1
        cmp %g1, %o1
        blu 1b
        nop
        retl
        nop
2:      xor %g1, %o2, %g2
        add %g1, 4, %g4
        xor %g4, %o2, %g3
        std %g2, [%g1]
        add %g1, 8, %g1
        cmp %g1, %o1
        blu 2b
        nop
        retl
        nop
3:      xor %g1, %o2, %g3
        srl %g3, 24, %g4
        stb %g4, [%g1]
        srl %g3, 16, %g4
        stb %g4, [%g1 + 1]
        srl %g3, 8, %g4
        stb %g4, [%g1 + 2]
        stb %g3, [%g1 + 3]
        add %g1, 4, %g1
        cmp %g1, %o1
        blu 3b
        nop
        retl
        nop

/* ms_check(lo %o0, hi %o1, seed %o2): word loads; %o0 = mismatches,
 * %o1 = the first bad VA (0: none), %o2 = the value read there; leaf */
ms_check:
        mov %o0, %g1
        clr %o4
        clr %o5
        clr %g2
1:      ld [%g1], %g3
        xor %g1, %o2, %g4
#ifdef MS_INJECT
        xor %g4, 0x100, %g4             /* self-test: every word mismatches */
#endif
        cmp %g3, %g4
        be 3f
        nop
        tst %o5
        bne 2f
        nop
        mov %g1, %o5
        mov %g3, %g2
2:      add %o4, 1, %o4
3:      add %g1, 4, %g1
        cmp %g1, %o1
        blu 1b
        nop
        mov %o4, %o0
        mov %o5, %o1
        retl
        mov %g2, %o2

/* ms_run(lo %o0): the four passes over [lo, lo + MS_SPAN); %o0 = total
 * mismatches, %o1 = the first bad VA, %o2 = its value; uses %l0-%l5 */
ms_run:
        mov %o7, %l5
        mov %o0, %l0
        set MS_SPAN, %l1
        add %l0, %l1, %l1               /* hi */
        clr %l2                         /* mismatches */
        clr %l3                         /* first bad VA */
        clr %l4                         /* its value */
#define MS_PASS(seed, mode, hireg)                               \
        mov %l0, %o0 ; mov hireg, %o1 ; set seed, %o2 ;          \
        call ms_write ; mov mode, %o3 ;                          \
        mov %l0, %o0 ; mov hireg, %o1 ; set seed, %o2 ;          \
        call ms_check ; nop ;                                    \
        add %l2, %o0, %l2 ;                                      \
        tst %l3 ; bne 9f ; nop ; mov %o1, %l3 ; mov %o2, %l4 ; 9:
        MS_PASS(0x00000000, 0, %l1)
        MS_PASS(0x5a5a5a5a, 1, %l1)
        MS_PASS(0xffffffff, 0, %l1)
        set MS_BYTES, %o5
        add %l0, %o5, %o5
        mov %o5, %g5
        MS_PASS(0x9e3779b9, 2, %g5)
        mov %l2, %o0
        mov %l3, %o1
        jmp %l5 + 8
        mov %l4, %o2

/* smp_fn_ms(lo %o0), on CPU n: caches on, ms_run, the first bad VA to
 * MP_SYNC + 4n, caches off; %o0 = mismatches. Keeps %l6. */
smp_fn_ms:
        mov %o7, %l7
        mov %o0, %l0
        call mmu_on
        nop
        call ms_run
        mov %l0, %o0
        mov %o0, %l1
        lda [%g0] 4, %o3
        srl %o3, 2, %o3
        and %o3, 3, %o3
        sll %o3, 2, %o3
        set MP_SYNC, %o4
        sta %o1, [%o4 + %o3] 0x20
        call mmu_off
        nop
        jmp %l7 + 8
        mov %l1, %o0

/* ms_wait(n %o0): wait for CPU n's mailbox to clear, MS_WAIT * 65536
 * uncached polls at most; %o0 = RES, %o1 = 1 on a timeout; leaf */
ms_wait:
        sll %o0, 4, %o0
        set MP_CMD, %o4
        add %o4, %o0, %o4
        set MS_WAIT, %o3
1:      sethi %hi(0x10000), %o5
2:      lda [%o4] 0x20, %o2
        tst %o2
        be 3f
        mov 0, %o1
        subcc %o5, 1, %o5
        bne 2b
        nop
        subcc %o3, 1, %o3
        bne 1b
        nop
        mov 1, %o1
3:      add %o4, MP_CMD_RES, %o4
        retl
        lda [%o4] 0x20, %o0

#define SMP_ALIVE_OR_SKIP(n)                                     \
        mov n, %o0 ; call mp_alive ; nop ; tst %o0 ; bne 1f ; nop ; \
        SKIP_TEST ; 1:

BEGIN(t_memstress, "memstress: CPUs 0-2, 144 MB each, cached word/doubleword/byte patterns")
        SMP_ALIVE_OR_SKIP(1)
        SMP_ALIVE_OR_SKIP(2)
        call mmu_tables_init
        nop
        /* level-1 PTEs: VA 0x4100_0000 + k * 16 MB -> pa (k + 1) * 16 MB */
        set MT_L1 + 0x41 * 4, %l0
        set MS_LO, %l1
        set MS_LO + 3 * MS_SPAN, %l2
1:      srl %l1, 4, %o0
        or %o0, 0x8e, %o0               /* C, ACC 3, ET 2 */
        sta %o0, [%l0] 0x20
        add %l0, 4, %l0
        set 0x01000000, %o1
        add %l1, %o1, %l1
        cmp %l1, %l2
        bl 1b
        nop
        STPAV(0, MP_SYNC + 4)
        STPAV(0, MP_SYNC + 8)
        call mmu_on
        nop
        mov 1, %o0
        set smp_fn_ms, %o1
        set MS_VA + MS_LO + MS_SPAN, %o2
        call mp_post
        mov 0, %o3
        mov 2, %o0
        set smp_fn_ms, %o1
        set MS_VA + MS_LO + 2 * MS_SPAN, %o2
        call mp_post
        mov 0, %o3
        set MS_VA + MS_LO, %o0
        call ms_run
        nop
        mov %o0, %i0                    /* CPU 0: mismatches */
        mov %o1, %i1                    /* first bad VA */
        mov %o2, %i2                    /* its value */
        call mmu_off
        nop
        call ms_wait
        mov 1, %o0
        mov %o0, %i3
        mov %o1, %i4
        call ms_wait
        mov 2, %o0
        mov %o0, %i5
        mov %o1, %l3
        set MP_SYNC + 4, %o0
        lda [%o0] 0x20, %l4             /* CPU 1's first bad VA */
        set MP_SYNC + 8, %o0
        lda [%o0] 0x20, %l5             /* CPU 2's */
        EXPECT(%i0, 0, 1)
        EXPECT(%i1, 0, 2)
        EXPECT(%i2, 0, 3)
        EXPECT(%i3, 0, 4)
        EXPECT(%i4, 0, 5)               /* no timeout */
        EXPECT(%l4, 0, 6)
        EXPECT(%i5, 0, 7)
        EXPECT(%l3, 0, 8)
        EXPECT(%l5, 0, 9)
END
#endif

        .section .testtab, "a", @progbits
        .word 0, 0                      /* end of the test table */

        .section .romend, "a", @progbits
        .align 4
        .globl rom_end
rom_end:
