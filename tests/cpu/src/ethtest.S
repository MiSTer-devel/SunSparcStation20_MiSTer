/* ethtest: the Ethernet path (the LANCE, its DMA2 channel, the IOMMU, the
 * frame mailbox eth_hps and Main's side of it), built apart from the suite
 * (python3 tests/cpu/build.py ss20 --main=ethtest, out/ss20/ethtest.rom):
 * it needs a Main that sends every frame back, which the simulation does
 * with --eth-loop (sim/run-eth.sh).
 *
 * The LANCE reaches memory through the IOMMU, as under an OS: its 24-bit
 * addresses with E_BASE_ADDR 0xff are DVMA 0xff00_0000 + a, and the first
 * 64 KB of that window map pa SCRATCH, so a LANCE address is an offset in
 * SCRATCH. The CPU builds the init block, the rings and the buffers through
 * ASI 0x20 (physical, uncached): no cache flush is needed.
 *
 * The station address is 08:00:20:12:34:56; the init block holds it the
 * Sun way, each 16-bit PADR word byte-swapped (PADR[7:0] is the first
 * byte on the wire, and the LANCE reads the words big-endian). */
#include "runtime.S"

        .text

#if defined(TARGET_SS20)
#  define LE_PA         0xf0c00000      /* ASI 0x2e: pa 0xe_f0c0_0000 */
#  define DMA_PA        0xf0400000      /* ASI 0x2e: pa 0xe_f040_0000 */
#  define SBUS_ASI      0x2e
#  define IOMMU_PA      0xe0000000      /* ASI 0x2f: pa 0xf_e000_0000 */
#  define IOMMU_ASI     0x2f
#  define SITM_SET_PA   0xf1410008      /* ASI 0x2f: system interrupt mask set */
#  define SITM_ASI      0x2f
#else
#  define LE_PA         0x78c00000
#  define DMA_PA        0x78400000
#  define SBUS_ASI      0x20
#  define IOMMU_PA      0x10000000
#  define IOMMU_ASI     0x20
#  define SITM_SET_PA   0x71e10008
#  define SITM_ASI      0x20
#endif
#define MEM_ASI         0x20            /* RAM, physical, uncached */

#ifndef ETH_POLLS
#define ETH_POLLS       400000
#endif

#define IOPT            (SCRATCH + 0x20000)     /* IOMMU table, 16 KB aligned */

/* LANCE addresses: offsets in SCRATCH */
#define IB              0x100           /* the init block */
#define RDR             0x200           /* RX ring: 4 descriptors (RLEN 2) */
#define TDR             0x300           /* TX ring: 1 descriptor (4 for chains) */
#define TXBUF           0x800           /* below 4096: an immediate */
#define RXBUF           0x2000          /* 4 x 2 KB */
#define RXBCNT          1600

/* DMA2's Ethernet channel */
#define E_CSR           0x10
#define E_BASE          0x1c
#define E_RESET         0x80

/* LANCE registers (16 bits) and CSR0 bits */
#define LE_RDP          0
#define LE_RAP          2
#define C0_INIT         0x0001
#define C0_STRT         0x0002
#define C0_STOP         0x0004
#define C0_TDMD         0x0008
#define C0_TXON         0x0010
#define C0_RXON         0x0020
#define C0_IDON         0x0100
#define C0_TINT         0x0200
#define C0_RINT         0x0400
#define C0_MISS         0x1000
#define D_OWN           0x8000
#define D_STP           0x0200
#define D_ENP           0x0100

/* le_w(csr %o0, value %o1); leaf */
le_w:   set LE_PA, %o2
        add %o2, LE_RAP, %o3
        stha %o0, [%o3] SBUS_ASI
        retl
        stha %o1, [%o2] SBUS_ASI

/* le_r(csr %o0) -> %o0; leaf */
le_r:   set LE_PA, %o2
        add %o2, LE_RAP, %o3
        stha %o0, [%o3] SBUS_ASI
        retl
        lduha [%o2] SBUS_ASI, %o0

/* mh(offset %o0, value %o1): a 16-bit word at SCRATCH + offset; leaf */
mh:     set SCRATCH, %o2
        retl
        stha %o1, [%o2 + %o0] MEM_ASI

/* mrh(offset %o0) -> %o0; leaf */
mrh:    set SCRATCH, %o2
        retl
        lduha [%o2 + %o0] MEM_ASI, %o0

/* mb(offset %o0, value %o1): a byte; leaf */
mb:     set SCRATCH, %o2
        retl
        stba %o1, [%o2 + %o0] MEM_ASI

/* mrb(offset %o0) -> %o0; leaf */
mrb:    set SCRATCH, %o2
        retl
        lduba [%o2 + %o0] MEM_ASI, %o0

/* wait_own(offset %i0) -> %i0 = 1 when the descriptor's OWN bit (in the
 * word at offset + 2) has cleared, 0 after ETH_POLLS */
wait_own:
        save %sp, -96, %sp
        set ETH_POLLS, %l0
1:      call mrh
        add %i0, 2, %o0
        set D_OWN, %o1
        andcc %o0, %o1, %g0
        be 2f
        subcc %l0, 1, %l0
        bne 1b
        nop
        ret
        restore %g0, 0, %o0
2:      ret
        restore %g0, 1, %o0

/* frame(dst %i0: 0 ours, 1 another station's, 2 broadcast, 3 ours with
 * type 0x88b6, which the simulation's Main sends back 1600 bytes long,
 * len %i1): a frame of len bytes in TXBUF from our address, type 0x88b5,
 * payload byte k = 7k + 3 + dst; then the TX descriptor, and TDMD */
frame:
        save %sp, -96, %sp
        clr %l0                         /* byte index */
        set mac, %l1
1:      cmp %i0, 2                      /* destination */
        bne 2f
        mov 0xff, %o1
        ba 4f
        nop
2:      ldub [%l1 + %l0], %o1
        cmp %i0, 1
        bne 4f
        cmp %l0, 3
        bl 4f
        nop
        mov 0x99, %o1
4:      call mb
        add %l0, TXBUF, %o0
        add %l0, 1, %l0
        cmp %l0, 6
        bl 1b
        nop
5:      sub %l0, 6, %o2                 /* source: bytes 6-11 */
        ldub [%l1 + %o2], %o1
        call mb
        add %l0, TXBUF, %o0
        add %l0, 1, %l0
        cmp %l0, 12
        bl 5b
        nop
        mov 0x88, %o1
        call mb
        mov TXBUF + 12, %o0
        cmp %i0, 3
        bne,a 7f
        mov 0xb5, %o1
        mov 0xb6, %o1
7:      call mb
        mov TXBUF + 13, %o0
        mov 14, %l0
6:      sub %l0, 14, %o1                /* payload */
        smul %o1, 7, %o1
        add %o1, 3, %o1
        add %o1, %i0, %o1
        call mb
        add %l0, TXBUF, %o0
        add %l0, 1, %l0
        cmp %l0, %i1
        bl 6b
        nop
        /* TMD0-3: the buffer, OWN|STP|ENP, -BCNT, 0 */
        set TXBUF, %o1
        call mh
        mov TDR, %o0
        set D_OWN | D_STP | D_ENP, %o1
        call mh
        mov TDR + 2, %o0
        neg %i1, %o1
        set 0xffff, %o2
        and %o1, %o2, %o1
        call mh
        mov TDR + 4, %o0
        clr %o1
        call mh
        mov TDR + 6, %o0
        mov 0, %o0
        call le_w
        mov C0_TDMD, %o1
        ret
        restore

/* check_rx(desc %i0, dst %i1, len %i2) -> %i0 = 0 when descriptor desc
 * (0-3) holds the frame frame() built for dst and len (+ the 4-byte FCS),
 * else the first failing check: 1 flags, 2 length, 3 + k byte k */
check_rx:
        save %sp, -96, %sp
        sll %i0, 3, %l2
        add %l2, RDR, %l2               /* the descriptor */
        call mrh
        add %l2, 2, %o0
        set 0xff00, %o1
        and %o0, %o1, %o0
        cmp %o0, D_STP | D_ENP
        bne 8f
        mov 1, %l7
        call mrh
        add %l2, 6, %o0
        set 0xfff, %o1
        and %o0, %o1, %o0
        add %i2, 4, %o1
        cmp %o0, %o1
        bne 8f
        mov 2, %l7
        sll %i0, 11, %l3
        set RXBUF, %o0
        add %l3, %o0, %l3               /* the buffer */
        /* the payload */
        mov 14, %l0
1:      call mrb
        add %l3, %l0, %o0
        sub %l0, 14, %o1
        smul %o1, 7, %o1
        add %o1, 3, %o1
        add %o1, %i1, %o1
        and %o1, 0xff, %o1
        cmp %o0, %o1
        bne 8f
        add %l0, 3, %l7
        add %l0, 1, %l0
        cmp %l0, %i2
        bl 1b
        nop
        /* the type */
        call mrb
        add %l3, 12, %o0
        cmp %o0, 0x88
        bne 8f
        mov 3 + 12, %l7
        clr %l7
8:      ret
        restore %l7, 0, %o0

/* eth_init(mode %i0, TLEN field %i1: 0 for one TX descriptor, 0x4000
 * for four) -> %i0 = CSR0 after INIT and STRT (0 if IDON never came): the
 * IOMMU, DMA2's channel, the init block and the rings */
eth_init:
        save %sp, -96, %sp
        set SITM_SET_PA, %l0            /* the test polls: mask everything */
        mov -1, %l1
        sta %l1, [%l0] SITM_ASI
        /* IOMMU: entries 0-15 of a 16 MB window at 0xff00_0000 map pa
           SCRATCH + 64 KB; IOPTE = pa[35:12] << 8 | W | V */
        set IOPT, %l0
        set SCRATCH, %l2
        clr %l3
1:      srl %l2, 4, %l4
        or %l4, 6, %l4
        sll %l3, 2, %l5
        sta %l4, [%l0 + %l5] MEM_ASI
        set 0x1000, %l6
        add %l2, %l6, %l2
        add %l3, 1, %l3
        cmp %l3, 16
        bl 1b
        nop
        set IOMMU_PA, %l1
        srl %l0, 4, %l4
        mov 4, %l5
        sta %l4, [%l1 + %l5] IOMMU_ASI  /* base address */
        mov 1, %l4                      /* ME, range 16 MB */
        sta %l4, [%l1] IOMMU_ASI
        mov 0x14, %l5
        sta %g0, [%l1 + %l5] IOMMU_ASI  /* flush all */
        /* DMA2: reset the channel, DVMA base 0xff */
        set DMA_PA, %l0
        mov E_RESET, %l1
        add %l0, E_CSR, %l2
        sta %l1, [%l2] SBUS_ASI
        sta %g0, [%l2] SBUS_ASI
        set 0xff000000, %l1
        add %l0, E_BASE, %l2
        sta %l1, [%l2] SBUS_ASI
        /* stop the LANCE; CSR3 BSWP|ACON|BCON, as every sun4m driver
           sets it (BSWP: frame bytes in memory in wire order; STOP has
           cleared CSR3) */
        mov 0, %o0
        call le_w
        mov C0_STOP, %o1
        mov 3, %o0
        call le_w
        mov 7, %o1
        /* the init block: MODE, PADR (swapped words), LADRF 0, the rings */
        mov %i0, %o1
        call mh
        mov IB, %o0
        set mac, %l1
        clr %l0
2:      ldub [%l1 + %l0], %o1           /* word k: mac[2k + 1] << 8 | mac[2k] */
        add %l0, 1, %o2
        ldub [%l1 + %o2], %o2
        sll %o2, 8, %o2
        or %o1, %o2, %o1
        call mh
        add %l0, IB + 2, %o0
        add %l0, 2, %l0
        cmp %l0, 6
        bl 2b
        nop
        clr %l0
3:      clr %o1                         /* LADRF */
        call mh
        add %l0, IB + 8, %o0
        add %l0, 2, %l0
        cmp %l0, 8
        bl 3b
        nop
        mov RDR, %o1
        call mh
        mov IB + 16, %o0
        set 0x4000, %o1                 /* RLEN 2: 4 descriptors, RDRA[23:16] 0 */
        call mh
        mov IB + 18, %o0
        mov TDR, %o1
        call mh
        mov IB + 20, %o0
        mov %i1, %o1                    /* TLEN, TDRA[23:16] 0 */
        call mh
        mov IB + 22, %o0
        /* the RX ring: 4 buffers, all the LANCE's */
        clr %l0
4:      sll %l0, 11, %o1
        set RXBUF, %o2
        add %o1, %o2, %o1
        sll %l0, 3, %l2
        call mh
        add %l2, RDR, %o0
        set D_OWN, %o1
        call mh
        add %l2, RDR + 2, %o0
        set (-RXBCNT) & 0xffff, %o1
        call mh
        add %l2, RDR + 4, %o0
        clr %o1
        call mh
        add %l2, RDR + 6, %o0
        add %l0, 1, %l0
        cmp %l0, 4
        bl 4b
        nop
        /* the TX descriptors: the host's */
        clr %l0
7:      clr %o1
        call mh
        add %l0, TDR + 2, %o0
        add %l0, 8, %l0
        cmp %l0, 32
        bl 7b
        nop
        /* CSR1/2: the init block's address; INIT, wait for IDON, STRT */
        mov 1, %o0
        call le_w
        mov IB, %o1
        mov 2, %o0
        call le_w
        clr %o1
        mov 0, %o0
        call le_w
        mov C0_INIT, %o1
        set ETH_POLLS, %l0
5:      call le_r
        mov 0, %o0
        andcc %o0, C0_IDON, %g0
        bne 6f
        subcc %l0, 1, %l0
        bne 5b
        nop
        ret
        restore %g0, 0, %o0
6:      mov 0, %o0
        call le_w
        mov C0_IDON | C0_STRT, %o1
        call le_r
        mov 0, %o0
        ret
        restore %o0, 0, %o0

/* ---------------------------------------------------------------- */

BEGIN(t_eth_init, "eth: the LANCE reads its init block (IDON), then runs (TXON, RXON)")
        clr %o1
        call eth_init
        clr %o0
        set 0x0036, %o1                 /* RXON TXON STOP STRT (INIT stays set until STOP) */
        and %o0, %o1, %o0
        EXPECT(%o0, C0_RXON | C0_TXON | C0_STRT, 1)
END

BEGIN(t_eth_loop, "eth: a 114-byte frame to our address comes back (Main loops it)")
        clr %o0
        call frame
        mov 114, %o1
        call wait_own
        mov TDR, %o0
        EXPECT(%o0, 1, 1)               /* sent */
        call mrh
        mov TDR + 2, %o0
        EXPECT(%o0, D_STP | D_ENP, 2)   /* no ERR */
        call wait_own
        mov RDR, %o0
        EXPECT(%o0, 1, 3)               /* received in descriptor 0 */
        clr %o0
        clr %o1
        call check_rx
        mov 114, %o2
        EXPECT(%o0, 0, 4)
        call le_r
        mov 0, %o0
        set C0_TINT | C0_RINT | C0_MISS, %o1
        and %o0, %o1, %o0
        EXPECT(%o0, C0_TINT | C0_RINT, 5)
        mov 0, %o0
        call le_w
        mov C0_TINT | C0_RINT, %o1
END

BEGIN(t_eth_filter, "eth: another station's frame is filtered out, a broadcast comes in")
        mov 1, %o0
        call frame
        mov 200, %o1
        call wait_own
        mov TDR, %o0
        EXPECT(%o0, 1, 1)
        call wait_own                   /* descriptor 1 must stay ours */
        mov RDR + 8, %o0
        EXPECT(%o0, 0, 2)
        mov 2, %o0
        call frame
        mov 60, %o1
        call wait_own
        mov TDR, %o0
        EXPECT(%o0, 1, 3)
        call wait_own
        mov RDR + 8, %o0
        EXPECT(%o0, 1, 4)
        mov 1, %o0
        mov 2, %o1
        call check_rx
        mov 60, %o2
        EXPECT(%o0, 0, 5)
        mov 0, %o0
        call le_w
        mov C0_TINT | C0_RINT, %o1
END

BEGIN(t_eth_long, "eth: a 1514-byte frame comes back whole")
        clr %o0
        call frame
        mov 1514, %o1
        call wait_own
        mov TDR, %o0
        EXPECT(%o0, 1, 1)
        call wait_own
        mov RDR + 16, %o0
        EXPECT(%o0, 1, 2)
        mov 2, %o0
        clr %o1
        call check_rx
        mov 1514, %o2
        EXPECT(%o0, 0, 3)
        mov 0, %o0
        call le_w
        mov C0_TINT | C0_RINT, %o1
END

BEGIN(t_eth_miss, "eth: with no buffer left the frame is missed (MISS), then the ring goes on")
        /* descriptor 3 is the last one the LANCE owns: take it back */
        clr %o1
        call mh
        mov RDR + 24 + 2, %o0
        clr %o0
        call frame
        mov 80, %o1
        call wait_own
        mov TDR, %o0
        EXPECT(%o0, 1, 1)
        set ETH_POLLS, %l0
1:      call le_r                       /* wait for MISS */
        mov 0, %o0
        set C0_MISS, %o1
        andcc %o0, %o1, %g0
        bne 2f
        subcc %l0, 1, %l0
        bne 1b
        nop
2:      set C0_MISS, %o1
        and %o0, %o1, %o0
        EXPECT(%o0, C0_MISS, 2)
        set C0_MISS | C0_TINT | C0_RINT, %o1    /* clear MISS and TINT */
        call le_w
        mov 0, %o0
        /* give descriptor 3 back: the next frame lands there */
        set D_OWN, %o1
        call mh
        mov RDR + 24 + 2, %o0
        clr %o0
        call frame
        mov 90, %o1
        call wait_own
        mov RDR + 24, %o0
        EXPECT(%o0, 1, 3)
        mov 3, %o0
        clr %o1
        call check_rx
        mov 90, %o2
        EXPECT(%o0, 0, 4)
END

BEGIN(t_eth_loopback, "eth: internal loopback (MODE LOOP|INTL): the frame comes back, not on the wire")
        clr %o1
        call eth_init
        mov 0x0044, %o0                 /* MODE: INTL | LOOP */
        set 0x0036, %o1
        and %o0, %o1, %o0
        EXPECT(%o0, C0_RXON | C0_TXON | C0_STRT, 1)
        clr %o0
        call frame
        mov 70, %o1
        call wait_own
        mov TDR, %o0
        EXPECT(%o0, 1, 2)
        call wait_own
        mov RDR, %o0
        EXPECT(%o0, 1, 3)               /* received in descriptor 0 */
        clr %o0
        clr %o1
        call check_rx
        mov 70, %o2
        EXPECT(%o0, 0, 4)
        /* back to normal for whatever runs next */
        clr %o1
        call eth_init
        clr %o0
END

/* tmd(desc %o0, offset %o1, bytes %o2, flags %o3): TX descriptor desc
 * (0-3) for the buffer at LANCE address TXBUF + offset; flags OWN, STP,
 * ENP as given. Not a leaf: calls mh. */
tmd:
        save %sp, -96, %sp
        sll %i0, 3, %l0
        add %l0, TDR, %l0
        set TXBUF, %o1
        add %o1, %i1, %o1
        call mh                         /* TMD0: address 15:0 */
        mov %l0, %o0
        neg %i2, %o1
        set 0xffff, %o2
        and %o1, %o2, %o1
        call mh                         /* TMD2: -BCNT */
        add %l0, 4, %o0
        clr %o1
        call mh                         /* TMD3 */
        add %l0, 6, %o0
        mov %i3, %o1
        call mh                         /* TMD1: flags, address 23:16 = 0 */
        add %l0, 2, %o0
        ret
        restore

/* chain(n %i0) -> %i0 = 0 when a 100-byte frame sent over n descriptors
 * (n = 2: 14 + 86 bytes; n = 3: 14 + 33 + 53, the last at an odd
 * address) comes back whole, else the failing step. As an OS's driver,
 * the later descriptors are handed over before the first. */
chain:
        save %sp, -96, %sp
        set 0x4000, %o1                 /* four TX descriptors */
        call eth_init
        clr %o0
        mov 1, %l7
        set 0x0036, %o1
        and %o0, %o1, %o0
        cmp %o0, C0_RXON | C0_TXON | C0_STRT
        bne 9f
        nop
        clr %o0                         /* the frame's bytes in TXBUF; */
        call frame                      /* frame() also sends it from */
        mov 100, %o1                    /* descriptor 0: let it go first */
        call wait_own
        mov TDR, %o0
        mov 2, %l7
        tst %o0
        be 9f
        nop
        call wait_own                   /* it came back into RX 0 */
        mov RDR, %o0
        mov 3, %l7
        tst %o0
        be 9f
        nop
        mov 0, %o0
        call le_w
        mov C0_TINT | C0_RINT, %o1
        /* now the chain, from descriptor 1 on */
        cmp %i0, 2
        bne 3f
        nop
        mov 2, %o0                      /* 2 fragments: 14 + 86 */
        mov 14, %o1
        mov 86, %o2
        set D_OWN | D_ENP, %o3
        call tmd
        nop
        mov 1, %o0
        clr %o1
        mov 14, %o2
        set D_OWN | D_STP, %o3
        call tmd
        nop
        ba 4f
        mov 2, %l6                      /* the last descriptor */
3:      mov 3, %o0                      /* 3 fragments: 14 + 33 + 53 */
        mov 47, %o1
        mov 53, %o2
        set D_OWN | D_ENP, %o3
        call tmd
        nop
        mov 2, %o0
        mov 14, %o1
        mov 33, %o2
        set D_OWN, %o3
        call tmd
        nop
        mov 1, %o0
        clr %o1
        mov 14, %o2
        set D_OWN | D_STP, %o3
        call tmd
        nop
        mov 3, %l6
4:      mov 0, %o0
        call le_w
        mov C0_TDMD, %o1
        sll %l6, 3, %o0
        call wait_own                   /* the last fragment went */
        add %o0, TDR, %o0
        mov 4, %l7
        tst %o0
        bne 5f
        nop
        /* stuck: print TMD1 of descriptors 0-3 and CSR0 */
        clr %l5
6:      sll %l5, 3, %o0
        call mrh
        add %o0, TDR + 2, %o0
        call puthex
        nop
        set s_sp, %o0
        call puts
        nop
        add %l5, 1, %l5
        cmp %l5, 4
        bl 6b
        nop
        call le_r
        mov 0, %o0
        call puthex
        nop
        set s_sp, %o0
        call puts
        nop
        set LE_PA, %o2                  /* CSR3 as a word: debug bits 31:20 */
        mov 3, %o0
        add %o2, LE_RAP, %o3
        stha %o0, [%o3] SBUS_ASI
        lda [%o2] SBUS_ASI, %o0
        call puthex
        nop
        set s_nl2, %o0
        call puts
        nop
        ba 9f
        nop
5:
        call wait_own                   /* and the frame came back */
        mov RDR + 8, %o0
        mov 5, %l7
        tst %o0
        be 9f
        nop
        mov 1, %o0
        clr %o1
        call check_rx
        mov 100, %o2
        mov 6, %l7
        tst %o0
        bne 9f
        nop
        clr %l7
9:      clr %o1                         /* back to one TX descriptor */
        call eth_init
        clr %o0
        ret
        restore %l7, 0, %o0

BEGIN(t_eth_chain2, "eth: a frame over two TX descriptors (STP, ENP) comes back whole")
        call chain
        mov 2, %o0
        EXPECT(%o0, 0, 1)
END

BEGIN(t_eth_chain3, "eth: a frame over three TX descriptors, odd lengths and address, comes back whole")
        call chain
        mov 3, %o0
        EXPECT(%o0, 0, 1)
END

        .section .rodata
mac:    .byte 0x08, 0x00, 0x20, 0x12, 0x34, 0x56
s_sp:   .asciz " "
s_nl2:  .asciz "  (TMD1 0-3, CSR0, CSR3: pc 31:26 dma_wr dma_rd busy fifordy tx_act tdmd)\n"


/* A frame longer than an Ethernet frame (1600 bytes: a host's offloaded
 * segment) is dropped before the LANCE (eth_hps RXMAX: the guests' buffers
 * are 1536 bytes and the LANCE checks no BCNT), without a MISS; the next
 * frame comes in. Needs sim/run-eth.sh (--eth-loop); on the board, Main
 * sends nothing back to the core's own address. */
BEGIN(t_eth_oversize, "eth: a 1600-byte received frame is dropped (no RINT, no MISS), the next one comes in")
        mov 0, %o0
        call le_w
        set C0_TINT | C0_RINT | C0_MISS, %o1
        mov 3, %o0
        call frame
        mov 100, %o1
        call wait_own
        mov TDR, %o0
        EXPECT(%o0, 1, 1)               /* sent */
        set ETH_POLLS, %l0
1:      call le_r
        mov 0, %o0
        set C0_RINT | C0_MISS, %o1
        andcc %o0, %o1, %o0
        bne 2f
        subcc %l0, 1, %l0
        bne 1b
        nop
2:      EXPECT(%o0, 0, 2)               /* nothing came in */
        mov 0, %o0
        call le_w
        set C0_TINT, %o1
        clr %o0
        call frame
        mov 100, %o1
        set ETH_POLLS, %l0
3:      call le_r
        mov 0, %o0
        set C0_RINT, %o1
        andcc %o0, %o1, %o0
        bne 4f
        subcc %l0, 1, %l0
        bne 3b
        nop
4:      set C0_RINT, %o1
        EXPECT_R(%o0, %o1, 3)           /* the next frame did */
        mov 0, %o0
        call le_w
        set C0_TINT | C0_RINT, %o1
END

        .section .testtab, "a", @progbits
        .word 0, 0                      /* end of the test table */

        .section .romend, "a", @progbits
        .align 4
        .globl rom_end
rom_end:
