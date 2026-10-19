# SS20 OBP 2.25 — hardware accessed by the machine code

Every physical address and alternate space the machine code in this ROM
touches, grouped by device: the trap handlers, the reset path, the POST, the
compiled C support code at `0x3d120-0x3e5ff`, `rom-cold-code`, and (listed
separately) the machine-code words of the Forth kernel that QEMU executed.
Generated from [`listing.s`](listing.s)'s analysis (every load/store whose
address the constant tracker resolves), then annotated by hand; addresses
computed at run time (loops, per-CPU offsets) are described in §2. This is
the list to diff against the core's address and ASI decoders.

Conventions: physical addresses are 36-bit, `0xS_HHHH_LLLL` with S =
PA[35:32] (bypass ASI 0x20 → S = 0, 0x2e → 0xe, 0x2f → 0xf). Width in bits;
r = load, w = store, rmw = `ldstub`/`swap`. "From" lists the labels of the
routines (or loop labels inside them) that make the access; see
[`romdis.json`](romdis.json) / [`listing.s`](listing.s).

## 1. Physical addresses (bypass ASIs 0x20, 0x2e, 0x2f and MMU-off accesses)


### MSI (MBus-to-SBus interface): MID register

| pa | Register | Width | r/w | From |
|---|---|---|---|---|
| `0xf_e000_2000` | MID register (MBus ID of the requesting master) | 32 | r | `c_get_mid`, `fw_prom_cold_code`, `get_mid`, `obp_prep`, `obp_start_caches`, `reset_entry` +5 |

### IOMMU

| pa | Register | Width | r/w | From |
|---|---|---|---|---|
| `0xf_e000_0000` | IOMMU control ([31:24] IMPL/VER, bit 0 enable, 4:2 range) | 32 | r/w | `c_get_mid`, `fw_prom_cold_code`, `iommu_addr_flush_loop`, `iommu_check_tlb_valid_except`, `iommu_diag_clear_loop`, `iommu_fill_tlb_and_tags` +12 |
| `0xf_e000_0004` | IOMMU base address | 32 | w | `iommu_diag_clear_loop`, `lance_lpbk_cleanup` |
| `0xf_e000_0014` | IOMMU flush all TLB entries | 32 | w | `lance_lpbk_cleanup` |
| `0xf_e000_0018` | IOMMU address flush | 32 | w | `iommu_addr_flush_loop` |
| `0xf_e000_0100` | IOMMU tag diagnostic window (+4 per entry) | 32 | w | `iommu_fill_tlb_and_tags` |
| `0xf_e000_0200` | IOMMU TLB diagnostic window (+4 per entry) | 32 | r/w | `iommu_addr_flush_loop`, `iommu_check_tlb_valid_except`, `iommu_diag_clear_loop`, `iommu_fill_tlb_and_tags` |

### MSI M-to-S regs (AFSR/AFAR/arbiter/slot cfg)

| pa | Register | Width | r/w | From |
|---|---|---|---|---|
| `0xf_e000_1000` | M-to-S async fault status (AFSR) | 32 | r/w | `irq_level_15`, `post_dma2_macio_d_addr_reg_test`, `post_dma2_macio_d_bcnt_reg_test`, `post_dma2_macio_d_csr_reg_test`, `post_dma2_macio_d_naddr_reg_test`, `post_dma2_macio_d_nbcnt_reg_test` +6 |
| `0xf_e000_1004` | M-to-S async fault address (AFAR) | 32 | r | `irq_level_15`, `post_dma2_macio_d_addr_reg_test`, `post_dma2_macio_d_bcnt_reg_test`, `post_dma2_macio_d_csr_reg_test`, `post_dma2_macio_d_naddr_reg_test`, `post_dma2_macio_d_nbcnt_reg_test` +5 |
| `0xf_e000_1008` | arbiter enable (bits 3:1 MBus masters 9-B, 20:16 SBus) | 32 | r/w | `lance_lpbk_have_ram`, `mp_dispatch`, `mp_probe_slaves`, `mp_wait_idle`, `post_entry`, `post_mbus_to_ebus_timeout_tests` +6 |

### EMC ECC memory controller

| pa | Register | Width | r/w | From |
|---|---|---|---|---|
| `0xf_0000_0000` | EMC ECC memory enable (IMPL/VER, MRR refresh 9:2, EI, EE) | 32 | r/w | `bcopy_call_one`, `emc_ctlregs_enable`, `emc_dump_regs`, `emc_enable_default_value`, `irq_level_15`, `post_emc_smc_control_regs_tests` +1 |
| `0xf_0000_0004` | EMC memory delay register | 32 | r/w | `cold_master_size_memory`, `emc_ctlregs_delay`, `emc_write_delay_reg` |
| `0xf_0000_0008` | EMC ECC fault status (EFSR) | 32 | r/w | `bcopy_ce_check_efar`, `bcopy_ce_check_efsr`, `ecc_ce_loop`, `ecc_ce_wait_irq`, `ecc_ceue_loop`, `ecc_ceue_wait_irq` +13 |
| `0xf_0000_000c` | EMC video configuration register (VCR) | 32 | r/w | `dsimm_size_slot`, `emc_ctlregs_vcr`, `mem_fill_copy_fragment`, `mem_probe_dsimm_loop`, `mem_probe_vsimm_loop`, `vsimm_probe_slot` |
| `0xf_0000_0010` | EMC ECC fault address 0 (EFAR0) | 32 | r | `bcopy_ce_check_efar`, `emc_dump_regs`, `irq_level_15`, `trap_unexpected_async` |
| `0xf_0000_0014` | EMC ECC fault address 1 (EFAR1) | 32 | r | `bcopy_ce_check_efar`, `emc_dump_regs`, `irq_level_15`, `trap_unexpected_async` |
| `0xf_0000_0018` | EMC ECC diagnostic register | 32 | r/w | `ecc_ce_loop`, `ecc_ceue_loop`, `ecc_ue_loop`, `emc_ctlregs_diag`, `emc_diag_write_dword`, `emc_dump_regs` +5 |

### ESCC0 keyboard/mouse (Z85C30)

| pa | Register | Width | r/w | From |
|---|---|---|---|---|
| `0xf_f100_0004` | ESCC0 channel A control (keyboard) | 8 | r/w | `kbd_getc_timeout`, `kbd_send`, `post_fail_cpu_module`, `post_fail_main_logic_board`, `post_fail_mixed_modules`, `post_fail_no_dsimm` |
| `0xf_f100_0006` | ESCC0 channel A data (keyboard) | 8 | r/w | `kbd_getc_timeout`, `kbd_send` |

### ESCC1 serial A/B (Z85C30)

| pa | Register | Width | r/w | From |
|---|---|---|---|---|
| `0xf_f110_0004` | ESCC1 channel A control (ttya) | 8 | r/w | `post_console_command`, `post_main_mem_addr_test`, `post_printf_nosave`, `printf_hex_digit`, `rttya_putc`, `ttya_drain` +3 |
| `0xf_f110_0006` | ESCC1 channel A data (ttya) | 8 | w | `post_console_command`, `printf_hex_digit`, `rttya_putc`, `ttya_putc` |

### NVRAM/TOD (MK48T08)

| pa | Width | r/w | From | Offset use |
|---|---|---|---|---|
| `0xf_f120_0001` | 8 | r/w | `nvram_diag_switch`, `reset_kbd_decide`, `reset_l1_d_pressed`, `rputhex_if_diag`, `rputs_if_diag` | diag-switch? (non-zero: POST, verbose boot messages) |
| `0xf_f120_0003` | 8 | r/w | `nvram_tod_probe`, `post_nvram_access_test` | NVRAM access check byte (0x10ccc) |
| `0xf_f120_000f` | 8 | w | `cold_master_map` | per-CPU release flags 0x0f..0x12 (reset: 0xff; slave clears, OBP sets; rom-cold-code 0x80/0x90/0x99) |
| `0xf_f120_004e` | 8 | r | `reset_l1_d_pressed` | checked for 1/2 before honouring Stop-D (guess: security mode) |
| `0xf_f120_1cd8` | 8 | w | `reset_skip_post`, `reset_watchdog_viking` | watchdog-reset post-mortem 0x1cd8..0x1f63: PTP0, PTP2, PTP2 tag (12 bytes), then 64 D-TLB entries x 10 bytes; post_exit_to_obp clears 0x1cd8..0x1cdf |
| `0xf_f120_1e00` | 8 | w | `mp_probe_slaves` | MP mailboxes: status 0x1e00+5n, command word 0x1e01+5n |
| `0xf_f120_1e20` | 8 | rmw/w | `console_lock`, `console_unlock` | console spin lock (ldstuba) |
| `0xf_f120_1ff0` | 8 | w | `mp_slave_setup_mmu`, `post_console_command` | POST flag (cleared by mp_slave_setup_mmu) |
| `0xf_f120_1ff1` | 8 | r/w | `post_main`, `post_master_start`, `post_print_cpu_id` | module flags: bit 0 = a module without MXCC, bit 1 = with MXCC (3 = mixed) |
| `0xf_f120_1ff2` | 8 | r/w | `hs_print_test_name`, `post_cache_flashclear_test`, `post_hypersparc_suite`, `post_main_start`, `post_master_start`, `post_mmu_flush_tests` +11 | POST verbosity: 2 = print test names |
| `0xf_f120_1ff8` | 8 | r/w | `tod_restore_regs_loop`, `tod_save_area_ram_loop`, `tod_save_regs_loop`, `tod_value_loop` | MK48T08 clock control (0x40 read, 0x80 write) |
| `0xf_f120_1ff9` | 8 | r/w | `tod_reg_loop`, `tod_restore_regs_loop`, `tod_value_loop` | MK48T08 seconds (then minutes .. year to 0x1fff) |

### counter/timers

| pa | Register | Width | r/w | From |
|---|---|---|---|---|
| `0xf_f130_0000` | processor 0 limit / user timer MSW | 32/64 | r/w | `mp_probe_slaves`, `reset_power_on`, `rkbd_getc_timeout` |
| `0xf_f130_0004` | processor 0 counter / user timer LSW | 32 | w | `reset_power_on` |
| `0xf_f130_000c` | processor 0 user timer start/stop | 32 | w | `reset_power_on` |
| `0xf_f131_0000` | system limit (level 10) | 32 | r/w | `irq_level_10`, `post_system_counter_test`, `sys_timer_heartbeat_start`, `sys_timer_heartbeat_stop` |
| `0xf_f131_0004` | system counter | 32 | r | `irq_level_10`, `post_system_counter_test` |
| `0xf_f131_0008` | system limit, no counter reset | 32 | w | `post_system_counter_test` |
| `0xf_f131_0010` | timer configuration (bit n: processor n counter is a user timer) | 32 | r/w | `counter_timer_body`, `counter_timer_wait_l14`, `reset_power_on`, `user_timer_body`, 4 Forth code words |

### interrupt controller

| pa | Register | Width | r/w | From |
|---|---|---|---|---|
| `0xf_f140_0004` | processor 0 clear-pending | 32 | w | `irq_level_15` |
| `0xf_f141_0000` | system interrupt pending | 32 | r | `post_soft_interrupts_off_test`, `pport_slave_start`, 1 Forth code word |
| `0xf_f141_0004` | interrupt target mask | 32 | r | `post_system_interrupt_regs_tests`, 3 Forth code words |
| `0xf_f141_0008` | interrupt target mask clear | 32 | w | `cbread_check_mxcc_err`, `irq_level_15`, `lance_lpbk_external_pass`, `lance_lpbk_internal_pass`, `mxcc_nc_block_copy_one`, `post_ecc_multiple_ce_test` +15 |
| `0xf_f141_000c` | interrupt target mask set | 32 | w | `bcopy_call_one`, `cbread_call_one`, `counter_timer_wait_l14`, `ecc_ce_wait_irq`, `ecc_ceue_wait_irq`, `ecc_ue_wait_irq` +15 |
| `0xf_f141_0010` | interrupt target register | 32 | r/w | `mp_run_with_target`, `post_check_master`, `post_ecc_multiple_ue_test`, `post_proc_counter_timer_test`, `post_proc_interrupt_regs_tests`, `post_soft_interrupts_off_test` +5 |

### floppy (82077)

| pa | Register | Width | r/w | From |
|---|---|---|---|---|
| `0xf_f170_0300` | floppy space, read to provoke an EBus timeout (dead test) | 32 | r | `post_mbus_to_ebus_timeout_tests` |

### AUXIO0 (LED/floppy/serial-B mux)

| pa | Register | Width | r/w | From |
|---|---|---|---|---|
| `0xf_f180_0000` | AUXIO0 (bit 0 LED, bit 2 floppy TC) | 8 | r/w | `obp_start`, `reset_jump_post`, `reset_mid_known` |

### system control/status

| pa | Register | Width | r/w | From |
|---|---|---|---|---|
| `0xf_f1f0_0000` | system control/status (bit 0 SW_RST, 1 SW reset status, 3 switch reset) | 32 | r/w | `obp_prep_mid_known`, `reset_check_sysctl` |

### SBus slot 15 base (DMA2 internal/ID?)

| pa | Register | Width | r/w | From |
|---|---|---|---|---|
| `0xe_f000_0000` | MACIO/DMA2 ID register (expected 0xfe810103) | 8/16/32 | r/w | `post_dma2_macio_id_register_test` |
| `0xe_f000_0001` |  | 8 | r | `post_dma2_macio_id_register_test` |
| `0xe_f000_0002` |  | 8/16 | r | `post_dma2_macio_id_register_test` |
| `0xe_f000_0003` |  | 8 | r | `post_dma2_macio_id_register_test` |

### DMA2 (SCSI DMA +0, ENET DMA +0x10)

| pa | Register | Width | r/w | From |
|---|---|---|---|---|
| `0xe_f040_0000` | DMA2 SCSI D_CSR | 8/32 | r/w | `dma2_d_clear_slave_err`, `dma2_d_reset_en_next`, `dma2_d_reset_pulse`, `irq_level_4`, `post_dma2_macio_d_addr_reg_test`, `post_dma2_macio_d_bcnt_reg_test` +5 |
| `0xe_f040_0004` | DMA2 SCSI D_ADDR (also rom-cold-code mailbox for the slave CTP) | 8/32 | r/w | `cold_mid_known`, `post_dma2_macio_d_addr_reg_test`, `post_dma2_macio_d_na_loaded_test`, `post_dma2_macio_d_naddr_reg_test`, `post_dma2_macio_d_nbcnt_reg_test`, `reset_check_sysctl` |
| `0xe_f040_0008` | DMA2 SCSI D_BCNT | 8/32 | r/w | `post_dma2_macio_d_bcnt_reg_test`, `post_dma2_macio_d_na_loaded_test`, `post_dma2_macio_d_nbcnt_reg_test`, `reset_check_sysctl` |
| `0xe_f040_0010` | DMA2 Ethernet E_CSR | 8/32 | r/w | `dma2_e_clear_slave_err`, `dma2_e_reset_pulse`, `irq_level_6`, `lance_lpbk_external_pass`, `lance_lpbk_internal_pass`, `post_dma2_macio_e_csr_reg_test` +3 |
| `0xe_f040_0014` | DMA2 Ethernet test CSR | 32 | r/w | `lance_loopback_run`, `post_ethernet_loopback_test` |
| `0xe_f040_0018` | DMA2 Ethernet cache valid bits | 32 | r | `post_ethernet_loopback_test` |
| `0xe_f040_001c` | DMA2 Ethernet base address | 8 | r/w | `lance_loopback_run`, `post_ethernet_loopback_test` |

### ESP 53C9x SCSI

| pa | Register | Width | r/w | From |
|---|---|---|---|---|
| `0xe_f080_0000` | ESP transfer count low (reg 0) | 8/32 | r/w | `post_esp_registers_tests`, `reset_check_sysctl` |
| `0xe_f080_0004` | ESP transfer count high (reg 1) | 8 | r/w | `post_esp_registers_tests` |
| `0xe_f080_0008` | ESP FIFO (reg 2) | 8 | r/w | `post_esp_registers_tests` |
| `0xe_f080_000c` | ESP command (reg 3) | 8/32 | r/w | `post_esp_registers_tests`, `reset_check_sysctl` |
| `0xe_f080_0020` | ESP configuration 1 (reg 8) | 8/32 | r/w | `post_esp_registers_tests`, `reset_check_sysctl` |
| `0xe_f080_0028` | ESP test (reg 0xa) | 32 | w | `reset_check_sysctl` |

### LANCE Am7990 Ethernet

| pa | Register | Width | r/w | From |
|---|---|---|---|---|
| `0xe_f0c0_0000` | LANCE register data port (RDP) | 8/16 | r/w | `lance_loopback_run`, `lance_lpbk_fill_buf_loop`, `lance_lpbk_wait_idon`, `lance_lpbk_wait_rx`, `lance_lpbk_wait_tx`, `post_lance_data_port_tests` |
| `0xe_f0c0_0002` | LANCE register address port (RAP) | 8/16 | r/w | `lance_loopback_run`, `lance_lpbk_fill_buf_loop`, `lance_lpbk_wait_rx`, `lance_lpbk_wait_tx`, `post_lance_address_port_tests`, `post_lance_data_port_tests` |

### parallel port (DMA2 PP)

| pa | Register | Width | r/w | From |
|---|---|---|---|---|
| `0xe_f480_0000` | parallel port P_CSR (+4 P_ADDR, +8 P_BCNT) | 32 | r/w | `irq_level_3`, `post_dma2_macio_p_addr_reg_test`, `post_dma2_macio_p_bcnt_reg_test`, `post_dma2_macio_p_csr_reg_test`, `post_pport_registers_tests` |
| `0xe_f480_0012` | parallel port operation configuration (OCR) | 16 | w | `post_dma2_macio_pport_io_lpbck_tst`, `post_dma2_macio_pport_xfr_lbck_tst` |
| `0xe_f480_0015` | parallel port transfer control (TCR) | 8 | r/w | `pport_xfr_lpbk_loop` |
| `0xe_f480_0016` | parallel port control output (OR) | 8 | w | `pport_io_lpbk_loop` |
| `0xe_f480_0017` | parallel port status input (IR) | 8 | r | `pport_io_lpbk_loop` |
| `0xe_f480_0018` | parallel port interrupt control (ICR) | 16 | r/w | `irq_level_3` |

### SBus slot 0

| pa | Register | Width | r/w | From |
|---|---|---|---|---|
| `0xe_0000_0010` | SBus slot 0, read to provoke an SBus timeout (dead test) | 32 | r | `post_mbus_to_sbus_timeout_tests` |

### VSIMM/MDI control, SIMM slot 4-7 at +0x4000000*(n-4)

| pa | Register | Width | r/w | From |
|---|---|---|---|---|
| `0x0_9000_0005` | VSIMM/MDI control space, slot 4 (level-8 handler) | 8 | r | `irq_level_8` |

### Unmapped probes

| pa | Register | Width | r/w | From |
|---|---|---|---|---|
| `0x0_2000_0000` | above the 512 MB of RAM: memory time-out probe (dead test) | 32 | r | `post_emc_smc_memory_timeout_tests` |

### Main memory used as fixed scratch (MMU off)

POST keeps its data at fixed physical addresses (plain `ld/st` with the MMU off, or ASI 0x20):

| pa | Width | r/w | From |
|---|---|---|---|
| `0x0_0000_0000` | 64 | w | `copy_256k_ktext_to_mem` |
| `0x0_0000_0040` | 32 | w | `ether_dump_fill_loop` |
| `0x0_0000_2000` | 32 | w | `mmu_build_ptp_test_tables`, `ptp_tables_l3_prom_loop`, `tlbtest_build_tables_non_hs` |
| `0x0_0000_2004` | 32 | w | `mmu_build_ptp_test_tables`, `ptp_tables_l3_prom_loop`, `tlbtest_build_tables_non_hs` |
| `0x0_0000_2008` | 32 | w | `tlbtest_clear_segment_ptes`, `tlbtest_fill_segments` |
| `0x0_0000_3000` | 32 | w | `ptp_tables_l2_ptps` |
| `0x0_0000_4000` | 32 | w | `ptp_tables_l2_ptps` |
| `0x0_0000_5000` | 32 | w | `ptp_tables_l2_ptps` |
| `0x0_0000_6000` | 32 | w | `ptp_tables_l2_ptps` |
| `0x0_0000_7000` | 32 | w | `ptp_tables_l3_prom_loop` |
| `0x0_0004_0000` | 32 | r/w | `hs_ecread_mode_loop`, `post_hypersparc_ecache_write_miss_test` |
| `0x0_0005_0000` | 32 | w | `tlb_read_miss_ram_ok`, `tlb_write_miss_ram_ok` |
| `0x0_0005_2000` | 32 | w | `tlb_read_miss_ram_ok`, `tlb_write_miss_ram_ok` |
| `0x0_0005_4000` | 32 | r/w | `tlb_read_miss_ram_ok` |
| `0x0_0005_4004` | 32 | r/w | `tlb_write_miss_ram_ok` |
| `0x0_0008_0000` | 32 | w | `hs_bcopy_on_pass_loop`, `post_hypersparc_icache_miss_test`, `tlbtest_fill_segments` |
| `0x0_0008_0004` | 32 | w | `post_hypersparc_icache_miss_test` |
| `0x0_0030_0000` | 16/32/64 | r/w | `endian_iu_start` |
| `0x0_0040_0000` | 8 | r/w | `tod_restore_regs_loop`, `tod_save_area_ram_loop`, `tod_save_regs_loop` |
| `0x0_0040_0001` | 8 | r | `tod_restore_regs_loop` |
| `0x0_0050_3184` | 32 | r/w | `tlb_hit_index_1_3` |
| `0x0_0050_3240` | 64 | w | `post_fpu_dp_ue_trap_priority_test`, `post_fpu_sp_ue_trap_priority_test` |
| `0x0_0050_3260` | 64 | w | `post_fpu_dp_ce_trap_priority_test`, `post_fpu_sp_ce_trap_priority_test` |
| `0x0_0060_0000` | 32/64 | r/w | `irq_level_15`, `mem_fill_copy_fragment` |
| `0x0_0060_0004` | 32 | w | `irq_level_15` |
| `0x0_0060_0008` | 32 | r/w | `ecc_ce_wait_irq`, `ecc_ceue_wait_irq`, `ecc_ue_wait_irq`, `irq_level_15` |
| `0x0_0060_0010` | 32 | r/w | `ecc_ce_wait_irq`, `ecc_ceue_wait_irq`, `ecc_ue_wait_irq`, `irq_level_15` |
| `0x0_0060_0014` | 32 | r/w | `ecc_ce_wait_irq`, `ecc_ceue_wait_irq`, `ecc_ue_wait_irq`, `irq_level_15` |
| `0x0_0070_0000` | 32 | r/w | `hs_bcopy_off_fail`, `hs_bcopy_off_pass_loop`, `hs_bcopy_off_verify_loop`, `hs_bfill_off_fail_exp1` +1 |
| `0x0_0074_0000` | 32 | r/w | `hs_bcopy_off_fail`, `hs_bcopy_off_pass_loop`, `hs_bcopy_off_verify_loop` |
| `0x0_00e0_0000` | 32 | w | `iommu_iopte_fill_loop` |
| `0x0_00f0_0000`..`0x0_00f0_0200` | 16 | w | `lance_loopback_run` |

## 2. Addresses computed at run time

The constant tracker cannot resolve these; the address pattern comes from the
code (see the group sections of [`post-tests.md`](post-tests.md)). n = MID & 3.

| Device | Addresses | Width | r/w | Used by |
|---|---|---|---|---|
| per-CPU interrupt | `0xf_f140_n000` pending, `+4` clear-pending, `+8` set-soft (bit 16+level soft, bit 15 level-15) | 32 | r/w | `irq_level_*` (clear), PROCn Interrupt Regs, Soft Interrupts OFF/ON, `reset_watchdog` |
| per-CPU counter | `0xf_f130_n000` limit / user-timer MSW, `+4` counter / LSW, `+8` limit without reset, `+0xc` user-timer start/stop | 32, 64 (`ldda/stda`) | r/w | PROCn User Timer, PROCn Counter/Timer, `mp_probe_slaves` (clears all four) |
| MP mailboxes | NVRAM `0x1e00+5n` status, `0x1e01+5n..0x1e04+5n` command word, `0x1f00+16n..` arguments | 8 | r/w | `mpcntl`, `mp_dispatch`, `mp_wait_idle`, `post_slave_idle_loop` |
| release flags | NVRAM `0x0f+n` | 8 | r/w | `reset_mid_known` (0xff), `obp_slave_wait_release`, `rom-cold-code` |
| watchdog dump | NVRAM `0x1cd8..0x1f63`: 12 bytes (PTP0, PTP2, PTP2 tag) + 64 D-TLB entries × 10 bytes (tag 3, lock 1, context 2, PTE 4) | 8 | w | `reset_watchdog_viking`, `reset_watchdog_save_tlb_loop` |
| TOD | NVRAM `0x1ff8..0x1fff`, save area pa `0x400000..0x400007` | 8 | r/w | TOD Registers Test |
| memory slots | `k * 0x4000000` (k = 0..7) byte/word probes; VSIMM control `0x9000_0000 + (k-4)*0x4000000`, `0x9c001000 - n*0x4000000` | 8/32 | r/w | `mem_probe_simm_config`, `dsimm_size_slot`, `rom-cold-code` |
| memory tests | `0xfc0000-0xfdffff` (address pattern), `0x600000` (FPU, handlers), `0x503xxx` (ECC injection), `0x700000-0x77ffff`, `0x80000-0xfffff`, `0xf80000` (page tables) | 8-64 | r/w | §5, §7, §10 of post-tests.md |
| IOMMU diagnostic | `0xf_e000_0100 + 4i` tags, `0xf_e000_0200 + 4i` TLB, `0xf_e000_0140` comparator VA (w), `0xf_e000_0150` comparator output (r), 16 entries | 32 | r/w | IOMMU CAM/TLB NTA, Comparator, TLB Flush |
| MSI slot config | `0xf_e000_1010 + 4k` (k = 0..3) | 32 | r/w | MSI/MSBI Control Reg Tests |
| DMA2 / PP registers | `0xe_f040_00xx`, `0xe_f480_00xx` with byte stores to provoke size errors | 8/32 | r/w | §9 |
| ESP registers | `0xe_f080_0000 + 4r` | 8 | r/w | ESP Registers Tests |
| boot PROM | `0xf_f000_0000 + off` (ASI 0x2f, strings in the reset path); ASI 9 at the image offset (tables, printf format strings) | 8/32 | r | `rputs_if_diag`, `post_printf`, table readers |
| memory, any address | ASI 0x20 `lda/sta` through `lda_asi20`/`sta_asi20` stubs and the NTA/MATS engines | 8-64 | r/w | memory, cache, MMU tests |


## 3. Alternate spaces (other than the bypass ASIs)

Resolved addresses, then what the space is used for. MMU registers (ASI 4):
0x000 MCNTL, 0x100 CTPR, 0x200 CTX, 0x300 SFSR, 0x400 SFAR, 0x500/0x600
AFSR/AFAR, 0x700 reset register (Ross), 0x1000-0x1700 HyperSPARC / emulation
registers. MXCC (ASI 2) offsets: see §6 of post-tests.md.

| ASI | va | Width | r/w | From | Meaning |
|---|---|---|---|---|---|
| 0x02 | `0x00000000` | 64 | r/w | `post_dead_bist_check` | (dead BIST code) |
| 0x02 | `0x01000008` | 32 | r/w | `mxcc_ecache_size_detect` | E-cache data diag word (size probe: aliasing of bit 20) |
| 0x02 | `0x01100008` | 32 | r/w | `mxcc_ecache_size_detect` | E-cache data diag word (size probe: aliasing of bit 20) |
| 0x02 | `0x01800000` | 64 | w | `mxcc_ecache_tags_clear_loop` | MXCC E-cache tag diag (+ line<<7) |
| 0x02 | `0x01c00000` | 64 | w | `mxcc_cacheable_read_one`, `mxcc_cacheable_write_one`, `mxcc_nc_block_copy_one`, `mxcc_nc_block_zero_one` | MXCC stream data |
| 0x02 | `0x01c00100` | 64 | w | `cbread_start_stream_rd`, `mxcc_nc_block_copy_one`, 1 Forth code word | MXCC stream source |
| 0x02 | `0x01c00200` | 64 | w | `bcopy_poll_src_rdy`, `mxcc_cacheable_write_one`, `mxcc_nc_block_zero_one`, 2 Forth code words | MXCC stream destination |
| 0x02 | `0x01c00a00` | 32 | r/w | `mxcc_creg_hi_clr_ce`, `mxcc_creg_hi_set_ce` | MXCC control (hi) |
| 0x02 | `0x01c00a04` | 32 | r/w | `mxcc_ecache_disable`, `mxcc_ecache_enable`, `mxcc_ecache_size_detect`, `mxcc_ecache_tags_clear` +4 | MXCC control register (CREG) |
| 0x02 | `0x01c00e00` | 64 | w | `bcopy_call_one`, `bcopy_ecc_modes`, `bcopy_ue_check_mxcc_err`, `bcopy_ue_mode` +6 | MXCC error register (EREG) |
| 0x02 | `0x01c00f00` | 64 | r | `c_get_mid`, `fw_prom_cold_code`, `get_mid`, `obp_prep` +4 | MXCC port (hi) |
| 0x02 | `0x40000000` | 8 | r/w | `asi2_sysenable_set_bit5` | (?) byte, bit 5 set (dead code 0xd9c0) |
| 0x03 | `0x00000400` | 32 | w | `cpu_enter_client`, `mp_slave_setup_mmu`, `post_iu_done`, `reset_watchdog_lock_tlb` +3 | flush (sta) / probe (lda) VA 0x0, type 4 (entire) |
| 0x03 | `0x00080100` | 32 | r | `tlb_probe_loop` | flush (sta) / probe (lda) VA 0x80000, type 1 (segment) |
| 0x04 | `0x00000000` | 32 | r/w | `c_get_mid`, `cold_master_map`, `cold_mid_known`, `cold_mmu_on` +69 | MMU control (PCR/MCNTL) |
| 0x04 | `0x00000100` | 32 | r/w | `cpu_enter_client`, `get_ctp_pa`, `hs_get_pte`, `hs_mmu_set_ctx_ctpr` +11 | context table pointer |
| 0x04 | `0x00000200` | 32 | r/w | `cpu_enter_client`, `dcache_wrhit_run`, `flush_entire_fill_loop`, `flush_l0_ctx_loop` +24 | context |
| 0x04 | `0x00000300` | 32 | r | `irq_level_15`, `mxcc_parity_error_one`, `post_iu_done`, `reset_entry` +2 | sync fault status (SFSR) |
| 0x04 | `0x00000400` | 32 | r/w | `irq_level_15`, `sub_0000eb90`, `trap_unexpected_sync_mmu` | sync fault address (SFAR) |
| 0x04 | `0x00000500` | 32 | r | `irq_level_15`, `trap_unexpected_async` | async fault status (AFSR) (?) |
| 0x04 | `0x00000600` | 32 | r | `irq_level_15`, `trap_unexpected_async` | async fault address (AFAR) (?) |
| 0x04 | `0x00000700` | 32 | r | `post_init_ross_mmu`, `reset_ross_mid_setup` | reset / breakpoint (?) |
| 0x04 | `0x00001000` | 32 | w | `mmu_build_ptp_test_tables`, `post_init_ross_mmu`, `tlbtest_build_tables` | MMU/cache control extension (?); HyperSPARC root pointer |
| 0x04 | `0x00001100` | 32 | w | `post_init_ross_mmu`, `reset_watchdog_mid_known` | HyperSPARC instruction pointer (?) |
| 0x04 | `0x00001200` | 32 | w | `post_init_ross_mmu`, `reset_watchdog_mid_known` | HyperSPARC data pointer (?) |
| 0x04 | `0x00001300` | 32 | w | `reset_watchdog_mid_known` | HyperSPARC index tag (?) |
| 0x04 | `0x00001500` | 32 | w | `reset_watchdog_mid_known` | SuperSPARC shadow SFSR (emulation) (?) |
| 0x04 | `0x00001600` | 32 | w | `reset_watchdog_mid_known` |  |
| 0x04 | `0x00001700` | 32 | w | `reset_watchdog_mid_known` |  |
| 0x05 | `0x00000000` | 32 | r/w | `itlb_bitpat_sel_loop`, `itlb_flush_fill_loop`, `reset_watchdog_lock_tlb` | entry 0, SEL 0: VA tag |
| 0x05 | `0x00000100` | 32 | w | `reset_watchdog_lock_tlb` | entry 0, SEL 1: context |
| 0x05 | `0x00000200` | 32 | r/w | `itlb_flush_check_loop`, `reset_watchdog_lock_tlb`, `tlb_invalidate_all_i_d`, `tlb_miss_check_tlbs` | entry 0, SEL 2: PTE |
| 0x05 | `0x00000500` | 32 | r | `ptp_test_check_iptp2` | entry 0, SEL 5: PTP2 |
| 0x05 | `0x00000600` | 32 | r | `ptp_test_check_iptp2` | entry 0, SEL 6: PTP2 VA tag |
| 0x05 | `0x00001000` | 32 | w | `reset_watchdog_lock_tlb` | entry 1, SEL 0: VA tag |
| 0x05 | `0x00001200` | 32 | w | `reset_watchdog_lock_tlb` | entry 1, SEL 2: PTE |
| 0x06 | `0x00000000` | 32 | r/w | `flush_l0_fill_loop`, `flush_l1_fill_loop`, `flush_l2_fill_loop`, `flush_l3_fill_loop` +12 | entry 0, SEL 0: VA tag |
| 0x06 | `0x00000008` | 32 | r/w | `hs_flush_ctx_loop`, `hs_flush_region_loop`, `hs_flush_segment_loop`, `hs_mmu_flush_level_test` +3 | HyperSPARC layout: entry 0, word 2 (CAM) |
| 0x06 | `0x00000010` | 32 | w | `reset_watchdog_mid_known` | HyperSPARC layout: entry 1, word 0 (RAM) |
| 0x06 | `0x00000018` | 32 | w | `reset_watchdog_mid_known` | HyperSPARC layout: entry 1, word 2 (CAM) |
| 0x06 | `0x00000100` | 32 | r/w | `flush_l0_fill_loop`, `flush_l1_fill_loop`, `flush_l2_fill_loop`, `flush_l3_fill_loop` +2 | entry 0, SEL 1: context |
| 0x06 | `0x00000200` | 32 | r/w | `flush_entire_check_loop`, `flush_l0_check_loop`, `flush_l0_fill_loop`, `flush_l1_check_loop` +10 | entry 0, SEL 2: PTE |
| 0x06 | `0x00000300` | 32 | r/w | `dtlb_rbo_lck_pattern_loop`, `reset_watchdog_save_tlb_loop` | entry 0, SEL 3: lock/RBO |
| 0x06 | `0x00000400` | 32 | r | `ptp_test_touch_loop`, `reset_watchdog_viking` | entry 0, SEL 4: cached root pointer PTP0 |
| 0x06 | `0x00000500` | 32 | r | `ptp_test_check_dptp2`, `reset_watchdog_viking` | entry 0, SEL 5: PTP2 |
| 0x06 | `0x00000600` | 32 | r | `ptp_test_check_dptp2`, `reset_watchdog_viking` | entry 0, SEL 6: PTP2 VA tag |
| 0x06 | `0x00001000` | 32 | w | `reset_watchdog_lock_tlb` | entry 1, SEL 0: VA tag |
| 0x06 | `0x00001200` | 32 | w | `reset_watchdog_lock_tlb` | entry 1, SEL 2: PTE |
| 0x06 | `0x00001500` | 32 | r | `ptp_test_check_dptp2` | entry 1, SEL 5: PTP2 (PTP2 #1) |
| 0x06 | `0x00001600` | 32 | r | `ptp_test_check_dptp2` | entry 1, SEL 6: PTP2 VA tag (PTP2 #1) |
| 0x06 | `0x00002500` | 32 | r | `ptp_test_check_dptp2` | entry 2, SEL 5: PTP2 (PTP2 #2) |
| 0x06 | `0x00002600` | 32 | r | `ptp_test_check_dptp2` | entry 2, SEL 6: PTP2 VA tag (PTP2 #2) |
| 0x06 | `0x00003500` | 32 | r | `ptp_test_check_dptp2` | entry 3, SEL 5: PTP2 (PTP2 #3) |
| 0x06 | `0x00003600` | 32 | r | `ptp_test_check_dptp2` | entry 3, SEL 6: PTP2 VA tag (PTP2 #3) |
| 0x09 | `0x00000000` | 64 | r | `copy_256k_ktext_to_mem` | PROM table/string at this offset |
| 0x09 | `0x00006200` | 32 | r | `itlb_bitpat_sel_loop` | PROM table/string at this offset |
| 0x09 | `0x00006240` | 32 | r | `dtlb_rbo_lck_pattern_loop` | PROM table/string at this offset |
| 0x09 | `0x0000ce88` | 32 | r | `post_hypersparc_icache_miss_test` | PROM table/string at this offset |
| 0x09 | `0x0000cea8` | 32 | r | `post_hypersparc_icache_miss_test` | PROM table/string at this offset |
| 0x09 | `0x0001113d` | 8 | r | `tod_reg_loop` | PROM table/string at this offset |
| 0x09 | `0x00017ea0` | 8 | r | `post_zs_init_serial` | PROM table/string at this offset |
| 0x09 | `0x00017ec0` | 8 | r | `post_zs_init_serial` | PROM table/string at this offset |
| 0x09 | `0x00017edc` | 8 | r | `post_zs_init_kbd` | PROM table/string at this offset |
| 0x09 | `0x00019684` | 32 | r | `memcfg_first_dsimm_base` | PROM table/string at this offset |
| 0x09 | `0x0001bb90` | 32 | r | `mxcc_regtest_stream_data_loop` | PROM table/string at this offset |
| 0x09 | `0x0001bb94` | 32 | r | `mxcc_regtest_table_loop` | PROM table/string at this offset |
| 0x09 | `0x0001bb98` | 32 | r | `mxcc_regtest_table_loop` | PROM table/string at this offset |
| 0x09 | `0x0001bb9c` | 32 | r | `mxcc_regtest_table_loop` | PROM table/string at this offset |
| 0x09 | `0x00024278` | 8 | r | `post_hypersparc_icache_ram_march_test` | PROM table/string at this offset |
| 0x09 | `0x0002427c` | 32 | r | `post_hypersparc_icache_ram_march_test` | PROM table/string at this offset |
| 0x09 | `0x00024280` | 32 | r | `post_hypersparc_icache_ram_march_test` | PROM table/string at this offset |
| 0x09 | `0x00024284` | 32 | r | `post_hypersparc_icache_ram_march_test` | PROM table/string at this offset |
| 0x09 | `0x00024288` | 32 | r | `post_hypersparc_icache_ram_march_test` | PROM table/string at this offset |
| 0x09 | `0x0002428c` | 32 | r | `post_hypersparc_icache_ram_march_test` | PROM table/string at this offset |
| 0x0c | `0x00000000` | 32 | w | `post_hypersparc_icache_hit_test` |  |
| 0x0c | `0x40000000` | 64 | r/w | `icache_flush_lock_check_loop`, `icache_flush_mru_check_loop`, `icache_stag_rw_loop`, `icache_tags_init` |  |
| 0x0c | `0x80000000` | 64 | r/w | `icache_flush_valid_check_loop`, `icache_ptag_rw_loop`, `icache_tags_init` |  |
| 0x0d | `0x00000000` | 64 | r/w | `icache_data_fill_loop`, `icache_ram_rw_loop`, `post_hypersparc_icache_ram_test` |  |
| 0x0d | `0x00000008` | 64 | w | `post_hypersparc_icache_ram_test` |  |
| 0x0e | `0x00000000` | 32 | r/w | `hs_ecache_clear_tags`, `hs_ecread_mode_loop`, `obp_cache_init_ross`, `post_hypersparc_ecache_write_miss_test` +1 |  |
| 0x0e | `0x00100000` | 32 | w | `obp_cache_init_ross` |  |
| 0x0e | `0x40000000` | 64 | r/w | `dcache_flush_lock_check_loop`, `dcache_flush_mru_check_loop`, `dcache_stag_rw_loop`, `dcache_tags_init` |  |
| 0x0e | `0x80000000` | 64 | r/w | `dcache_flush_valid_check_loop`, `dcache_ptag_rw_loop`, `dcache_tags_init` |  |
| 0x0f | `0x00000000` | 32/64 | r/w | `dcache_data_fill_loop`, `dcache_ram_rw_loop`, `ecache_size_probe`, `hs_ecache_size_set_cs` +4 |  |
| 0x0f | `0x00000004` | 32 | w | `post_hypersparc_cache_ram_wr_test` |  |
| 0x0f | `0x00020000` | 32 | w | `ecache_size_probe`, `hs_ecache_size_set_cs`, `obp_cache_init_ross` |  |
| 0x0f | `0x00040000` | 32 | w | `ecache_size_probe`, `obp_cache_init_ross` |  |
| 0x0f | `0x00080000` | 32 | w | `ecache_size_probe`, `obp_cache_init_ross` |  |
| 0x0f | `0x00100000` | 32 | w | `ecache_size_probe`, `obp_cache_init_ross` |  |
| 0x0f | `0x00200000` | 32 | w | `obp_cache_init_ross` |  |
| 0x13 | `0x00000000` | 32 | w | 1 Forth code word |  |
| 0x14 | `0x00000000` | 32 | w | 1 Forth code word |  |
| 0x17 | `0x00080000` | 32 | w | `hs_bcopy_on_copy_loop` |  |
| 0x17 | `0x00700000` | 32 | w | `hs_bcopy_off_pass_loop` |  |
| 0x1f | `0x00080000` | 64 | w | `hs_bfill_on_fill_loop` |  |
| 0x1f | `0x00700000` | 64 | w | `hs_bfill_off_pattern_loop` |  |
| 0x31 | `0x00000000` | 32 | w | `hs_icache_flush_all`, `obp_cache_init_ross`, `reset_watchdog_mid_known`, 3 Forth code words |  |
| 0x32 | `0x00000000` | 32 | w | `obp_cache_init_viking` |  |
| 0x36 | `0x00000000` | 32 | w | `cache_flash_clear_all`, `icache_flush_lock_check_loop`, `obp_cache_init_viking`, `post_icache_ptag_write_read_test` +3 |  |
| 0x36 | `0x80000000` | 32 | w | `cache_flash_clear_all`, `cache_flashclear_do_flash`, `obp_cache_init_viking`, `post_icache_flush_test` +4 |  |
| 0x37 | `0x00000000` | 32 | w | `cache_flash_clear_all`, `dcache_flash_clear_both`, `dcache_flush_lock_check_loop`, `obp_cache_init_viking` +4 |  |
| 0x37 | `0x80000000` | 32 | w | `cache_flash_clear_all`, `dcache_flash_clear_both`, `obp_cache_init_viking`, `post_dcache_flush_test` +4 |  |
| 0x38 | `0x00000000` | 64 | r/w | `c_get_mid`, `fw_prom_cold_code`, `obp_prep`, `obp_start_caches` +4 |  |
| 0x38 | `0x00000100` | 64 | w | `reset_entry` |  |
| 0x38 | `0x00000200` | 64 | w | `reset_entry` |  |
| 0x38 | `0x00000300` | 64 | w | `reset_entry` |  |
| 0x39 | `0x00000000` | 32 | w | `post_dead_bist_check` |  |
| 0x39 | `0x00000100` | 32 | r | `post_dead_bist_check` |  |
| 0x4c | `0x00000000` | 32 | r/w | `obp_cache_init_snoop`, 6 Forth code words |  |

Spaces used with computed addresses only (all from the POST unless noted):

| ASI | Use |
|---|---|
| 0x02 | SuperSPARC MXCC registers / E-cache diag (or, without MXCC, control space) — `bcopy_ecc_modes`, `bcopy_ue_mode`, `cbread_parity_owned`, `ecache_data_line_march`, `ecache_data_march_down` +15 |
| 0x03 | MMU flush (sta) / probe (lda); va = VA[31:12] \| type << 8 — `lda_asi03`, `mmu_flush_va_type`, `mmu_flush_va_type_2`, `ptp_test_exit`, `ptp_test_pass` +1 |
| 0x04 | MMU registers — `lda_asi04`, `mmu_reg_walk_loop`, `mxcc_parity_disable`, `post_emc_smc_memory_timeout_tests`, `post_fpu_dp_data_store_trap_test` +5 |
| 0x05 | I-TLB diagnostic (SuperSPARC-II); entry << 12 \| SEL << 8 — `itlb_flush_fill_loop`, `lda_asi05`, `sta_asi05` |
| 0x06 | D-TLB / unified TLB diagnostic; entry << 12 \| SEL << 8 (HyperSPARC: entry << 4) — `dtlb_bitpat_loop`, `flush_entire_fill_loop`, `hs_flush_page_loop`, `hs_tlb_probe_a`, `hs_tlb_probe_b` +8 |
| 0x09 | supervisor instruction space = the PROM in boot mode (tables, strings) — `dtlb_bitpat_loop`, `find_first_dsimm`, `find_first_vsimm`, `hs_icache_data_cmp2`, `hs_icache_data_load2` +11 |
| 0x0c | I-cache tags: va bit 31 = physical tag (way, set), bit 30 = per-set tag (MRU/lock) — `cache_ptag_write`, `cache_stag_write`, `lda_asi0c`, `ldda_asi0c`, `obp_cache_init_viking` +4 |
| 0x0d | I-cache data: VA[28:26] way, [11:6] set, [5:3] doubleword — `hs_icache_data_cmp2`, `hs_icache_data_load2`, `ldda_asi0d`, `stda_asi0d` |
| 0x0e | D-cache tags: as ASI 0x0c (HyperSPARC: E-cache tags) — `cache_ptag_write`, `cache_stag_write`, `hs_ecflush_asi_loop`, `lda_asi0e`, `ldda_asi0e` +6 |
| 0x0f | D-cache data: VA[27:26] way, [11:5] set, [4:3] doubleword (HyperSPARC: E-cache data) — `hs_ecflush_asi_loop`, `lda_asi0f`, `ldda_asi0f`, `obp_cache_init`, `sta_asi0f` |
| 0x10 | flush page (I+D caches, and E-cache on Ross) — `hs_ecflush_asi_loop`, `hs_flush_page_iccr`, `hs_flush_page_iccr_alt`, `hs_icflush_page_iccr`, `hs_icflush_page_iccr_alt` +1 |
| 0x11 | flush segment — `hs_ecflush_asi_loop`, `hs_flush_seg_iccr`, `hs_flush_seg_iccr_alt`, `hs_icflush_seg_iccr`, `hs_icflush_seg_iccr_alt` +1 |
| 0x12 | flush region — `hs_ecflush_asi_loop`, `hs_flush_region_iccr`, `hs_flush_region_iccr_alt`, `hs_icflush_region_iccr`, `hs_icflush_region_iccr_alt` +1 |
| 0x13 | flush context — `hs_ecflush_asi_loop`, `hs_flush_ctx_iccr`, `hs_flush_ctx_iccr_alt`, `hs_icflush_ctx_iccr`, `hs_icflush_ctx_iccr_alt` +3 |
| 0x14 | flush user — `hs_ecflush_asi_loop`, `hs_flush_user_iccr`, `hs_flush_user_iccr_alt`, `hs_icflush_user_iccr`, `hs_icflush_user_iccr_alt` +2 |
| 0x17 | HyperSPARC block copy — `sta_asi17` |
| 0x18 | HyperSPARC I-cache flush page (stub never called) — `sta_asi18` |
| 0x19 | I-cache flush segment (stub never called) — `sta_asi19` |
| 0x1a | I-cache flush region (stub never called) — `sta_asi1a` |
| 0x1b | I-cache flush context (stub never called) — `sta_asi1b` |
| 0x1c | I-cache flush user (stub never called) — `sta_asi1c` |
| 0x1f | HyperSPARC block fill — `stda_asi1f` |
| 0x20 | bypass, pa[35:32] = 0 (memory) — `addr_pat_down_loop`, `addr_pat_up_loop`, `bcopy_check_dest_mem`, `bzero_check_mem`, `cbwrite_check_dest_mem` +59 |
| 0x2e | bypass, pa[35:32] = 0xe (SBus) — `lda_asi2e`, `lduba_asi2e`, `lduha_asi2e`, `post_dma2_macio_p_addr_reg_test`, `post_dma2_macio_p_bcnt_reg_test` +8 |
| 0x2f | bypass, pa[35:32] = 0xf (control space) — `bcopy_mask_irqs_exit`, `copy_ctl_space_to_ram`, `counter_timer_body`, `ebus_timeout_wait_l15`, `ecc_ce_loop` +74 |
| 0x30 | SuperSPARC store-buffer tags — `obp_cache_init_viking` |
| 0x31 | Ross: flush whole I-cache; SuperSPARC: store-buffer data — `sta_asi31` |
| 0x36 | I-cache flash clear (va 0: valid + MRU, va 0x80000000: lock bits) — `sta_asi36` |
| 0x37 | D-cache flash clear (same encoding) — `cache_flashclear_do_flash`, `sta_asi37` |
| 0x39 | SuperSPARC BIST / diag (dead code only) — `lda_asi39`, `sta_asi39` |
| 0x00, 0x01, 0x07, 0x08, 0x0a, 0x0b, 0x15, 0x16, 0x1d, 0x1e, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d | only through the generic `lda_by_asi` / `sta_by_asi` dispatchers (0x18a98 / 0x18e74: a compare chain with one `lda`/`sta` per ASI 0x00-0x30), used by the NTA/MATS march engines with the ASI chosen by the caller |

The Forth kernel's machine-code words (reached through the QEMU trace) add
generic alternate-space accessors (one `lda`/`sta` per ASI in jump tables, e.g.
at `0x52d10`, `0x52ff0`, `0x532e8`, `0x535e8`) covering ASIs
0x02, 0x03, 0x04, 0x10, 0x11, 0x12, 0x13, 0x14, 0x20, 0x2e, 0x2f, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x4b, 0x4c; the addresses there are
chosen by Forth code (see `forth-dictionary.txt`).

## 4. Devices easy to miss

Devices the machine code touches beyond the usual sun4m set (quick check, not
an audit):

- EMC/SMC memory controller, pa `0xf_0000_0000-0x1f` (reads return
  0xBADACCE5): used by the reset path (`rom-cold-code` delay register), the
  SIMM probe (VCR) and every ECC test.
- MSI M-to-S registers: AFSR/AFAR (`0xf_e000_1000/1004`), arbiter enable
  (`0xf_e000_1008`), slot configuration (`0xf_e000_1010-101c`), MID register
  (`0xf_e000_2000`). A MID register reading 0 makes every CPU identify as
  MID 8 (README §5, post-tests §11.2).
- IOMMU diagnostic windows (`0x100`, `0x200`) and comparator (`0x140/0x150`).
- MACIO ID register `0xe_f000_0000` and the parallel port `0xe_f480_0000`.
- VSIMM/MDI control space `0x0_9x00_0000` (probed by the SIMM probe and
  `rom-cold-code`; reads must not hang).
- CPU side: MXCC ASI 2 (with MB = 1 only the SuperSPARC-II
  banner path touches it), TLB diagnostic ASIs 5/6, cache diagnostic ASIs
  0x0c-0x0f and flash clear 0x36/0x37, store-buffer ASIs 0x30/0x32, ASI 0x38 as
  a data register, ACTION
  ASI 0x4c.

