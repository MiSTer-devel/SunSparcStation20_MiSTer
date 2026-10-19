/* Test-writing macros. Conventions:
 *
 *   %g7        runtime variables (VARS); never touch it in a test
 *   %g1-%g6    free for tests, preserved by EXPECT
 *   %l0-%l7    free (each test runs in its own window: BEGIN does a save)
 *   %i0-%i5    free
 *   %o0-%o7    clobbered by EXPECT and by every call
 *
 * EXPECT changes the integer condition codes: read %psr into a register
 * before an EXPECT when the flags are what is being checked.
 */
#ifndef MACROS_H
#define MACROS_H

#include "platform.h"

/* Register a test: its name string and entry go in the test table. */
#define BEGIN(fn, name)                                          \
        .pushsection .rodata ;                                   \
.L_name_##fn: .asciz name ;                                      \
        .popsection ;                                            \
        .pushsection .testtab ;                                  \
        .word .L_name_##fn, fn ;                                 \
        .popsection ;                                            \
        .align 4 ;                                               \
fn:     save %sp, -96, %sp

#define END     ret ; restore

/* check obs (register) against exp (constant); code identifies the check */
#define EXPECT(obs, exp, code)                                   \
        mov obs, %o1 ; set exp, %o2 ; set code, %o0 ;            \
        call check_eq ; nop

/* check obs against the value in register expr */
#define EXPECT_R(obs, expr, code)                                \
        mov obs, %o1 ; mov expr, %o2 ; set code, %o0 ;           \
        call check_eq ; nop

/* arm the trap catcher: the next trap of type tt is recorded in
 * V_TRAP_SEEN/PC/NPC and the trapping instruction is skipped */
#define EXPECT_TRAP(tt)                                          \
        mov -1, %o0 ; st %o0, [%g7 + V_TRAP_SEEN] ;              \
        set tt, %o0 ; st %o0, [%g7 + V_TRAP_EXPECT]

/* after the trapping instruction: the trap must have been taken */
#define CHECK_TRAPPED(tt, code)                                  \
        ld [%g7 + V_TRAP_SEEN], %o1 ; set tt, %o2 ; set code, %o0 ; \
        call check_eq ; nop ;                                    \
        mov -1, %o0 ; st %o0, [%g7 + V_TRAP_EXPECT]

/* after an instruction that must NOT trap */
#define CHECK_NOT_TRAPPED(code)                                  \
        ld [%g7 + V_TRAP_SEEN], %o1 ; set -1, %o2 ; set code, %o0 ; \
        call check_eq ; nop ;                                    \
        mov -1, %o0 ; st %o0, [%g7 + V_TRAP_EXPECT]

/* mark the current test as skipped (e.g. no FPU) and return */
#define SKIP_TEST                                                \
        mov 1, %o0 ; st %o0, [%g7 + V_SKIP] ; ret ; restore

/* set the integer condition codes to nzvc (4-bit constant or register
 * form below); keeps every other PSR field */
#define SET_ICC(nzvc)                                            \
        rd %psr, %o0 ; set 0xff0fffff, %o1 ; and %o0, %o1, %o0 ; \
        set ((nzvc) << PSR_ICC_SHIFT), %o1 ; or %o0, %o1, %o0 ;  \
        wr %o0, %psr ; nop ; nop ; nop

/* read the condition codes as a 4-bit NZVC value into reg */
#define GET_ICC(reg)                                             \
        rd %psr, reg ; srl reg, PSR_ICC_SHIFT, reg ; and reg, 0xf, reg

#endif
