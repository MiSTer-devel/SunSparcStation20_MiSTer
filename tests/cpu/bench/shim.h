/* SPDX-License-Identifier: GPL-2.0-or-later
 *
 * shim.h - the little of libc the perfbench kernels need, freestanding:
 * they run inside tests/cpu/src/perfbench.S (the suite's runtime, the MMU
 * on, cacheable, out of boot mode), compiled by clang to assembly. */
#ifndef PERFBENCH_SHIM_H
#define PERFBENCH_SHIM_H

typedef unsigned int size_t;

void *malloc(size_t n);
char *strcpy(char *d, const char *s);
int strcmp(const char *a, const char *b);
void *memcpy(void *d, const void *s, size_t n);
void *memset(void *d, int c, size_t n);

/* the runtime's (tests/cpu/src/runtime.S) */
void puts(const char *s);
void puthex(unsigned int v);

#endif
