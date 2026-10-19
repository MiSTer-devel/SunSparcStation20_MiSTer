/* The SuperSPARC cache diagnostic image (ASI 0x0c-0x0f, the flash clears
 * 0x36/0x37; audit C-1/C-2), as the SS20 POST exercises it
 * (docs/rom-disassembly/ss20-obp-2.25/post-tests.md section 3): the D-cache
 * data (ASI 0x0f: way VA[27:26], set [11:5], doubleword [4:3]; 4 x 128 x
 * 4), the I-cache data (0x0d: way [28:26], set [11:6], doubleword [5:3];
 * 5 x 64 x 8), the physical tags (0x0e / 0x0c at 0x80000000 | way << 26 |
 * set << 5 or 6: all-ones reads back hi 0x01010100 (D: V, D, S) or
 * 0x03000000 (I: two valid bits) and lo 0x00ffffff), the set tags
 * (0x40000000 | set << 5 or 6: lo 0x00000f0e (D) / 0x00001f1e (I), the
 * MRU bits [11:8] / [12:8] and the locks [3:1] / [4:1]; hi reads 0), and
 * the two flash clears: at 0 every PTAG high word and the MRU bits go,
 * at 0x80000000 the lock bits. MMU off, caches off, as in the POST. */
#include "macros.h"

#if defined(TARGET_SS20)
/* count a mismatch in %g2, keep the first in %g3 (exp) / %g4 (obs) and its
 * address (%o5) in %g5 */
#define CD_CHECK(e, o)                                                  \
        cmp e, o ; be 9f ; nop ; inc %g2 ; cmp %g2, 1 ; bne 9f ; nop ;  \
        mov e, %g3 ; mov o, %g4 ; mov %o5, %g5 ; 9:

/* cd_walk(entry function %i5, base %i0, ways %i1, set shift %i2, sets
 * %i3, doublewords %i4, set stride %g6): call %i5 with %o5 = base | way
 * << 26 | set << shift | dw << 3 for every way, every %g6th set (the
 * simulation's cycle budget; the POST walks them all) and every dw; the
 * function is a leaf using %o0-%o4 and may read %l0/%l1 */
cd_walk:
        mov %o7, %l4                    /* the calls below clobber %o7 */
        clr %l6                         /* way */
1:      clr %l7                         /* set */
2:      clr %l3                         /* doubleword */
3:      sll %l6, 26, %o5
        or %o5, %i0, %o5
        sll %l7, %i2, %o0
        or %o5, %o0, %o5
        sll %l3, 3, %o0
        call %i5
        or %o5, %o0, %o5
        inc %l3
        cmp %l3, %i4
        bne 3b
        nop
        add %l7, %g6, %l7
        cmp %l7, %i3
        blu 2b
        nop
        inc %l6
        cmp %l6, %i1
        bne 1b
        nop
        jmpl %l4 + 8, %g0
        nop

/* the data images: {address, ~address} written, then read back */
cd_wr_pat_f: mov %o5, %o2 ; xnor %o5, %g0, %o3 ; retl ; stda %o2, [%o5] 0x0f
cd_wr_pat_d: mov %o5, %o2 ; xnor %o5, %g0, %o3 ; retl ; stda %o2, [%o5] 0x0d
cd_rd_pat_f: ldda [%o5] 0x0f, %o2 ; xnor %o5, %g0, %o1
        CD_CHECK(%o5, %o2) ; CD_CHECK(%o1, %o3) ; retl ; nop
cd_rd_pat_d: ldda [%o5] 0x0d, %o2 ; xnor %o5, %g0, %o1
        CD_CHECK(%o5, %o2) ; CD_CHECK(%o1, %o3) ; retl ; nop
/* the tags: {%l0, %l1} written (or, cd_wr_idx_*: {%l0, %l1 | way << 8 |
 * set}), then read back as {%l0, %l1} (cd_rd_*) */
cd_wr_e: mov %l0, %o2 ; mov %l1, %o3 ; retl ; stda %o2, [%o5] 0x0e
cd_wr_c: mov %l0, %o2 ; mov %l1, %o3 ; retl ; stda %o2, [%o5] 0x0c
cd_wr_idx_e: srl %o5, 26, %o0 ; and %o0, 7, %o0 ; sll %o0, 8, %o0
        srl %o5, 5, %o1 ; and %o1, 0x7f, %o1 ; or %o0, %o1, %o0
        or %o0, %l1, %o3 ; mov %l0, %o2 ; retl ; stda %o2, [%o5] 0x0e
cd_wr_idx_c: srl %o5, 26, %o0 ; and %o0, 7, %o0 ; sll %o0, 8, %o0
        srl %o5, 6, %o1 ; and %o1, 0x3f, %o1 ; or %o0, %o1, %o0
        or %o0, %l1, %o3 ; mov %l0, %o2 ; retl ; stda %o2, [%o5] 0x0c
cd_rd_e: ldda [%o5] 0x0e, %o2
        CD_CHECK(%l0, %o2) ; CD_CHECK(%l1, %o3) ; retl ; nop
cd_rd_c: ldda [%o5] 0x0c, %o2
        CD_CHECK(%l0, %o2) ; CD_CHECK(%l1, %o3) ; retl ; nop
cd_rd_idx_e: srl %o5, 26, %o0 ; and %o0, 7, %o0 ; sll %o0, 8, %o0
        srl %o5, 5, %o1 ; and %o1, 0x7f, %o1 ; or %o0, %o1, %o0
        or %o0, %l1, %o1 ; ldda [%o5] 0x0e, %o2
        CD_CHECK(%l0, %o2) ; CD_CHECK(%o1, %o3) ; retl ; nop
cd_rd_idx_c: srl %o5, 26, %o0 ; and %o0, 7, %o0 ; sll %o0, 8, %o0
        srl %o5, 6, %o1 ; and %o1, 0x3f, %o1 ; or %o0, %o1, %o0
        or %o0, %l1, %o1 ; ldda [%o5] 0x0c, %o2
        CD_CHECK(%l0, %o2) ; CD_CHECK(%o1, %o3) ; retl ; nop

#define CD_WALK(fn, base, ways, shift, sets, dws, stride)                \
        set fn, %i5 ; set base, %i0 ; mov ways, %i1 ; mov shift, %i2 ;  \
        mov sets, %i3 ; mov stride, %g6 ; call cd_walk ; mov dws, %i4
#define CD_RESULTS(code)                                                \
        EXPECT_R(%g4, %g3, code) ; EXPECT_R(%g2, %g0, code + 1) ;       \
        mov %g5, %o3 ; EXPECT_R(%o3, %g0, code + 2)
#define CD_CLEAR  clr %g2 ; clr %g3 ; clr %g4 ; clr %g5
/* QEMU's SS-20 has no cache diagnostic ASIs (it hangs on them): the
 * core's private SYSCONF register (ASI 4, 0xd00) tells it apart */
#define CD_CORE_OR_SKIP                                                 \
        set 0xd00, %o0 ; lda [%o0] 4, %o0 ; tst %o0 ; bne 1f ; nop ;    \
        SKIP_TEST ; 1:

BEGIN(t_cdiag_data, "cache: SS20 ASI 0x0f/0x0d D and I data images hold every doubleword (4x128x4, 5x64x8)")
        CD_CORE_OR_SKIP
        CD_CLEAR
        sta %g0, [%g0] 0x37
        sta %g0, [%g0] 0x36
        CD_WALK(cd_wr_pat_f, 0, 4, 5, 128, 4, 7)
        CD_WALK(cd_rd_pat_f, 0, 4, 5, 128, 4, 7)
        CD_RESULTS(1)
        CD_CLEAR
        CD_WALK(cd_wr_pat_d, 0, 5, 6, 64, 8, 5)
        CD_WALK(cd_rd_pat_d, 0, 5, 6, 64, 8, 5)
        CD_RESULTS(4)
        CD_CLEAR
        CD_WALK(cd_rd_pat_f, 0, 4, 5, 128, 4, 7) /* the I pass left the D image alone */
        CD_RESULTS(7)
END

BEGIN(t_cdiag_tags, "cache: SS20 ASI 0x0e/0x0c PTAGs keep V/D/S or V and PA[35:12], STAGs the MRU and lock bits")
        CD_CORE_OR_SKIP
        CD_CLEAR
        set -1, %l0                     /* all-ones: what is writable */
        set -1, %l1
        CD_WALK(cd_wr_e, 0x80000000, 4, 5, 128, 1, 3)
        set 0x01010100, %l0
        set 0x00ffffff, %l1
        CD_WALK(cd_rd_e, 0x80000000, 4, 5, 128, 1, 3)
        CD_RESULTS(1)
        CD_CLEAR
        set -1, %l0
        set -1, %l1
        CD_WALK(cd_wr_c, 0x80000000, 5, 6, 64, 1, 3)
        set 0x03000000, %l0
        set 0x00ffffff, %l1
        CD_WALK(cd_rd_c, 0x80000000, 5, 6, 64, 1, 3)
        CD_RESULTS(4)
        CD_CLEAR
        set 0, %l0                      /* STAGs: hi is nothing, lo the MRU and lock bits */
        set -1, %l1
        CD_WALK(cd_wr_e, 0x40000000, 1, 5, 128, 1, 3)
        CD_WALK(cd_wr_c, 0x40000000, 1, 6, 64, 1, 3)
        set 0x00000f0e, %l1
        CD_WALK(cd_rd_e, 0x40000000, 1, 5, 128, 1, 3)
        set 0x00001f1e, %l1
        CD_WALK(cd_rd_c, 0x40000000, 1, 6, 64, 1, 3)
        CD_RESULTS(7)
        CD_CLEAR
        set 0x01000000, %l0             /* each PTAG its own PA: no aliasing */
        set 0x00500000, %l1
        CD_WALK(cd_wr_idx_e, 0x80000000, 4, 5, 128, 1, 3)
        set 0x03000000, %l0
        set 0x00600000, %l1
        CD_WALK(cd_wr_idx_c, 0x80000000, 5, 6, 64, 1, 3)
        set 0x01000000, %l0
        set 0x00500000, %l1
        CD_WALK(cd_rd_idx_e, 0x80000000, 4, 5, 128, 1, 3)
        set 0x03000000, %l0
        set 0x00600000, %l1
        CD_WALK(cd_rd_idx_c, 0x80000000, 5, 6, 64, 1, 3)
        set 0, %l0                      /* the STAGs too */
        set 0x00000f0e, %l1
        CD_WALK(cd_rd_e, 0x40000000, 1, 5, 128, 1, 3)
        set 0x00001f1e, %l1
        CD_WALK(cd_rd_c, 0x40000000, 1, 6, 64, 1, 3)
        CD_RESULTS(10)
        CD_CLEAR
        clr %l0                         /* zeros read back as zeros */
        clr %l1
        CD_WALK(cd_wr_e, 0x80000000, 4, 5, 128, 1, 3)
        CD_WALK(cd_wr_c, 0x80000000, 5, 6, 64, 1, 3)
        CD_WALK(cd_wr_e, 0x40000000, 1, 5, 128, 1, 3)
        CD_WALK(cd_wr_c, 0x40000000, 1, 6, 64, 1, 3)
        CD_WALK(cd_rd_e, 0x80000000, 4, 5, 128, 1, 3)
        CD_WALK(cd_rd_c, 0x80000000, 5, 6, 64, 1, 3)
        CD_WALK(cd_rd_e, 0x40000000, 1, 5, 128, 1, 3)
        CD_WALK(cd_rd_c, 0x40000000, 1, 6, 64, 1, 3)
        CD_RESULTS(13)
END

/* The POST's Cache Flashclear Test: every STAG lo 0xf0e / 0x1f1e and PTAG
 * {0x01000000 / 0x03000000, 0x502}; the lock flash (VA 0x80000000)
 * leaves STAG lo 0xf00 / 0x1f00 and the PTAGs; the valid/MRU flash (VA 0)
 * leaves STAG lo 0xe / 0x1e and PTAG hi 0, lo 0x502. The D side first,
 * then the I side; the other side's tags must not change. */
#define CD_TAGS_INIT                                                    \
        set 0, %l0 ; set 0x00000f0e, %l1 ;                              \
        CD_WALK(cd_wr_e, 0x40000000, 1, 5, 128, 1, 3) ;                    \
        set 0, %l0 ; set 0x00001f1e, %l1 ;                              \
        CD_WALK(cd_wr_c, 0x40000000, 1, 6, 64, 1, 3) ;                     \
        set 0x01000000, %l0 ; set 0x502, %l1 ;                          \
        CD_WALK(cd_wr_e, 0x80000000, 4, 5, 128, 1, 3) ;                    \
        set 0x03000000, %l0 ; set 0x502, %l1 ;                          \
        CD_WALK(cd_wr_c, 0x80000000, 5, 6, 64, 1, 3)
#define CD_TAGS_CHECK(dstag, dptag, istag, iptag)                       \
        set 0, %l0 ; set dstag, %l1 ;                                   \
        CD_WALK(cd_rd_e, 0x40000000, 1, 5, 128, 1, 3) ;                    \
        set 0, %l0 ; set istag, %l1 ;                                   \
        CD_WALK(cd_rd_c, 0x40000000, 1, 6, 64, 1, 3) ;                     \
        set dptag, %l0 ; set 0x502, %l1 ;                               \
        CD_WALK(cd_rd_e, 0x80000000, 4, 5, 128, 1, 3) ;                    \
        set iptag, %l0 ; set 0x502, %l1 ;                               \
        CD_WALK(cd_rd_c, 0x80000000, 5, 6, 64, 1, 3)

BEGIN(t_cdiag_flash, "cache: SS20 flash clears on the image: lock (VA 0x80000000) drops the locks, valid (VA 0) the PTAG V bits and the MRUs")
        CD_CORE_OR_SKIP
        CD_CLEAR
        set 0x80000000, %l5
        CD_TAGS_INIT
        sta %g0, [%l5] 0x37             /* D lock */
        CD_TAGS_CHECK(0xf00, 0x01000000, 0x1f1e, 0x03000000)
        CD_RESULTS(1)
        CD_CLEAR
        CD_TAGS_INIT
        sta %g0, [%g0] 0x37             /* D valid/MRU */
        CD_TAGS_CHECK(0xe, 0, 0x1f1e, 0x03000000)
        CD_RESULTS(4)
        CD_CLEAR
        CD_TAGS_INIT
        sta %g0, [%l5] 0x36             /* I lock */
        CD_TAGS_CHECK(0xf0e, 0x01000000, 0x1f00, 0x03000000)
        CD_RESULTS(7)
        CD_CLEAR
        CD_TAGS_INIT
        sta %g0, [%g0] 0x36             /* I valid/MRU */
        CD_TAGS_CHECK(0xf0e, 0x01000000, 0x1e, 0)
        CD_RESULTS(10)
        CD_CLEAR
        sta %g0, [%g0] 0x37             /* both: the image all 0 but the PAs */
        sta %g0, [%l5] 0x37
        sta %g0, [%g0] 0x36
        sta %g0, [%l5] 0x36
        CD_TAGS_CHECK(0, 0, 0, 0)
        CD_RESULTS(13)
        CD_CLEAR
        clr %l0                         /* every tag 0 again */
        clr %l1
        CD_WALK(cd_wr_e, 0x80000000, 4, 5, 128, 1, 3)
        CD_WALK(cd_wr_c, 0x80000000, 5, 6, 64, 1, 3)
        sta %g0, [%g0] 0x37
        sta %g0, [%g0] 0x36
END
#else
BEGIN(t_cdiag_data, "cache: SS20 ASI 0x0f/0x0d D and I data images hold every doubleword (4x128x4, 5x64x8)")
        SKIP_TEST
END
BEGIN(t_cdiag_tags, "cache: SS20 ASI 0x0e/0x0c PTAGs keep V/D/S or V and PA[35:12], STAGs the MRU and lock bits")
        SKIP_TEST
END
BEGIN(t_cdiag_flash, "cache: SS20 flash clears on the image: lock (VA 0x80000000) drops the locks, valid (VA 0) the PTAG V bits and the MRUs")
        SKIP_TEST
END
#endif
