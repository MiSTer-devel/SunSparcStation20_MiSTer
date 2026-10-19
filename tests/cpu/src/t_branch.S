/* Control transfer: all 16 Bicc and Ticc conditions against all 16 icc
 * values (gen/cond_tab.S), annul bit, delay slots, call/jmpl links. */
#include "macros.h"

/* taken_bicc(cond %o0, icc %o1) -> %o0 = 1 if b<cond> is taken */
        .section .text
        .align 4
taken_bicc:
        rd %psr, %o2                    /* set the icc */
        set 0xff0fffff, %o3
        and %o2, %o3, %o2
        sll %o1, PSR_ICC_SHIFT, %o1
        or %o2, %o1, %o2
        wr %o2, %psr
        nop ; nop ; nop
        set bicc_stubs, %o2
        sll %o0, 4, %o0
        jmp %o2 + %o0
        nop
        .align 16
bicc_stubs:
        bn 1f ;   nop ; retl ; mov 0, %o0
        be 1f ;   nop ; retl ; mov 0, %o0
        ble 1f ;  nop ; retl ; mov 0, %o0
        bl 1f ;   nop ; retl ; mov 0, %o0
        bleu 1f ; nop ; retl ; mov 0, %o0
        bcs 1f ;  nop ; retl ; mov 0, %o0
        bneg 1f ; nop ; retl ; mov 0, %o0
        bvs 1f ;  nop ; retl ; mov 0, %o0
        ba 1f ;   nop ; retl ; mov 0, %o0
        bne 1f ;  nop ; retl ; mov 0, %o0
        bg 1f ;   nop ; retl ; mov 0, %o0
        bge 1f ;  nop ; retl ; mov 0, %o0
        bgu 1f ;  nop ; retl ; mov 0, %o0
        bcc 1f ;  nop ; retl ; mov 0, %o0
        bpos 1f ; nop ; retl ; mov 0, %o0
        bvc 1f ;  nop ; retl ; mov 0, %o0
1:      retl
        mov 1, %o0

/* taken_ticc(cond %o0, icc %o1) -> %o0 = 1 if t<cond> 0x21 trapped */
taken_ticc:
        save %sp, -96, %sp
        mov -1, %l0
        st %l0, [%g7 + V_TRAP_SEEN]
        mov TT_TICC(0x21), %l0
        st %l0, [%g7 + V_TRAP_EXPECT]
        rd %psr, %l2
        set 0xff0fffff, %l3
        and %l2, %l3, %l2
        sll %i1, PSR_ICC_SHIFT, %l1
        or %l2, %l1, %l2
        wr %l2, %psr
        nop ; nop ; nop
        set ticc_stubs, %l2
        sll %i0, 4, %l1
        jmpl %l2 + %l1, %o7
        nop
        ld [%g7 + V_TRAP_SEEN], %l0
        mov -1, %l1
        st %l1, [%g7 + V_TRAP_EXPECT]
        cmp %l0, TT_TICC(0x21)
        be,a 1f
        mov 1, %i0
        mov 0, %i0
1:      ret
        restore
        .align 16
ticc_stubs:
        tn 0x21 ; retl ; nop ; nop
        te 0x21 ; retl ; nop ; nop
        tle 0x21 ; retl ; nop ; nop
        tl 0x21 ; retl ; nop ; nop
        tleu 0x21 ; retl ; nop ; nop
        tcs 0x21 ; retl ; nop ; nop
        tneg 0x21 ; retl ; nop ; nop
        tvs 0x21 ; retl ; nop ; nop
        ta 0x21 ; retl ; nop ; nop
        tne 0x21 ; retl ; nop ; nop
        tg 0x21 ; retl ; nop ; nop
        tge 0x21 ; retl ; nop ; nop
        tgu 0x21 ; retl ; nop ; nop
        tcc 0x21 ; retl ; nop ; nop
        tpos 0x21 ; retl ; nop ; nop
        tvc 0x21 ; retl ; nop ; nop

BEGIN(t_bicc_conds, "branch: 16 Bicc conditions x 16 icc values")
        clr %l0                         /* icc */
1:      set cond_tab, %l2
        sll %l0, 2, %l3
        ld [%l2 + %l3], %l4             /* expected mask */
        clr %l1                         /* condition */
        clr %l5                         /* observed mask */
2:      mov %l1, %o0
        call taken_bicc
        mov %l0, %o1
        sll %o0, %l1, %o0
        or %l5, %o0, %l5
        add %l1, 1, %l1
        cmp %l1, 16
        bl 2b
        nop
        mov %l5, %o1
        mov %l4, %o2
        call check_eq
        mov %l0, %o0                    /* code = icc value */
        add %l0, 1, %l0
        cmp %l0, 16
        bl 1b
        nop
END

BEGIN(t_ticc_conds, "branch: 16 Ticc conditions x 16 icc values")
        clr %l0
1:      set cond_tab, %l2
        sll %l0, 2, %l3
        ld [%l2 + %l3], %l4
        clr %l1
        clr %l5
2:      mov %l1, %o0
        call taken_ticc
        mov %l0, %o1
        sll %o0, %l1, %o0
        or %l5, %o0, %l5
        add %l1, 1, %l1
        cmp %l1, 16
        bl 2b
        nop
        mov %l5, %o1
        mov %l4, %o2
        call check_eq
        mov %l0, %o0
        add %l0, 1, %l0
        cmp %l0, 16
        bl 1b
        nop
END

BEGIN(t_annul, "branch: annul bit and delay slots")
        /* untaken conditional with a=1: delay slot annulled */
        clr %l1
        cmp %g0, 1                      /* Z=0 */
        be,a 1f
        mov 1, %l1
1:      EXPECT(%l1, 0, 1)
        /* taken conditional with a=1: delay slot executed */
        clr %l1
        cmp %g0, %g0                    /* Z=1 */
        be,a 2f
        mov 2, %l1
        mov 0x99, %l1                   /* skipped */
2:      EXPECT(%l1, 2, 2)
        /* ba,a: delay slot always annulled */
        clr %l1
        ba,a 3f
        mov 3, %l1
3:      EXPECT(%l1, 0, 3)
        /* ba without annul: delay slot executed */
        clr %l1
        ba 4f
        mov 4, %l1
4:      EXPECT(%l1, 4, 4)
        /* bn,a: never taken, delay slot annulled */
        clr %l1
        bn,a 5f
        mov 5, %l1
        add %l1, 0x10, %l1
5:      EXPECT(%l1, 0x10, 5)
        /* bn without annul: delay slot executed, falls through */
        clr %l1
        bn 6f
        mov 6, %l1
        add %l1, 0x20, %l1
6:      EXPECT(%l1, 0x26, 6)
        /* untaken conditional, a=0: delay slot executed */
        clr %l1
        cmp %g0, 1
        be 7f
        mov 7, %l1
        add %l1, 0x30, %l1
7:      EXPECT(%l1, 0x37, 7)
END

BEGIN(t_call_jmpl, "branch: call/jmpl link register, computed jumps")
        /* call writes its own address into %o7 */
1:      call 2f
        nop
        ba 3f
        nop
2:      mov %o7, %l0
        retl
        nop
3:      set 1b, %l1
        EXPECT_R(%l0, %l1, 1)
        /* jmpl writes its own address into rd */
        set 5f, %l2
4:      jmpl %l2, %l3
        nop
        mov 0xbad, %l4                  /* skipped */
5:      set 4b, %l1
        EXPECT_R(%l3, %l1, 2)
        /* jmpl with register + immediate target */
        set 6f - 8, %l2
        jmpl %l2 + 8, %g0
        mov 0x61, %l4                   /* delay slot executes */
        mov 0xbad, %l4
6:      EXPECT(%l4, 0x61, 3)
        /* misaligned jmpl target traps with mem_address_not_aligned */
        set 7f + 2, %l2
        EXPECT_TRAP(TT_ALIGN)
        jmpl %l2, %g0
        nop
7:      CHECK_TRAPPED(TT_ALIGN, 4)
END
