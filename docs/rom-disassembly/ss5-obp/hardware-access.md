# SPARCstation 5 boot PROM (OBP 2.15): hardware access map

Every physical address and alternate space (ASI) that the **machine code** of
`ss5.bin` touches: the POST, the reset paths, the boot-time serial code, the
page-table builder and `obp_cold_entry` (PROM `0x70000000`-`0x7000f6ff` and
`0x7002a86c`-`0x7002ab4f`). The Forth kernel's own accesses are not included.
This is the input for a diff against a core's address decoder.

How it was made: `romdis.py` tracks `sethi`/`or`/`add` constants, so most
effective addresses are known statically; the device tables below are generated
from that analysis (every `lda`/`sta`/`ld*`/`st*` with a constant address) and
the purposes come from reading the code ([`post-tests.md`](post-tests.md)).
Accesses whose address is computed at run time are listed separately (§3).
Width: B = byte, H = halfword, W = word, D = doubleword (`ldda`/`stda`).
PA is the 31-bit microSPARC-II physical address (ASI 0x20 gives PA = VA[30:0]).

## 1. CPU-internal alternate spaces

| ASI | Space (microSPARC-II) | VA / range | Access | Routines | Purpose |
|---|---|---|---|---|---|
| 0x03 | MMU flush/probe | `0x400` (type 4 = entire) | W store | `post_entry`, `watchdog_reenter_obp` | flush the whole TLB |
| 0x04 | MMU registers | `0x000` PCR | R/W | `cache_init_enable` (\|= 0x300 IE+DE), `obp_cold_entry` and `watchdog_reenter_obp` (\|= EN, &= ~BM 0x4000), `trap_data_access_error` (&= ~0x8100 AC+DE), `pcr_*` library | control |
| 0x04 | | `0x100` context table pointer | R/W | `post_entry` (=0), `mmu_reg_walk_test` (mask `0x00ffffc0`), `mmu_set_ctx_table_ptr` | |
| 0x04 | | `0x200` context | R/W | `post_entry`, `watchdog_reenter_obp` (save, =0), `mmu_reg_walk_test` (mask `0xff`), `mmu_set_ctx` | |
| 0x04 | | `0x300` SFSR, `0x400` SFAR | R | `report_sync_trap`, `mmu_read_clear_sfar_sfsr` (uncalled), bus time-out tests (SFSR `0x816` SBus / `0x416` EBus after mask `0x3e0`) | fault status |
| 0x04 | | `0x1000` TLB replacement control | W / R-W | `tlb_init_clear` (=0), `mmu_reg_walk_test` (mask `0x0011ffff`, bit 6 forced) | |
| 0x04 | | `0x1300` SFSR diag, `0x1400` SFAR diag | R/W | `mmu_reg_walk_test` (masks `0x00016fff`, `0xffffffff`) | writable aliases |
| 0x04 | | `0x10000000` | R/W | `pcr_set_bit0_via_0x10000000`, `pcr_clear_bit0_via_0x10000000` (uncalled) | VA[12:8]=0, so this is the PCR on microSPARC-II (the intent may have been the IOMMU control register) |
| 0x06 | TLB diagnostic | `0x000+4n` PTE, `0x100+4n` lower tag, `0x300+4n` upper tag, n=0..63 (layout inferred) | W, R | `tlb_init_clear`, `post_mmu_tlb_nta` via `nta_march_test`, `watchdog_reenter_obp`, `iommu_tlb_fill`/`iommu_tlb_check` (IOMMU flush tests), `tlb_load_entries`/`tlb_read_entries` (uncalled) | TLB RAM/CAM tests, preload |
| 0x09 | supervisor instruction (PROM reads) | PROM `0x7000xxxx` | B, W R | `post_printf` (format strings), `escc_init_*` (tables `0x7000a920`/`a940`/`a95c`), `mem_probe_bank` (`0x70007864`), `post_iommu_regs` (`0x7000a780`), `post_tod_regs` (`0x70006e4c`), `copy_rom_*`, `tlb_load_entries` | constant data from the PROM |
| 0x0c | I-cache tags | `0x0000-0x3fe0`, 32-byte lines | W, R | `cache_init_enable`, `icache_clear_tags`, `post_icache_tag_nta` (mask `0xffffcfff`) | |
| 0x0d | I-cache data | `0x0000-0x3ffc` | W, R | `post_icache_ram_nta` | |
| 0x0e | D-cache tags | `0x0000-0x1ff0`, 16-byte lines | W, R | `cache_init_enable`, `dcache_clear_tags`, `post_dcache_tag_nta` (mask `0xffffefff`) | |
| 0x0f | D-cache data | `0x0000-0x1ffc` | W, R | `post_dcache_ram_nta` | |
| 0x20 | MMU bypass | any PA | all widths | everything in §2-§4 | devices and physical RAM |
| 0x00-0x30 | (dispatch stubs) | – | W/H/B store, W load | `asi_st_word`, `asi_st_half`, `asi_st_byte`, `asi_ld_word` | 49-entry tables, one stub per ASI; only 0x06, 0x0c-0x0f are used (through `nta_march_test`) |

No other ASI is used by the machine code (in particular no flush ASIs
0x10-0x14, no ASI 0x39, no ASI 0x21-0x2f: the stubs for 0x21-0x2f encode 0x20).

## 2. Physical devices (ASI 0x20, constant addresses)

### RAM

| PA | Width | R/W | Routines | Purpose |
|---|---|---|---|---|
| `0x00000080` | W | W | `pport_wait_irq_hcr` | stray word store (bug, meant for AFSR; uncalled test) |
| `0x00000400` | B | W | `pport_xfr_loop` | stray byte store (bug, meant for BPP OCR; uncalled test) |
| `0x00002300` | B | R/W | `post_tod_regs` | TOD save area (fixed PA, assumes RAM at 0) |
| `0x00002301` | B | R | `post_tod_regs` | TOD save area |

### IOMMU

| PA | Width | R/W | Routines | Purpose |
|---|---|---|---|---|
| `0x10000000` | W | W | `post_iommu_tlb_flush` | IOMMU control (IOCR): pattern test mask 0x1d, version 0x04000000; ME set/clear around the flush tests |
| `0x10000018` | W | W | `iommu_flush_entry_loop` | IOMMU address flush (page i<<12) |

### SBus controller

| PA | Width | R/W | Routines | Purpose |
|---|---|---|---|---|
| `0x10001000` | W | R/W | `post_dma2_d_addr`, `post_dma2_d_bcnt`, `post_dma2_d_csr`, `post_dma2_d_naddr`, `post_dma2_d_nbcnt`, `post_dma2_e_csr`, `post_lance_addr_port`, `post_lance_data_port`, `pport_wait_irq_hcr`, `pport_wait_irq_ocr`, `report_async_trap`, `sbus_clear_afsr` | AFSR: expect 0x93820000 after a wrong-size store; write 0 to clear |
| `0x10001004` | W | R | `post_dma2_d_addr`, `post_dma2_d_bcnt`, `post_dma2_d_csr`, `post_dma2_d_naddr`, `post_dma2_d_nbcnt`, `post_dma2_e_csr`, `post_lance_addr_port`, `post_lance_data_port`, `pport_wait_irq_hcr`, `pport_wait_irq_ocr`, `report_async_trap`, `sbus_clear_afsr` | AFAR: expect the PA of the wrong-size store |
| `0x10001050` | W | R/W | `sbus_clear_mfsr` | MFSR (memory fault status), read and cleared (uncalled helper) |
| `0x10001054` | W | R | `sbus_clear_mfsr` | MFAR (memory fault address), read (uncalled helper) |

### MID register / SBus arbitration enable

| PA | Width | R/W | Routines | Purpose |
|---|---|---|---|---|
| `0x10002000` | W | R/W | `mid_clear_sbae_bits`, `mid_set_sbae_bits`, `post_ebus_read_timeout`, `post_entry`, `post_sbus_read_timeout`, `reset_watchdog` | MID register: SBAE = 0 at POST entry / watchdog; SBAE[4:0] set around the bus time-out reads |

### ESCC0 keyboard/mouse (Z85C30)

| PA | Width | R/W | Routines | Purpose |
|---|---|---|---|---|
| `0x71000004` | B | R/W | `kbd_recv_timeout`, `kbd_send`, `post_fail_boot_prom_dead`, `post_fail_cpu_board`, `post_fail_cpu_board_leds`, `post_fail_nvram`, `post_fail_simm`, `post_fail_simm_dead` | keyboard Z85C30 ch A control: init table, RR0 Rx/Tx polling, RR1 All Sent |
| `0x71000006` | B | R/W | `kbd_recv_timeout`, `kbd_send` | keyboard data: 0x01 reset, 0x0e LED, 0x0f layout; replies 0xff/ID, 0xfe/layout; Stop 0x01, d 0x4f |

### ESCC1 serial A/B (Z85C30)

| PA | Width | R/W | Routines | Purpose |
|---|---|---|---|---|
| `0x71100004` | B | R/W | `post_seq_pass`, `ttya_getc_nowait`, `ttya_putc`, `ttya_putc_boot` | ttya Z85C30 ch A control: init, RR0 bit 2 Tx empty, RR1 bit 0 All Sent |
| `0x71100006` | B | W | `ttya_putc`, `ttya_putc_boot` | ttya data: all POST and boot output |

### NVRAM/TOD (MK48T08)

| PA | Width | R/W | Routines | Purpose |
|---|---|---|---|---|
| `0x71200000` | B | R | `post_poll_ttya_command` | NVRAM byte 0 (read by the uncalled ttya command poller) |
| `0x71200001` | B | R/W | `boot_puthex_if_diag`, `boot_puts`, `nvram_diag_switch`, `rpo_kbd_decide`, `rpo_l1d` | NVRAM byte 1 = diag-switch?: gates boot_puts and POST; 0xff written on Stop-d |
| `0x71200003` | B | R/W | `post_nvram_access` | NVRAM byte 3: NVRAM Access Test (left 0) |
| `0x7120004e` | B | R | `rpo_l1d` | NVRAM byte 0x4e = security-mode (1/2 blocks Stop-d) |
| `0x71201dd8` | B | W | `post_exit_soft_reset` | NVRAM byte 0x1dd8: cleared 8 times at POST exit (purpose unknown) |
| `0x71201ff8` | B | R/W | `post_tod_regs` | TOD control (W, R, S, CAL): 0x40 / 0x80 / restore |
| `0x71201ff9` | B | R/W | `post_tod_regs` | TOD seconds (mask 0x7f); 0x71201ffa-fff min, hour, day, date, month, year via the table loop |

### floppy (82077)

| PA | Width | R/W | Routines | Purpose |
|---|---|---|---|---|
| `0x71400300` | W | R | `post_ebus_read_timeout` | EBus address with no device: read to provoke an error acknowledge (tt 0x29) |

### counter/timers

| PA | Width | R/W | Routines | Purpose |
|---|---|---|---|---|
| `0x71d00000` | D,W | R/W | `irq14_proc_counter_lbit_check`, `kbd_getc_timeout`, `post_proc0_counter_timer`, `post_proc0_user_timer`, `reset_power_on` | proc0 limit / user-timer MSW (ldda 64-bit with LSW): L bit, limit mask, UT value |
| `0x71d00004` | W | R/W | `irq14_proc_counter_lbit_check`, `post_proc0_counter_timer`, `reset_power_on` | proc0 counter / user-timer LSW |
| `0x71d00008` | W | W | `post_proc0_counter_timer` | proc0 limit without counter reset |
| `0x71d0000c` | W | R/W | `post_proc0_user_timer`, `reset_power_on` | proc0 user-timer start/stop (RUN) |
| `0x71d10000` | W | R/W | `irq10_led_blink`, `irq10_spinner`, `irq10_sys_counter_lbit_check`, `post_quiesce_leds_off`, `sys_timer_irq10_arm`, `sys_timer_irq10_disarm`, `sys_timer_limit_irq_setup` | system (level-10) limit: written 0 by post_quiesce_leds_off; dead timer helpers |
| `0x71d10004` | W | R | `irq10_sys_counter_lbit_check` | system counter: L-bit check (unreachable path) |
| `0x71d10010` | W | R/W | `post_proc0_counter_timer`, `post_proc0_user_timer`, `reset_power_on` | timer configuration: T0 = 1 (user timer) at power-on and in the timer tests |

### interrupt controller

| PA | Width | R/W | Routines | Purpose |
|---|---|---|---|---|
| `0x71e00000` | W | R | `irq15_ack_hardint15`, `post_proc0_irq_regs`, `post_soft_irq_off`, `post_soft_irq_on`, `trap_irq01`, `trap_irq02`, `trap_irq03`, `trap_irq04`, `trap_irq05`, `trap_irq06`, `trap_irq07`, `trap_irq08`, `trap_irq09`, `trap_irq10`, `trap_irq11`, `trap_irq12`, `trap_irq13`, `trap_irq14`, `trap_irq15` | proc0 interrupt pending: expected-value checks, dummy read after each clear |
| `0x71e00004` | W | W | `irq15_ack_hardint15`, `post_proc0_irq_regs`, `post_soft_irq_off`, `trap_irq01`, `trap_irq02`, `trap_irq03`, `trap_irq04`, `trap_irq05`, `trap_irq06`, `trap_irq07`, `trap_irq08`, `trap_irq09`, `trap_irq10`, `trap_irq11`, `trap_irq12`, `trap_irq13`, `trap_irq14`, `trap_irq15`, `watchdog_reenter_obp` | proc0 clear-pending: 1<<(16+level) soft clear, 0x8000 level-15 clear |
| `0x71e00008` | W | W | `post_proc0_irq_regs`, `post_soft_irq_off`, `post_soft_irq_on` | proc0 set-soft: raise soft interrupts |
| `0x71e10000` | W | R | `post_soft_irq_off`, `post_soft_irq_on` | system interrupt pending: must read 0 |
| `0x71e10008` | W | W | `post_dma2_pport_slave_err`, `post_ebus_read_timeout`, `post_proc0_counter_timer`, `post_proc0_irq_regs`, `post_sbus_read_timeout`, `post_soft_irq_off`, `post_soft_irq_on`, `pport_wait_irq_ocr`, `sys_timer_irq10_arm`, `sys_timer_limit_irq_setup` | system interrupt mask clear (0xf05dff80 unmask) |
| `0x71e1000c` | W | W | `irq10_sys_counter_lbit_check`, `irq14_proc_counter_lbit_check`, `no_irq_fail_dead`, `post_dma2_pport_slave_err`, `post_ebus_read_timeout`, `post_proc0_counter_timer`, `post_proc0_irq_regs`, `post_quiesce_leds_off`, `post_sbus_read_timeout`, `post_soft_irq_off`, `post_soft_irq_on`, `pport_wait_irq_ocr`, `proc_counter_no_irq_fail`, `sys_timer_irq10_disarm`, `trap_irq04`, `trap_irq06`, `trap_irq15` | system interrupt mask set (0xf05dff80; 0x80080000 = MA+T; 0x80040000/0x80010000 in DMA2 handlers) |

### system control/status

| PA | Width | R/W | Routines | Purpose |
|---|---|---|---|---|
| `0x71f00000` | W | R/W | `post_entry`, `post_poll_ttya_command`, `reset_entry`, `sysctl_soft_reset` | system control/status: read bit 1 (SW reset) / bit 4 (watchdog); write 1 = SW reset |

### SBus slot 5 base / DMA2 ID register

| PA | Width | R/W | Routines | Purpose |
|---|---|---|---|---|
| `0x78000000` | B,H,W | R/W | `post_dma2_id_reg` | slot-5 ID register: expect 0xfe810103 as word, halves, bytes; read-only (uncalled test) |
| `0x78000001` | B | R | `post_dma2_id_reg` | ID register byte 1 |
| `0x78000002` | B,H | R | `post_dma2_id_reg` | ID register half/byte 2 |
| `0x78000003` | B | R | `post_dma2_id_reg` | ID register byte 3 |

### DMA2 (ESP/LANCE DMA)

| PA | Width | R/W | Routines | Purpose |
|---|---|---|---|---|
| `0x78400000` | B,W | R/W | `dma2_d_clear_slave_err`, `dma2_d_reset`, `dma2_d_reset_chain`, `post_dma2_d_addr`, `post_dma2_d_bcnt`, `post_dma2_d_chain`, `post_dma2_d_csr`, `post_dma2_d_naddr`, `post_dma2_d_nbcnt`, `trap_irq04` | DMA2 D_CSR (ESP DMA): reset 0x80, SLAVE_ERR 0x40 (W1C), EN_CNT/EN_NEXT, ID 0xa0000000 |
| `0x78400004` | B,W | R/W | `post_dma2_d_addr`, `post_dma2_d_chain`, `post_dma2_d_naddr`, `post_dma2_d_nbcnt` | DMA2 D_ADDR: 0x55555555/0/0xaaaaaaaa; byte store -> slave error |
| `0x78400008` | B,W | R/W | `post_dma2_d_bcnt`, `post_dma2_d_chain`, `post_dma2_d_nbcnt` | DMA2 D_BCNT: 0x00e69f10/0; byte store -> slave error |
| `0x78400010` | B,W | R/W | `dma2_e_clear_slave_err`, `dma2_e_reset`, `post_dma2_e_csr`, `post_lance_addr_port`, `post_lance_data_port`, `trap_irq06` | DMA2 E_CSR (Ethernet DMA): reset, SLAVE_ERR |

### ESP 53C9x SCSI

| PA | Width | R/W | Routines | Purpose |
|---|---|---|---|---|
| `0x78800000` | B | R/W | `post_esp_regs` | ESP transfer count low |
| `0x78800004` | B | R/W | `post_esp_regs` | ESP transfer count high |
| `0x78800008` | B | R/W | `post_esp_regs` | ESP FIFO (89 ab cd ef) |
| `0x7880000c` | B | R/W | `post_esp_regs` | ESP command (0x80 DMA NOP) |
| `0x78800020` | B | R/W | `post_esp_regs` | ESP configuration 1 (0x55/0xaa/0x00) |

### LANCE Am7990 Ethernet

| PA | Width | R/W | Routines | Purpose |
|---|---|---|---|---|
| `0x78c00000` | B,H | R/W | `post_lance_data_port` | LANCE RDP: CSR0 = 4, CSR1 = 0xa8a8; byte store -> slave error |
| `0x78c00002` | B,H | R/W | `post_lance_addr_port`, `post_lance_data_port` | LANCE RAP: 1/0; byte store -> slave error |

### DMA2 parallel / BPP

| PA | Width | R/W | Routines | Purpose |
|---|---|---|---|---|
| `0x7c800000` | W | R/W | `post_dma2_p_addr`, `post_dma2_p_bcnt`, `post_dma2_p_csr`, `post_dma2_pport_slave_err`, `post_pport_regs`, `pport_wait_irq_hcr`, `pport_wait_irq_ocr`, `trap_irq03` | DMA2 P_CSR (parallel DMA): reset 0x80, status bits, SLAVE_ERR |
| `0x7c800004` | W | R/W | `post_dma2_p_addr` | DMA2 P_ADDR: 0xa55a5aa5/0xffffffff/0 |
| `0x7c800008` | W | R/W | `post_dma2_p_bcnt` | DMA2 P_BCNT: 24-bit (0x005a5aa5, 0x00ffffff, 0) |
| `0x7c800010` | B,H | R/W | `post_dma2_pport_slave_err`, `post_pport_regs` | BPP HCR (half); byte store -> slave error |
| `0x7c800012` | B,H | R/W | `post_dma2_pport_io_loopback`, `post_dma2_pport_xfr_loopback`, `post_pport_regs`, `pport_wait_irq_hcr` | BPP OCR (half): reset value 0x200a; 0x400 EN_DIAG |
| `0x7c800015` | B | R/W | `post_pport_regs`, `pport_xfr_loop` | BPP TCR (byte): DIR set at reset |
| `0x7c800016` | B | R | `pport_io_loop` | BPP OR (loopback read, broken test) |
| `0x7c800017` | B | W | `pport_io_loop` | BPP IR (loopback write, broken test) |
| `0x7c800018` | H | R/W | `trap_irq03` | BPP interrupt control (half): trap_irq03 acknowledge |

### other onboard (?)

| PA | Width | R/W | Routines | Purpose |
|---|---|---|---|---|
| `0x7cc00000` | W | R | `post_sbus_read_timeout` | slot-5 offset 0x4c00000, no device: read to provoke an SBus time-out (tt 0x29) |

## 3. ASI 0x20 accesses with a run-time address

These use a register the constant tracker cannot follow (loop variables,
arguments, delay-slot constants on a branch target). Their targets, from the
code:

| Routine(s) | Instructions | Addresses |
|---|---|---|
| `escc_wr_reg`, `escc_init_ttya`, `escc_init_kbd`, `ttya_rx_ready`, `ttya_getc_wait`, `ttya_getc_nowait`, `boot_puts` | `stba`/`lduba` | Z85C30 control/data `0x71000004/6`, `0x71100004/6`; `boot_puts` reads the PROM string at `0x70000000 + offset` |
| `trap_window_overflow`, `trap_window_underflow` | `stda`/`ldda` | the POST stack, `%sp` = lowest bank + `0xc00` and below |
| `mem_probe_bank` | `sta`/`lda` | bank base n·32 MB + {0, 4, 1/2/4/8/16 MB (+4), 0x20, 0x24} |
| `mem_march_test`, `mem_march_test_b` | `sta`/`lda` | top 64 KB of the highest bank, first 20 KB of the lowest |
| `mmu_alloc_clear`, `pa_ld_word`, `pa_st_word` (from `mmu_build_boot_tables`/`mmu_map_range`) | `sta`/`lda` | page tables at the top of the kernel's RAM region |
| `c_mem_fill64`, `c_mem_check64_up`/`down` (Forth-called) | `stda`/`ldda` | memory under test |
| `iommu_reg_walk_test`, `iommu_walk_loop` | `sta`/`lda` | SSCR0 `0x10001010`, IOMMU control `0x10000000`, IOMMU base `0x10000004` |
| `post_iommu_tlb_flush`, `iommu_flush_entry_loop`, `post_iommu_tlb_flush_all` | `sta` | IOMMU address flush `0x10000018` (page i<<12), flush all `0x10000014` |
| `post_sbus_read_timeout`, `post_ebus_read_timeout` | `lda`/`sta` | MID `0x10002000` (SBAE bits), system mask set/clear `0x71e1000c`/`0x71e10008` |
| `post_proc0_user_timer` | `stda`/`ldda` | user timer `0x71d00000` (64-bit) |
| `post_proc0_counter_timer`, `irq14_proc_counter_lbit_check`, `irq10_sys_counter_lbit_check` | `lda` | `0x71d00000`/`0x71d00004`, `0x71d10000`/`0x71d10004` |
| `copy_*`, `fill_asi_words*`, `tlb_read_entries` (uncalled library) | all | caller-supplied |
| `asi_st_*`/`asi_ld_word` stubs for ASI 0x20-0x2f | all widths | caller-supplied (not used with 0x20 by the POST) |

## 4. RAM and virtual addresses used by the machine code

| Address | Access | Routine | Purpose |
|---|---|---|---|
| lowest bank + `0x0c00` down | stack (bypass spills) | POST | `%sp` after `post_main` |
| lowest bank + `0x2000`-`0x201f` | W, D | FPU tests | pattern table / operand and result slots |
| lowest bank + `0x2100` | W, D | FPU tests | store target |
| PA `0x00002100`, `0x00002108` | W, D | `trap_fp_exception` | FSR and FQ dump (absolute: needs RAM at PA 0) |
| PA `0x00002300`-`0x00002307` | B | `post_tod_regs` | TOD save area (absolute) |
| `0x0e000000`-`0x0f000000` (downwards in 32 MB steps) | W | `obp_cold_entry` | find the highest bank: `0x55555555`, `0xaaaaaaaa`, `0xdeadbeef`, `0xfeedc0ed` at +0..+0xc; size probe at +0, +2/4/8/16 MB |
| top of that bank, downwards | W (bypass) | `mmu_build_boot_tables` | 4 KiB context table, 64 KiB kernel RAM, 1 KiB L1 table, L2/L3 tables |
| VA `0xffef0000`-`0xffef1fff` | W, B | `obp_cold_entry` | initial RAM image (copied from PROM `0x7003bd60`, 0x980 bytes) and zeroed tail |
| VA `0xffef0034`, `…003c`, `…0040`, `…0078`, `…00a8`, `…04a0`-`…04b0`, `…04b8`, `…04bc` | W | `obp_cold_entry` | parameters for the Forth kernel: RAM image base, stacks, POST results, memory base/size |
| VA `0xffeff000` | TBR | `obp_cold_entry` | RAM trap table |
| VA `0xffd00000`-`0xffd7ffff`, `0x00000000`-`0x0007ffff` | mapped | `mmu_build_boot_tables` | PROM (512 KiB windows) |

## 5. Address ranges for the decoder diff

Physical ranges the machine code reaches, with the registers used:

| Range | Device | Registers used |
|---|---|---|
| `0x00000000`-`0x0fffffff` | RAM, 8 banks × 32 MB | sizing probes, march tests, scratch, page tables |
| `0x10000000`-`0x10000fff` | IOMMU | +0 control, +4 base, +0x14 flush all, +0x18 address flush |
| `0x10001000`-`0x10001fff` | SBus controller | +0 AFSR, +4 AFAR, +0x10 SSCR0 (SSCR1-4 listed, not reached), +0x50 MFSR, +0x54 MFAR |
| `0x10002000` | MID / SBAE | +0 |
| `0x70000000`-`0x7003ffff` | **boot PROM** | instruction fetch in boot mode; ASI 9 loads (`post_printf`, tables; boot-mode mapped like fetches); **ASI 0x20 loads** at `0x7000xxxx` (`boot_puts`); and, once the MMU is on, every PTE OBP builds for the PROM (`mmu_map_range(0x70000000, …)`, watchdog TLB entries → PA `0x7000c000`, `0x70027000`) |
| `0x71000000` | Z85C30 #0 (keyboard ch A) | +4 control, +6 data |
| `0x71100000` | Z85C30 #1 (ttya ch A) | +4 control, +6 data |
| `0x71200000`-`0x71201fff` | MK48T08 NVRAM/TOD | +0, +1, +3, +0x4e, +0x1dd8, +0x1ff8-+0x1fff |
| `0x71400300` | EBus, floppy range (no device at +0x300) | read to force an error acknowledge |
| `0x71d00000`-`0x71d0000f` | processor 0 counter / user timer | +0, +4, +8, +0xc |
| `0x71d10000`-`0x71d10013` | system counter, timer configuration | +0, +4, +0x10 |
| `0x71e00000`-`0x71e0000b` | processor 0 interrupts | +0 pending, +4 clear, +8 set-soft |
| `0x71e10000`-`0x71e1000f` | system interrupts | +0 pending, +8 mask clear, +0xc mask set |
| `0x71f00000` | system control/status | +0 |
| `0x78000000`-`0x78000003` | slot-5 ID register | word, halves, bytes (uncalled test) |
| `0x78400000`-`0x78400013` | DMA2 ESP and Ethernet channels | +0 D_CSR, +4 D_ADDR, +8 D_BCNT, +0x10 E_CSR |
| `0x78800000`-`0x78800023` | ESP 53C9x | +0, +4, +8, +0xc, +0x20 |
| `0x78c00000`-`0x78c00003` | LANCE | +0 RDP, +2 RAP |
| `0x7c800000`-`0x7c800019` | DMA2 parallel channel + BPP | +0 P_CSR, +4 P_ADDR, +8 P_BCNT, +0x10..+0x18 BPP |
| `0x7cc00000` | slot-5 hole | read to force an SBus time-out |

Not touched by the machine code at all: TCX and the other SBus slots, the
CS4231/APC audio block, the floppy controller proper, the AUX registers
(`0x719xxxxx`), and the second channels (B) of both Z85C30s.
