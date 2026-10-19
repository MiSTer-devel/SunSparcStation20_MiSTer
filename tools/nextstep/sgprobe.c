/* sgprobe: BuildDisk's FindDisks scan through /dev/sg0, with every result
 * printed (NeXTSTEP 3.3 for SPARC; no libraries, raw syscalls).
 *   sgprobe        targets 0-7, LUNs 0-7, stop a target's LUNs at the first
 *                  failed INQUIRY (as FindDisks), then READ CAPACITY and
 *                  TEST UNIT READY on each device found
 *   sgprobe T      only target T, LUN 0, ten INQUIRYs in a row
 *   sgprobe g[C]   (with the above) the request's option bits not zero, as
 *                  BuildDisk leaves them uninitialized (C: the low byte)
 * tools/nextstep/build.sh builds it, tools/nextstep/sgprobe.sh runs it on the
 * board. GPL-2.0-or-later. */

typedef unsigned char u8;

struct scsi_adr { u8 t, l; };
struct scsi_req {
    u8 cdb[12];
    int dma_dir;            /* 0 read, 1 write */
    void *addr;
    int dma_max;
    int ioto;
    int io_status;          /* 0x1c */
    u8 scsi_status;         /* 0x20 */
    u8 pad[3];
    u8 sense[28];           /* 0x24 */
    int dma_xfr;            /* 0x40 */
    int tv_sec, tv_usec;    /* 0x44 */
    int opts;               /* 0x4c */
    int pad2[2];
};

#define SGIOCSTL  0x80027300
#define SGIOCREQ  0xc0587301
#define SGIOCENAS 0x20007302

__asm__(".section .text.start,\"ax\"\n"
        ".globl _start\n"
        "_start:\n"
        "  ld [%sp + 0x40], %o0\n"
        "  call main\n"
        "  add %sp, 0x44, %o1\n"
        "  mov 1, %g1\n"
        "  ta 0\n"
        "  nop\n");

static int sys(int n, int a, int b, int c)
{
    register int g1 __asm__("g1") = n;
    register int o0 __asm__("o0") = a;
    register int o1 __asm__("o1") = b;
    register int o2 __asm__("o2") = c;
    __asm__ volatile("ta 0\n\tbcc 1f\n\tnop\n\tsub %%g0, %%o0, %%o0\n1:"
                     : "+r"(o0), "+r"(o1), "+r"(o2) : "r"(g1)
                     : "memory", "cc", "o3", "o4", "o5", "g2", "g3", "g4");
    return o0;
}

#define SYS_write 4
#define SYS_open 5
#define SYS_ioctl 54
#define SYS_select 93

void *memset(void *d, int c, unsigned n)
{
    u8 *p = d;
    while (n--) *p++ = c;
    return d;
}

void *memcpy(void *d, const void *s, unsigned n)
{
    u8 *p = d; const u8 *q = s;
    while (n--) *p++ = *q++;
    return d;
}

#define DATA __attribute__((section(".data")))
#define obuf ((char *)0x8000)   /* zero-filled part of the segment */
static int olen DATA;

static void flush(void)
{
    if (olen) sys(SYS_write, 1, (int)obuf, olen);
    olen = 0;
}

static void putc_(char c)
{
    obuf[olen++] = c;
    if (c == '\n' || olen == 2048) flush();
}

static void puts_(const char *s) { while (*s) putc_(*s++); }

static void hex(unsigned v, int n)
{
    while (n--) putc_("0123456789abcdef"[(v >> (4 * n)) & 15]);
}

static void dec(int v)
{
    char b[12]; int i = 0;
    if (v < 0) { putc_('-'); v = -v; }
    do { b[i++] = '0' + v % 10; v /= 10; } while (v);
    while (i) putc_(b[--i]);
}

static void sleep20ms(void)
{
    int tv[2] = { 0, 20000 };
    {
        register int g1 __asm__("g1") = SYS_select;
        register int o0 __asm__("o0") = 0;
        register int o1 __asm__("o1") = 0;
        register int o2 __asm__("o2") = 0;
        register int o3 __asm__("o3") = 0;
        register int o4 __asm__("o4") = (int)tv;
        __asm__ volatile("ta 0" : "+r"(o0), "+r"(o1), "+r"(o2), "+r"(o3), "+r"(o4)
                         : "r"(g1) : "memory", "cc", "o5", "g2", "g3", "g4");
    }
}

static int fd DATA;
#define data ((u8 *)0x8800)
static u8 garbage DATA;  /* nonzero: the request's option bits left as BuildDisk leaves them */

static int req(struct scsi_req *r, const u8 *cdb, int n, int len)
{
    int i;
    memset(r, 0, sizeof *r);
    memcpy(r->cdb, cdb, n);
    r->dma_dir = 0;
    r->addr = data;
    r->dma_max = len;
    r->ioto = 10;
    if (garbage) r->opts = 0x0fe00000 | garbage;
    for (i = 0; i < len; i++) data[i] = 0xee;
    return sys(SYS_ioctl, fd, SGIOCREQ, (int)r);
}

static void show(const char *what, struct scsi_req *r, int ret, int len)
{
    int i;
    puts_("  "); puts_(what); puts_(" ret="); dec(ret);
    puts_(" io="); dec(r->io_status);
    puts_(" st="); hex(r->scsi_status, 2);
    puts_(" xfr="); dec(r->dma_xfr);
    puts_(" t="); dec(r->tv_sec * 1000000 + r->tv_usec); puts_("us");
    if (r->io_status == 2) {
        puts_(" sense="); for (i = 0; i < 14; i++) hex(r->sense[i], 2);
    }
    if (len) {
        puts_("\n   ");
        for (i = 0; i < len && i < 36; i++) hex(data[i], 2);
    }
    putc_('\n');
}

static int inquiry(int t, int l, int verbose)
{
    struct scsi_req r;
    static const u8 inq[6] = { 0x12, 0, 0, 0, 36, 0 };
    u8 c[6]; int tries = 5, ret;
    memcpy(c, inq, 6);
    c[1] = l << 5;
    for (;;) {
        ret = req(&r, c, 6, 36);
        show("INQUIRY", &r, ret, verbose || r.io_status == 0 ? 36 : 0);
        if (ret == -1 || ret < 0) return 0;
        if (r.io_status == 0) return 1;
        if (r.io_status != 2 && r.io_status != 0xd) return 0;
        if (--tries == 0) return 0;
        sleep20ms();
    }
}

static int settarget(int t, int l)
{
    struct scsi_adr a;
    int ret;
    a.t = t; a.l = l;
    ret = sys(SYS_ioctl, fd, SGIOCSTL, (int)&a);
    puts_("t"); dec(t); puts_(" l"); dec(l); puts_(": SGIOCSTL "); dec(ret); putc_('\n');
    return ret;
}

int main(int argc, char **argv)
{
    int t, l, found[8], nf = 0, i, ret, only = -1;
    struct scsi_req r;
    static const u8 rcap[10] = { 0x25 };
    static const u8 tur[6] = { 0 };

    for (i = 1; i < argc; i++) {
        if (argv[i][0] == 'g') garbage = argv[i][1] ? argv[i][1] : 0x0a;
        else if (argv[i][0] >= '0' && argv[i][0] <= '7') only = argv[i][0] - '0';
    }
    fd = sys(SYS_open, (int)"/dev/sg0", 2, 0);
    puts_("open /dev/sg0: "); dec(fd); putc_('\n');
    if (fd < 0) { flush(); return 1; }
    ret = sys(SYS_ioctl, fd, SGIOCENAS, 0);
    puts_("SGIOCENAS: "); dec(ret); putc_('\n');
    if (only >= 0) {
        if (settarget(only, 0) == 0)
            for (i = 0; i < 10; i++) inquiry(only, 0, 1);
        flush();
        return 0;
    }
    for (t = 0; t < 8; t++)
        for (l = 0; l < 8; l++) {
            if (settarget(t, l) != 0) continue;
            if (!inquiry(t, l, 0)) break;
            if ((data[0] & 0x1f) <= 0x1e && l == 0) found[nf++] = t;
        }
    for (i = 0; i < nf; i++) {
        t = found[i];
        puts_("target "); dec(t); putc_('\n');
        settarget(t, 0);
        ret = req(&r, tur, 6, 0);
        show("TEST UNIT READY", &r, ret, 0);
        ret = req(&r, rcap, 10, 8);
        show("READ CAPACITY", &r, ret, 8);
        inquiry(t, 0, 1);
    }
    puts_("done\n");
    flush();
    return 0;
}
