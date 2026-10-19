/* Per-target constants for the bare-metal CPU test suite.
 *
 * The suite is a boot PROM image: it starts at the reset vector with the
 * MMU off and reports on ttya (ESCC channel A). One source, one image per
 * target, because the PROM's link address differs:
 *
 *   ss5-qemu  qemu-system-sparc -M SS-5    PROM at pa 0x0_70000000 (as on a
 *                                          real SPARCstation 5)
 *   ss20      qemu -M SS-20 and the core   PROM at pa 0xF_F0000000, run in
 *                                          boot mode from VA 0
 *
 * With the MMU off, data accesses are physical with pa[35:32] = 0. The SS20
 * PROM is therefore not readable at its link address: the start-up code
 * copies the image to RAM at pa 0 (SHADOW_ROM) so that constant tables and
 * strings can be read at their link addresses, while instructions keep
 * coming from the PROM in boot mode.
 */
#ifndef PLATFORM_H
#define PLATFORM_H

#if defined(TARGET_SS5_QEMU)
#  define ROM_BASE      0x70000000
#  define IO_ASI        0x20            /* MMU bypass, pa[35:32] = 0 */
#  define ESCC_BASE     0x71100000
#  define SHADOW_ROM    0
#elif defined(TARGET_SS20)
#  define ROM_BASE      0x00000000
#  define IO_ASI        0x2f            /* MMU bypass, pa[35:32] = 0xf */
#  define ESCC_BASE     0xf1100000
#  define SHADOW_ROM    1
#  define ROM_PA_LOW    0xf0000000      /* pa 0xf_f0000000 via ASI 0x2f */
#else
#  error "define TARGET_SS5_QEMU or TARGET_SS20"
#endif

/* ESCC (Z85C30) on sun4m: channel B control/data at +0/+2, channel A
 * (ttya) control/data at +4/+6. */
#define TTYA_CTRL       (ESCC_BASE + 4)
#define TTYA_DATA       (ESCC_BASE + 6)

/* RAM layout (physical, MMU off). The SS20 shadow copy of the PROM image
 * occupies the bottom of RAM, so everything else starts at 1 MiB. */
#define VARS            0x00100000      /* runtime variables, see VAR_* */
#define STACK_TOP       0x001ff000
#define SCRATCH         0x00200000      /* free for tests: 1 MiB */
#define SCRATCH_SIZE    0x00100000

/* SS20: the parked CPUs' mailboxes (runtime.S mp_park, t_msi.S), and the
 * MSI registers, through ASI 0x2f (pa 0xf_xxxx_xxxx). */
#define MP_MID          0x00180000      /* + 4n: CPU n's MID register read */
#define MP_COUNT        0x00180010      /* + 4n: CPU n's loop counter */
/* The dispatcher (runtime.S mp_park, mp_post, mp_wait): CPU 0 posts a
 * function and two arguments to CPU n's mailbox; CPU n runs it with the
 * MMU off, in boot mode, with traps disabled and no stack (leaf code
 * only: a trap there is error mode), stores %o0 in RES and clears FN. */
#define MP_CMD          0x00180100      /* + 0x10n: CPU n's mailbox */
#define MP_CMD_FN       0x0             /* function to run; 0 = idle/done */
#define MP_CMD_ARG0     0x4
#define MP_CMD_ARG1     0x8
#define MP_CMD_RES      0xc
#define MP_SYNC         0x00180200      /* + 4n: free for a test's handshake */
#define MP_WAIT_POLLS   100000          /* mp_wait gives up after this */
#define IOMMU_CTRL_PA   0xe0000000
#define MSI_ARB_PA      0xe0001008      /* arbiter enable */
#define MSI_MID_PA      0xe0002000      /* MID of the requesting master */

/* Runtime variables, offsets from VARS (kept in %g7 by convention). */
#define V_TRAP_EXPECT   0x00    /* tt the current test expects, or -1 */
#define V_TRAP_SEEN     0x04    /* tt of the last expected trap taken */
#define V_TRAP_PC       0x08
#define V_TRAP_NPC      0x0c
#define V_UNEXP_TT      0x10
#define V_UNEXP_PC      0x14
#define V_TEST_FAILS    0x18    /* failed checks in the current test */
#define V_WIN_OVF       0x1c    /* window overflow traps taken */
#define V_WIN_UNF       0x20    /* window underflow traps taken */
#define V_NWINDOWS      0x24
#define V_FPU           0x28    /* 1 when PSR.EF sticks */
#define V_PASS          0x2c
#define V_FAIL          0x30
#define V_TRAPS         0x34    /* all non-window traps taken */
#define V_DETAILS       0x38    /* detail lines printed for this test */
#define V_PSR0          0x3c    /* PSR at reset (impl/ver) */
#define V_TT_RESUME     0x40    /* 1: expected trap re-executes (jmp %l1) */
#define V_SKIP          0x44    /* set by a test that could not run */
#define V_SKIP_COUNT    0x48
#define V_TRAP_PSR      0x4c    /* PSR on entry of the last expected trap */
#define V_WBMODE        0x50    /* D-cache mode seen by t_cache_wrhit:
                                   0 unknown, 1 write-through, 2 write-back */
#define V_TRAP_RESUME   0x54    /* non-zero: the next expected trap resumes
                                   there (once), not after the trapping
                                   instruction: for instruction faults */
#define V_IRQ_MODE      0x58    /* non-zero: interrupts (tt 0x11-0x1f) are counted in
                                   V_IRQ_COUNT, the harness source acknowledged,
                                   and the interrupted instruction resumed */
#define V_IRQ_COUNT     0x5c
#define V_SIZE          0x80

/* ta SVC_SUPER: the runtime resumes after it in supervisor mode; a test
 * that switched to user mode (PSR.S = 0) comes back with it. */
#define SVC_SUPER       0x7e

/* Trap types (SPARC V8 table 7-1) */
#define TT_RESET        0x00
#define TT_IACC         0x01
#define TT_ILLEGAL      0x02
#define TT_PRIV         0x03
#define TT_FP_DISABLED  0x04
#define TT_WIN_OVF      0x05
#define TT_WIN_UNF      0x06
#define TT_ALIGN        0x07
#define TT_FP_EXC       0x08
#define TT_DACC         0x09
#define TT_TAG_OVF      0x0a
#define TT_CP_DISABLED  0x24
#define TT_IACC_ERR     0x21
#define TT_DACC_ERR     0x29
#define TT_DIV_ZERO     0x2a
#define TT_TICC(n)      (0x80 + (n))

#define PSR_EF          0x00001000
#define PSR_S           0x00000080
#define PSR_PS          0x00000040
#define PSR_ET          0x00000020
#define PSR_PIL_MASK    0x00000f00
#define PSR_ICC_SHIFT   20

#endif
