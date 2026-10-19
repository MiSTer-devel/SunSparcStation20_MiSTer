/* SPDX-License-Identifier: GPL-2.0-or-later
 *
 * bench.c - CPI microbenchmarks for the profile (docs/benchmarks/
 * profile-20261014.md), so a pipeline change can be measured in minutes
 * of simulation instead of a NetBSD boot. perfbench.S calls bench_main()
 * with the MMU on (identity map, cacheable) and boot mode off.
 *
 * Each kernel is announced on ttya as "M-NAME" (the marker
 * tools/perfsplit.py splits +perf output by), then timed on the system
 * counter: "K NAME <iterations> <ticks of 500 ns>" in hex.
 *   DHRY   Dhrystone 2.1 (UnixBench's, unchanged): user-mode integer code
 *   COPY   4 KB page copy, word loop (fork/exec/file-copy-like stores)
 *   ZERO   4 KB page clear, doubleword stores (page zeroing)
 *   CHASE  pointer walk over 256 KB (loads that miss the L1)
 *   SORT   insertion sort of 256 ints (branchy, data-dependent)
 *   FP     a double-precision multiply-add loop (Whetstone-like FP) */
#include "shim.h"

#define SYS_CTR 0xf1310004u             /* ASI 0x2f: 500 ns ticks in 30:9 */

static unsigned int ticks(void)
{
    unsigned int v;
    __asm__ __volatile__("lda [%1] 0x2f, %0" : "=r"(v) : "r"(SYS_CTR));
    return (v >> 9) & 0x3fffff;
}

static void report(const char *name, unsigned int iters, unsigned int t0)
{
    unsigned int dt = (ticks() - t0) & 0x3fffff;
    puts("K ");
    puts(name);
    puts(" ");
    puthex(iters);
    puts(" ");
    puthex(dt);
    puts("\n");
}

/* --- the little libc ---------------------------------------------------- */
static char heap[4096];
static unsigned int heap_used;

void *malloc(size_t n)
{
    void *p = &heap[heap_used];
    heap_used += (n + 7) & ~7u;
    return p;
}

char *strcpy(char *d, const char *s)
{
    char *r = d;
    while ((*d++ = *s++) != 0)
        ;
    return r;
}

int strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}

void *memcpy(void *d, const void *s, size_t n)
{
    char *dd = d; const char *ss = s;
    while (n--) *dd++ = *ss++;
    return d;
}

void *memset(void *d, int c, size_t n)
{
    char *dd = d;
    while (n--) *dd++ = (char)c;
    return d;
}

/* --- the kernels -------------------------------------------------------- */
unsigned long dhry_run(unsigned long runs);

/* the big buffers live in RAM above the ROM image (256 KB at pa 0) and
   the suite's SCRATCH tables, inside mmu_on's 16 MB identity map */
#define page_a ((unsigned int *)0x00500000)
#define page_b ((unsigned int *)0x00501000)
#define chase  ((unsigned int *)0x00600000)  /* 65536 words, 256 KB */
static int sortbuf[256];
static double fpv[64];

static void k_copy(int n)
{
    for (int r = 0; r < n; r++) {
        volatile unsigned int *d = page_b;
        const unsigned int *s = page_a;
        for (int i = 0; i < 1024; i++)
            d[i] = s[i];
    }
}

static void k_zero(int n)
{
    for (int r = 0; r < n; r++) {
        volatile unsigned long long *d = (unsigned long long *)page_b;
        for (int i = 0; i < 512; i++)
            d[i] = 0;
    }
}

static unsigned int k_chase(int n)
{
    /* a stride that is not a power of two, so successive loads hit
       different lines and sets */
    for (unsigned int i = 0; i < 65536; i++)
        chase[i] = (i + 4099u) & 65535u;
    unsigned int p = 0;
    for (int i = 0; i < n; i++)
        p = chase[p];
    return p;
}

static void k_sort(int n)
{
    for (int r = 0; r < n; r++) {
        unsigned int x = 12345u + (unsigned int)r;
        for (int i = 0; i < 256; i++) {
            x = x * 1103515245u + 12345u;
            sortbuf[i] = (int)(x >> 8);
        }
        for (int i = 1; i < 256; i++) {
            int v = sortbuf[i], j = i - 1;
            while (j >= 0 && sortbuf[j] > v) {
                sortbuf[j + 1] = sortbuf[j];
                j--;
            }
            sortbuf[j + 1] = v;
        }
    }
}

static double k_fp(int n)
{
    for (int i = 0; i < 64; i++)
        fpv[i] = 1.0 + i * 0.001;
    double acc = 0.0, k = 0.999;
    for (int r = 0; r < n; r++)
        for (int i = 0; i < 64; i++)
            acc = acc * k + fpv[i];
    return acc;
}

volatile unsigned int bench_sink;

void bench_main(void)
{
    unsigned int t;

    for (int i = 0; i < 1024; i++)
        page_a[i] = i * 3u;

    puts("M-DHRY\n");
    t = ticks();
    report("DHRY", (unsigned int)dhry_run(2000), t);

    puts("M-COPY\n");
    t = ticks();
    k_copy(256);
    report("COPY", 256, t);

    puts("M-ZERO\n");
    t = ticks();
    k_zero(512);
    report("ZERO", 512, t);

    puts("M-CHASE\n");
    t = ticks();
    bench_sink = k_chase(100000);
    report("CHASE", 100000, t);

    puts("M-SORT\n");
    t = ticks();
    k_sort(16);
    report("SORT", 16, t);

    puts("M-FP\n");
    t = ticks();
    bench_sink = (unsigned int)k_fp(2000);
    report("FP", 2000, t);

    puts("M-END\n");
}
