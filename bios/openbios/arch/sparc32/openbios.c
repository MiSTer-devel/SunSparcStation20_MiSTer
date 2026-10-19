/* tag: openbios forth environment, executable code
 *
 * Copyright (C) 2003 Patrick Mauritz, Stefan Reinauer
 *
 * See the file "COPYING" for further information about
 * the copyright and warranty status of this work.
 */

#include "config.h"
#include "libopenbios/openbios.h"
#include "libopenbios/bindings.h"
#include "libopenbios/console.h"
#include "drivers/drivers.h"
#include "asm/types.h"
#include "dict.h"
#include "kernel/kernel.h"
#include "kernel/stack.h"
#include "arch/common/nvram.h"
#include "packages/nvram.h"
#include "../../drivers/timer.h" // XXX
#include "libopenbios/sys_info.h"
#include "openbios.h"
#include "boot.h"
#include "romvec.h"
#include "openprom.h"
#include "psr.h"
#include "libopenbios/video.h"
#define NO_QEMU_PROTOS
#include "arch/common/fw_cfg.h"
#include "arch/sparc32/ofmem_sparc32.h"

#define MEMORY_SIZE     (128*1024)       /* 128K ram for hosted system */
#define UUID_FMT "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x"
#define FW_CFG_SUN4M_DEPTH   (FW_CFG_ARCH_LOCAL + 0x00)

int qemu_machine_type;

#define HWCONF_SP605 (1)     // Xilinx SP605         DVI/VGA : Chrontel CH7301C
#define HWCONF_C5G   (0x11)  // Terasic CycloneV GX  HDMI    : Analog Devices ADV7513
#define HWCONF_MiSTer (0x12) // Terasic DE10nano     HDMI    : Auto Set

struct hwdef {
    uint64_t iommu_base, slavio_base;
    uint64_t intctl_base, counter_base, nvram_base, ms_kb_base, serial_base;
    unsigned long fd_offset, counter_offset, intr_offset;
    unsigned long aux1_offset, aux2_offset;
    uint64_t dma_base, esp_base, le_base;
    uint64_t tcx_base;
    int intr_ncpu;
    int mid_offset;
    int machine_id_low, machine_id_high;
};

static const struct hwdef hwdefs[] = {
    /* SS-5 */
    {
        .iommu_base   = 0x10000000,
        .tcx_base     = 0x50000000,
        .slavio_base  = 0x71000000,
        .ms_kb_base   = 0x71000000,
        .serial_base  = 0x71100000,
        .nvram_base   = 0x71200000,
#ifdef CONFIG_TACUS
        .fd_offset    = -1,
#else
        .fd_offset    = 0x00400000,
#endif
        .counter_offset = 0x00d00000,
        .intr_offset  = 0x00e00000,
        .intr_ncpu    = 1,
        .aux1_offset  = 0x00900000,
        .aux2_offset  = 0x00910000,
        .dma_base     = 0x78400000,
        .esp_base     = 0x78800000,
        .le_base      = 0x78c00000,
        .mid_offset   = 0,
        .machine_id_low = 32,
        .machine_id_high = 63,
    },
    /* SS-10, SS-20 */
    {
        .iommu_base   = 0xfe0000000ULL,
        .tcx_base     = 0xe20000000ULL,
        .slavio_base  = 0xff1000000ULL,
        .ms_kb_base   = 0xff1000000ULL,
        .serial_base  = 0xff1100000ULL,
        .nvram_base   = 0xff1200000ULL,
#ifdef CONFIG_TACUS
        .fd_offset    = -1,
#else
        .fd_offset    = 0x00700000, // 0xff1700000ULL,
#endif
        .counter_offset = 0x00300000, // 0xff1300000ULL,
        .intr_offset  = 0x00400000, // 0xff1400000ULL,
        .intr_ncpu    = 4,
        .aux1_offset  = 0x00800000, // 0xff1800000ULL,
        .aux2_offset  = 0x00a01000, // 0xff1a01000ULL,
        .dma_base     = 0xef0400000ULL,
        .esp_base     = 0xef0800000ULL,
        .le_base      = 0xef0c00000ULL,
        .mid_offset   = 8,
        .machine_id_low = 64,
        .machine_id_high = 65,
    },
    /* SS-600MP */
    {
        .iommu_base   = 0xfe0000000ULL,
        .tcx_base     = 0xe20000000ULL,
        .slavio_base  = 0xff1000000ULL,
        .ms_kb_base   = 0xff1000000ULL,
        .serial_base  = 0xff1100000ULL,
        .nvram_base   = 0xff1200000ULL,
        .fd_offset    = -1,
        .counter_offset = 0x00300000, // 0xff1300000ULL,
        .intr_offset  = 0x00400000, // 0xff1400000ULL,
        .intr_ncpu    = 4,
        .aux1_offset  = 0x00800000, // 0xff1800000ULL,
        .aux2_offset  = 0x00a01000, // 0xff1a01000ULL, XXX should not exist
        .dma_base     = 0xef0081000ULL,
        .esp_base     = 0xef0080000ULL,
        .le_base      = 0xef0060000ULL,
        .mid_offset   = 8,
        .machine_id_low = 66,
        .machine_id_high = 66,
    },
};

static const struct hwdef *hwdef;

void setup_timers(void)
{
}

static volatile int t;
void udelay(unsigned int usecs)
{
    int i;
    for (i=0;i<usecs*10;i++) t=i;
}

void mdelay(unsigned int msecs)
{
}


static __inline__ unsigned int srmmu_get_mmureg(void)
{
        unsigned int retval;
	__asm__ __volatile__("lda [%%g0] %1, %0\n\t" :
			     "=r" (retval) :
			     "i" (4));
	return retval;
}

static __inline__ void srmmu_set_mmureg(unsigned long regval)
{
	__asm__ __volatile__("sta %0, [%%g0] %1\n\t" : :
			     "r" (regval), "i" (4) : "memory");

}

static void cache_flush_all(void)
{
 unsigned i;
 //Flush combined I&D : Any : 0x15
 for (i=0;i<16384;i+=8) {
	__asm__ __volatile__("sta %%g0,[%0] %1\n\t" :  :
	             "r" (i),
	             "i" (0x15) : "memory");
 }
}

static inline unsigned lda0(volatile unsigned addr)
{
    unsigned ret;
    __asm__ __volatile__("lda [%1] 32, %0\n\t"
                         :"=r"(ret):"r"(addr):"memory");
    return ret;
}

static void mb86904_init(void)
{
    uint8_t v;
    v=lda0(0x10003018) >> 24;
    
    PUSH(32);
    fword("encode-int");
    push_str("cache-line-size");
    fword("property");

    PUSH(512);
    fword("encode-int");
    push_str("cache-nlines");
    fword("property");

    PUSH(v);
    fword("encode-int");
    push_str("mask_rev");
    fword("property");
}

/* MBus ID of the CPU node being built (setup_cpu), for the module
 * addresses in its "reg": MBus module n (MID 8 + n) answers at
 * 0xf_f8000000 + (n << 24), so each CPU node gets its own unit address
 * (TI,TMS390Z55@f,f8fffffc, @f,f9fffffc, ...), as on a real SS10/SS20.
 * Solaris builds a devinfo node per CPU node from these. */
static int cpu_mid;

static void tms390z55_init(void)
{
    uint32_t mbase = 0xf8000000 + (((cpu_mid - 8) & 3) << 24);


#ifndef CONFIG_TACUS
    push_str("");
    fword("encode-string");
    push_str("ecache-parity?");
    fword("property");

    push_str("");
    fword("encode-string");
    push_str("bfill?");
    fword("property");

    push_str("");
    fword("encode-string");
    push_str("bcopy?");
    fword("property");

#endif
    push_str("");
    fword("encode-string");
    push_str("cache-physical?");
    fword("property");

    PUSH(0xf);
    fword("encode-int");
    PUSH(mbase + 0x00fffffc);
    fword("encode-int");
    fword("encode+");
    PUSH(4);
    fword("encode-int");
    fword("encode+");

    PUSH(0xf);
    fword("encode-int");
    fword("encode+");
    PUSH(mbase + 0x00c00000);
    fword("encode-int");
    fword("encode+");
    PUSH(0x1000);
    fword("encode-int");
    fword("encode+");

    PUSH(0xf);
    fword("encode-int");
    fword("encode+");
    PUSH(mbase);
    fword("encode-int");
    fword("encode+");
    PUSH(0x1000);
    fword("encode-int");
    fword("encode+");

    PUSH(0xf);
    fword("encode-int");
    fword("encode+");
    PUSH(mbase + 0x00800000);
    fword("encode-int");
    fword("encode+");
    PUSH(0x1000);
    fword("encode-int");
    fword("encode+");
    push_str("reg");
    fword("property");
}

static void rt625_init(void)
{
    PUSH(32);
    fword("encode-int");
    push_str("cache-line-size");
    fword("property");

    PUSH(512);
    fword("encode-int");
    push_str("cache-nlines");
    fword("property");

}

static void bad_cpu_init(void)
{
    printk("This CPU is not supported yet, freezing.\n");
    for(;;);
}

struct cpudef {
    unsigned long iu_version;
    const char *name;
    int psr_impl, psr_vers, impl, vers;
    int dcache_line_size, dcache_lines, dcache_assoc;
    int icache_line_size, icache_lines, icache_assoc;
    int ecache_line_size, ecache_lines, ecache_assoc;
    int mmu_nctx;
    void (*initfn)(void);
};

static const struct cpudef sparc_defs[] = {
    {
        .iu_version = 0x00 << 24, /* Impl 0, ver 0 */
        .name = "FMI,MB86900",
        .initfn = bad_cpu_init,
    },
    {
        .iu_version = 0x04 << 24, /* Impl 0, ver 4 */
        .name = "FMI,MB86904",
        .psr_impl = 0,
        .psr_vers = 4,
        .impl = 0,
        .vers = 4,
        .dcache_line_size = 0x10,
        .dcache_lines = 0x200,
        .dcache_assoc = 1,
        .icache_line_size = 0x20,
        .icache_lines = 0x200,
        .icache_assoc = 1,
        .ecache_line_size = 0x20,
        .ecache_lines = 0x4000,
        .ecache_assoc = 1,
        .mmu_nctx = 0x100,
        .initfn = mb86904_init,
    },
    {
        .iu_version = 0x05 << 24, /* Impl 0, ver 5 */
        .name = "FMI,MB86907",
        .psr_impl = 0,
        .psr_vers = 5,
        .impl = 0,
        .vers = 5,
        .dcache_line_size = 0x20,
        .dcache_lines = 0x200,
        .dcache_assoc = 1,
        .icache_line_size = 0x20,
        .icache_lines = 0x200,
        .icache_assoc = 1,
        .ecache_line_size = 0x20,
        .ecache_lines = 0x4000,
        .ecache_assoc = 1,
        .mmu_nctx = 0x100,
        .initfn = mb86904_init,
    },
    {
        .iu_version = 0x10 << 24, /* Impl 1, ver 0 */
        .name = "LSI,L64811",
        .initfn = bad_cpu_init,
    },
    {
        .iu_version = 0x11 << 24, /* Impl 1, ver 1 */
        .name = "CY,CY7C601",
        .psr_impl = 1,
        .psr_vers = 1,
        .impl = 1,
        .vers = 1,
        .mmu_nctx = 0x10,
        .initfn = bad_cpu_init,
    },
    {
        .iu_version = 0x13 << 24, /* Impl 1, ver 3 */
        .name = "CY,CY7C611",
        .initfn = bad_cpu_init,
    },
    {
        .iu_version = 0x40000000,
#ifndef CONFIG_TACUS
        .name = "TI,TMS390Z55",
#else
        /* TACUS: a SuperSPARC with its on-chip caches only, no SuperCache
           (MXCC): an SM50 module, as the Sun PROM names it on the core */
        .name = "TI,TMS390Z50",
#endif
        .psr_impl = 4,
        .psr_vers = 0,
        .impl = 0,
        .vers = 4,
        .dcache_line_size = 0x20,
        .dcache_lines = 0x80,
        .dcache_assoc = 4,
        .icache_line_size = 0x40,
        .icache_lines = 0x40,
        .icache_assoc = 5,
        .ecache_line_size = 0x20,
        .ecache_lines = 0x8000,
        .ecache_assoc = 1,
#ifndef CONFIG_TACUS
        .mmu_nctx = 0x10000,
#else
        .mmu_nctx = 0x100,
#endif
        .initfn = tms390z55_init,
    },
    {
        .iu_version = 0x41000000,
        .name = "TI,TMS390S10",
        .psr_impl = 4,
        .psr_vers = 1,
        .impl = 4,
        .vers = 1,
        .dcache_line_size = 0x10,
        .dcache_lines = 0x80,
        .dcache_assoc = 4,
        .icache_line_size = 0x20,
        .icache_lines = 0x80,
        .icache_assoc = 5,
        .ecache_line_size = 0x20,
        .ecache_lines = 0x8000,
        .ecache_assoc = 1,
        .mmu_nctx = 0x10000,
        .initfn = tms390z55_init,
    },
    {
        .iu_version = 0x42000000,
        .name = "TI,TMS390S10",
        .psr_impl = 4,
        .psr_vers = 2,
        .impl = 4,
        .vers = 2,
        .dcache_line_size = 0x10,
        .dcache_lines = 0x80,
        .dcache_assoc = 4,
        .icache_line_size = 0x20,
        .icache_lines = 0x80,
        .icache_assoc = 5,
        .ecache_line_size = 0x20,
        .ecache_lines = 0x8000,
        .ecache_assoc = 1,
        .mmu_nctx = 0x10000,
        .initfn = tms390z55_init,
    },
    {
        .iu_version = 0x43000000,
        .name = "TI,TMS390S10",
        .psr_impl = 4,
        .psr_vers = 3,
        .impl = 4,
        .vers = 3,
        .dcache_line_size = 0x10,
        .dcache_lines = 0x80,
        .dcache_assoc = 4,
        .icache_line_size = 0x20,
        .icache_lines = 0x80,
        .icache_assoc = 5,
        .ecache_line_size = 0x20,
        .ecache_lines = 0x8000,
        .ecache_assoc = 1,
        .mmu_nctx = 0x10000,
        .initfn = tms390z55_init,
    },
    {
        .iu_version = 0x44000000,
        .name = "TI,TMS390S10",
        .psr_impl = 4,
        .psr_vers = 4,
        .impl = 4,
        .vers = 4,
        .dcache_line_size = 0x10,
        .dcache_lines = 0x80,
        .dcache_assoc = 4,
        .icache_line_size = 0x20,
        .icache_lines = 0x80,
        .icache_assoc = 5,
        .ecache_line_size = 0x20,
        .ecache_lines = 0x8000,
        .ecache_assoc = 1,
        .mmu_nctx = 0x10000,
        .initfn = tms390z55_init,
    },
    {
        .iu_version = 0x1e000000,
        .name = "Ross,RT625",
        .psr_impl = 1,
        .psr_vers = 14,
        .impl = 1,
        .vers = 7,
        .dcache_line_size = 0x20,
        .dcache_lines = 0x80,
        .dcache_assoc = 4,
        .icache_line_size = 0x40,
        .icache_lines = 0x40,
        .icache_assoc = 5,
        .ecache_line_size = 0x20,
        .ecache_lines = 0x8000,
        .ecache_assoc = 1,
        .mmu_nctx = 0x10000,
        .initfn = rt625_init,
    },
    {
        .iu_version = 0x1f000000,
        .name = "Ross,RT620",
        .psr_impl = 1,
        .psr_vers = 15,
        .impl = 1,
        .vers = 7,
        .dcache_line_size = 0x20,
        .dcache_lines = 0x80,
        .dcache_assoc = 4,
        .icache_line_size = 0x40,
        .icache_lines = 0x40,
        .icache_assoc = 5,
        .ecache_line_size = 0x20,
        .ecache_lines = 0x8000,
        .ecache_assoc = 1,
        .mmu_nctx = 0x10000,
        .initfn = rt625_init,
    },
    {
        .iu_version = 0x20000000,
        .name = "BIT,B5010",
        .initfn = bad_cpu_init,
    },
    {
        .iu_version = 0x50000000,
        .name = "MC,MN10501",
        .initfn = bad_cpu_init,
    },
    {
        .iu_version = 0x90 << 24, /* Impl 9, ver 0 */
        .name = "Weitek,W8601",
        .initfn = bad_cpu_init,
    },
    {
        .iu_version = 0xf2000000,
        .name = "GR,LEON2",
        .initfn = bad_cpu_init,
    },
    {
        .iu_version = 0xf3000000,
        .name = "GR,LEON3",
        .initfn = bad_cpu_init,
    },
};


#ifdef CONFIG_TACUS

extern volatile unsigned *aux_reg;

uint16_t machine_id;
uint16_t video_type; // 0=TCX 1=CG3

static unsigned machine_detect(void)
{
	unsigned int retval;
	__asm__ __volatile__("lda [%1] %2, %0\n\t" :
			     "=r" (retval) :
			     "r" (0x00000D00), // MMU SYSCONF register
			     "i" (0x04)); // ASI MMU REGS

    if (retval&0x10)
        return 0; // SS20
    else
        return 0xA0; // SS5

}

static unsigned numcpu(void)
{
	unsigned int retval;
	__asm__ __volatile__("lda [%1] %2, %0\n\t" :
			     "=r" (retval) :
			     "r" (0x00000D00), // MMU SYSCONF register
			     "i" (0x04)); // ASI MMU REGS

    return (retval & 3) + 1;
}

#endif

static const struct cpudef *
id_cpu(void)
{
    unsigned long iu_version;
    unsigned int i;

    asm("rd %%psr, %0\n"
        : "=r"(iu_version) :);
    iu_version &= 0xff000000;

    for (i = 0; i < sizeof(sparc_defs)/sizeof(struct cpudef); i++) {
        if (iu_version == sparc_defs[i].iu_version)
            return &sparc_defs[i];
    }
    printk("Unknown cpu (psr %lx), freezing!\n", iu_version);
    for (;;);
}

static void setup_cpu(int mid_offset)
{
    uint32_t temp;
    unsigned int i;
    const struct cpudef *cpu;

    // Add cpus
#ifndef CONFIG_TACUS    
    temp = fw_cfg_read_i32(FW_CFG_NB_CPUS);
#else
    temp = numcpu();
#endif

    cpu = id_cpu();
    printk("CPUs: %d * %s\n", temp, cpu->name);
    
    for (i = 0; i < temp; i++) {
        push_str("/");
        fword("find-device");

        fword("new-device");

        push_str(cpu->name);
        fword("device-name");

        push_str("cpu");
        fword("device-type");

        PUSH(cpu->psr_impl);
        fword("encode-int");
        push_str("psr-implementation");
        fword("property");

        PUSH(cpu->psr_vers);
        fword("encode-int");
        push_str("psr-version");
        fword("property");

        PUSH(cpu->impl);
        fword("encode-int");
        push_str("implementation");
        fword("property");

        PUSH(cpu->vers);
        fword("encode-int");
        push_str("version");
        fword("property");

        /* The core reports its CPU clock in Hz at AUXIO0 + 8; older cores
           read 0 there, which leaves the property as it was. */
        PUSH(aux_reg[2]);
        fword("encode-int");
        push_str("clock-frequency");
        fword("property");

        PUSH(4096);
        fword("encode-int");
        push_str("page-size");
        fword("property");

        PUSH(cpu->dcache_line_size);
        fword("encode-int");
        push_str("dcache-line-size");
        fword("property");

        PUSH(cpu->dcache_lines);
        fword("encode-int");
        push_str("dcache-nlines");
        fword("property");

        PUSH(cpu->dcache_assoc);
        fword("encode-int");
        push_str("dcache-associativity");
        fword("property");

        PUSH(cpu->icache_line_size);
        fword("encode-int");
        push_str("icache-line-size");
        fword("property");

        PUSH(cpu->icache_lines);
        fword("encode-int");
        push_str("icache-nlines");
        fword("property");

        PUSH(cpu->icache_assoc);
        fword("encode-int");
        push_str("icache-associativity");
        fword("property");

#ifndef CONFIG_TACUS
        /* TACUS: no external cache (no ecache-* properties, as on an SM50
           under the Sun PROM): the OS would size a 1 MB cache that is not
           there */
        PUSH(cpu->ecache_line_size);
        fword("encode-int");
        push_str("ecache-line-size");
        fword("property");

        PUSH(cpu->ecache_lines);
        fword("encode-int");
        push_str("ecache-nlines");
        fword("property");

        PUSH(cpu->ecache_assoc);
        fword("encode-int");
        push_str("ecache-associativity");
        fword("property");
#endif

        PUSH(2);
        fword("encode-int");
        push_str("ncaches");
        fword("property");

        PUSH(cpu->mmu_nctx);
        fword("encode-int");
        push_str("mmu-nctx");
        fword("property");

        PUSH(8);
        fword("encode-int");
        push_str("sparc-version");
        fword("property");

        push_str("");
        fword("encode-string");
        push_str("cache-coherence?");
        fword("property");

        PUSH(i + mid_offset);
        fword("encode-int");
        push_str("mid");
        fword("property");

        cpu_mid = i + mid_offset;
        cpu->initfn();

        fword("finish-device");
    }
}

static void dummy_mach_init(uint64_t base)
{
}

struct machdef {
    uint16_t machine_id;
    const char *banner_name;
    const char *model;
    const char *name;
    void (*initfn)(uint64_t base);
};

static const struct machdef sun4m_defs[] = {
    {
        .machine_id = 32,
        .banner_name = "SPARCstation 5",
        .model = "SUNW,501-3059",
        .name = "SUNW,SPARCstation-5",
        .initfn = ss5_init,
    },
    {
        .machine_id = 33,
        .banner_name = "SPARCstation Voyager",
        .model = "SUNW,501-2581",
        .name = "SUNW,SPARCstation-Voyager",
        .initfn = dummy_mach_init,
    },
    {
        .machine_id = 34,
        .banner_name = "SPARCstation LX",
        .model = "SUNW,501-2031",
        .name = "SUNW,SPARCstation-LX",
        .initfn = dummy_mach_init,
    },
    {
        .machine_id = 35,
        .banner_name = "SPARCstation 4",
        .model = "SUNW,501-2572",
        .name = "SUNW,SPARCstation-4",
        .initfn = ss5_init,
    },
    {
        .machine_id = 36,
        .banner_name = "SPARCstation Classic",
        .model = "SUNW,501-2326",
        .name = "SUNW,SPARCstation-Classic",
        .initfn = dummy_mach_init,
    },
    {
        .machine_id = 37,
        .banner_name = "Tadpole S3 GX",
        .model = "S3",
        .name = "Tadpole_S3GX",
        .initfn = ss5_init,
    },
    {
        .machine_id = 64,
        .banner_name = "SPARCstation 10 (1 X 390Z55)",
        .model = "SUNW,S10,501-2365",
        .name = "SUNW,SPARCstation-10",
        .initfn = ob_eccmemctl_init,
    },
    {
        .machine_id = 65,
        .banner_name = "SPARCstation 20 (1 X 390Z55)",
        .model = "SUNW,S20,501-2324",
        .name = "SUNW,SPARCstation-20",
        .initfn = ob_eccmemctl_init,
    },
    {
        .machine_id = 66,
        .banner_name = "SPARCsystem 600(1 X 390Z55)",
        .model = NULL,
        .name = "SUNW,SPARCsystem-600",
        .initfn = ob_eccmemctl_init,
    },
};

static const struct machdef *
id_machine(uint16_t id)
{
    unsigned int i;

    for (i = 0; i < sizeof(sun4m_defs)/sizeof(struct machdef); i++) {
        if (id == sun4m_defs[i].machine_id)
            return &sun4m_defs[i];
    }
    printk("Unknown machine (ID %d), freezing!\n", machine_id);
    for (;;);
}


static void setup_machine(uint64_t base)
{
#ifndef CONFIG_TACUS
    uint16_t machine_id;
#endif
    const struct machdef *mach;

#ifndef CONFIG_TACUS
    machine_id = fw_cfg_read_i16(FW_CFG_MACHINE_ID);
#endif
    mach = id_machine(machine_id);

    push_str("/");
    fword("find-device");
    push_str(mach->banner_name);
    fword("encode-string");
    push_str("banner-name");
    fword("property");

    if (mach->model) {
        push_str(mach->model);
        fword("encode-string");
        push_str("model");
        fword("property");
    }
    push_str(mach->name);
    fword("encode-string");
    push_str("name");
    fword("property");

    mach->initfn(base);
}

/* Add /uuid */
static void setup_uuid(void)
{
    static uint8_t qemu_uuid[16];

#ifndef CONFIG_TACUS
    fw_cfg_read(FW_CFG_UUID, (char *)qemu_uuid, 16);
#else
    qemu_uuid[ 0]=0x11;    qemu_uuid[ 1]=0x22;
    qemu_uuid[ 2]=0x33;    qemu_uuid[ 3]=0x44;
    qemu_uuid[ 4]=0x55;    qemu_uuid[ 5]=0x66;
    qemu_uuid[ 6]=0x77;    qemu_uuid[ 7]=0x88;
    qemu_uuid[ 8]=0x99;    qemu_uuid[ 9]=0xAA;
    qemu_uuid[10]=0xBB;    qemu_uuid[11]=0xCC;
    qemu_uuid[12]=0xDD;    qemu_uuid[13]=0xEE;
    qemu_uuid[14]=0xFF;    qemu_uuid[15]=0x00;
#endif

    printk("UUID: " UUID_FMT "\n", qemu_uuid[0], qemu_uuid[1], qemu_uuid[2],
           qemu_uuid[3], qemu_uuid[4], qemu_uuid[5], qemu_uuid[6],
           qemu_uuid[7], qemu_uuid[8], qemu_uuid[9], qemu_uuid[10],
           qemu_uuid[11], qemu_uuid[12], qemu_uuid[13], qemu_uuid[14],
           qemu_uuid[15]);

    push_str("/");
    fword("find-device");

    PUSH((long)&qemu_uuid);
    PUSH(16);
    fword("encode-bytes");
    push_str("uuid");
    fword("property");
}

static void setup_stdio(void)
{
    char nographic;
    const char *stdin, *stdout;

#ifndef CONFIG_TACUS
    fw_cfg_read(FW_CFG_NOGRAPHIC, &nographic, 1);
#else
    
    nographic=1-probe_video();
    if (nographic) printk (">> Console = Serial port\n");
              else printk (">> Console = Keyboard, Display\n");
#endif
    
    if (nographic) {
        obp_stdin = PROMDEV_TTYA;
        obp_stdout = PROMDEV_TTYA;
        stdin = "ttya";
        stdout = "ttya";
    } else {
        obp_stdin = PROMDEV_KBD;
        obp_stdout = PROMDEV_SCREEN;
        stdin = "keyboard";
        stdout = "screen";
    }

    /* The console follows the OSD on every boot: for this boot only, the
       NVRAM keeps its own input-device / output-device. */
    push_str(stdin);
    push_str("input-device");
    fword("$setenv-temp");

    push_str(stdout);
    push_str("output-device");
    fword("$setenv-temp");

    obp_stdin_path = stdin;
    obp_stdout_path = stdout;
}

static void init_memory(void)
{
    phys_addr_t phys;
    ucell virt;
    
    /* Claim the memory from OFMEM */
    phys = ofmem_claim_phys(-1, MEMORY_SIZE, PAGE_SIZE);
    if (!phys)
        printk("panic: not enough physical memory on host system.\n");
    
    virt = ofmem_claim_virt(OF_CODE_START - MEMORY_SIZE, MEMORY_SIZE, 0);
    if (!virt)
        printk("panic: not enough virtual memory on host system.\n");

    /* Generate the mapping (and lock translation into the TLBs) */
    ofmem_map(phys, virt, MEMORY_SIZE, ofmem_arch_default_translation_mode(phys));

    /* we push start and end of memory to the stack
     * so that it can be used by the forth word QUIT
     * to initialize the memory allocator
     */
    
    PUSH(virt);
    PUSH(virt + MEMORY_SIZE);
}

static uint8_t crc7(char bit, uint8_t crc)
{
 uint8_t v;
 bit=bit?1:0;
 bit=bit ^ (crc&64)>>6;
 v=bit?0x9:0;
 return ((crc & 63)<<1) ^ v;
}

#ifdef CONFIG_TACUS
uint32_t regsd=0;

#define SD_CONT   (1<<13)
#define SD_PULSE  (1<<14)
#define SD_CMDEN  (1<<7)
#define SD_DATAEN (1<<6)
#define SD_CMD    (1<<4)
#define SD_DATA   (15)
#define SYSACE_EN (1<<22)
#define SDMMC_EN  (1<<23)
#define SD_HI_FREQ (3<<20)
#define SD_CMDIN  (1<<12)
#define SD_DATIN  (0xF00)
#define SD_RESET  (1<<17)
#define SD_DISK   (1<<16)
#define SD_BUSY   (1<<15)
#define SD_SD     (1<<18)

static uint32_t sd_read(void) {
    udelay(40);
    return *(volatile uint32_t *)(aux_reg + 6);
}

static void sd_write(uint32_t d) {
    *(volatile uint32_t *)(aux_reg + 6)=d;
    udelay(40);
}

#define sd_write_size(d) *(volatile uint32_t *)(aux_reg + 7)=(d)

static void sd_init(unsigned did)
{
    regsd=0x1F | (did << 29);
    sd_write(regsd);
    regsd=0x1F | (did << 29) | SD_CMDEN | SD_DATAEN;
    sd_write(regsd);
    udelay(10000);
    regsd=0x1F | (did << 29);
    sd_write(regsd);
    regsd|=SD_CONT;
    sd_write(regsd);
    udelay(10000*50);
    regsd&=~SD_CONT;
    sd_write(regsd);
    udelay(10000);
}

static int sd_cmd(uint8_t *cmd,uint8_t *resp,int rlen)
{
    uint8_t crc;
    int i,j;
    char bit;

    regsd|=SD_CMD; // CMD=1
    sd_write(regsd | SD_PULSE);
    while (sd_read()&SD_BUSY);
    
    regsd|=SD_CMDEN; // CMDEN=1
    sd_write(regsd | SD_PULSE);
    while (sd_read()&SD_BUSY);

    // Command
    crc=0;
    for (i=0;i<5;i++) {
        for (j=7;j>=0;j--) {
	        bit=(cmd[i]>>j) & 1;
	        crc=crc7(bit,crc);
            if (bit)
                regsd|=SD_CMD;
            else
                regsd&=~SD_CMD;
        sd_write(regsd | SD_PULSE);
        while (sd_read()&SD_BUSY);
        }
    }
    
    // CRC
    for (j=6;j>=0;j--) {
        bit=(crc>>j) & 1;
        if (bit)
            regsd|=SD_CMD;
        else
            regsd&=~SD_CMD;
        sd_write(regsd | SD_PULSE);
        while (sd_read()&SD_BUSY);
    }
    
    // 1 final
    regsd|=SD_CMD;
    sd_write(regsd | SD_PULSE);
    while (sd_read()&SD_BUSY);

    // Tristate
    regsd&=~SD_CMDEN;
    sd_write(regsd | SD_PULSE);
    while (sd_read()&SD_BUSY);

    if (!resp) return 0;

    // Answer
    for (i=0;i<500;i++) {
        sd_write(regsd | SD_PULSE);
        while (sd_read()&SD_BUSY);
        if (!(sd_read() & SD_CMDIN)) break;
    }
    if (i==500) {
       return -1; // Timeout
    }

    for (i=0;i<rlen/8;i++) {
        resp[i]=0;
        for (j=7;j>=0;j--) {
            sd_read();
	    if (sd_read()&SD_CMDIN)
	       resp[i]|=1<<j;
	    sd_write(regsd | SD_PULSE);
            while (sd_read()&SD_BUSY);
        }
    }
    sd_write(regsd | SD_PULSE);
    while (sd_read()&SD_BUSY);
    sd_write(regsd | SD_PULSE);
    while (sd_read()&SD_BUSY);
    sd_write(regsd | SD_PULSE);
    while (sd_read()&SD_BUSY);
    
    return 0;
}

static int sd_cmd_datain(uint8_t *cmd,uint8_t *resp,uint8_t *data,int len)
{
    uint8_t crc;
    uint32_t sr;
    int i,j,i2,j2;
    int din=0;
    char bit;
 
    regsd|=SD_CMD;
    sd_write(regsd | SD_PULSE);
    while (sd_read()&SD_BUSY);

    regsd|=SD_CMDEN;
    sd_write(regsd | SD_PULSE);
    while (sd_read()&SD_BUSY);

    // Command
    crc=0;
    for (i=0;i<5;i++) {
        for (j=7;j>=0;j--) {
            bit=(cmd[i]>>j) & 1;
            crc=crc7(bit,crc);
            if (bit)
                regsd|=SD_CMD;
            else
                regsd&=~SD_CMD;
            sd_write(regsd | SD_PULSE);
            while (sd_read()&SD_BUSY);
        }
    }

    // CRC
    for (j=6;j>=0;j--) {
        bit=(crc>>j) & 1;
        if (bit)
            regsd|=SD_CMD;
        else
            regsd&=~SD_CMD;
       sd_write(regsd | SD_PULSE);
       while (sd_read()&SD_BUSY);
    }

    // 1 final
    regsd|=SD_CMD;
    sd_write(regsd | SD_PULSE);
    while (sd_read()&SD_BUSY);

    // Tristate
    regsd&=~SD_CMDEN;
    sd_write(regsd | SD_PULSE);
    while (sd_read()&SD_BUSY);

    if (!resp) return 0;
  
    // Answer
    i2=0;
    j2=0;
    for (i=0;i<500;i++) {
        sd_write(regsd | SD_PULSE);
        while (sd_read()&SD_BUSY);
        if (!(sd_read() & SD_CMDIN)) break;
    }
    if (i==500) return -1; // Timeout
 
    for (i=0;i<48/8;i++) {
        resp[i]=0;
        for (j=7;j>=0;j--) {
            sr=sd_read();
            if (sr&SD_CMDIN)
                resp[i]|=1<<j;
            if (din) {
                if (j2==0) data[i2]=0;
                data[i2]|=((sr & SD_DATIN)>>8)<< (4*(1-j2));
                j2++;
                if (j2==2) { j2=0; i2++; }
            }
            if (!((sr>>8)&1)) din=1;
            sd_write(regsd | SD_PULSE);
            while (sd_read()&SD_BUSY);
        }
    }

    // DATA
    for(;i2<len+17;) {
        sr=sd_read();
        if (din) {
            if (j2==0) data[i2]=0;
            data[i2]|=((sr & SD_DATIN)>>8)<< (4*(1-j2));
            j2++;
            if (j2==2) { j2=0; i2++; }

        }
        if (!((sr>>8)&1)) din=1;
        sd_write(regsd | SD_PULSE);
        while (sd_read()&SD_BUSY);
    }
    printk ("\n");
    
    sd_write(regsd | SD_PULSE);
    while (sd_read()&SD_BUSY);
    sd_write(regsd | SD_PULSE);
    while (sd_read()&SD_BUSY);
    sd_write(regsd | SD_PULSE);
    while (sd_read()&SD_BUSY);
    
    return 0;
}

static void sd_appcmd(uint16_t rca)
{
    uint8_t cmd[6];
    uint8_t resp[20];

    // CMD55 : APP_CMD : Application specific Command
    cmd[0]=0x40 + 55;
    cmd[1]=rca>>8;
    cmd[2]=rca&255;
    cmd[3]=0;
    cmd[4]=0;
    cmd[5]=1;
    sd_cmd(cmd,resp,48);
}

static int init_sysace( void )
{
    // Detect ?
    regsd|=SYSACE_EN;
    sd_write(regsd);
    return 0;
}

static int init_sdcard(unsigned did)
{
    uint8_t cmd[6];
    uint8_t resp[20];
    uint8_t dat[600];
    int i,j;
    uint16_t rca;
    uint32_t size,mult,blen;
    int r;
    uint8_t sdhc;
        
    sd_init(did);
    
    //CMD0 : GO_IDLE_STATE  : RESET
    cmd[0]=0x40 + 0;
    cmd[1]=0;
    cmd[2]=0;
    cmd[3]=0;
    cmd[4]=0;
    cmd[5]=1;
    sd_cmd(cmd,NULL,48);
    
    // CMD8 : Send Interface Condition
    cmd[0]=0x40 + 8;
    cmd[1]=0;
    cmd[2]=0;
    cmd[3]=1; // Voltage = 2.7 - 3.6
    cmd[4]=0x55; // Check pattern
    cmd[5]=1;
    r=sd_cmd(cmd,resp,48);
    
    // ACMD41
    sd_appcmd(0);
    cmd[0]=0x40 + 41;
    cmd[1]=0x40; // SDHC + SDXC
    cmd[2]=1; // OCR
    cmd[3]=0; // OCR
    cmd[4]=0; // Reserved
    cmd[5]=1;
    r=sd_cmd(cmd,resp,48);
    if (r) {
       // MMC initialisation
       // CMD1 : Send Interface Condition
       cmd[0]=0x40 + 1;
       cmd[1]=0x40; // 31-24  0100_0000
       cmd[2]=0x10; // 23-16
       cmd[3]=0x00; // 15-8
       cmd[4]=0x00; // 7-0
       cmd[5]=1;
       r=sd_cmd(cmd,resp,48);
       if (r) {
          printk ("No MMC, no SD, no SDHC\n");
          return -1;
       }
       
       i=0;
       while (!(resp[1]&0x80) && (i<1000)) {
           // CMD1 : Send Interface Condition
           cmd[0]=0x40 + 1;
           cmd[1]=0x00; // 31-24  0100_0000
           cmd[2]=0x10; // 23-16
           cmd[3]=0x00; // 15-8
           cmd[4]=0x00; // 7-0
           cmd[5]=1;
           r=sd_cmd(cmd,resp,48);
           
           for (j=0;j<100;j++) {
               sd_write(regsd | SD_PULSE);
               while (sd_read()&SD_BUSY);
           }
           i++;
       }
       if (i==1000) {
           printk ("MMC : Error. Timeout init\n");
           return -1;
       }
       
       printk ("MMC CMD1 tries :%i\n",i);
       
       printk ("MMC : OCR = %02X %02X %02X %02X\n",
             (unsigned)resp[1],(unsigned)resp[2],(unsigned)resp[3],(unsigned)resp[4]);
       sdhc=resp[1]&0x40;
       if (sdhc) printk ("MMC : Sector access\n");
            else printk ("MMC : Byte access\n");
       
       if (sdhc) {
           printk ("MMC : Sector access : Unsupported. Sorry\n");
           return -1;
       }
       
       // CMD2 : ALL SEND CID
       cmd[0]=0x40 + 2;
       cmd[1]=0; // Stuff
       cmd[2]=0; // Stuff
       cmd[3]=0; // Stuff
       cmd[4]=0; // Stuf
       cmd[5]=1;
       sd_cmd(cmd,resp,136);
       printk ("MMC : CID : MID=%02X OID=%02X_%02X PNM='%c%c%c%c%c'"
                 " REV=%02X S/N=%02X%02X%02X%02X DATE=%02X%02X%02X\n",
                 (unsigned)resp[0] ,(unsigned)resp[1] ,(unsigned)resp[2] ,(char)resp[3] ,
                 (char)resp[4] ,(char)resp[5] ,(char)resp[6] ,(char)resp[7] ,
                 (unsigned)resp[8] ,(unsigned)resp[9] ,(unsigned)resp[10],(unsigned)resp[11],
                 (unsigned)resp[12],(unsigned)resp[13],(unsigned)resp[14],(unsigned)resp[15]);

        // CMD3 : SET RELATIVE ADDR. Different from SD CMD3 !!!!
        rca=1;
        cmd[0]=0x40 + 3;
        cmd[1]=rca>>8;
        cmd[2]=rca&255;
        cmd[3]=0; // Stuff
        cmd[4]=0; // Stuff
        cmd[5]=1;
        for (i=0;i<20;i++) resp[i]=0;
        sd_cmd(cmd,resp,48);
        
        // CMD9 : SEND CSD
        cmd[0]=0x40 + 9;
        cmd[1]=rca>>8;
        cmd[2]=rca&255;
        cmd[3]=0;
        cmd[4]=0;
        cmd[5]=1;
        sd_cmd(cmd,resp,136);
        if (r) printk ("NO ANSWER CSD\n");
        printk ("MMC : CSD : %02X %02X %02X %02X  %02X %02X %02X %02X  %02X %02X %02X %02X  %02X %02X %02X\n",
                 (unsigned)resp[1] ,(unsigned)resp[2] ,(unsigned)resp[3] ,
                 (unsigned)resp[4] ,(unsigned)resp[5] ,(unsigned)resp[6] ,(unsigned)resp[7] ,
                 (unsigned)resp[8] ,(unsigned)resp[9] ,(unsigned)resp[10],(unsigned)resp[11],
                 (unsigned)resp[12],(unsigned)resp[13],(unsigned)resp[14],(unsigned)resp[15]);

        blen = 1<<(resp[6]&15);
        size = resp[9] >> 6 | resp[8] << 2 | (resp[7] & 3) << 10; // C_SIZE
        mult = (resp[10] & 3) << 1 | resp[11] >>7;
        printk ("      blocklen= %i size = %i mult = %i : ",blen,size,mult);
        mult = 1 << (mult+2);
        size = (size +1) * mult * blen / 512;
        printk ("%i MB\n",size/2/1024);
        regsd|=SD_SD;    // Mode SD : Byte address
        sd_write(regsd);
        sd_write_size(size-1);

        // CMD7 : SELECT CARD
        cmd[0]=0x40 + 7;
        cmd[1]=rca>>8;
        cmd[2]=rca&255;
        cmd[3]=0;
        cmd[4]=0;
        cmd[5]=1;
        for (i=0;i<20;i++) resp[i]=0;
        sd_cmd(cmd,resp,48);
        
        // CMD6 : SWITCH_FUNC
        cmd[0]=0x40 + 6;
        cmd[1]=3; // 3=write byte
        cmd[2]=183;  // Bus width
        cmd[3]=1; // 4bits
        cmd[4]=0;
        cmd[5]=1;
        for (i=0;i<20;i++) resp[i]=0;
        sd_cmd(cmd,resp,48);

        // CMD6 : SWITCH_FUNC
        cmd[0]=0x40 + 6;
        cmd[1]=3; // 3=write byte
        cmd[2]=185;  // Speed
        cmd[3]=1; // Fast
        cmd[4]=0;
        cmd[5]=1;
        for (i=0;i<20;i++) resp[i]=0;
        sd_cmd(cmd,resp,48);

        // CMD8 : Send EXT_CSD
        cmd[0]=0x40 + 8;
        cmd[1]=0;
        cmd[2]=0;
        cmd[3]=0;
        cmd[4]=0;
        cmd[5]=1;

        for (i=0;i<20;i++) resp[i]=0;
        sd_cmd_datain(cmd,resp,dat,512);

        printk ("MMC : EXT_CSD :");
        for (i=0;i<512;i++) { // Switch status : §4.3.10.4 page 58
           if ((i&15)==0) printk ("\n  %3i : ",i);
           printk ("%02X ",dat[i]);
        }
        
        printk ("\n");
        printk ("\nMMC INIT OK!\n");
       
    } else {
       // SD/SDHC initialisation
       i=0;
       while (!(resp[1]&0x80) && (i<1000)) {
           // ACMD41 : Set Op Conditions
           sd_appcmd(0);
           cmd[0]=0x40 + 41;
           cmd[1]=0x40; // SDHC + SDXC
           cmd[2]=1; // OCR
           cmd[3]=0; // OCR
           cmd[4]=0; // Reserved
           cmd[5]=1;
           r=sd_cmd(cmd,resp,48);
           
           for (j=0;j<100;j++) {
               sd_write(regsd | SD_PULSE);
               while (sd_read()&SD_BUSY);
           }
           i++;
       }
       if (i==1000) {
           printk ("SD : Error. Timeout init\n");
           return -1;
       }
       
       printk ("SD ACMD41 tries :%i\n",i);
       
       sdhc=resp[1]&0x40;
       if (sdhc) printk ("SD : SDHC detected\n");
            else printk ("SD : SD detected\n");
       
       // CMD2 : ALL SEND CID
       cmd[0]=0x40 + 2;
       cmd[1]=0; // Stuff
       cmd[2]=0; // Stuff
       cmd[3]=0; // Stuff
       cmd[4]=0; // Stuf
       cmd[5]=1;
       r=sd_cmd(cmd,resp,136);
       if (r) {
           printk ("SD : CMD2 : No answer ?\n");
           return -1;
       }
       printk ("SD : CID : MID=%02X OID=%02X_%02X PNM='%c%c%c%c%c'"
                " REV=%02X S/N=%02X%02X%02X%02X DATE=%02X%02X%02X\n", // R2 : CID
                (unsigned)resp[0] ,(unsigned)resp[1] ,(unsigned)resp[2] ,(char)resp[3] ,
                (char)resp[4] ,(char)resp[5] ,(char)resp[6] ,(char)resp[7] ,
                (unsigned)resp[8] ,(unsigned)resp[9] ,(unsigned)resp[10],(unsigned)resp[11],
                (unsigned)resp[12],(unsigned)resp[13],(unsigned)resp[14],(unsigned)resp[15]);

       // CMD3 : SEND RELATIVE ADDR
       cmd[0]=0x40 + 3;
       cmd[1]=0; // Stuff
       cmd[2]=0; // Stuff
       cmd[3]=0; // Stuff
       cmd[4]=0; // Stuf
       cmd[5]=1;
       r=sd_cmd(cmd,resp,48);
       if (r) {
           printk ("SD : CMD3 : No answer ?\n");
           return -1;
       }
       rca=(resp[1]<<8) | resp[2];
       
       // CMD9 : SEND CSD
       cmd[0]=0x40 + 9;
       cmd[1]=rca>>8;
       cmd[2]=rca&255;
       cmd[3]=0;
       cmd[4]=0;
       cmd[5]=1;
       r=sd_cmd(cmd,resp,136);
       if (r) {
           printk ("SD : CMD9 : No answer ?\n");
           return -1;
       } 
       printk ("SD : CSD : %02X %02X %02X %02X  %02X %02X %02X %02X  %02X %02X %02X %02X  %02X %02X %02X\n",
                 (unsigned)resp[1] ,(unsigned)resp[2] ,(unsigned)resp[3] ,
                 (unsigned)resp[4] ,(unsigned)resp[5] ,(unsigned)resp[6] ,(unsigned)resp[7] ,
                 (unsigned)resp[8] ,(unsigned)resp[9] ,(unsigned)resp[10],(unsigned)resp[11],
                 (unsigned)resp[12],(unsigned)resp[13],(unsigned)resp[14],(unsigned)resp[15]);
   
       if ((resp[1]&0xC0)==0) {
          printk ("SD : CSD ver 1.0 : SD\n");
          blen = 1<<(resp[6]&15);
          size = resp[9] >> 6 | resp[8] << 2 | (resp[7] & 3) << 10;
          mult = (resp[10] & 3) << 1 | resp[11] >>7;
          printk ("     SD blocklen= %i size = %i mult = %i : ",blen,size,mult);
          mult = 1 << (mult+2);
          size = (size +1) * mult * blen / 512;
          printk ("%i MB\n",size/2/1024);
          regsd|=SD_SD;    // Mode SD : Byte address
          sd_write(regsd);
       } else
       if ((resp[1]&0xC0)==0x40) {
          printk ("SD : CSD ver 2.0 : SDHC\n");
          size=(resp[8]&0x3F)<<16 | resp[9] <<8 | resp[10]; // * 512kB
          printk ("     SDHC size : 0x%X : %i MB\n",size,size/2);
          size = (size+1) * 1024;
       } else {
          printk ("SD : ERROR CSD\n");
          return -1;
       }

       sd_write_size(size-1);
   
       // CMD7 : SELECT CARD
       cmd[0]=0x40 + 7;
       cmd[1]=rca>>8;
       cmd[2]=rca&255;
       cmd[3]=0;
       cmd[4]=0;
       cmd[5]=1;
       r=sd_cmd(cmd,resp,48);
    
       // ACMD6 : Set bus width
       sd_appcmd(rca);
       cmd[0]=0x40 + 6;
       cmd[1]=0;
       cmd[2]=0;
       cmd[3]=0;
       cmd[4]=2; // 1=1bit, 2=4bits
       cmd[5]=1;
       r=sd_cmd(cmd,resp,48);

       // ACMD51 : SendSCR
       sd_appcmd(rca);
       cmd[0]=0x40 + 51;
       cmd[1]=0;
       cmd[2]=0;
       cmd[3]=0;
       cmd[4]=0;
       cmd[5]=1;
       r=sd_cmd_datain(cmd,resp,dat,8);
       printk ("SD : SCR : %02X %02X %02X %02X  %02X %02X %02X %02X\n",
                dat[0],dat[1],dat[2],dat[3],dat[4],dat[5],dat[6],dat[7]);
       printk ("SD : SCR : SD_SPEC=%i SD_SPEC3=%i SD_BUS_WIDTH=%X\n",dat[0]& 15,dat[2]>>7,dat[1]&15);
       
       if (((dat[0]&15) == 0) || ((dat[1]&4) == 0)) {
          printk ("SD : ERROR : Too old. CMD6 not supported.\n");
       }
       
       // CMD6 : SWITCH_FUNC
       cmd[0]=0x40 + 6;
       cmd[1]=0; // 0= check 0x80= switch
       cmd[2]=0xFF;
       cmd[3]=0xFF;
       cmd[4]=0xF1;
       cmd[5]=1;
       sd_cmd_datain(cmd,resp,dat,512/8);
       printk ("SD : Switch status");
      
       if (!(dat[13] & 2)) { 
          printk ("SD : Need HI SPEED SDR25 mode. Error.\n");
          return -1;
       }
      
       // CMD6 : SWITCH_FUNC
       cmd[0]=0x40 + 6;
       cmd[1]=0x80; // 0= check 0x80= switch
       cmd[2]=0xFF;
       cmd[3]=0xFF;
       cmd[4]=0xF1;
       cmd[5]=0x1;
       sd_cmd_datain(cmd,resp,dat,512/8);
       for (i=0;i<512/8;i++) {
           if (!(i&15)) printk ("\n [%3i:%3i] :",511-i*8,511-i*8-127);
           printk ("%02X ",dat[i]);
        }
        printk ("\n");
        
        // ACMD13 : SD STATUS
        sd_appcmd(rca);
        cmd[0]=0x40 + 13;
        cmd[1]=0;
        cmd[2]=0;
        cmd[3]=0;
        cmd[4]=0;
        cmd[5]=1;
        sd_cmd_datain(cmd,resp,dat,512/8);
        printk ("SD : SD status");
        for (i=0;i<512/8;i++) {
            if (!(i&15)) printk ("\n [%3i:%3i] :",511-i*8,511-i*8-127);
            printk ("%02X ",dat[i]);
        }
        printk ("\n");
        printk ("\nSDcard INIT OK!\n");
        
    }

    regsd|=SDMMC_EN;        
    sd_write(regsd);

    regsd|=SD_RESET;
    sd_write(regsd);
    
    regsd&=~SD_RESET;
    sd_write(regsd);

    // Fast clock
    regsd|=SD_HI_FREQ;
    sd_write(regsd);
    
    // Enable SD/MMC SCSI disk
    regsd|=SD_DISK;
    sd_write(regsd);

    printk ("\n");
    return 0;
}

#endif

static void
arch_init( void )
{
        char *cmdline;
        uint32_t temp;
        

#ifndef CONFIG_TACUS
        const char *kernel_cmdline;
        char buf[256];
#endif
        unsigned long mem_size;

        printk("ARCH INIT START\n");
        fw_cfg_init();

#ifndef CONFIG_TACUS
        fw_cfg_read(FW_CFG_SIGNATURE, buf, 4);
        buf[4] = '\0';

        printk("Configuration device id %s", buf);
        temp = fw_cfg_read_i32(FW_CFG_ID);
        machine_id = fw_cfg_read_i16(FW_CFG_MACHINE_ID);
        graphic_depth = fw_cfg_read_i16(FW_CFG_SUN4M_DEPTH);
#else
        printk("Configuration OpenBIOS TACUS");
 
        temp = 1;
        if (machine_detect() == 0xA0) {
            machine_id = 32; // SS5
            printk(" (SS5)");
        } else {
            machine_id = 65; // SS20
            printk(" (SS20)");
        }
        
        graphic_depth = 8;
#endif

        printk(" version %d machine id %d\n", temp, machine_id);
        printk("RAMSIZE= %d\n",(int)qemu_mem_size);
        
        if (temp != 1) {
            printk("Incompatible configuration device version, freezing\n");
            for(;;);
        }

	openbios_init();
	modules_init();
        ob_init_mmu();
        ob_init_iommu(hwdef->iommu_base);
#ifdef CONFIG_DRIVER_OBIO
#ifndef CONFIG_TACUS
        mem_size = fw_cfg_read_i32(FW_CFG_RAM_SIZE);
#else
        /* entry.S's size (TACUS_RAMSIZE: SYSCONF, or the OSD's if less):
           the other CPUs' mailbox is below its top */
        mem_size = qemu_mem_size;
#endif
	ob_obio_init(hwdef->slavio_base, hwdef->fd_offset,
                     hwdef->counter_offset, hwdef->intr_offset, hwdef->intr_ncpu,
                     hwdef->aux1_offset, hwdef->aux2_offset,
                     mem_size);

        setup_machine(hwdef->slavio_base);

        nvconf_init();
#endif
#ifdef CONFIG_DRIVER_SBUS
#ifdef CONFIG_DEBUG_CONSOLE_VIDEO
	setup_video();
#ifdef CONFIG_TACUS
    if (*aux_reg & 4) {
      video_type=1; // CG3
    } else {
      video_type=0; // TCX
      video_accel_init(hwdef->tcx_base);
    }

    printk("INIT VIDEO\n");
    init_video();
    printk("INIT SDCARD\n");
    /* The MiSTer core has no Direct SD any more (disks come through the
       HPS): with no card on the lines, the probe only ran out its timeouts. */
    if (((*aux_reg & 0xFF0000)>>16) != HWCONF_MiSTer)
        init_sdcard(0);
    if (((*aux_reg & 0xFF0000)>>16)==HWCONF_C5G && (*aux_reg & 2)) {
        // C5G : Double SDcard option
        init_sdcard(1);
    }
    if (((*aux_reg & 0xFF0000)>>16)==HWCONF_SP605) {
        printk("INIT SYSACE\n");
        init_sysace();
    }
    printk("END INIT\n");

#endif
#endif
	ob_sbus_init(hwdef->iommu_base + 0x1000ULL, qemu_machine_type);
#endif
	device_end();

        setup_cpu(hwdef->mid_offset);

        setup_stdio();
	/* Initialiase openprom romvec */
        romvec = init_openprom();

#ifndef CONFIG_TACUS
	kernel_size = fw_cfg_read_i32(FW_CFG_KERNEL_SIZE);
	if (kernel_size) {
		kernel_image = fw_cfg_read_i32(FW_CFG_KERNEL_ADDR);

		/* Mark the kernel memory as in use */
		ofmem_claim_phys(PAGE_ALIGN(kernel_image), PAGE_ALIGN(kernel_size), 0);
		ofmem_claim_virt(PAGE_ALIGN(kernel_image), PAGE_ALIGN(kernel_size), 0);
	}

        kernel_cmdline = (const char *) fw_cfg_read_i32(FW_CFG_KERNEL_CMDLINE);
        if (kernel_cmdline) {
            cmdline = strdup(kernel_cmdline);
            obp_arg.argv[1] = cmdline;
        } else {
	    cmdline = strdup("");
	}
#else
    kernel_size = 0;
    cmdline = strdup("");
#endif
	qemu_cmdline = (uint32_t)cmdline;

        /* Setup nvram variables */
        push_str("/options");
        fword("find-device");
#ifndef CONFIG_TACUS
        push_str(cmdline);
        fword("encode-string");
        push_str("boot-file");
        fword("property");
	boot_device = fw_cfg_read_i16(FW_CFG_BOOT_DEVICE);
	switch (boot_device) {
	case 'a':
		push_str("floppy");
		break;
	case 'c':
		push_str("disk");
		break;
	default:
	case 'd':
		push_str("cdrom:d cdrom");
		break;
	case 'n':
		push_str("net");
		break;
	}

	fword("encode-string");
	push_str("boot-device");
	fword("property");
#else
    /* boot-file and boot-device come from the NVRAM (defaults "" and
       "disk"). The OSD's AutoBoot OFF stops at ok for this boot only; ON
       leaves auto-boot? to the NVRAM (default true). */
    if (*aux_reg & 8) {
      printk(">> auto-boot = false (OSD)\n");
      push_str("false");
      push_str("auto-boot?");
      fword("$setenv-temp");
    }
    
    if (video_type)
      printk (">> Video = CG3\n");
    else
      printk (">> Video = TCX\n");

    /* One-shot boot command left behind by obp_reboot() (e.g. the Solaris
       installer's "reboot disk:b").  Consume it here and override boot-command
       for this boot only ($setenv-temp: the NVRAM keeps its own), so it
       reverts to the NVRAM's next time.  nvram_get_reboot_command() clears
       the magic, so the override never repeats. */
    {
        char rbtcmd[128] = "";

        if (nvram_get_reboot_command(rbtcmd, sizeof(rbtcmd)) &&
            strcmp(rbtcmd, NVRAM_REBOOT_HALT) == 0) {
            /* the client halted (romvec halt/abort): back to ok */
            printk("Program terminated\n");
            push_str("false");
            push_str("auto-boot?");
            fword("$setenv-temp");
        } else if (rbtcmd[0]) {
            char bootcmd[160];

            /* The romvec reboot string is the argument to "boot"; prepend
               "boot " unless the caller already spelled out the full word. */
            if (strncmp(rbtcmd, "boot", 4) == 0) {
                strcpy(bootcmd, rbtcmd);
            } else {
                strcpy(bootcmd, "boot ");
                strcat(bootcmd, rbtcmd);
            }
            printk(">> reboot boot-command = %s\n", bootcmd);
            push_str(bootcmd);
            push_str("boot-command");
            fword("$setenv-temp");
        }
    }

#endif

	device_end();
	
	bind_func("platform-boot", boot );
	bind_func("(go)", go );
	
	/* Set up other properties */
        push_str("/chosen");
        fword("find-device");

        setup_uuid();

	/* Enable interrupts */
	temp = get_psr();
	temp = (temp & ~PSR_PIL) | (13 << 8); /* Enable CPU timer interrupt (level 14) */
	put_psr(temp);

    
    
        printk("ARCH INIT END\n");
    
}

extern struct _console_ops arch_console_ops;

#ifdef CONFIG_TACUS
/* The caches go on as soon as the MMU is set up (init_mmu_swift), so the
 * whole start-up runs cached; the message is printed once the console is up.
 *
 *     10 : WB
 *     20 : AW
 *     40 : L2TLB
 *    100 : DCE
 *    200 : ICE
 *   4000 : DSNOOP/ISNOOP
 *
 * The I-cache was left off at first: every instruction came from DDR, and
 * OpenBIOS took about two minutes to reach "Trying disk" on the SS20.
 * OpenBIOS runs no code it writes (its Forth is threaded data), and go()
 * turns both caches off and flushes them before it enters a loaded program,
 * so the I-cache is on while OpenBIOS runs. */
static const char *tacus_cache_msg;

/* A software or watchdog reset keeps the memory: the core clears it only at
 * power-up, at the OSD reset and with a new ROM (ss_core sCLR). The Sun OBP
 * clears all of it at every reset ("Initializing Memory"), and clients count
 * on finding it zeroed: after fsck's reboot NeXTSTEP, started on the last
 * run's data, reset the machine at every boot. The system status register's RS (bit 1: a software reset) or
 * WD (bit 4: a watchdog reset) says the memory was kept; both stay set until
 * a power-up or an OSD reset. OpenBIOS's own memory, the top
 * OFMEM_PHYS_RESERVED, is left alone, and so is the word at 0 (entry.S's
 * release flag for the other CPUs). */
static uint32_t tacus_phys_ld(uint64_t pa)
{
    uint32_t v;

    if (pa >> 32)
        __asm__ __volatile__("lda [%1] 0x2f, %0" : "=r" (v) : "r" ((uint32_t)pa));
    else
        __asm__ __volatile__("lda [%1] 0x20, %0" : "=r" (v) : "r" ((uint32_t)pa));
    return v;
}

static void tacus_clear_memory(void)
{
    uint32_t stat, pa = 8, end = qemu_mem_size - OFMEM_PHYS_RESERVED;

    stat = tacus_phys_ld(hwdef->slavio_base + 0x00f00000) & 0xff; /* SLAVIO_RESET */
    if (!(stat & 0x12))
        return;
    printk("Clearing memory (%s reset)\n", (stat & 0x10) ? "watchdog" : "software");
    __asm__ __volatile__(
        "clr %%o4\n\t"
        "clr %%o5\n"
        "1:\tstda %%o4, [%0] 0x20\n\t"
        "add %0, 8, %0\n\t"
        "cmp %0, %1\n\t"
        "blu 1b\n\t"
        " nop\n"
        : "+r" (pa) : "r" (end) : "o4", "o5", "cc", "memory");
    cache_flush_all();
}

static void tacus_caches_on(void)
{
    if ((srmmu_get_mmureg() >> 24)==4) {
        tacus_cache_msg = "SET MMUREGS MS2\n";
        srmmu_set_mmureg(srmmu_get_mmureg() | 0x0340);
    } else {
        tacus_cache_msg = "SET MMUREGS SS\n";
        srmmu_set_mmureg(srmmu_get_mmureg() | 0x4340);
    }
    cache_flush_all();
}
#endif

int openbios(void)
{
        unsigned int i;

#ifdef CONFIG_TACUS
        if (machine_detect() == 0xA0) {
            qemu_machine_type = 32; // SS5
        } else {
            qemu_machine_type = 65; // SS20
        }
#endif
        
        for (i = 0; i < sizeof(hwdefs) / sizeof(struct hwdef); i++) {
            if (hwdefs[i].machine_id_low <= qemu_machine_type &&
                hwdefs[i].machine_id_high >= qemu_machine_type) {
                hwdef = &hwdefs[i];
                break;
            }
        }
        if (!hwdef)
            for(;;); // Internal inconsistency, hang

#ifdef CONFIG_DEBUG_CONSOLE
        init_console(arch_console_ops);
#endif
        /* Make sure we setup OFMEM before the MMU as we need malloc() to setup page tables */
        ofmem_init();

#ifdef CONFIG_DRIVER_SBUS
        init_mmu_swift();
#endif
#ifdef CONFIG_TACUS
        tacus_caches_on();
#endif
#ifdef CONFIG_DEBUG_CONSOLE
#ifdef CONFIG_DEBUG_CONSOLE_SERIAL
	escc_uart_init(hwdef->serial_base | (CONFIG_SERIAL_PORT? 0ULL: 4ULL),
                  CONFIG_SERIAL_SPEED);
#endif
#ifdef CONFIG_DEBUG_CONSOLE_VIDEO
	kbd_init(hwdef->ms_kb_base);
#endif
#endif
 
    printk("OpenBIOS start!\n");
#ifdef CONFIG_TACUS
    tacus_clear_memory();
#endif
        collect_sys_info(&sys_info);

        dict = (unsigned char *)sys_info.dict_start;
        dicthead = (cell)sys_info.dict_end;
        last = sys_info.dict_last;
        dictlimit = sys_info.dict_limit;

	forth_init();

#ifdef CONFIG_DEBUG_BOOT
	printk("forth started.\n");
	printk("initializing memory...");
#endif

	init_memory();

#ifdef CONFIG_DEBUG_BOOT
	printk("done\n");
#endif

	PUSH_xt( bind_noname_func(arch_init) );
	fword("PREPOST-initializer");

	PC = (ucell)findword("initialize-of");

	if (!PC) {
		printk("panic: no dictionary entry point.\n");
		return -1;
	}
#ifdef CONFIG_DEBUG_DICTIONARY
	printk("done (%d bytes).\n", dicthead);
	printk("Jumping to dictionary...\n");
#endif

#ifdef CONFIG_TACUS
    printk("%s", tacus_cache_msg);
#endif
    
	enterforth((xt_t)PC);

        free(dict);
	return 0;
}
