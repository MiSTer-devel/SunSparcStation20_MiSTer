/* scsitest: the SCSI path (ESP, DMA2, the SCSI targets, the SD-card
 * images), built apart from the suite (python3 tests/cpu/build.py ss20
 * --main=scsitest, out/ss20/scsitest.rom) because it needs disk images of
 * known content: sim/run-scsi.sh makes them and checks the report.
 *
 * The images: every 512-byte block n holds
 *   word 0  'SCSI'          word 1  the image tag ('HD0\0', 'HD1\0')
 *   word 2  n               word k  (n << 8 | k) ^ 0xa5a5a5a5, k = 3..127
 * HD0 answers at target 3 and HD1 at target 1 (REWORK Decisions).
 *
 * The ESP is driven two ways:
 *   mode 0  as OpenBIOS's drivers/esp.c do_command does it: SELATN with
 *           DMA, a data phase if any, ICCS only after a data phase, never
 *           MESSAGE ACCEPTED (a command without data, TEST UNIT READY,
 *           leaves the target in its status phase);
 *   mode 1  the whole sequence: ICCS and MESSAGE ACCEPTED every time;
 *   mode 2  exactly drivers/esp.c's do_command: as mode 0, but ICCS is
 *           issued and its two FIFO bytes and the interrupt register read
 *           at once, without waiting for its interrupt (so that interrupt
 *           is still pending when the next command starts; ESP-7).
 * Every wait has a timeout (SCSI_POLLS), so a target that stops answering
 * is a FAIL, not a hang.
 *
 * DMA goes through the IOMMU, as under OpenBIOS: a 16 MB DVMA window at
 * 0xff00_0000 whose first 64 KB map pa SCRATCH (QEMU's IOMMU does not pass
 * addresses through when it is off). The CPU reaches the buffers through
 * ASI 0x20 (MMU bypass, uncached), so no cache flush is needed after a
 * DMA. */
#include "runtime.S"

        .text

#if defined(TARGET_SS20)
#  define ESP_PA        0xf0800000      /* ASI 0x2e: pa 0xe_f080_0000 */
#  define DMA_PA        0xf0400000      /* ASI 0x2e: pa 0xe_f040_0000 */
#  define SBUS_ASI      0x2e
#else
#  define ESP_PA        0x78800000
#  define DMA_PA        0x78400000
#  define SBUS_ASI      0x20
#endif
#define MEM_ASI         0x20            /* RAM, physical, uncached */
#if defined(TARGET_SS20)
#  define SITM_SET_PA   0xf1410008      /* ASI 0x2f: system interrupt mask set */
#  define SITM_ASI      0x2f
#else
#  define SITM_SET_PA   0x71e10008
#  define SITM_ASI      0x20
#endif

#ifndef SCSI_POLLS
#define SCSI_POLLS      2000000         /* about a second on the board */
#endif

#define CMDBUF          SCRATCH                 /* IDENTIFY + CDB */
#define DATABUF         (SCRATCH + 0x1000)      /* up to 32 KB */
#define TABLE           (SCRATCH + 0x10000)     /* per target, 16 bytes: */
#define IOPT            (SCRATCH + 0x20000)     /* IOMMU table, 16 KB aligned */
#define DVMA            0xff000000              /* DVMA of pa SCRATCH */
#if defined(TARGET_SS20)
#  define IOMMU_PA      0xe0000000      /* ASI 0x2f: pa 0xf_e000_0000 */
#  define IOMMU_ASI     0x2f
#else
#  define IOMMU_PA      0x10000000
#  define IOMMU_ASI     0x20
#endif
#define TB_PRESENT      0x0                     /*   1: answered INQUIRY */
#define TB_TYPE         0x4                     /*   peripheral type */
#define TB_BLOCKS       0x8                     /*   READ CAPACITY: last LBA + 1 */
#define TB_BS           0xc                     /*   block size */

/* ESP registers (byte, 4-byte stride) and commands */
#define ESP_TCLOW       0x00
#define ESP_TCMED       0x04
#define ESP_FIFO        0x08
#define ESP_CMD         0x0c
#define ESP_STATUS      0x10    /* write: bus ID */
#define ESP_INTR        0x14
#define ESP_SEQ         0x18
#define ESP_FFLAGS      0x1c
#define ESP_CFG1        0x20
#define C_DMA           0x80
#define C_RESET         0x02
#define C_BUSRESET      0x03
#define C_TI            0x10
#define C_ICCS          0x11
#define C_MSGACC        0x12
#define C_SELATN        0x42
#define C_SELATNS       0x43
#define C_FLUSH         0x01
#define I_DC            0x20    /* interrupt: disconnected */
#define I_ILL           0x40    /* interrupt: illegal command */

/* DMA2 (espdma) registers and D_CSR bits */
#define D_CSR           0x0
#define D_ADDR          0x4
#define D_INT           0x001   /* the ESP interrupts */
#define D_RESET         0x080
#define D_WRITE         0x100   /* device to memory */
#define D_EN            0x200

/* errors returned by scsi_cmd (negative) */
#define E_NOTARGET      -1
#define E_TO_SEL        -2
#define E_TO_DATA       -3
#define E_TO_ICCS       -4
#define E_TO_MSGACC     -5
#define E_NODATA        -6      /* went to status instead of data */
#define E_ILLEGAL       -7      /* the ESP rejected the selection */

/* esp_w(reg %o0, value %o1); leaf */
esp_w:  set ESP_PA, %o2
        retl
        stba %o1, [%o2 + %o0] SBUS_ASI

/* esp_r(reg %o0) -> %o0; leaf */
esp_r:  set ESP_PA, %o2
        retl
        lduba [%o2 + %o0] SBUS_ASI, %o0

/* dma_w(reg %o0, value %o1); leaf */
dma_w:  set DMA_PA, %o2
        retl
        sta %o1, [%o2 + %o0] SBUS_ASI

/* wait_int() -> %o0 = 1 when the ESP interrupts, 0 after SCSI_POLLS; leaf */
wait_int:
        set DMA_PA, %o2
        set SCSI_POLLS, %o1
1:      lda [%o2] SBUS_ASI, %o0          /* D_CSR (offset 0) */
        andcc %o0, D_INT, %g0
        bne 2f
        subcc %o1, 1, %o1
        bne 1b
        nop
        retl
        clr %o0
2:      retl
        mov 1, %o0

/* esp_init(): chip reset, bus reset, DMA2 reset; the bus reset interrupt
 * is cleared */
esp_init:
        save %sp, -96, %sp
        /* the test polls: mask every system interrupt source (QEMU raises
           the ESP's at level 15 even with D_CSR INT_EN clear) */
        set SITM_SET_PA, %l0
        mov -1, %l1
        sta %l1, [%l0] SITM_ASI
        /* the IOMMU: entries 0-15 of a 16 MB window map pa SCRATCH + 64 KB;
           IOPTE = pa[35:12] << 8 | W | V */
        set IOPT, %l0
        set SCRATCH, %l2
        clr %l3
1:      srl %l2, 4, %l4
        or %l4, 6, %l4
        sll %l3, 2, %l5
        sta %l4, [%l0 + %l5] MEM_ASI
        set 0x1000, %l6
        add %l2, %l6, %l2
        add %l3, 1, %l3
        cmp %l3, 16
        bl 1b
        nop
        set IOMMU_PA, %l1
        srl %l0, 4, %l4                 /* IBA[35:14] in bits 31:10 */
        mov 4, %l5
        sta %l4, [%l1 + %l5] IOMMU_ASI  /* base address */
        mov 1, %l4                      /* ME, range 16 MB */
        sta %l4, [%l1] IOMMU_ASI
        mov 0x14, %l5
        sta %g0, [%l1 + %l5] IOMMU_ASI  /* flush all */
        mov D_RESET, %o1
        call dma_w
        mov D_CSR, %o0
        clr %o1
        call dma_w
        mov D_CSR, %o0
        mov C_RESET, %o1
        call esp_w
        mov ESP_CMD, %o0
        mov C_BUSRESET, %o1
        call esp_w
        mov ESP_CMD, %o0
        mov 0, %o1
        call esp_w
        mov ESP_CMD, %o0
        call esp_r                      /* clear a pending interrupt */
        mov ESP_INTR, %o0
        ret
        restore

/* scsi_cmd(id %i0, cdb %i1, cdblen %i2, datalen %i3, dir %i4, mode %i5)
 *   cdb: address of the CDB bytes (in the ROM); dir 0 data in, 1 data out
 *   (DATABUF holds the data either way); mode 0 OpenBIOS's sequence,
 *   1 the whole sequence, 2 OpenBIOS's without waiting for ICCS (see the
 *   top); mode 2 returns status 0 after a data phase, as OpenBIOS ignores it
 *   -> %i0 = the SCSI status byte (0 GOOD, 2 CHECK CONDITION), 0 when
 *   mode 0 skipped the status (no data phase), or an E_* error;
 *   %i1 = the ESP status register after the data phase */
scsi_cmd:
        save %sp, -96, %sp
        /* IDENTIFY + the CDB into CMDBUF */
        set CMDBUF, %l0
        mov 0x80, %l1
        stba %l1, [%l0] MEM_ASI
        clr %l2
1:      ldub [%i1 + %l2], %l1
        add %l2, 1, %l3
        stba %l1, [%l0 + %l3] MEM_ASI
        add %l2, 1, %l2
        cmp %l2, %i2
        bl 1b
        nop
        /* select with ATN, command bytes by DMA */
        mov %i0, %o1
        call esp_w
        mov ESP_STATUS, %o0
        mov ESP_TCLOW, %o0
        call esp_w
        add %i2, 1, %o1
        mov ESP_TCMED, %o0
        call esp_w
        clr %o1
        set DVMA + (CMDBUF - SCRATCH), %o1
        call dma_w
        mov D_ADDR, %o0
        set D_EN, %o1
        call dma_w
        mov D_CSR, %o0
        mov C_SELATN | C_DMA, %o1
        call esp_w
        mov ESP_CMD, %o0
        call wait_int
        nop
        tst %o0
        be 90f
        mov E_TO_SEL, %i0
        call esp_r
        mov ESP_STATUS, %o0
        mov %o0, %l5                    /* status */
        call esp_r
        mov ESP_INTR, %o0
        andcc %o0, I_ILL, %g0
        bne 90f
        mov E_ILLEGAL, %i0
        andcc %o0, I_DC, %g0
        bne 90f
        mov E_NOTARGET, %i0
        mov %l5, %i1
        tst %i3
        be 50f                          /* no data phase */
        nop
        /* the data phase */
        and %l5, 7, %l6
        cmp %l6, 3                      /* status phase: no data */
        be 60f
        mov E_NODATA, %l7
        set DVMA + (DATABUF - SCRATCH), %o1
        call dma_w
        mov D_ADDR, %o0
        mov ESP_TCLOW, %o0
        call esp_w
        and %i3, 0xff, %o1
        mov ESP_TCMED, %o0
        call esp_w
        srl %i3, 8, %o1
        mov D_EN | D_WRITE, %o1
        tst %i4
        bne,a 2f
        mov D_EN, %o1
2:      call dma_w
        mov D_CSR, %o0
        mov C_TI | C_DMA, %o1
        call esp_w
        mov ESP_CMD, %o0
        call wait_int
        nop
        tst %o0
        be 90f
        mov E_TO_DATA, %i0
        call esp_r
        mov ESP_STATUS, %o0
        mov %o0, %i1
        call esp_r
        mov ESP_INTR, %o0
        clr %l7
        ba 60f
        nop
50:     /* no data phase: modes 0 and 2 stop here, as OpenBIOS does */
        clr %l7
        cmp %i5, 1
        bne 90f
        clr %i0
60:     /* ICCS: status and message bytes into the FIFO */
        clr %o1
        call dma_w
        mov D_CSR, %o0
        mov C_ICCS, %o1
        call esp_w
        mov ESP_CMD, %o0
        cmp %i5, 2
        be 65f
        nop
        call wait_int
        nop
        tst %o0
        be 90f
        mov E_TO_ICCS, %i0
        call esp_r
        mov ESP_FIFO, %o0
        mov %o0, %l4                    /* the SCSI status byte */
        call esp_r
        mov ESP_FIFO, %o0               /* the message (COMMAND COMPLETE) */
        call esp_r
        mov ESP_INTR, %o0
        tst %i5
        be 70f
        nop
        mov C_MSGACC, %o1
        call esp_w
        mov ESP_CMD, %o0
        call wait_int
        nop
        tst %o0
        be 90f
        mov E_TO_MSGACC, %i0
        call esp_r
        mov ESP_INTR, %o0
        ba 70f
        nop
65:     /* mode 2: OpenBIOS reads the FIFO and the interrupt register at
           once, and does not look at the status byte */
        call esp_r
        mov ESP_FIFO, %o0
        call esp_r
        mov ESP_FIFO, %o0
        call esp_r
        mov ESP_INTR, %o0
        clr %l4
70:     tst %l7
        bne 90f                         /* E_NODATA */
        mov %l7, %i0
        mov %l4, %i0
90:     clr %o1
        call dma_w
        mov D_CSR, %o0
        ret
        restore

/* esp_go(cmd %i0) -> %i0 = the interrupt register, %i1 = the status
 * register read before it; %i0 = -1 when no interrupt came */
esp_go:
        save %sp, -96, %sp
        mov %i0, %o1
        call esp_w
        mov ESP_CMD, %o0
        call wait_int
        nop
        tst %o0
        be,a 9f
        mov -1, %i0
        call esp_r
        mov ESP_STATUS, %o0
        mov %o0, %i1
        call esp_r
        mov ESP_INTR, %o0
        mov %o0, %i0
9:      ret
        restore

/* subch() -> %i0 = the audio status, %i1 = the absolute LBA, %i2 = the
 * track (READ SUB-CHANNEL of t6, the current position); %i0 = -1 when the
 * command failed */
subch:
        save %sp, -96, %sp
        mov 6, %o0
        set cdb_subch, %o1
        mov 10, %o2
        mov 16, %o3
        clr %o4
        call scsi_cmd
        mov 1, %o5
        tst %o0
        bne,a 9f
        mov -1, %i0
        set DATABUF, %l0
        mov 1, %l1
        lduba [%l0 + %l1] MEM_ASI, %i0
        mov 6, %l1
        lduba [%l0 + %l1] MEM_ASI, %i2
        clr %i1
        mov 8, %l1
1:      lduba [%l0 + %l1] MEM_ASI, %l2
        sll %i1, 8, %i1
        or %i1, %l2, %i1
        add %l1, 1, %l1
        cmp %l1, 12
        bl 1b
        nop
9:      ret
        restore

#if defined(TARGET_SS20)
/* spin(n %o0): n ticks (500 ns) of the system counter (pa 0xf_f131_0004,
 * ticks in bits 30:9, free-running from reset); leaf. Not a loop count:
 * this ROM runs in boot mode, whose PROM fetches run at the real EPROM's
 * pace, so loops are no measure of time (as kbdtest). */
#  define SYS_CTR       0xf1310004      /* ASI 0x2f */
spin:   set SYS_CTR, %o1
        lda [%o1] 0x2f, %o2             /* the count at the last look */
1:      lda [%o1] 0x2f, %o3
        sub %o3, %o2, %o4               /* ticks since */
        mov %o3, %o2
        srl %o4, 9, %o4
        set 0x3fffff, %o3               /* (the 22-bit count wraps) */
        and %o4, %o3, %o4
        subcc %o0, %o4, %o0
        bg 1b
        nop
        retl
        nop
#else
/* spin(n %o0): about n loops of nothing; leaf */
spin:   subcc %o0, 1, %o0
        bne spin
        nop
        retl
        nop
#endif

/* the CDBs */
        .pushsection .rodata
cdb_inquiry:    .byte 0x12, 0, 0, 0, 36, 0
cdb_tur:        .byte 0x00, 0, 0, 0, 0, 0
/* CD audio (PLAN S2) */
cdb_toc:        .byte 0x43, 0, 0, 0, 0, 0, 0, 0x03, 0x24, 0     /* 804 bytes */
cdb_play2:      .byte 0x48, 0, 0, 0, 2, 1, 0, 2, 1, 0           /* track 2 */
cdb_subch:      .byte 0x42, 0, 0x40, 1, 0, 0, 0, 0, 16, 0       /* position, LBA */
cdb_pause:      .byte 0x4b, 0, 0, 0, 0, 0, 0, 0, 0, 0
cdb_resume:     .byte 0x4b, 0, 0, 0, 0, 0, 0, 0, 1, 0
cdb_audpage:    .byte 0x1a, 0x08, 0x0e, 0, 20, 0                /* page 0Eh */
cdb_capacity:   .byte 0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0
cdb_sense:      .byte 0x03, 0, 0, 0, 255, 0
sdtr_out:       .byte 0x01, 3, 0x01, 0x19, 0x0f /* SDTR: 100 ns, offset 15 */
sdtr_in:        .byte 0x01, 3, 0x01, 0x19, 0x00 /* the reply: asynchronous */
s_t:            .asciz "    t"
s_type:         .asciz " type "
s_blocks:       .asciz " blocks "
s_bs:           .asciz " bs "
s_id:           .asciz " id '"
s_notready:     .asciz " not ready\n"
s_q:            .asciz "'\n"
s_err:          .asciz "    error "
s_at_t:         .asciz " at t"
s_lba:          .asciz " lba "
s_regs:         .asciz " stat/intr/seq/dcsr "
        .balign 4
        .popsection

/* rw10(id %i0, opcode %i1, lba %i2, count %i3, mode %i4) -> %i0 as
 * scsi_cmd; the CDB is built in RAM (scsi_cmd copies it) */
rw10:
        save %sp, -112, %sp
        add %fp, -16, %l0               /* 10 bytes on the stack */
        stb %i1, [%l0]
        stb %g0, [%l0 + 1]
        srl %i2, 24, %l1
        stb %l1, [%l0 + 2]
        srl %i2, 16, %l1
        stb %l1, [%l0 + 3]
        srl %i2, 8, %l1
        stb %l1, [%l0 + 4]
        stb %i2, [%l0 + 5]
        stb %g0, [%l0 + 6]
        srl %i3, 8, %l1
        stb %l1, [%l0 + 7]
        stb %i3, [%l0 + 8]
        stb %g0, [%l0 + 9]
        mov %i0, %o0
        mov %l0, %o1
        mov 10, %o2
        sll %i3, 9, %o3                 /* 512-byte blocks */
        cmp %i1, 0x2a                   /* WRITE(10): data out */
        be,a 1f
        mov 1, %o4
        clr %o4
1:      call scsi_cmd
        mov %i4, %o5
        mov %o0, %i0
        mov %o1, %i1                    /* the ESP status after the data */
        ret
        restore

/* check_block(n %i0, tag %i1, buffer offset %i2) -> %i0 = 0 when the
 * block at DATABUF + %i2 is block n of the image tagged %i1, else the
 * index of the first bad word + 1 */
check_block:
        save %sp, -96, %sp
        set DATABUF, %l0
        add %l0, %i2, %l0
        lda [%l0] MEM_ASI, %l1
        set 0x53435349, %l2             /* 'SCSI' */
        cmp %l1, %l2
        bne 9f
        mov 1, %l3
        mov 4, %l4
        lda [%l0 + %l4] MEM_ASI, %l1
        cmp %l1, %i1
        bne 9f
        mov 2, %l3
        mov 8, %l4
        lda [%l0 + %l4] MEM_ASI, %l1
        cmp %l1, %i0
        bne 9f
        mov 3, %l3
        set 0xa5a5a5a5, %l5
        sll %i0, 8, %l6
1:      sll %l3, 2, %l4
        lda [%l0 + %l4] MEM_ASI, %l1
        or %l6, %l3, %l2
        xor %l2, %l5, %l2
        cmp %l1, %l2
        bne 9f
        add %l3, 1, %l3
        cmp %l3, 128
        bl 1b
        nop
        ret
        restore %g0, 0, %o0
9:      ret
        restore %l3, 0, %o0

/* report(id %i0, error %i1): "    error <e> at t<id>" */
report_err:
        save %sp, -96, %sp
        set s_err, %o0
        call puts
        nop
        call puthex
        mov %i1, %o0
        set s_at_t, %o0
        call puts
        nop
        call putdec
        mov %i0, %o0
        set s_regs, %o0                 /* ESP status, interrupt, sequence */
        call puts
        nop
        call esp_r
        mov ESP_STATUS, %o0
        call puthex
        nop
        call esp_r
        mov ESP_INTR, %o0
        call puthex
        nop
        call esp_r
        mov ESP_SEQ, %o0
        call puthex
        nop
        set DMA_PA, %o1
        call puthex
        lda [%o1] SBUS_ASI, %o0         /* D_CSR */
        set s_nl, %o0
        call puts
        nop
        ret
        restore

/* probe(mode %i0): OpenBIOS's probe of targets 0-7: INQUIRY, TEST UNIT
 * READY (up to 5 times), READ CAPACITY; fills TABLE and prints a line per
 * target found. %i0 = the number of errors other than "no target". */
probe:
        save %sp, -96, %sp
        mov %i0, %l7                    /* mode */
        clr %l6                         /* errors */
        clr %l0                         /* target id */
1:      set TABLE, %l1
        sll %l0, 4, %l2
        add %l1, %l2, %l1
        clr [%l1 + TB_PRESENT]
        clr [%l1 + TB_TYPE]
        clr [%l1 + TB_BLOCKS]
        clr [%l1 + TB_BS]
        mov %l0, %o0
        set cdb_inquiry, %o1
        mov 6, %o2
        mov 36, %o3
        clr %o4
        call scsi_cmd
        mov %l7, %o5
        cmp %o0, E_NOTARGET
        be 8f
        nop
        tst %o0
        bne,a 7f
        nop
        mov 1, %l2
        st %l2, [%l1 + TB_PRESENT]
        set DATABUF, %l3
        lduba [%l3] MEM_ASI, %l2
        and %l2, 0x1f, %l2
        st %l2, [%l1 + TB_TYPE]
        /* TEST UNIT READY, up to 5 times */
        mov 5, %l4
2:      mov %l0, %o0
        set cdb_tur, %o1
        mov 6, %o2
        clr %o3
        clr %o4
        call scsi_cmd
        mov %l7, %o5
        tst %o0
        bl 7f
        nop
        be 3f
        nop
        subcc %l4, 1, %l4
        bne 2b
        nop
        /* never ready (a CD drive without a disc): OpenBIOS skips it too */
6:      set s_t, %o0
        call puts
        nop
        call putdec
        mov %l0, %o0
        set s_type, %o0
        call puts
        nop
        call puthex
        ld [%l1 + TB_TYPE], %o0
        set s_notready, %o0
        call puts
        nop
        ba 8f
        nop
3:      mov %l0, %o0
        set cdb_capacity, %o1
        mov 10, %o2
        mov 8, %o3
        clr %o4
        call scsi_cmd
        mov %l7, %o5
        /* no capacity (status instead of data, or CHECK CONDITION): a drive
           without a medium. Mode 0's TEST UNIT READY never reads its status,
           so this is where OpenBIOS's sequence finds out */
        cmp %o0, E_NODATA
        be 6b
        cmp %o0, 2
        be 6b
        tst %o0
        bne 7f
        nop
        set DATABUF, %l3
        lda [%l3] MEM_ASI, %l2
        add %l2, 1, %l2
        st %l2, [%l1 + TB_BLOCKS]
        mov 4, %l2
        lda [%l3 + %l2] MEM_ASI, %l2
        st %l2, [%l1 + TB_BS]
        /* "    t<id> type <t> blocks <n> bs <bs> id '<vendor product>'" */
        set s_t, %o0
        call puts
        nop
        call putdec
        mov %l0, %o0
        set s_type, %o0
        call puts
        nop
        call puthex
        ld [%l1 + TB_TYPE], %o0
        set s_blocks, %o0
        call puts
        nop
        call puthex
        ld [%l1 + TB_BLOCKS], %o0
        set s_bs, %o0
        call puts
        nop
        call puthex
        ld [%l1 + TB_BS], %o0
        set s_id, %o0
        call puts
        nop
        /* INQUIRY bytes 8-31 are gone (READ CAPACITY reused DATABUF):
           print the vendor and product of a fresh INQUIRY */
        mov %l0, %o0
        set cdb_inquiry, %o1
        mov 6, %o2
        mov 36, %o3
        clr %o4
        call scsi_cmd
        mov %l7, %o5
        mov 8, %l4
4:      set DATABUF, %l3
        lduba [%l3 + %l4] MEM_ASI, %o0
        cmp %o0, 0x20
        bl,a 5f
        mov '.', %o0
        cmp %o0, 0x7e
        bg,a 5f
        mov '.', %o0
5:      call putc
        nop
        add %l4, 1, %l4
        cmp %l4, 32
        bl 4b
        nop
        set s_q, %o0
        call puts
        nop
        ba 8f
        nop
7:      /* an error other than "no target" */
        mov %o0, %o1
        call report_err
        mov %l0, %o0
        add %l6, 1, %l6
8:      add %l0, 1, %l0
        cmp %l0, 8
        bl 1b
        nop
        ret
        restore %l6, 0, %o0

/* target_blocks(id %o0) -> %o0 = blocks of a present disk, 0 otherwise;
 * leaf */
target_blocks:
        set TABLE, %o1
        sll %o0, 4, %o2
        add %o1, %o2, %o1
        ld [%o1 + TB_PRESENT], %o2
        tst %o2
        be,a 1f
        clr %o0
        ld [%o1 + TB_TYPE], %o2
        tst %o2
        bne,a 1f
        clr %o0
        ld [%o1 + TB_BLOCKS], %o0
1:      retl
        nop

/* read_check(id %i0, tag %i1, lba %i2, count %i3, mode %i4) -> %i0 = 0,
 * or 0x100 + the scsi_cmd error/status, or 0x200 + lba offset * 0x1000 +
 * the check_block result */
read_check:
        save %sp, -96, %sp
        mov %i0, %o0
        mov 0x28, %o1
        mov %i2, %o2
        mov %i3, %o3
        call rw10
        mov %i4, %o4
        tst %o0
        bne,a 9f
        add %o0, 0x100, %i0
        clr %l0
1:      add %i2, %l0, %o0
        mov %i1, %o1
        call check_block
        sll %l0, 9, %o2
        tst %o0
        bne 8f
        add %l0, 1, %l0
        cmp %l0, %i3
        bl 1b
        nop
        ret
        restore %g0, 0, %o0
8:      sub %l0, 1, %l0
        sll %l0, 12, %l0
        add %o0, %l0, %o0
        add %o0, 0x200, %i0
9:      ret
        restore

#define TAG_HD0 0x48443000      /* 'HD0\0' */
#define TAG_HD1 0x48443100      /* 'HD1\0' */

/* ---------------------------------------------------------------- */

/* Mode 0 is OpenBIOS's sequence, which only the core's ESP model accepts:
 * a real 53C9x (and QEMU's) stays connected in MESSAGE IN without
 * MESSAGE ACCEPTED and rejects the next selection as an illegal command.
 * QEMU builds leave these out (-DSCSI_NO_MODE0). */
#ifndef SCSI_NO_MODE0
BEGIN(t_scsi_probe0, "scsi: OpenBIOS's probe of t0-7 (INQUIRY, TUR, READ CAPACITY), mode 0")
        call esp_init
        nop
        call probe
        clr %o0
        EXPECT(%o0, 0, 1)               /* no errors besides absent targets */
        mov 3, %o0
        call target_blocks
        nop
        tst %o0
        bne 1f
        nop
        mov 1, %l0                      /* no disk at t3: nothing to read */
        st %l0, [%g7 + V_SKIP]
1:
END

BEGIN(t_scsi_read0, "scsi: READ(10) at t3: blocks 0-15 one by one, 16-31 by 8, mode 0")
        mov 3, %o0
        call target_blocks
        nop
        tst %o0
        bne 1f
        mov 1, %l0
        ba 9f
        st %l0, [%g7 + V_SKIP]
1:      clr %l1                         /* lba */
2:      mov 3, %o0
        set TAG_HD0, %o1
        mov %l1, %o2
        mov 1, %o3
        call read_check
        clr %o4
        EXPECT(%o0, 0, 1)
        add %l1, 1, %l1
        cmp %l1, 16
        bl 2b
        nop
3:      mov 3, %o0
        set TAG_HD0, %o1
        mov %l1, %o2
        mov 8, %o3
        call read_check
        clr %o4
        EXPECT(%o0, 0, 2)
        add %l1, 8, %l1
        cmp %l1, 32
        bl 3b
        nop
9:
END

/* The same reads seen through the D-cache: with the MMU off a plain load
 * of RAM is cached (E3), so the buffer's lines, cached by a load before
 * each READ(10), must be dropped by the DMA's snoops -- or the CPU reads
 * the previous block. OpenBIOS reads its DMA buffer this way; on the board
 * the NetBSD loader got stale blocks (2026-10-10). */
check_block_c:
        save %sp, -96, %sp
        set DATABUF, %l0
        add %l0, %i2, %l0
        ld [%l0], %l1
        set 0x53435349, %l2             /* 'SCSI' */
        cmp %l1, %l2
        bne 9f
        mov 1, %l3
        ld [%l0 + 4], %l1
        cmp %l1, %i1
        bne 9f
        mov 2, %l3
        ld [%l0 + 8], %l1
        cmp %l1, %i0
        bne 9f
        mov 3, %l3
        set 0xa5a5a5a5, %l5
        sll %i0, 8, %l6
1:      sll %l3, 2, %l4
        ld [%l0 + %l4], %l1
        or %l6, %l3, %l2
        xor %l2, %l5, %l2
        cmp %l1, %l2
        bne 9f
        add %l3, 1, %l3
        cmp %l3, 128
        bl 1b
        nop
        ret
        restore %g0, 0, %o0
9:      ret
        restore %l3, 0, %o0

/* read_check_c(id %i0, tag %i1, lba %i2, count %i3, mode %i4): as
 * read_check, with the buffer's lines loaded (cached) before the READ and
 * the blocks checked through the cache */
read_check_c:
        save %sp, -96, %sp
        set DATABUF, %l0
        sll %i3, 9, %l1
        add %l0, %l1, %l1
1:      ld [%l0], %g0
        add %l0, 32, %l0
        cmp %l0, %l1
        blu 1b
        nop
        mov %i0, %o0
        mov 0x28, %o1
        mov %i2, %o2
        mov %i3, %o3
        call rw10
        mov %i4, %o4
        tst %o0
        bne,a 9f
        add %o0, 0x100, %i0
        clr %l0
2:      add %i2, %l0, %o0
        mov %i1, %o1
        call check_block_c
        sll %l0, 9, %o2
        tst %o0
        bne 8f
        add %l0, 1, %l0
        cmp %l0, %i3
        bl 2b
        nop
        ret
        restore %g0, 0, %o0
8:      sub %l0, 1, %l0
        sll %l0, 12, %l0
        add %o0, %l0, %o0
        add %o0, 0x200, %i0
9:      ret
        restore

BEGIN(t_scsi_read0_cached, "scsi: READ(10) at t3 seen through the D-cache (the buffer cached before each read): blocks 0-31 one by one, 32-47 by 8, mode 0")
        mov 3, %o0
        call target_blocks
        nop
        tst %o0
        bne 1f
        mov 1, %l0
        ba 9f
        st %l0, [%g7 + V_SKIP]
1:      clr %l1                         /* lba */
2:      mov 3, %o0
        set TAG_HD0, %o1
        mov %l1, %o2
        mov 1, %o3
        call read_check_c
        clr %o4
        EXPECT(%o0, 0, 1)
        add %l1, 1, %l1
        cmp %l1, 32
        bl 2b
        nop
3:      mov 3, %o0
        set TAG_HD0, %o1
        mov %l1, %o2
        mov 8, %o3
        call read_check_c
        clr %o4
        EXPECT(%o0, 0, 2)
        add %l1, 8, %l1
        cmp %l1, 48
        bl 3b
        nop
9:
END

/* The two-disk case: t3 and t1 in turn, as an OS with two disks does. */
BEGIN(t_scsi_two0, "scsi: t3 and t1 in turn, 16 reads each, with TUR in between, mode 0")
        mov 1, %o0
        call target_blocks
        nop
        mov %o0, %l2
        mov 3, %o0
        call target_blocks
        nop
        tst %o0
        be,a 9f
        mov 1, %l0
        tst %l2
        be,a 9f
        mov 1, %l0
        clr %l1
1:      mov 3, %o0
        set TAG_HD0, %o1
        mov %l1, %o2
        mov 1, %o3
        call read_check
        clr %o4
        EXPECT(%o0, 0, 1)
        mov 1, %o0
        set TAG_HD1, %o1
        mov %l1, %o2
        mov 1, %o3
        call read_check
        clr %o4
        EXPECT(%o0, 0, 2)
        mov 1, %o0                      /* TUR at t1, left in status */
        set cdb_tur, %o1
        mov 6, %o2
        clr %o3
        clr %o4
        call scsi_cmd
        clr %o5
        EXPECT(%o0, 0, 3)
        add %l1, 1, %l1
        cmp %l1, 16
        bl 1b
        nop
        ba 10f
        nop
9:      st %l0, [%g7 + V_SKIP]
10:
END


/* Mode 2: OpenBIOS's do_command to the letter. ICCS's interrupt is still
 * pending when the next select starts: a select must not appear done
 * before it is (ESP-7 first held the selection itself, and OpenBIOS's
 * probe then lost its disk). */
BEGIN(t_scsi_probe2, "scsi: OpenBIOS's probe, ICCS not awaited (mode 2), then READ(10) of t3 blocks 0-15")
        call esp_init
        nop
        /* OpenBIOS's ob_esp_init: bus reset and NOP, and its interrupt
           left pending into the first select */
        mov C_BUSRESET, %o1
        call esp_w
        mov ESP_CMD, %o0
        mov 0, %o1
        call esp_w
        mov ESP_CMD, %o0
        call probe
        mov 2, %o0
        EXPECT(%o0, 0, 1)               /* no errors besides absent targets */
        mov 3, %o0
        call target_blocks
        nop
        tst %o0
        bne 1f
        nop
        mov 1, %l0                      /* no disk at t3: nothing to read */
        ba 9f
        st %l0, [%g7 + V_SKIP]
1:      clr %l1                         /* lba */
2:      mov 3, %o0
        set TAG_HD0, %o1
        mov %l1, %o2
        mov 1, %o3
        call read_check
        mov 2, %o4
        EXPECT(%o0, 0, 2)
        add %l1, 1, %l1
        cmp %l1, 16
        bl 2b
        nop
9:
END
#endif

BEGIN(t_scsi_write1, "scsi: WRITE(10) at t3 block 8, read back, restore, mode 1")
        mov 3, %o0
        call target_blocks
        nop
        tst %o0
        bne 1f
        mov 1, %l0
        ba 9f
        st %l0, [%g7 + V_SKIP]
1:      call esp_init
        nop
        /* the bus reset leaves a UNIT ATTENTION: TEST UNIT READY takes it */
        mov 3, %l0
2:      mov 3, %o0
        set cdb_tur, %o1
        mov 6, %o2
        clr %o3
        clr %o4
        call scsi_cmd
        mov 1, %o5
        tst %o0
        be 3f
        subcc %l0, 1, %l0
        bne 2b
        nop
3:      /* block 8 with block 9's content: write it, read it back */
        mov 3, %o0
        set TAG_HD0, %o1
        mov 9, %o2
        mov 1, %o3
        call read_check
        mov 1, %o4
        EXPECT(%o0, 0, 1)
        mov 3, %o0
        mov 0x2a, %o1
        mov 8, %o2
        mov 1, %o3
        call rw10
        mov 1, %o4
        mov %o1, %l5
        EXPECT(%o0, 0, 2)
        /* the DMA's end interrupt comes with the target's STATUS phase, not
           while it still writes the block to the image (NetBSD reads the
           phase there: session 8's write timeouts) */
        and %l5, 7, %l5
        EXPECT(%l5, 3, 6)
        mov 3, %o0                      /* block 8 now reads as block 9 */
        mov 0x28, %o1
        mov 8, %o2
        mov 1, %o3
        call rw10
        mov 1, %o4
        EXPECT(%o0, 0, 3)
        mov 9, %o0
        set TAG_HD0, %o1
        call check_block
        clr %o2
        EXPECT(%o0, 0, 4)               /* lba 8 holds what was written */
        /* restore block 8: rebuild its pattern in DATABUF */
        set DATABUF, %l1
        set 0x53435349, %l2
        sta %l2, [%l1] MEM_ASI
        set TAG_HD0, %l2
        mov 4, %l3
        sta %l2, [%l1 + %l3] MEM_ASI
        mov 8, %l2
        mov 8, %l3
        sta %l2, [%l1 + %l3] MEM_ASI
        mov 3, %l3
        set 0xa5a5a5a5, %l5
4:      or %l3, 0x800, %l2              /* (8 << 8) | k */
        xor %l2, %l5, %l2
        sll %l3, 2, %l4
        sta %l2, [%l1 + %l4] MEM_ASI
        add %l3, 1, %l3
        cmp %l3, 128
        bl 4b
        nop
        mov 3, %o0
        mov 0x2a, %o1
        mov 8, %o2
        mov 1, %o3
        call rw10
        mov 1, %o4
        EXPECT(%o0, 0, 5)
        mov 3, %o0
        set TAG_HD0, %o1
        mov 8, %o2
        mov 1, %o3
        call read_check
        mov 1, %o4
        EXPECT(%o0, 0, 6)
9:
END

BEGIN(t_scsi_probe1, "scsi: the probe with ICCS and MESSAGE ACCEPTED every time, mode 1")
        call esp_init
        nop
        call probe
        mov 1, %o0
        EXPECT(%o0, 0, 1)
END

BEGIN(t_scsi_last1, "scsi: READ(10) of the last block of t3, mode 1")
        mov 3, %o0
        call target_blocks
        nop
        tst %o0
        bne 1f
        mov 1, %l0
        ba 9f
        st %l0, [%g7 + V_SKIP]
1:      sub %o0, 1, %o2
        mov 3, %o0
        set TAG_HD0, %o1
        mov 1, %o3
        call read_check
        mov 1, %o4
        EXPECT(%o0, 0, 1)
9:
END

/* REQUEST SENSE with 255 bytes allowed: the target sends its 18 and goes
 * to STATUS, so the DMA stops in the middle of a word. Bytes 16 and 17
 * (sense-key specific, 0) must reach memory and byte 18 must not change
 * (chipset.md DMA-5: the ESP's partial last word was never written). */
BEGIN(t_scsi_sense1, "scsi: REQUEST SENSE, 18 of 255 bytes: the last partial word reaches memory, mode 1")
        mov 3, %o0
        call target_blocks
        nop
        tst %o0
        bne 1f
        mov 1, %l0
        ba 9f
        st %l0, [%g7 + V_SKIP]
1:      set DATABUF, %l3
        set 0xeeeeeeee, %l1
        clr %l2
2:      sta %l1, [%l3 + %l2] MEM_ASI
        add %l2, 4, %l2
        cmp %l2, 32
        bl 2b
        nop
        mov 3, %o0
        set cdb_sense, %o1
        mov 6, %o2
        mov 255, %o3
        clr %o4
        call scsi_cmd
        mov 1, %o5
        EXPECT(%o0, 0, 1)               /* GOOD */
        set DATABUF, %l3
        lduba [%l3] MEM_ASI, %l2
        EXPECT(%l2, 0x70, 2)            /* current error, fixed format */
        mov 7, %l4
        lduba [%l3 + %l4] MEM_ASI, %l2
        EXPECT(%l2, 10, 3)              /* additional length */
        mov 16, %l4
        lduba [%l3 + %l4] MEM_ASI, %l2
        EXPECT(%l2, 0, 4)               /* byte 16: was left 0xee */
        mov 17, %l4
        lduba [%l3 + %l4] MEM_ASI, %l2
        EXPECT(%l2, 0, 5)               /* byte 17 */
        mov 18, %l4
        lduba [%l3 + %l4] MEM_ASI, %l2
        EXPECT(%l2, 0xee, 6)            /* nothing past the 18 bytes */
9:
END

/* Synchronous negotiation as the Sun esp driver (SunOS 4, NeXTSTEP) does
 * it: IDENTIFY, select with ATN and stop, the SDTR by Transfer
 * Information, then the target's SDTR reply a byte at a time, each one
 * followed by MESSAGE ACCEPTED. That must be a bus service (the target asks
 * for the next byte, then for the CDB), not a disconnect: NeXTSTEP took it
 * for an unexpected bus free (pkt_reason 0x14) and its generic SCSI
 * device, which BuildDisk uses, found no disk (chipset.md ESP-8). Then
 * INQUIRY with its CDB through the FIFO, ICCS, MESSAGE ACCEPTED, which
 * does disconnect. */
BEGIN(t_scsi_sdtr1, "scsi: SDTR as Sun's esp driver sends it, the reply accepted byte by byte, then INQUIRY")
        mov 3, %o0
        call target_blocks
        nop
        tst %o0
        bne 1f
        mov 1, %l0
        ba 9f
        st %l0, [%g7 + V_SKIP]
1:      clr %o1
        call dma_w
        mov D_CSR, %o0
        mov 3, %o1
        call esp_w
        mov ESP_STATUS, %o0
        mov C_FLUSH, %o1
        call esp_w
        mov ESP_CMD, %o0
        mov 0xc0, %o1                   /* IDENTIFY, disconnect allowed */
        call esp_w
        mov ESP_FIFO, %o0
        call esp_go
        mov C_SELATNS, %o0
        mov %o1, %l6
        and %o0, I_DC, %l2
        EXPECT(%l2, 0, 1)               /* selected */
        and %l6, 7, %l2
        EXPECT(%l2, 6, 2)               /* stopped in MESSAGE OUT */
        set sdtr_out, %l3
        clr %l4
2:      ldub [%l3 + %l4], %o1
        call esp_w
        mov ESP_FIFO, %o0
        add %l4, 1, %l4
        cmp %l4, 5
        bl 2b
        nop
        call esp_go
        mov C_TI, %o0
        and %o1, 7, %l2
        EXPECT(%l2, 7, 3)               /* the target answers in MESSAGE IN */
        set sdtr_in, %l3
        clr %l4
3:      call esp_go
        mov C_TI, %o0
        call esp_r
        mov ESP_FIFO, %o0
        ldub [%l3 + %l4], %l5
        EXPECT_R(%o0, %l5, 4)           /* the reply, byte by byte */
        call esp_go
        mov C_MSGACC, %o0
        mov %o1, %l6
        and %o0, I_DC, %l2
        EXPECT(%l2, 0, 5)               /* no disconnect */
        cmp %l4, 4
        be 4f
        and %l6, 7, %l2
        EXPECT(%l2, 7, 6)               /* the next byte */
        add %l4, 1, %l4
        ba 3b
        nop
4:      EXPECT(%l2, 2, 7)               /* then the CDB */
        set cdb_inquiry, %l3
        clr %l4
5:      ldub [%l3 + %l4], %o1
        call esp_w
        mov ESP_FIFO, %o0
        add %l4, 1, %l4
        cmp %l4, 6
        bl 5b
        nop
        call esp_go
        mov C_TI, %o0
        and %o1, 7, %l2
        EXPECT(%l2, 1, 8)               /* DATA IN */
        set DVMA + (DATABUF - SCRATCH), %o1
        call dma_w
        mov D_ADDR, %o0
        mov 36, %o1
        call esp_w
        mov ESP_TCLOW, %o0
        clr %o1
        call esp_w
        mov ESP_TCMED, %o0
        set D_EN | D_WRITE, %o1
        call dma_w
        mov D_CSR, %o0
        call esp_go
        mov C_TI | C_DMA, %o0
        and %o1, 7, %l2
        EXPECT(%l2, 3, 9)               /* STATUS */
        clr %o1
        call dma_w
        mov D_CSR, %o0
        call esp_go
        mov C_ICCS, %o0
        call esp_r
        mov ESP_FIFO, %o0
        EXPECT(%o0, 0, 10)              /* GOOD */
        call esp_r
        mov ESP_FIFO, %o0
        EXPECT(%o0, 0, 11)              /* COMMAND COMPLETE */
        call esp_go
        mov C_MSGACC, %o0
        and %o0, I_DC, %l2
        EXPECT(%l2, I_DC, 12)           /* the target is gone */
        set DATABUF, %l3
        lduba [%l3] MEM_ASI, %l2
        EXPECT(%l2, 0, 13)              /* a disk */
9:
END

/* A SIMPLE QUEUE TAG after IDENTIFY (select with ATN and stop, the two-byte
 * message by Transfer Information): the target takes it, as a queue of one,
 * and asks for the CDB; before, it rejected 20h and took the tag byte for
 * another message. NeXTSTEP's generic SCSI device passes options it may
 * leave unset, so its commands can come tagged. */
BEGIN(t_scsi_tag1, "scsi: a SIMPLE QUEUE TAG message after IDENTIFY is taken, then INQUIRY")
        mov 3, %o0
        call target_blocks
        nop
        tst %o0
        bne 1f
        mov 1, %l0
        ba 9f
        st %l0, [%g7 + V_SKIP]
1:      clr %o1
        call dma_w
        mov D_CSR, %o0
        mov 3, %o1
        call esp_w
        mov ESP_STATUS, %o0
        mov C_FLUSH, %o1
        call esp_w
        mov ESP_CMD, %o0
        mov 0xc0, %o1
        call esp_w
        mov ESP_FIFO, %o0
        call esp_go
        mov C_SELATNS, %o0
        mov %o1, %l6
        and %l6, 7, %l2
        EXPECT(%l2, 6, 1)               /* MESSAGE OUT */
        mov 0x20, %o1                   /* SIMPLE QUEUE TAG 5 */
        call esp_w
        mov ESP_FIFO, %o0
        mov 5, %o1
        call esp_w
        mov ESP_FIFO, %o0
        call esp_go
        mov C_TI, %o0
        and %o1, 7, %l2
        EXPECT(%l2, 2, 2)               /* the CDB, no MESSAGE REJECT */
        set cdb_inquiry, %l3
        clr %l4
2:      ldub [%l3 + %l4], %o1
        call esp_w
        mov ESP_FIFO, %o0
        add %l4, 1, %l4
        cmp %l4, 6
        bl 2b
        nop
        call esp_go
        mov C_TI, %o0
        and %o1, 7, %l2
        EXPECT(%l2, 1, 3)               /* DATA IN */
        set DVMA + (DATABUF - SCRATCH), %o1
        call dma_w
        mov D_ADDR, %o0
        mov 36, %o1
        call esp_w
        mov ESP_TCLOW, %o0
        clr %o1
        call esp_w
        mov ESP_TCMED, %o0
        set D_EN | D_WRITE, %o1
        call dma_w
        mov D_CSR, %o0
        call esp_go
        mov C_TI | C_DMA, %o0
        clr %o1
        call dma_w
        mov D_CSR, %o0
        call esp_go
        mov C_ICCS, %o0
        call esp_r
        mov ESP_FIFO, %o0
        EXPECT(%o0, 0, 4)               /* GOOD */
        call esp_r
        mov ESP_FIFO, %o0
        call esp_go
        mov C_MSGACC, %o0
        and %o0, I_DC, %l2
        EXPECT(%l2, I_DC, 5)
9:
END

/* CD audio (PLAN S2), with sim/run-scsi.sh's third run (a CD at t6 whose
 * track table, from the harness as from Main, has audio tracks 2 and 3 of
 * 150 frames after the data track): READ TOC lists them, PLAY AUDIO
 * TRACK/INDEX plays track 2, READ SUB-CHANNEL reports it playing with the
 * position moving, paused with it still, then completed (once, then no
 * status); the audio control page has both volumes at FF. */
BEGIN(t_scsi_cdda, "scsi: CD audio at t6: READ TOC, PLAY track 2, SUB-CHANNEL, PAUSE/RESUME, the end")
        mov 6, %o0                      /* a pending UNIT ATTENTION goes */
        set cdb_tur, %o1
        mov 6, %o2
        clr %o3
        clr %o4
        call scsi_cmd
        mov 1, %o5
        mov 6, %o0
        set cdb_toc, %o1
        mov 10, %o2
        set 804, %o3
        clr %o4
        call scsi_cmd
        mov 1, %o5
        tst %o0
        be 1f
        mov 1, %l0
        ba 9f                           /* no CD (not ready): skip */
        st %l0, [%g7 + V_SKIP]
1:      set DATABUF, %l3
        mov 3, %l1
        lduba [%l3 + %l1] MEM_ASI, %l2
        cmp %l2, 2
        bge 2f
        mov 1, %l0
        ba 9f                           /* no audio tracks (old Main): skip */
        st %l0, [%g7 + V_SKIP]
2:      EXPECT(%l2, 3, 1)               /* last track */
        mov 13, %l1                     /* track 2's ADR/control */
        lduba [%l3 + %l1] MEM_ASI, %l2
        EXPECT(%l2, 0x10, 2)
        mov 14, %l1
        lduba [%l3 + %l1] MEM_ASI, %l2
        EXPECT(%l2, 2, 3)
        mov 18, %l1                     /* its address (LBA, low 2 bytes) */
        lduba [%l3 + %l1] MEM_ASI, %l4
        mov 19, %l1
        lduba [%l3 + %l1] MEM_ASI, %l2
        sll %l4, 8, %l4
        or %l4, %l2, %l4                /* %l4 = track 2's start */
        mov 6, %o0
        set cdb_play2, %o1
        mov 10, %o2
        clr %o3
        clr %o4
        call scsi_cmd
        mov 1, %o5
        EXPECT(%o0, 0, 4)               /* PLAY accepted */
        set 30000, %o0
        call spin
        nop
        call subch
        nop
        mov %o1, %l5
        mov %o2, %l6
        EXPECT(%o0, 0x11, 5)            /* playing */
        EXPECT(%l6, 2, 6)               /* track 2 */
        set 60000, %o0
        call spin
        nop
        call subch
        nop
        mov %o1, %l6
        cmp %l6, %l5
        bgu,a 3f                        /* the position moves */
        clr %l7
        mov 1, %l7
3:      EXPECT(%l7, 0, 7)
        mov 6, %o0
        set cdb_pause, %o1
        mov 10, %o2
        clr %o3
        clr %o4
        call scsi_cmd
        mov 1, %o5
        EXPECT(%o0, 0, 8)
        call subch
        nop
        mov %o1, %l5
        EXPECT(%o0, 0x12, 9)            /* paused */
        set 60000, %o0
        call spin
        nop
        call subch
        nop
        EXPECT_R(%o1, %l5, 10)          /* still */
        mov 6, %o0
        set cdb_resume, %o1
        mov 10, %o2
        clr %o3
        clr %o4
        call scsi_cmd
        mov 1, %o5
        EXPECT(%o0, 0, 11)
        set 400, %l7                    /* until it ends */
4:      set 20000, %o0
        call spin
        nop
        call subch
        nop
        cmp %o0, 0x11
        bne 5f
        subcc %l7, 1, %l7
        bne 4b
        nop
5:      mov %o1, %l6
        EXPECT(%o0, 0x13, 12)           /* completed */
        add %l4, 150, %l4
        EXPECT_R(%l6, %l4, 13)          /* past track 2's last frame */
        call subch
        nop
        EXPECT(%o0, 0x15, 14)           /* then no status */
        mov 6, %o0
        set cdb_audpage, %o1
        mov 6, %o2
        mov 20, %o3
        clr %o4
        call scsi_cmd
        mov 1, %o5
        EXPECT(%o0, 0, 15)
        set DATABUF, %l3
        mov 4, %l1
        lduba [%l3 + %l1] MEM_ASI, %l2
        EXPECT(%l2, 0x0e, 16)           /* the page */
        mov 13, %l1
        lduba [%l3 + %l1] MEM_ASI, %l2
        EXPECT(%l2, 0xff, 17)           /* port 0's volume */
9:
END

        .section .testtab, "a", @progbits
        .word 0, 0                      /* end of the test table */

        .section .romend, "a", @progbits
        .align 4
        .globl rom_end
rom_end:
