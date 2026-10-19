/* FPU first cut: moves, arithmetic in both precisions, conversions,
 * compares and FBfcc, FSR exception bits. Skipped when PSR.EF does not
 * stick (no FPU). FSR.ver (bits 19:17) is implementation-specific and
 * masked out. Expected values are IEEE 754 round-to-nearest results. */
#include "macros.h"

#define FTMP    (SCRATCH + 0x100)
#define LDF(val, freg)  set val, %o0 ; st %o0, [%g7 + V_SIZE] ; ld [%g7 + V_SIZE], freg
#define STF(freg, reg)  st freg, [%g7 + V_SIZE] ; ld [%g7 + V_SIZE], reg
#define FSR_MASK        0xfff1ffff

#define FPU_OR_SKIP                                             \
        ld [%g7 + V_FPU], %o0 ; tst %o0 ; bne 1f ; nop ;        \
        SKIP_TEST ; 1:                                          \
        ld [%g7 + V_SKIP], %fsr        /* FSR = 0 */

BEGIN(t_fpu_single, "fpu: single precision add/sub/mul/div/sqrt, moves")
        FPU_OR_SKIP
        LDF(0x3f800000, %f0)            /* 1.0 */
        LDF(0x40000000, %f1)            /* 2.0 */
        fadds %f0, %f1, %f2
        STF(%f2, %l0)
        EXPECT(%l0, 0x40400000, 1)      /* 3.0 */
        fsubs %f0, %f1, %f2
        STF(%f2, %l0)
        EXPECT(%l0, 0xbf800000, 2)      /* -1.0 */
        LDF(0x3fc00000, %f3)            /* 1.5 */
        fmuls %f3, %f1, %f2
        STF(%f2, %l0)
        EXPECT(%l0, 0x40400000, 3)
        LDF(0x40400000, %f4)            /* 3.0 */
        fdivs %f0, %f4, %f2
        STF(%f2, %l0)
        EXPECT(%l0, 0x3eaaaaab, 4)      /* 1/3 rounded to nearest */
        fsqrts %f1, %f2
        STF(%f2, %l0)
        EXPECT(%l0, 0x3fb504f3, 5)      /* sqrt(2) */
        fnegs %f0, %f2
        STF(%f2, %l0)
        EXPECT(%l0, 0xbf800000, 6)
        fabss %f2, %f5
        STF(%f5, %l0)
        EXPECT(%l0, 0x3f800000, 7)
        fmovs %f4, %f6
        STF(%f6, %l0)
        EXPECT(%l0, 0x40400000, 8)
END

BEGIN(t_fpu_double, "fpu: double precision arithmetic, even/odd pairs")
        FPU_OR_SKIP
        LDF(0x3ff00000, %f0)            /* 1.0 */
        LDF(0x00000000, %f1)
        LDF(0x3cb00000, %f2)            /* 2^-52 */
        LDF(0x00000000, %f3)
        faddd %f0, %f2, %f4
        STF(%f4, %l0)
        STF(%f5, %l1)
        EXPECT(%l0, 0x3ff00000, 1)
        EXPECT(%l1, 0x00000001, 2)      /* 1 + ulp */
        LDF(0x40080000, %f6)            /* 3.0 */
        LDF(0x00000000, %f7)
        fdivd %f0, %f6, %f8
        STF(%f8, %l0)
        STF(%f9, %l1)
        EXPECT(%l0, 0x3fd55555, 3)
        EXPECT(%l1, 0x55555555, 4)
        fmuld %f8, %f6, %f10            /* (1/3)*3 rounds back to 1.0 */
        STF(%f10, %l0)
        STF(%f11, %l1)
        EXPECT(%l0, 0x3ff00000, 5)
        EXPECT(%l1, 0x00000000, 6)
        LDF(0x40000000, %f12)           /* 2.0 */
        LDF(0x00000000, %f13)
        fsqrtd %f12, %f14
        STF(%f14, %l0)
        STF(%f15, %l1)
        EXPECT(%l0, 0x3ff6a09e, 7)
        EXPECT(%l1, 0x667f3bcd, 8)
        fsubd %f0, %f12, %f16
        STF(%f16, %l0)
        EXPECT(%l0, 0xbff00000, 9)
END

BEGIN(t_fpu_convert, "fpu: fitos/fitod/fstoi/fdtoi/fstod/fdtos")
        FPU_OR_SKIP
        LDF(0xfffffff9, %f0)            /* integer -7 */
        fitos %f0, %f1
        STF(%f1, %l0)
        EXPECT(%l0, 0xc0e00000, 1)
        fitod %f0, %f2
        STF(%f2, %l0)
        STF(%f3, %l1)
        EXPECT(%l0, 0xc01c0000, 2)
        EXPECT(%l1, 0, 3)
        LDF(0x402ccccd, %f4)            /* 2.7f */
        fstoi %f4, %f5                  /* rounds toward zero */
        STF(%f5, %l0)
        EXPECT(%l0, 2, 4)
        LDF(0xc0059999, %f6)            /* -2.7 double */
        LDF(0x9999999a, %f7)
        fdtoi %f6, %f8
        STF(%f8, %l0)
        EXPECT(%l0, 0xfffffffe, 5)
        LDF(0x3fc00000, %f9)            /* 1.5f */
        fstod %f9, %f10
        STF(%f10, %l0)
        STF(%f11, %l1)
        EXPECT(%l0, 0x3ff80000, 6)
        EXPECT(%l1, 0, 7)
        LDF(0x3fd55555, %f12)           /* 1/3 double */
        LDF(0x55555555, %f13)
        fdtos %f12, %f14
        STF(%f14, %l0)
        EXPECT(%l0, 0x3eaaaaab, 8)
END

BEGIN(t_fpu_compare, "fpu: fcmps/fcmpd fcc values and FBfcc")
        FPU_OR_SKIP
        LDF(0x3f800000, %f0)            /* 1.0 */
        LDF(0x40000000, %f1)            /* 2.0 */
        LDF(0x7fc00000, %f2)            /* quiet NaN */
        fcmps %f0, %f1
        nop
        st %fsr, [%g7 + V_SIZE]
        ld [%g7 + V_SIZE], %l0
        srl %l0, 10, %l0
        and %l0, 3, %l0
        EXPECT(%l0, 1, 1)               /* fcc = 1: rs1 < rs2 */
        fcmps %f1, %f0
        nop
        st %fsr, [%g7 + V_SIZE]
        ld [%g7 + V_SIZE], %l0
        srl %l0, 10, %l0
        and %l0, 3, %l0
        EXPECT(%l0, 2, 2)               /* greater */
        fcmps %f0, %f0
        nop
        st %fsr, [%g7 + V_SIZE]
        ld [%g7 + V_SIZE], %l0
        srl %l0, 10, %l0
        and %l0, 3, %l0
        EXPECT(%l0, 0, 3)               /* equal */
        fcmps %f0, %f2
        nop
        st %fsr, [%g7 + V_SIZE]
        ld [%g7 + V_SIZE], %l0
        srl %l0, 10, %l0
        and %l0, 3, %l0
        EXPECT(%l0, 3, 4)               /* unordered */
        /* FBfcc on the last compare (unordered) */
        clr %l1
        fbu 2f
        nop
        mov 1, %l1
2:      EXPECT(%l1, 0, 5)
        fcmps %f0, %f1
        nop
        clr %l1
        fbl,a 3f
        mov 2, %l1
        mov 3, %l1
3:      EXPECT(%l1, 2, 6)
        fcmps %f0, %f1
        nop
        clr %l1
        fbge 4f
        nop
        mov 4, %l1
4:      EXPECT(%l1, 4, 7)
END

BEGIN(t_fpu_fsr, "fpu: FSR cexc/aexc on inexact, divide-by-zero, invalid")
        FPU_OR_SKIP
        LDF(0x3f800000, %f0)            /* 1.0 */
        LDF(0x40400000, %f1)            /* 3.0 */
        LDF(0x00000000, %f2)            /* 0.0 */
        fdivs %f0, %f1, %f3             /* inexact */
        st %fsr, [%g7 + V_SIZE]
        ld [%g7 + V_SIZE], %l0
        set FSR_MASK, %l7
        and %l0, %l7, %l0
        EXPECT(%l0, 0x00000021, 1)      /* aexc.nx | cexc.nx */
        fdivs %f0, %f2, %f3             /* 1/0 = +inf, dz */
        STF(%f3, %l1)
        EXPECT(%l1, 0x7f800000, 2)
        st %fsr, [%g7 + V_SIZE]
        ld [%g7 + V_SIZE], %l0
        and %l0, %l7, %l0
        EXPECT(%l0, 0x00000062, 3)      /* aexc nx|dz, cexc dz */
        fdivs %f2, %f2, %f3             /* 0/0 = NaN, invalid */
        st %fsr, [%g7 + V_SIZE]
        ld [%g7 + V_SIZE], %l0
        and %l0, %l7, %l0
        EXPECT(%l0, 0x00000270, 4)      /* aexc nv|dz|nx, cexc nv */
        fadds %f0, %f0, %f3             /* exact: cexc cleared */
        st %fsr, [%g7 + V_SIZE]
        ld [%g7 + V_SIZE], %l0
        and %l0, %l7, %l0
        EXPECT(%l0, 0x00000260, 5)
END

/* Trapped underflow (TEM.UF): FLT_MIN * FLT_MIN = 2^-252 and DBL_MIN *
 * DBL_MIN leave nothing of the mantissa after the denormalisation; the
 * result is tiny all the same: fp_exception (deferred on the core, taken
 * at the next FP store, which is blocked; precise under QEMU), ftt 1,
 * cexc UF | NX. This is the Sun POST's "FPU SP/DP Underflow CEXC" tests.
 * Then untrapped: the result is +0 with cexc and aexc UF | NX. */
#define UF_TRAP_CASE(fpop, s1, d, fst, code)                            \
        set 0x0f800000, %o0 ; st %o0, [%g7 + V_SIZE] ;                  \
        ld [%g7 + V_SIZE], %fsr         /* TEM = all */ ;              \
        set FTMP, %l0 ; st %g0, [%l0] ; st %g0, [%l0 + 4] ;             \
        EXPECT_TRAP(TT_FP_EXC) ;                                        \
        fpop s1, s1, d ; fst d, [%l0] ; nop ;                           \
        CHECK_TRAPPED(TT_FP_EXC, code) ;                                \
        std %fq, [%g7 + V_SIZE]         /* leave exception mode */ ;   \
        st %fsr, [%g7 + V_SIZE] ; ld [%g7 + V_SIZE], %l1 ;              \
        set FSR_MASK, %l7 ; and %l1, %l7, %l1 ;                         \
        EXPECT(%l1, 0x0f804005, code + 1) /* TEM, ftt 1, cexc UF|NX */ ;\
        ld [%l0], %l2 ; EXPECT(%l2, 0, code + 2) /* the store blocked */ ; \
        ld [%l0 + 4], %l2 ; EXPECT(%l2, 0, code + 3)

BEGIN(t_fpu_underflow, "fpu: FLT_MIN*FLT_MIN, DBL_MIN*DBL_MIN: trapped UF|NX (store blocked), untrapped +0")
        FPU_OR_SKIP
        LDF(0x00800000, %f1)            /* FLT_MIN */
        LDF(0x12345678, %f3)            /* a store that got through shows */
        LDF(0x00100000, %f4)            /* DBL_MIN */
        LDF(0x00000000, %f5)
        LDF(0x12345678, %f6)
        LDF(0x9abcdef0, %f7)
        UF_TRAP_CASE(fmuls, %f1, %f3, st, 1)
        UF_TRAP_CASE(fmuld, %f4, %f6, std, 5)
        ld [%g7 + V_SKIP], %fsr         /* untrapped */
        fmuls %f1, %f1, %f3
        STF(%f3, %l2)
        EXPECT(%l2, 0, 9)
        st %fsr, [%g7 + V_SIZE]
        ld [%g7 + V_SIZE], %l1
        and %l1, %l7, %l1
        EXPECT(%l1, 0x000000a5, 10)     /* aexc UF|NX, cexc UF|NX */
        fmuld %f4, %f4, %f6
        STF(%f6, %l2)
        EXPECT(%l2, 0, 11)
        STF(%f7, %l2)
        EXPECT(%l2, 0, 12)
        st %fsr, [%g7 + V_SIZE]
        ld [%g7 + V_SIZE], %l1
        and %l1, %l7, %l1
        EXPECT(%l1, 0x000000a5, 13)
END

/* The shape of Solaris libm's __libm__k_sin small-argument path (sin()
 * returned its argument on the board): the double argument arrives in
 * %o0/%o1, the callee moves it into %f0 by std/ldd through its frame,
 * builds a polynomial with ldd constants and fmuld/faddd, and the final
 * faddd into %f0 sits in the delay slot of a taken annulling branch,
 * followed straight by ret/restore twice (the sin() wrapper). */
        .align 8
.L_ks_c: .word 0x40000000, 0          /* 2.0 */
         .word 0x3ff00000, 0          /* 1.0 */
.L_ks_kern:                            /* (x, y): x + x*(x*x*2) if y == 0 */
        save %sp, -192, %sp
        std %i0, [%fp - 8]
        sethi %hi(0x80000000), %l5
        andn %i0, %l5, %l1
        ldd [%fp - 8], %f0
        set .L_ks_c, %l0
        sethi %hi(0x3e400000), %l2
        cmp %l1, %l2
        bge,a 1f
        fmuld %f0, %f0, %f2
        ba 3f
        fdtoi %f0, %f4
1:      ldd [%l0], %f10
        fmuld %f2, %f10, %f10
        std %i2, [%fp - 16]
        andncc %i2, %l5, %g0
        fmuld %f0, %f10, %f10
        be,a 3f
        faddd %f0, %f10, %f0
        ldd [%fp - 16], %f4
        faddd %f4, %f10, %f10
        ba 3f
        faddd %f0, %f10, %f0
3:      ret
        restore
.L_ks_wrap:                            /* sin(x) for a small x */
        save %sp, -192, %sp
        mov %i0, %o0
        mov %i1, %o1
        clr %o2
        call .L_ks_kern
        clr %o3
        ret
        restore

BEGIN(t_fpu_ksin, "fpu: libm k_sin shape: faddd in a taken annulling slot, std/ldd moves, nested ret")
        FPU_OR_SKIP
        set .L_ks_c + 8, %l0
        ldd [%l0], %f0                  /* the caller's %f0 = x = 1.0 */
        set 0x3ff00000, %o0
        clr %o1
        call .L_ks_wrap
        nop
        std %f0, [%g7 + V_SIZE]
        ld [%g7 + V_SIZE], %l1
        ld [%g7 + V_SIZE + 4], %l2
        EXPECT(%l1, 0x40080000, 1)      /* 1 + 1*2 = 3.0 */
        EXPECT(%l2, 0, 2)
        /* again with x = 0.5: 0.5 + 0.5*0.5 = 0.75 */
        set 0x3fe00000, %o0
        clr %o1
        call .L_ks_wrap
        nop
        std %f0, [%g7 + V_SIZE]
        ld [%g7 + V_SIZE], %l1
        EXPECT(%l1, 0x3fe80000, 3)
END
