/* SS20 SMP: coherency between CPUs with their caches on and MCNTL.SE
 * (bus snooping) set, atomic instructions under contention, and what SE
 * off does (audit C-4, SMP-3). CPU 1 and 2 run functions through the
 * dispatcher (runtime.S mp_post/mp_wait): leaf code, no stack, no traps.
 * Each function turns its own MMU and caches on with the tables CPU 0
 * built (mmu_setup.S) and off again before returning. SKIP where the
 * secondary CPUs do not run (QEMU). */
#include "macros.h"

#if defined(TARGET_SS20)

/* smp_fn_store(addr %o0, value %o1), on CPU n: cache the line, store,
 * raise MP_SYNC + 4n to 1, wait (bounded) for CPU 0 to set it to 2,
 * read the line back, flush it, caches off; %o0 = the value read back */
smp_fn_store:
        mov %o7, %l7
        mov %o0, %l0
        mov %o1, %l1
        call mmu_on
        nop
        ld [%l0], %g0
        st %l1, [%l0]
        lda [%g0] 4, %o0
        srl %o0, 2, %o0
        and %o0, 3, %o0
        sll %o0, 2, %o0
        set MP_SYNC, %l3
        add %l3, %o0, %l3
        mov 1, %o0
        sta %o0, [%l3] 0x20
        set MP_WAIT_POLLS, %l4
1:      lda [%l3] 0x20, %o0
        cmp %o0, 2
        be 2f
        nop
        subcc %l4, 1, %l4
        bne 1b
        nop
2:      ld [%l0], %l2
        sta %g0, [%l0] 0x10             /* flush the line */
        call mmu_off
        nop
        jmp %l7 + 8
        mov %l2, %o0

/* smp_inc_loop(counter %o0, mode %o1): 64 increments of the word at
 * counter under the lock word at counter + 4, taken with ldstub (mode 0)
 * or swap (mode 1), each attempt bounded; %o0 = increments done; leaf */
smp_inc_loop:
        mov 64, %o2
        add %o0, 4, %o3
1:      set 100000, %o4
2:      cmp %o1, 0
        bne 3f
        nop
        ldstub [%o3], %o5
        ba 4f
        nop
3:      mov 1, %o5
        swap [%o3], %o5
4:      tst %o5
        be 5f
        nop
        subcc %o4, 1, %o4
        bne 2b
        nop
        ba 9f                           /* the lock never came free */
        nop
5:      ld [%o0], %o5
        add %o5, 1, %o5
        st %o5, [%o0]
        cmp %o1, 0
        bne 6f
        nop
        ba 7f
        stb %g0, [%o3]
6:      st %g0, [%o3]
7:      subcc %o2, 1, %o2
        bne 1b
        nop
9:      mov 64, %o0
        retl
        sub %o0, %o2, %o0

/* smp_fn_inc(counter %o0, mode %o1), on CPU n: caches on, smp_inc_loop,
 * caches off (mmu_off flushes MT_SEG); %o0 = increments done */
smp_fn_inc:
        mov %o7, %l7
        mov %o0, %l0
        mov %o1, %l1
        call mmu_on
        nop
        mov %l0, %o0
        call smp_inc_loop
        mov %l1, %o1
        mov %o0, %l2
        call mmu_off
        nop
        jmp %l7 + 8
        mov %l2, %o0

/* smp_sync_wait(n %o0, value %o1): poll MP_SYNC + 4n for value, bounded;
 * %o0 = 1 seen, 0 timed out; leaf */
smp_sync_wait:
        sll %o0, 2, %o0
        set MP_SYNC, %o2
        add %o2, %o0, %o2
        set MP_WAIT_POLLS, %o3
1:      lda [%o2] 0x20, %o4
        cmp %o4, %o1
        be 2f
        mov 1, %o0
        subcc %o3, 1, %o3
        bne 1b
        nop
        mov 0, %o0
2:      retl
        nop

#define SMP_ALIVE_OR_SKIP(n)                                     \
        mov n, %o0 ; call mp_alive ; nop ; tst %o0 ; bne 1f ; nop ; \
        SKIP_TEST ; 1:

/* CPU 0 holds a line; CPU 1 stores to it with its cache on; CPU 0's
 * next load sees the store (write-through: the bus write invalidates
 * CPU 0's copy; write-back: CPU 1 owns the line and supplies it). */
BEGIN(t_smp_coherent, "smp: SS20 CPU 0 sees CPU 1's cached store (SE on)")
        SMP_ALIVE_OR_SKIP(1)
        call mmu_tables_init
        nop
        STPAV(0x61610000, MT_PAGE(6) + 0x40)
        STPAV(0, MP_SYNC + 4)
        call mmu_on
        nop
        set MT_PAGE(6) + 0x40, %l0
        ld [%l0], %l1                   /* cached, old */
        mov 1, %o0
        set smp_fn_store, %o1
        mov %l0, %o2
        set 0x62620000, %o3
        call mp_post
        nop
        mov 1, %o0
        call smp_sync_wait
        mov 1, %o1
        mov %o0, %l6                    /* CPU 1 has stored */
        ld [%l0], %l2                   /* new */
        mov 2, %o0
        set MP_SYNC + 4, %o1
        sta %o0, [%o1] 0x20             /* let CPU 1 go on */
        call mp_wait
        mov 1, %o0
        mov %o0, %l3
        mov %o1, %l7
        lda [%l0] 0x20, %i0             /* memory, after CPU 1's flush */
        call mmu_off
        nop
        EXPECT(%l1, 0x61610000, 1)
        EXPECT(%l6, 1, 2)
        EXPECT(%l2, 0x62620000, 3)
        EXPECT(%l7, 0, 4)               /* no timeout */
        EXPECT(%l3, 0x62620000, 5)
        EXPECT(%i0, 0x62620000, 6)
END

/* CPUs 0, 1 and 2 each add 64 to a shared counter under a lock, once
 * with ldstub and once with swap; the total must be exact. */
BEGIN(t_smp_atomic, "smp: SS20 3 CPUs increment a shared counter under ldstub and swap locks")
        SMP_ALIVE_OR_SKIP(1)
        SMP_ALIVE_OR_SKIP(2)
        call mmu_tables_init
        nop
        set MT_PAGE(7), %l0
        clr %i1                         /* mode */
        call mmu_on
        nop
8:      sta %g0, [%l0] 0x20             /* counter */
        add %l0, 4, %o0
        sta %g0, [%o0] 0x20             /* lock */
        mov 1, %o0
        set smp_fn_inc, %o1
        mov %l0, %o2
        call mp_post
        mov %i1, %o3
        mov 2, %o0
        set smp_fn_inc, %o1
        mov %l0, %o2
        call mp_post
        mov %i1, %o3
        mov %l0, %o0
        call smp_inc_loop
        mov %i1, %o1
        mov %o0, %l1
        call mp_wait
        mov 1, %o0
        mov %o0, %l2
        mov %o1, %l3
        call mp_wait
        mov 2, %o0
        mov %o0, %l4
        mov %o1, %l5
        sta %g0, [%l0] 0x10             /* flush CPU 0's copy */
        lda [%l0] 0x20, %l6
        sll %i1, 4, %i2                 /* codes 0x10 * mode + n */
        add %i2, 1, %o0
        mov %l1, %o1
        call check_eq
        mov 64, %o2
        add %i2, 2, %o0
        mov %l2, %o1
        call check_eq
        mov 64, %o2
        add %i2, 3, %o0
        mov %l3, %o1
        call check_eq
        mov 0, %o2
        add %i2, 4, %o0
        mov %l4, %o1
        call check_eq
        mov 64, %o2
        add %i2, 5, %o0
        mov %l5, %o1
        call check_eq
        mov 0, %o2
        add %i2, 6, %o0
        mov %l6, %o1
        call check_eq
        mov 192, %o2
        add %i1, 1, %i1
        cmp %i1, 2
        bl 8b
        nop
        call mmu_off
        nop
END

/* With SE off, CPU 0 does not snoop: after CPU 1's store its cached copy
 * is stale, as on the real module (Sun-4M: snooping off after reset,
 * the OBP sets SE on every CPU). SE is turned on again before CPU 0
 * flushes its line and reads the new value. */
BEGIN(t_smp_nosnoop, "smp: SS20 with SE off CPU 0 keeps its stale copy of CPU 1's line (C-4)")
        SMP_ALIVE_OR_SKIP(1)
        call mmu_tables_init
        nop
        STPAV(0x71710000, MT_PAGE(8) + 0x20)
        STPAV(0, MP_SYNC + 4)
        call mmu_on
        nop
        lda [%g0] 4, %l5
        set MCR_SE, %o1
        andn %l5, %o1, %o0
        sta %o0, [%g0] 4                /* SE off */
        set MT_PAGE(8) + 0x20, %l0
        ld [%l0], %l1
        mov 1, %o0
        set smp_fn_store, %o1
        mov %l0, %o2
        set 0x72720000, %o3
        call mp_post
        nop
        mov 1, %o0
        call smp_sync_wait
        mov 1, %o1
        mov %o0, %l6
        ld [%l0], %l2                   /* stale */
        mov 2, %o0
        set MP_SYNC + 4, %o1
        sta %o0, [%o1] 0x20
        call mp_wait
        mov 1, %o0
        mov %o0, %l3
        mov %o1, %l7
        sta %l5, [%g0] 4                /* SE on */
        sta %g0, [%l0] 0x10             /* drop the stale line */
        ld [%l0], %l4
        call mmu_off
        nop
        EXPECT(%l1, 0x71710000, 1)
        EXPECT(%l6, 1, 2)
        EXPECT(%l2, 0x71710000, 3)
        EXPECT(%l7, 0, 4)
        EXPECT(%l3, 0x72720000, 5)
        EXPECT(%l4, 0x72720000, 6)
END
/* A token goes round CPUs 0, 1 and 2 through words 0-2 of one cached
 * line (MT_PAGE(10) + 0x60), RING_ROUNDS times: CPU n > 0 polls word n-1
 * for k, then stores k in word n; CPU 0 stores k in word 0 and polls word
 * 2. Every round each CPU also increments its own counter, word 4 + n,
 * and takes and drops its own byte n of word 3 with ldstub. Each poll
 * hits the CPU's cached copy until the other CPU's store invalidates it:
 * a missed invalidation is a poll that times out. An atomic or a
 * write-back that wrote the whole line from a stale copy would undo
 * another CPU's counter. (Solaris 8 on the board, 3 CPUs: lost updates
 * and a fault on a PTE the kernel had installed, 2026-10-01.) */
#define RING_ROUNDS     2000
#define RING_POLLS      200000

/* ring_loop(line %o0, n %o1, rounds %o2): %o0 = rounds completed; leaf,
 * %o0-%o5 and %g1-%g4 */
ring_loop:
        sll %o1, 2, %g2
        add %o0, %g2, %g2               /* word n: my token */
        add %g2, 16, %g3                /* word 4 + n: my counter */
        add %o0, 12, %g4
        add %g4, %o1, %g4               /* byte n of word 3 */
        tst %o1
        bne 1f
        add %o0, 8, %g1                 /* CPU 0 waits on word 2 */
        ba 2f
        nop
1:      sub %g2, 4, %g1                 /* CPU n waits on word n - 1 */
2:      mov 1, %o3                      /* k */
3:      tst %o1
        be 5f
        nop
        set RING_POLLS, %o4
4:      ld [%g1], %o5
        cmp %o5, %o3
        be 5f
        nop
        subcc %o4, 1, %o4
        bne 4b
        nop
        ba 9f
        nop
5:      st %o3, [%g2]                   /* pass the token */
        ld [%g3], %o5
        add %o5, 1, %o5
        st %o5, [%g3]
        ldstub [%g4], %o5
        stb %g0, [%g4]
        tst %o1
        bne 7f
        nop
        set RING_POLLS, %o4             /* CPU 0: the token comes back */
6:      ld [%g1], %o5
        cmp %o5, %o3
        be 7f
        nop
        subcc %o4, 1, %o4
        bne 6b
        nop
        ba 9f
        nop
7:      cmp %o3, %o2
        bge 8f
        nop
        ba 3b
        add %o3, 1, %o3
8:      add %o3, 1, %o3
9:      retl
        sub %o3, 1, %o0

/* smp_fn_ring(line %o0, rounds %o1), on CPU n: caches on, ring_loop as
 * participant n, caches off; %o0 = rounds completed. Keeps %l6 (the
 * dispatcher's mailbox pointer). */
smp_fn_ring:
        mov %o7, %l7
        mov %o0, %l0
        mov %o1, %l1
        call mmu_on
        nop
        lda [%g0] 4, %o1
        srl %o1, 2, %o1
        and %o1, 3, %o1
        mov %l0, %o0
        call ring_loop
        mov %l1, %o2
        mov %o0, %l2
        call mmu_off
        nop
        jmp %l7 + 8
        mov %l2, %o0

BEGIN(t_smp_ring, "smp: SS20 3 CPUs pass a token through one cached line, with counters and ldstub")
        SMP_ALIVE_OR_SKIP(1)
        SMP_ALIVE_OR_SKIP(2)
        call mmu_tables_init
        nop
        set MT_PAGE(10) + 0x60, %l0
        clr %o0
1:      sta %g0, [%l0 + %o0] 0x20
        add %o0, 4, %o0
        cmp %o0, 32
        bl 1b
        nop
        call mmu_on
        nop
        mov 1, %o0
        set smp_fn_ring, %o1
        mov %l0, %o2
        call mp_post
        set RING_ROUNDS, %o3
        mov 2, %o0
        set smp_fn_ring, %o1
        mov %l0, %o2
        call mp_post
        set RING_ROUNDS, %o3
        mov %l0, %o0
        mov 0, %o1
        call ring_loop
        set RING_ROUNDS, %o2
        mov %o0, %l1                    /* CPU 0's rounds */
        call mp_wait
        mov 1, %o0
        mov %o0, %l2
        mov %o1, %l3
        call mp_wait
        mov 2, %o0
        mov %o0, %l4
        mov %o1, %l5
        ld [%l0 + 16], %i0              /* the counters, CPU 0 cached */
        ld [%l0 + 20], %i1
        ld [%l0 + 24], %i2
        ld [%l0 + 12], %i3              /* the ldstub bytes, all free */
        sta %g0, [%l0] 0x10
        add %l0, 20, %o0
        lda [%o0] 0x20, %i4             /* CPU 1's counter in memory */
        add %l0, 24, %o0
        lda [%o0] 0x20, %i5             /* CPU 2's */
        call mmu_off
        nop
        EXPECT(%l1, RING_ROUNDS, 1)
        EXPECT(%l2, RING_ROUNDS, 2)
        EXPECT(%l3, 0, 3)
        EXPECT(%l4, RING_ROUNDS, 4)
        EXPECT(%l5, 0, 5)
        EXPECT(%i0, RING_ROUNDS, 6)
        EXPECT(%i1, RING_ROUNDS, 7)
        EXPECT(%i2, RING_ROUNDS, 8)
        EXPECT(%i3, 0, 9)
        EXPECT(%i4, RING_ROUNDS, 10)
        EXPECT(%i5, RING_ROUNDS, 11)
END
#endif
