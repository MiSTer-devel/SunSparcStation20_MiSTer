/**
 ** Standalone startup code for Linux PROM emulator.
 ** Copyright 1999 Pete A. Zaitcev
 ** This code is licensed under GNU General Public License.
 **/
/*
 * $Id: head.S,v 1.12 2002/07/23 05:47:09 zaitcev Exp $
 */

#define __ASSEMBLY
#include "autoconf.h"
#include "psr.h"
#include "asm/asi.h"
#include "asm/crs.h"
#define NO_QEMU_PROTOS
#define NO_OPENBIOS_PROTOS
#include "arch/common/fw_cfg.h"

#define CFG_ADDR 0x00000510
#define CFG_ASI  0x2d

#define PHYS_JJ_INTR0	0x71E00000  /* CPU0 interrupt control registers */

#define PHYS_SS10_INTR0 	0xf1400000

#define PHYS_SS2_INTR0 	0xf5000000
#define SER_ADDR2       0xf1000004

#define PHYS_SS1000_SBI         0x02800000
#define SER_ADDR1000            0x00200004

#define ASI_CACHE_FLUSH_COMBINED_ALL 0x15

#define WRITE_PAUSE    nop; nop; nop; /* Have to do this after %wim/%psr chg */

#ifdef CONFIG_TACUS
/* The RAM size, in r: SYSCONF[31:20] (MMU register 0xD00), or the memory
   chosen in the MiSTer OSD if less: AUXIO0 + 0x1C reads 0x5A in bits 31:24
   and megabytes in 11:0 (SYSCONF[4]: SS20, the AUXIO at pa 0xf_f180_0000;
   else the SS5's, at 0x7190_0000). Every CPU must use the same size: the
   page tables and the other CPUs' mailbox sit below its top. Clobbers t1
   and t2; uses the local labels 7, 8 and 9. */
#define TACUS_RAMSIZE(r, t1, t2) \
        set     0xd00, r; \
        lda     [r] ASI_M_MMUREGS, t1; \
        srl     t1, 20, r; \
        sll     r, 20, r; \
        andcc   t1, 0x10, %g0; \
        bne     7f; \
         nop; \
        set     0x7190001c, t1; \
        lda     [t1] ASI_M_BYPASS, t1; \
        ba      8f; \
         nop; \
7:      set     0xf180001c, t1; \
        lda     [t1] 0x2f, t1; \
8:      srl     t1, 24, t2; \
        cmp     t2, 0x5a; \
        bne     9f; \
         sll    t1, 20, t1; \
        tst     t1; \
        be      9f; \
         nop; \
        cmp     t1, r; \
        bgeu    9f; \
         nop; \
        mov     t1, r; \
9:
#endif

        .globl	entry, _entry

	.section ".text", "ax"
	.align	8

        /* Memory map:
	 *
	 * Top +-------------------------+
	 *     | SMP CPU table           |
	 *     | s + 0x1f00 ... 0x1f0f   |
	 *     | s + 0x1f0c valid        |
	 *     | s + 0x1f08 entry        |
	 *     | s + 0x1f04 ctxtbl       |
	 *     | s + 0x1f00 ctx          |
	 *     +-------------------------+
	 *     | Bootstrap               |
	 *     | MMU L3 tables 8 * 0x100 |
	 *     | s + 0xa00 ... 0x11ff    |
	 *     +-------------------------+
	 *     | Bootstrap               |
	 *     | MMU L2 tables 2 * 0x100 |
	 *     | s + 0x800 ... 0x9ff     |
	 *     +-------------------------+
	 *     | Bootstrap               |
	 *     | MMU L1 table 0x400      |
	 *     | s + 0x400 ... 0x7ff     |
	 *     +-------------------------+
	 *     | Bootstrap               |
	 *     | MMU L0/ctx table 0x400  |
	 *     | s + 0x000 ... 0x3ff     |
	 *     +-------------------------+
	 *     |                         |
	 *     | ROM into RAM            |
	 *     |                         |
	 *     +-------------------------+
	 *     :                         :
	 * Bottom
	 */

/*
 * Entry point
 * We start execution from here.
 */
_entry:
entry:
        /* Switch to our main context.
         * Main context is statically defined in C.
         */
        ! Check signature "QEMU"
#ifdef CONFIG_TACUS
        ! Get RAM SIZE
        TACUS_RAMSIZE(%g1, %g3, %g4)

        ! Get CPU number
        ! MMU Register 0xx : Control Register [3:2]
        lda     [%g0] ASI_M_MMUREGS, %g7
        srl     %g7, 2, %g7
        and     %g7, 3, %g7
        
        sta     %g0, [%g0] ASI_M_BYPASS ! [0000] = 0000
        
#else
        set     CFG_ADDR, %g5
        mov     FW_CFG_SIGNATURE, %g2
        stha    %g2, [%g5] CFG_ASI
        add     %g5, 2, %g5
        lduba   [%g5] CFG_ASI, %g2
        cmp     %g2, 'Q'
        bne     bad_conf
         nop
        lduba   [%g5] CFG_ASI, %g2
        cmp     %g2, 'E'
        bne     bad_conf
         nop
        lduba   [%g5] CFG_ASI, %g2
        cmp     %g2, 'M'
        bne     bad_conf
         nop
        lduba   [%g5] CFG_ASI, %g2
        cmp     %g2, 'U'
        bne     bad_conf
         nop

        ! Get memory size from configuration device
        ! NB: little endian format
        mov     FW_CFG_RAM_SIZE, %g2
        sub     %g5, 2, %g5
        stha    %g2, [%g5] CFG_ASI
        add     %g5, 2, %g5
        lduba   [%g5] CFG_ASI, %g4

        lduba   [%g5] CFG_ASI, %g3
        sll     %g3, 8, %g3
        or      %g3, %g4, %g4

        lduba   [%g5] CFG_ASI, %g3
        sll     %g3, 16, %g3
        or      %g3, %g4, %g4

        lduba   [%g5] CFG_ASI, %g3
        sll     %g3, 24, %g3
        or      %g3, %g4, %g1
        ! %g1 contains end of memory
        
        ! Get CPU number
        ! XXX: not all CPUs should have MXCC
        set     0x1c00f00, %g2
        ldda    [%g2] ASI_CONTROL, %g2
        srl     %g3, 24, %g7
        subcc   %g7, 8, %g7

        ! Only the first CPU clears memory
        bnz     clear_done
         nop
        
        ! Get kernel address from configuration device
        ! NB: little endian format
        mov     FW_CFG_KERNEL_ADDR, %g2
        sub     %g5, 2, %g5
        stha    %g2, [%g5] CFG_ASI
        add     %g5, 2, %g5
        lduba   [%g5] CFG_ASI, %g4

        lduba   [%g5] CFG_ASI, %g3
        sll     %g3, 8, %g3
        or      %g3, %g4, %g4

        lduba   [%g5] CFG_ASI, %g3
        sll     %g3, 16, %g3
        or      %g3, %g4, %g4

        lduba   [%g5] CFG_ASI, %g3
        sll     %g3, 24, %g3
        or      %g3, %g4, %g4

        ! If kernel address is set, don't clear from base of RAM in order to
        ! leave the kernel image intact
        mov     0, %g6
        cmp     %g4, 0
        beq     clear_mem
         nop

        ! Start from 16M
        set     0x1000000, %g6

clear_mem:
        sta     %g0, [%g6] ASI_M_BYPASS
        add     %g6, 0x4, %g6
        cmp     %g6, %g1
        bl      clear_mem
         nop

clear_done:
#endif
        ! Start of private memory in %g6
        set     0x2000, %g3
        sub     %g1, %g3, %g6

        ! Get machine ID from configuration device
#ifndef CONFIG_TACUS
        mov     FW_CFG_MACHINE_ID, %g2
        sub     %g5, 2, %g5
        stha    %g2, [%g5] CFG_ASI
        add     %g5, 2, %g5
        lduba   [%g5] CFG_ASI, %g4

        lduba   [%g5] CFG_ASI, %g3
        sll     %g3, 8, %g3
        or      %g3, %g4, %g4
#else
        ! Machine ID SS-10 = 64, SS-5 = 32
        set     0x78400000, %g4  /* DMA2 */
        stba    %g0, [%g4] 0x20
        lduba   [%g4] 0x20, %g4
        cmp     %g4,0xA0
        bz      ss5
         set     65, %g4
        b       ss20
         nop
 ss5:   set     32, %g4
 ss20:  
        
#endif
        mov     %g4, %y

        cmp     %g4, 96
        bgeu    ss1000
         cmp    %g4, 64
        bgeu    ss10
         cmp    %g4, 32
        blu     ss2
         nop

        ! Ok, this is SS-5, uniprocessor
        ba      first_cpu
         nop
 
ss10:
        ! Ok, this is SS-10/20 or SS-600MP

        tst     %g7
        bz      first_cpu
         nop
         
         
#ifdef CONFIG_TACUS


        ! Flush cache
        set 0,%g2
        set 0x4000,%g3
loopflush_mp:
        sta    %g0, [%g2] ASI_CACHE_FLUSH_COMBINED_ALL
        sta    %g0, [%g2] ASI_M_TXTC_TAG
        sta    %g0, [%g2] ASI_M_DATAC_TAG
        cmp  %g2,%g3
        bne  loopflush_mp
         add  %g2,4,%g2
        nop
       
        ! Wait for end of CPU0 initialisation
        set     0xFFFE0000, %g5
        set     0xdadad0d0, %g6
waitinit:
        udiv    %g5,%g5,%g0
        udiv    %g5,%g5,%g0
        udiv    %g5,%g5,%g0
        udiv    %g5,%g5,%g0
        lda     [%g0] ASI_M_BYPASS, %g3
        cmp     %g3,%g6
        bne     waitinit
         nop
        
        ! get memory size, as CPU 0 does: its page tables are at the top
        TACUS_RAMSIZE(%g1, %g3, %g4)         ! G1 = MEM SIZE
        
        ! Set   MMU registers
        set     0x2000, %g3
        sub     %g1, %g3, %g7               ! ctx table at s+0x0
        set     AC_M_CTPR, %g2
        srl     %g7, 4, %g7
        sta     %g7, [%g2] ASI_M_MMUREGS	! set ctx table ptr
        set     AC_M_CXR, %g2
        sta     %g0, [%g2] ASI_M_MMUREGS	! context 0

        ! Jump to protected mode
        set     highmom_mp - 0x0fd00000 , %g2
        
        ! MMU enable
        set 0x001 , %g3 // XCE=1, DCE=0, ICE=0 ,MMU_EN=1, BootMode=0, NoFault=0
        
        jmp     %g2
         nop
        nop
        nop
highmom_mp:
        nop
        nop
        nop
        sta    %g3, [%g0] ASI_M_MMUREGS	! enable mmu
        nop
        nop
        nop
        set     highmem_mp , %g2
        jmp %g2
         nop
        nop
highmem_mp:
        nop
        nop
        

        ! Get CPU number
        ! MMU Register 0xx : Control Register [3:2]
        lda     [%g0] ASI_M_MMUREGS, %g7
        srl     %g7, 2, %g7
        and     %g7, 3, %g7
        
        ! Clear softints used for SMP CPU startup
        set     PHYS_SS10_INTR0 + 0x04, %g3
        sll     %g7, 12, %g2
        add     %g3, %g2, %g2
        set     0xffffffff, %g3
        sta     %g3, [%g2] ASI_M_CTL         ! clear softints
        add     %g2, 4, %g2
        sta     %g0, [%g2] ASI_M_CTL         ! clear softints
        
        ! TACUS: wait with the I-cache on (MCNTL.ICE), flushed first: with
        ! it off this CPU fetched every instruction of the loop from memory
        ! and took half the memory from the first one, for as long as no OS
        ! starts it (a uniprocessor kernel never does). Off again below.
        set     0, %g2
        set     0x4000, %g3
flush_mp1:
        sta     %g0, [%g2] ASI_CACHE_FLUSH_COMBINED_ALL
        cmp     %g2, %g3
        bne     flush_mp1
         add    %g2, 8, %g2
        lda     [%g0] ASI_M_MMUREGS, %g3
        or      %g3, 0x200, %g3
        sta     %g3, [%g0] ASI_M_MMUREGS

        ! Wait for an softint to awake secondary CPUs
        set     PHYS_SS10_INTR0, %g3
        sll     %g7, 12, %g2
        add     %g3, %g2, %g2
        set     0, %g6
        set     0xFFFE0000, %g5
waiting:
        inc     %g6
        udiv    %g5,%g5,%g0
        udiv    %g5,%g5,%g0
        udiv    %g5,%g5,%g0
        udiv    %g5,%g5,%g0
        cmp     %g6, 20
        bl      waiting
         nop
        set     0, %g6
        lda     [%g2] ASI_M_CTL, %g3            ! read pending softints
        btst    %g3,%g5
        bz      waiting
         nop
#endif
        
        ! Clear softints used for SMP CPU startup
        set     PHYS_SS10_INTR0 + 0x04, %g3
        sll     %g7, 12, %g2
        add     %g3, %g2, %g2
        set     0xffffffff, %g3
        sta     %g3, [%g2] ASI_M_CTL         ! clear softints
        add     %g2, 4, %g2
        sta     %g0, [%g2] ASI_M_CTL         ! clear softints
        
        ! The I-cache off again, as the OS expects it, and flushed
        lda     [%g0] ASI_M_MMUREGS, %g3
        andn    %g3, 0x200, %g3
        sta     %g3, [%g0] ASI_M_MMUREGS
        set     0, %g2
        set     0x4000, %g3
flush_mp2:
        sta     %g0, [%g2] ASI_CACHE_FLUSH_COMBINED_ALL
        cmp     %g2, %g3
        bne     flush_mp2
         add    %g2, 8, %g2

        ! Get start of private memory in %g6
        set     0x2000, %g2
        sub     %g1, %g2, %g6
        
        ! SMP init, jump to user specified address
        set	0x1f04, %g5
        add     %g6, %g5, %g5                 ! ctxtbl
        lda     [%g5] ASI_M_BYPASS, %g2
        sta     %g0, [%g5] ASI_M_BYPASS
        set     AC_M_CTPR, %g3
        sta     %g2, [%g3] ASI_M_MMUREGS        ! set ctx table ptr
        set	0x1f00, %g5
        add     %g6, %g5, %g5                 ! ctx
        lda     [%g5] ASI_M_BYPASS, %g2
        sta     %g0, [%g5] ASI_M_BYPASS
        set     AC_M_CXR, %g3
        sta     %g2, [%g3] ASI_M_MMUREGS        ! set context
        set	0x1f08, %g5
        add     %g6, %g5, %g5                 ! entry
        lda     [%g5] ASI_M_BYPASS, %g2
        sta     %g0, [%g5] ASI_M_BYPASS

        ! MMU on and the core's L2 TLB (bit 6, also gated by the OSD
        ! option), as CPU 0 has it: the OS keeps the bit (Solaris does)
        set 0x041 , %g3 // XCE=1, DCE=0, ICE=0 ,MMU_EN=1, BootMode=0, NoFault=0
        sta    %g3, [%g0] ASI_M_MMUREGS	    ! configure mmu
        nop
        nop
        nop
        jmp %g2        ! jump to kernel
         nop

ss2:
        ! Ok, this is SS-2
        set     ss2_error, %o2
        b       ss2_ss1000_halt
         nop

ss1000:
        ! Ok, this is SS-1000 or SS-2000
        set     ss1000_error, %o2
        b       ss2_ss1000_halt
         nop

first_cpu:
        /* Create temporary page tables and map the ROM area to end of
        RAM. This will be done properly in iommu.c later. */
        ! Calculate start of page tables etc. to %g6
        set     0x2000, %g4
        sub     %g1, %g4, %g6                   ! start of private memory

        mov     %g6, %g2                        ! ctx table at s+0x0
        add	%g2, 0x400, %g3			! l1 table at s+0x400
        srl	%g3, 0x4, %g3
        or	%g3, 0x1, %g3
        sta	%g3, [%g2] ASI_M_BYPASS
        add	%g2, 0x400, %g2			! s+0x400
        add	%g2, 0x400, %g3			! l2 table for ram (00xxxxxx) at s+0x800
        srl	%g3, 0x4, %g3
        or	%g3, 0x1, %g3
        sta	%g3, [%g2] ASI_M_BYPASS
        add	%g2, 0x500, %g3			! l2 table for rom (ffxxxxxx) at s+0x900
        add	%g2, 0x3fc, %g2			! s+0x7fc
        srl	%g3, 0x4, %g3
        or	%g3, 0x1, %g3
        sta	%g3, [%g2] ASI_M_BYPASS
#ifdef CONFIG_TACUS
        sub %g2, 0x3c, %g2          ! l2 table for rom (f0xxxxxx) at s+0x900
        sta	%g3, [%g2] ASI_M_BYPASS
        add %g2, 0x3c,%g2
#endif
        add	%g2, 0x4, %g2			! s+0x800
        set     0x40, %g6
        set	((7 << 2) | 2), %g3		! 7 = U: --- S: RWX (main memory)
1:      sta	%g3, [%g2] ASI_M_BYPASS
        add     %g2, 4, %g2
        deccc   %g6
        bne     1b
         nop
                                                ! s+0x900

#ifdef CONFIG_TACUS
        add	%g2, 0xa00 - 0x900, %g3
        srl	%g3, 0x4, %g3
        or	%g3, 0x1, %g3
        sta	%g3, [%g2] ASI_M_BYPASS
#endif
        
        add	%g2, 0xa00 - 0x900, %g3		! l3 table for rom at s+0xa00        
        add	%g2, 0x0d0, %g2			! s+0x9d0
        srl	%g3, 0x4, %g3
        or	%g3, 0x1, %g3
        sta	%g3, [%g2] ASI_M_BYPASS
        add	%g2, 4, %g2			! s+0x9d4
        add	%g2, 0xb00 - 0x9d4, %g3		! 2nd l3 table for rom at s+0xb00
        srl	%g3, 0x4, %g3
        or	%g3, 0x1, %g3
        sta	%g3, [%g2] ASI_M_BYPASS
        add	%g2, 4, %g2			! s+0x9d8
        add	%g2, 0xc00 - 0x9d8, %g3		! 3rd l3 table for rom at s+0xc00
        srl	%g3, 0x4, %g3
        or	%g3, 0x1, %g3
        sta	%g3, [%g2] ASI_M_BYPASS
        add	%g2, 4, %g2			! s+0x9dc
        add	%g2, 0xd00 - 0x9dc, %g3		! 4th l3 table for rom at s+0xd00
        srl	%g3, 0x4, %g3
        or	%g3, 0x1, %g3
        sta	%g3, [%g2] ASI_M_BYPASS
        add	%g2, 4, %g2			! s+0x9e0
        add	%g2, 0xe00 - 0x9e0, %g3		! 5th l3 table for rom at s+0xe00
        srl	%g3, 0x4, %g3
        or	%g3, 0x1, %g3
        sta	%g3, [%g2] ASI_M_BYPASS
        add	%g2, 4, %g2			! s+0x9e4
        add	%g2, 0xf00 - 0x9e4, %g3		! 6th l3 table for rom at s+0xf00
        srl	%g3, 0x4, %g3
        or	%g3, 0x1, %g3
        sta	%g3, [%g2] ASI_M_BYPASS
        add	%g2, 4, %g2			! s+0x9e8
        add	%g2, 0x1000 - 0x9e8, %g3	! 7th l3 table for rom at s+0x1000
        srl	%g3, 0x4, %g3
        or	%g3, 0x1, %g3
        sta	%g3, [%g2] ASI_M_BYPASS
        add	%g2, 4, %g2			! s+0x9ec
        add	%g2, 0x1100 - 0x9ec, %g3	! 8th l3 table for rom at s+0x1100
        srl	%g3, 0x4, %g3
        or	%g3, 0x1, %g3
        sta	%g3, [%g2] ASI_M_BYPASS
      add	%g2, 0xa00-0x9ec, %g2		! s+0xa00

        /* Use end of ram for code, rodata, data, and bss
        sections. SunOS wants to write to trap table... */
#ifndef CONFIG_TACUS
        set	_end, %g6
        set	_start, %g4
#else
        set	_end   - 0x0fd00000, %g6
        set	_start - 0x0fd00000, %g4
#endif
        
        sub     %g6, %g4, %g6
        sub     %g1, %g6, %g3
        set	0x1000, %g5
        sub     %g3, %g5, %g3
        sub     %g3, %g5, %g3                   ! start of ROM copy
        mov     %g3, %g7                        ! save in %g7
        srl     %g6, 12, %g6                    ! # of all pages
1:      srl	%g3, 0x4, %g4
        or	%g4, ((7 << 2) | 2), %g4        ! 7 = U: --- S: RWX
        sta	%g4, [%g2] ASI_M_BYPASS
        add	%g2, 4, %g2
        add	%g3, %g5, %g3
        deccc	%g6
        bne	1b
         nop

        mov	%g1, %g6                        ! %g6 = memory size

        /* Copy the code, rodata and data sections from ROM. */
        sub     %g7, 4, %g3
        
#ifndef CONFIG_TACUS
        set	_start - 4, %g4                 ! First address of TEXT - 4
        set	_bss, %g5                       ! Last address of DATA
#else
        set	_start - 0x0fd00000 - 4, %g4                 ! First address of TEXT - 4
!        set	_bss   - 0x0fd00000- 0x20000, %g5                       ! Last address of DATA
        set	_bss   - 0x0fd00000, %g5                       ! Last address of DATA
#endif
        ba	2f
         nop
1:
        lda     [%g4] ASI_M_KERNELTXT, %g1
        sta	%g1, [%g3] ASI_M_BYPASS
2:
        cmp     %g4, %g5
        add     %g3, 0x4, %g3
        bl      1b
         add    %g4, 0x4, %g4

        set     0x2000, %g3
        sub     %g6, %g3, %g7                   ! ctx table at s+0x0
        set     AC_M_CTPR, %g2
        srl     %g7, 4, %g7
        sta     %g7, [%g2] ASI_M_MMUREGS	! set ctx table ptr
        set     AC_M_CXR, %g2
        sta     %g0, [%g2] ASI_M_MMUREGS	! context 0
#ifndef CONFIG_TACUS
        set     highmem, %g2
        set	1, %g1
        jmp     %g2
         sta    %g1, [%g0] ASI_M_MMUREGS	! enable mmu
highmem:
#else

/* Purge cache instructions & data */

        set 0,%g1
        //  16K
        set 0x4000,%g2
#define ASI_CACHE_FLUSH_COMBINED_ALL 0x15

loopflush:
        sta    %g0, [%g1] ASI_CACHE_FLUSH_COMBINED_ALL
        sta    %g0, [%g1] ASI_M_TXTC_TAG
        sta    %g0, [%g1] ASI_M_DATAC_TAG
        cmp  %g1,%g2
        bne  loopflush
         add  %g1,4,%g1
        nop
        
        set     highmom - 0x0fd00000 , %g2
        
        /* MMU enable */
        set 0x001 , %g1 // XCE=1, DCE=0, ICE=0 ,MMU_EN=1, BootMode=0, NoFault=0
        
        jmp     %g2
         nop
        nop
        nop
highmom:
        nop
        nop
        nop
        sta    %g1, [%g0] ASI_M_MMUREGS	! enable mmu
        nop
        nop
        nop
        set     highmem , %g2
        jmp %g2
         nop
        nop
highmem:
        nop
        nop
        nop
        TACUS_RAMSIZE(%g1, %g3, %g4) // G1=RAMSIZE
        sub     %g1,0x1700,%g1
        sta     %g0, [%g1] ASI_M_BYPASS
        add     %g1,0x400,%g1
        sta     %g0, [%g1] ASI_M_FLUSH_PROBE
      
        nop
        nop
        /* RAZ zone mem pour NextSTEP */
        nop
        /*
        set 0,%g1
        set 0x6800000, %o0
        set  0x800000, %g2
zz600000:       
        stda %g0, [%o0] ASI_M_BYPASS
        subcc %g2,8,%g2
        bne zz600000
        add %o0,8,%o0
        */
        
        set   0xdadad0d0,%g1
        sta   %g1, [%g0] ASI_M_BYPASS
        
        udiv    %g1,%g1,%g0
        udiv    %g1,%g1,%g0
        udiv    %g1,%g1,%g0
        udiv    %g1,%g1,%g0
        udiv    %g1,%g1,%g0
        udiv    %g1,%g1,%g0
        udiv    %g1,%g1,%g0
        udiv    %g1,%g1,%g0
        udiv    %g1,%g1,%g0
        udiv    %g1,%g1,%g0
        udiv    %g1,%g1,%g0
        udiv    %g1,%g1,%g0
        udiv    %g1,%g1,%g0
        udiv    %g1,%g1,%g0
        udiv    %g1,%g1,%g0
        udiv    %g1,%g1,%g0
        udiv    %g1,%g1,%g0
        udiv    %g1,%g1,%g0
        udiv    %g1,%g1,%g0
        udiv    %g1,%g1,%g0

        sta   %g0, [%g0] ASI_M_BYPASS
        
#endif
        /*
         * The code which enables traps is a simplified version of
         * kernel head.S.
         *
         * We know number of windows as 8 so we do not calculate them.
         * The deadwood is here for any case.
         */

        /* Turn on Supervisor, EnableFloating, and all the PIL bits.
         * Also puts us in register window zero with traps off.
         */
        set	(PSR_PS | PSR_S | PSR_PIL | PSR_EF), %g2
        wr	%g2, 0x0, %psr
        WRITE_PAUSE

        /* Zero out our BSS section. */
        set	_bss - 4, %o0           ! First address of BSS
        set	_estack - 4, %o1        ! Last address of BSS
        ba	2f
         nop
1:
        st	%g0, [%o0]
2:
        subcc	%o0, %o1, %g0
        bl	1b
         add	%o0, 0x4, %o0

        set     trap_table, %g1
        wr      %g1, 0x0, %tbr

        set     qemu_mem_size, %g1
        st      %g6, [%g1]

        set     _end, %o0                       ! Store va->pa conversion factor
        set     _start, %o2
        sub     %o0, %o2, %o0
        sub     %g6, %o0, %o0
        set     0x2000, %o1
        sub     %o0, %o1, %o0                   ! start of ROM copy
        sub     %o2, %o0, %o0                   ! start of ROM copy
        set     va_shift, %g1
        st      %o0, [%g1]

        set     qemu_machine_type, %g1
        mov     %y, %g2
        st      %g2, [%g1]

        /* Compute NWINDOWS and stash it away. Now uses %wim trick explained
         * in the V8 manual. Ok, this method seems to work, Sparc is cool...
         * No, it doesn't work, have to play the save/readCWP/restore trick.
         */

        wr      %g0, 0x0, %wim                  ! so we do not get a trap
        WRITE_PAUSE

        save

        rd      %psr, %g3

        restore

        and     %g3, 0x1f, %g3
        add     %g3, 0x1, %g3

        mov     2, %g1
        wr      %g1, 0x0, %wim                  ! make window 1 invalid
        WRITE_PAUSE

        cmp     %g3, 0x7
        bne     1f
         nop

        /* !!! Self-modifying code !!! */

        /* Adjust our window handling routines to
         * do things correctly on 7 window Sparcs.
         */
#define PATCH_INSN(src, dest) \
        set     src, %g5; \
        set     dest, %g2; \
        ld      [%g5], %g4; \
        st      %g4, [%g2];

        /* Patch for window spills... */
        PATCH_INSN(spnwin_patch1_7win, spnwin_patch1)
        PATCH_INSN(spnwin_patch2_7win, spnwin_patch2)

        /* Patch for window fills... */
        PATCH_INSN(fnwin_patch1_7win, fnwin_patch1)
        PATCH_INSN(fnwin_patch2_7win, fnwin_patch2)
        

1:
        /*nop
        set 0x701 , %g1 // XCE=1, DCE=0, ICE=1 ,MMU_EN=1, BootMode=0, NoFault=0
        sta    %g1, [%g0] ASI_M_MMUREGS // Enable instruction cache
        nop*/
        nop
        
        /* Finally, turn on traps so that we can call c-code. */
        rd	%psr, %g3
        wr	%g3, PSR_ET, %psr
        WRITE_PAUSE

        set     0, %fp
        call    __switch_context_nosave
         nop

        /* We get here when the main context switches back to
         * the boot context.
         * Return to previous bootloader.
         */
        ret
         nop

ss2_ss1000_halt:
        set     SER_ADDR2, %o0
        set     SER_ADDR1000, %o1
        mov     0x05, %o3 /* Reg 5, TXCTRL2 */
        stba    %o3, [%o0] ASI_M_BYPASS
        stba    %o3, [%o1] ASI_M_CTL
        mov     0x68, %o3 /* 8 bits, Tx enabled */
        stba    %o3, [%o0] ASI_M_BYPASS
        stba    %o3, [%o1] ASI_M_CTL
        add     %o0, 2, %o0
        add     %o1, 2, %o1

1:      lduba   [%o2] ASI_M_KERNELTXT, %o3
        cmp     %o3, 0
        be      2f
         nop
        stba    %o3, [%o0] ASI_M_BYPASS
        stba    %o3, [%o1] ASI_M_CTL
        b       1b
         inc    %o2
bad_conf:
2:      b       2b
         nop

        .section .rodata
ss2_error:
        .string "Sun4c machines are not supported by OpenBIOS yet, freezing\r\n"
ss1000_error:
        .string "Sun4d machines are not supported by OpenBIOS yet, freezing\r\n"
