/* Caches on. The rest of the suite runs with the MMU off, where the core
 * takes its non-cacheable path and never touches the caches. This test
 * builds an identity map (RAM cacheable, the I/O page uncached, the PROM
 * cacheable), turns the MMU and both caches on, runs a routine from
 * cacheable RAM twice (cold and warm caches) with loads, stores, load-use
 * pairs and taken branches whose targets are on the same and on another
 * 32-byte line, then turns everything off again. SS5 targets only: the
 * SS20 PROM is not reachable through an identity map. */
#include "macros.h"

#if defined(TARGET_SS5_QEMU)

#define PT_CTX   (SCRATCH + 0x0000)     /* context table, 256 entries */
#define PT_L1    (SCRATCH + 0x1000)     /* level-1 table: 256 x 16 MB */
#define C_CODE   (SCRATCH + 0x10000)    /* the routine, in cacheable RAM */
#define C_DATA   (SCRATCH + 0x20000)    /* 4 KB of cacheable data */
#define N_WORDS  1024
#define CHECKSUM 0x17fa00               /* sum of 3*i, i = 0..1023 */

/* SRMMU level-1 PTE for a 16 MB region: PPN in bits 31:8, C bit 7,
 * ACC = 3 (all access) in bits 4:2, ET = 2 */
#define PTE_C(pa)   ((((pa) >> 4) & 0xffffff00) | 0x80 | 0x0e)
#define PTE_NC(pa)  ((((pa) >> 4) & 0xffffff00) | 0x0e)

/* The routine: %o0 = data base; returns the checksum in %o0. Position
 * independent; copied to C_CODE. Loop 1 stores 3*i with its back branch
 * on the same line as its target; loop 2 sums the words back, with the
 * load-use pair and its back branch on the line after its target. */
        .section .text
        .align 32
cache_body:
        save %sp, -96, %sp
        mov %i0, %l0
        clr %l1
        .align 32
1:      sll %l1, 1, %l2
        add %l2, %l1, %l2
        st %l2, [%l0]
        add %l1, 1, %l1
        cmp %l1, N_WORDS
        bne 1b
        add %l0, 4, %l0
        clr %l3
        mov %i0, %l0
        clr %l1
        .align 32
2:      ld [%l0], %l2
        add %l3, %l2, %l3
        add %l1, 1, %l1
        cmp %l1, N_WORDS
        add %l0, 4, %l0
        nop
        nop
        nop
        bne 2b                          /* next line: cross-line target */
        nop
        ret
        restore %l3, 0, %o0
cache_body_end:

BEGIN(t_cache_on, "cache: MMU identity map, I/D caches on, loops in RAM")
        /* context table: entry 0 is a PTD to the level-1 table */
        set PT_CTX, %l0
        set ((PT_L1 >> 4) | 1), %l1
        st %l1, [%l0]
        /* level-1 table: invalid, then RAM, I/O, PROM */
        set PT_L1, %l0
        mov 256, %l2
1:      st %g0, [%l0]
        subcc %l2, 1, %l2
        bne 1b
        add %l0, 4, %l0
        set PT_L1, %l0
        set PTE_C(0x00000000), %l1
        st %l1, [%l0]
        st %l1, [%l0 + 0x40 * 4]        /* alias: VA 0x40xxxxxx -> RAM */
        set PTE_NC(0x71000000), %l1
        st %l1, [%l0 + 0x71 * 4]
        set PTE_C(ROM_BASE), %l1
        st %l1, [%l0 + (ROM_BASE >> 24) * 4]
        /* the routine goes to cacheable RAM */
        set cache_body, %l0
        set cache_body_end, %l1
        set C_CODE, %l2
2:      ld [%l0], %l3
        st %l3, [%l2]
        add %l0, 4, %l0
        cmp %l0, %l1
        blu 2b
        add %l2, 4, %l2
        /* MMU on: CTPR, context 0, TLB flush, PCR with E, DCE, ICE and
         * boot mode off; the PROM is now fetched through the map */
        set (PT_CTX >> 4), %l1
        mov 0x100, %l0
        sta %l1, [%l0] 0x04
        mov 0x200, %l0
        sta %g0, [%l0] 0x04
        mov 0x400, %l0
        sta %g0, [%l0] 0x03
        lda [%g0] 0x04, %l6             /* PCR, restored below */
        set 0x4000, %l1
        andn %l6, %l1, %l1
        or %l1, 0x301, %l1
        sta %l1, [%g0] 0x04
        nop ; nop ; nop
        set C_CODE, %l4
#ifdef CACHE_TIMING
        /* processor counter (2 MHz, bits 30:9) around the two runs; the
         * tick count is printed below. Measurement builds only: the
         * suite's own end-of-run cycle count is paced by the serial
         * output, not by the CPU. */
        set 0x71d00004, %l0
        ld [%l0], %g4
#endif
        set C_DATA, %o0
        call %l4                        /* cold caches */
        nop
        mov %o0, %l5
        set C_DATA, %o0
        call %l4                        /* warm caches */
        nop
        mov %o0, %l7
#ifdef CACHE_TIMING
        set 0x71d00004, %l0
        ld [%l0], %g5
        sub %g5, %g4, %g4
        sll %g4, 1, %g4
        srl %g4, 10, %g4                /* ticks */
#endif
        /* proof that this ran translated and cached: word 1 read through
         * the alias, and the PCR as it is now */
        set 0x40000000 + C_DATA + 4, %l0
        ld [%l0], %g2
        lda [%g0] 0x04, %g3
        /* everything off again */
        sta %l6, [%g0] 0x04
        nop ; nop ; nop
        mov 0x400, %l0
        sta %g0, [%l0] 0x03
        EXPECT(%l5, CHECKSUM, 1)
        EXPECT(%l7, CHECKSUM, 2)
        EXPECT(%g2, 3, 3)               /* 3*1, through the alias */
        set 0x4301, %l0
        and %g3, %l0, %g3
        EXPECT(%g3, 0x301, 4)           /* E, DCE, ICE on, BM off */
#ifdef CACHE_TIMING
        set s_cache_ticks, %o0
        call puts
        nop
        call puthex
        mov %g4, %o0
        set s_nl, %o0
        call puts
        nop
#endif
END

#ifdef CACHE_TIMING
        .section .rodata
s_cache_ticks: .asciz "    cache ticks="
        .section .text
#endif

#endif
