// SPDX-License-Identifier: GPL-2.0-or-later
//
// ss20_machine: the SPARCstation 20, everything below the MiSTer glue
// (VERILOG-PLAN.md §2). The MiSTer top (SunSparcStation.sv) and the
// simulation's sim/sim_top.sv both wrap this module, so whatever the board
// runs is what the simulation runs.
//
// Phase 4 (in progress): one CPU module (MID 8) on ss20_memctl (main
// memory and the boot PROM in DDR3, ss20_loader filling it from hps_io),
// ss20_iobridge to the system devices of rtl/obio (both ESCCs, the M48T08,
// the counter/timers, the interrupt controller, the system registers), and
// ttya on the MiSTer's serial line through ss20_uart. Not yet: nvram_sd,
// the SBus devices (TCX, DMA2/ESP, LANCE), the keyboard and mouse, sound,
// the MSI/EMC registers; the screen still shows phase 0's test pattern.

// Clocks: clk is the machine (55 MHz on the board), clk_vid the pixel clock
// (65 MHz). They are unrelated; the simulation drives both from one clock.
//
// The DDR3 port is the single Avalon master the framework provides; the
// machine's own masters (memory controller, video scan-out, the Ethernet
// mailbox) will share it through rtl/mister/ddram_arb.sv inside this module.
// Addresses are 64-bit word addresses of the ARM's physical map (ARM
// physical / 8): the machine's memory is the FPGA window from 0x2000_0000
// (word 0x0400_0000, ss20_memctl.sv); the Ethernet mailbox is at
// 0x1FF0_0000 (word 0x03FE_0000).
//
// The hps_io side follows Main's support/sun (plan §1.2): ioctl index 0 is
// the boot PROM, index 64 the ID PROM seed; SD slots 0/1 the disks, 2 the
// CD, 3 the 8 KB NVRAM image; sd_blk_cnt is blocks - 1, up to 32 blocks.

module ss20_machine #(
  parameter int CLK_HZ     = 55_000_000,
  parameter bit SKIP_CLEAR = 1'b0,       // simulation: its DDR model starts zeroed
  parameter int NCPU       = 2,          // CPU modules, MID 8 up (1 to 4; two fit the Cyclone V)
  // the hang reporter (rtl/lib/hang_dump.sv) on CPU 0: a line "#HANGC ..."
  // on ttya when it stops committing for 0.6 s, "#HANGT ..." when it runs
  // 4.9 s without a trap once interrupts and user code have run. Off by
  // default: it costs ~2.8k ALMs (98 % full with it, HDMI +0.08 ns)
  parameter bit HANG_DUMP  = 1'b0
)(
  input  logic         clk,
  input  logic         rst,            // synchronous to clk
  input  logic         clk_vid,

  // options, from ss20_osd
  input  logic         opt_autoboot_i,
  input  logic         opt_serial_i,
  input  logic         opt_cg3_i,
  input  logic [7:0]   opt_kbd_layout_i,
  input  logic         opt_l2tlb_i,
  input  logic [9:0]   opt_ram_mb_i,
  input  logic         opt_eth_i,

  // DDR3 (Avalon-MM master, clocked by clk)
  input  logic         ddr_busy_i,
  output logic [7:0]   ddr_burstcnt_o,
  output logic [28:0]  ddr_addr_o,
  output logic         ddr_rd_o,
  output logic         ddr_we_o,
  output logic [63:0]  ddr_din_o,
  output logic [7:0]   ddr_be_o,
  input  logic [63:0]  ddr_dout_i,
  input  logic         ddr_dout_ready_i,

  // the SDRAM module: the TCX's VRAM (rtl/machine/vram_sdram.sv,
  // rtl/mister/sdram64.sv). SDRAM_CLK comes from the top (clk_sdram, the
  // 270-degree copy of clk, through a DDIO register).
  input  logic         clk_sdram,
  input  logic [1:0]   sdram_rd_mode_i, // the read capture point (sdram64: 0 on the board)
  inout  wire  [15:0]  sdram_dq,
  output logic [12:0]  sdram_a,
  output logic [1:0]   sdram_ba,
  output logic         sdram_dqml,
  output logic         sdram_dqmh,
  output logic         sdram_ncs,
  output logic         sdram_nras,
  output logic         sdram_ncas,
  output logic         sdram_nwe,
  output logic         sdram_cke,

  // hps_io: downloads (WIDE: 16-bit words, ioctl_addr counts bytes)
  input  logic         ioctl_download_i,
  input  logic [7:0]   ioctl_index_i,
  input  logic         ioctl_wr_i,
  input  logic [26:0]  ioctl_addr_i,
  input  logic [15:0]  ioctl_dout_i,
  output logic         ioctl_wait_o,

  // hps_io: SD block access, VDNUM = 4, 512-byte blocks, WIDE
  input  logic [3:0]   img_mounted_i,
  input  logic         img_readonly_i,
  input  logic [63:0]  img_size_i,
  output logic [31:0]  sd_lba_o [4],
  output logic [5:0]   sd_blk_cnt_o [4],
  output logic [3:0]   sd_rd_o,
  output logic [3:0]   sd_wr_o,
  input  logic [3:0]   sd_ack_i,
  input  logic [12:0]  sd_buff_addr_i,
  input  logic [15:0]  sd_buff_dout_i,
  output logic [15:0]  sd_buff_din_o [4],
  input  logic         sd_buff_wr_i,

  // hps_io: the RTC (BCD, MSM6242B layout; bit 64 toggles on each update)
  input  logic [64:0]  rtc_i,

  // ttya, to the HPS UART
  output logic         uart_txd_o,
  input  logic         uart_rxd_i,
  output logic         uart_rts_o,
  input  logic         uart_cts_i,
  output logic         uart_dtr_o,
  input  logic         uart_dsr_i,

  // keyboard and mouse, hps_io's event interface
  input  logic [10:0]  ps2_key_i,      // [7:0] code, [8] extended, [9] pressed, [10] toggles
  input  logic [24:0]  ps2_mouse_i,    // PS/2 packet bytes 0-2, [24] toggles
  output logic [2:0]   kbd_led_status_o,
  output logic [2:0]   kbd_led_use_o,

  // video, in the clk_vid domain
  output logic         vid_ce_o,
  output logic [7:0]   vid_r_o,
  output logic [7:0]   vid_g_o,
  output logic [7:0]   vid_b_o,
  output logic         vid_hs_o,
  output logic         vid_vs_o,
  output logic         vid_de_o,

  // audio, signed, in the clk domain
  output logic [15:0]  audio_l_o,
  output logic [15:0]  audio_r_o,

  output logic         led_disk_o,
  output logic         led_user_o
);

  import mem_pkg::*;
  import iobus_pkg::*;
  import sun4m_pkg::*;

  // ------------------------------------------------------------ loader --
  // The PROM download and the memory clear; the machine runs once a PROM
  // is in and the clear is done.
  logic        run, ld_active;
  logic [1:0]  ld_state;
  logic        ld_we;
  logic [7:0]  ld_bc, ld_be;
  logic [28:0] ld_addr;
  logic [63:0] ld_din;

  ss20_loader #(.SKIP_CLEAR(SKIP_CLEAR)) u_loader (
    .clk, .rst, .ram_mb_i(opt_ram_mb_i),
    .ioctl_download_i, .ioctl_index_i, .ioctl_wr_i, .ioctl_addr_i, .ioctl_dout_i, .ioctl_wait_o,
    .run_o(run), .active_o(ld_active), .state_o(ld_state),
    .ddr_wait_i(mm_wait), .ddr_burstcnt_o(ld_bc), .ddr_addr_o(ld_addr), .ddr_we_o(ld_we),
    .ddr_din_o(ld_din), .ddr_be_o(ld_be));

  // The machine's reset: the loader's, and a software reset (the system
  // control register) for a few cycles, which keeps memory
  logic       sw_reset;
  logic       nv_ready;                  // (nvram_sd, below)
  logic [3:0] swr_cnt;
  logic       rst_m, rst_swr;
  always_ff @(posedge clk) begin
    if (rst || !run) swr_cnt <= '0;
    else if (sw_reset) swr_cnt <= 4'd15;
    else if (swr_cnt != 4'd0) swr_cnt <= swr_cnt - 4'd1;
  end
  assign rst_swr = swr_cnt != 4'd0;
  assign rst_m   = rst || !run || rst_swr || !nv_ready;   // the NVRAM image loads first

  /* verilator lint_off PINCONNECTEMPTY */  // (the blocks' unused outputs, left open)

  // ------------------------------------------------------------ the CPUs --
  // NCPU modules, MID 8 + n; every write on the interconnect is snooped by
  // all of them (each holds the broadcast while its queue is nearly full)
  mem_req_t    bus_req [NCPU+1];          // the CPUs, then DVMA
  mem_rsp_t    bus_rsp [NCPU+1];
  snoop_t      snoop;
  logic [NCPU-1:0] snoop_holds, wd_resets, boot_modes;
  logic [NCPU-1:0][3:0] irl_v;
  logic        snoop_hold, wd_reset;
  logic [NCPU-1:0]       dbg_commit, dbg_trap;      // the hang reporter's view of each CPU
  logic [NCPU-1:0][7:0]  dbg_tt;
  logic [NCPU-1:0][31:0] dbg_pc, dbg_psr;
  logic [NCPU-1:0][5:0][31:0] dbg_w;

  genvar gc;
  generate for (gc = 0; gc < NCPU; gc = gc + 1) begin : g_cpu
    cpu_module #(.HAS_FPU(1'b1), .SS20(1'b1), .NCPU_M1(2'(NCPU - 1))) u_cpu (
      .clk, .rst(rst_m), .mid_i(4'(8 + gc)), .irl_i(irl_v[gc]), .cache_en_i(1'b1), .ram_mb_i({2'b00, opt_ram_mb_i}),
      .mem_req_o(bus_req[gc]), .mem_rsp_i(bus_rsp[gc]), .snoop_i(snoop), .snoop_hold_o(snoop_holds[gc]),
      .wd_reset_o(wd_resets[gc]), .si_reset_o(), .halt_o(), .boot_mode_o(boot_modes[gc]),
      .dbg_commit_o(dbg_commit[gc]), .dbg_trap_o(dbg_trap[gc]), .dbg_tt_o(dbg_tt[gc]),
      .dbg_pc_o(dbg_pc[gc]), .dbg_psr_o(dbg_psr[gc]), .dbg_w_o(dbg_w[gc]));
  end endgenerate
  assign snoop_hold = |snoop_holds;
  assign wd_reset   = |wd_resets;

  // ---------------------------------------------------- memory and I/O --
  mem_req_t    io_req;
  mem_rsp_t    io_rsp;
  logic        mem_acc;               // memctl -> emc: the ECC model
  logic [3:0]      ecc_fix_v;
  logic [3:0][5:0] ecc_fix_bit;
  logic        mc_rd, mc_we;
  logic [7:0]  mc_bc, mc_be;
  logic [28:0] mc_addr;
  logic [63:0] mc_din;

  // the interconnect: the CPUs and the MSI's DVMA (ss20_msi, below) share
  // the memory controller; the MSI's arbiter-enable register parks CPUs
  // 9 and up (its bits 3:1)
  mem_req_t    dma_req, mb_req;
  mem_rsp_t    dma_rsp, mb_rsp;
  logic [3:0]  mb_mid;
  logic [31:0] arb_en;
  logic [NCPU-1:0] park;
  always_comb begin
    park = '0;
    for (int n = 1; n < NCPU; n++) park[n] = !arb_en[n];
  end
  assign bus_req[NCPU] = dma_req;
  assign dma_rsp = bus_rsp[NCPU];
  ss20_mbus #(.NCPU(NCPU)) u_mbus (
    .clk, .rst(rst_m), .req_i(bus_req), .rsp_o(bus_rsp), .park_i(park),
    .req_o(mb_req), .rsp_i(mb_rsp), .mid_o(mb_mid));

  // the granted master's boot mode (DVMA, MID 0: never), for the PROM's
  // boot-mode timing in the memory controller
  logic mb_boot;
  always_comb begin
    mb_boot = 1'b0;
    for (int n = 0; n < NCPU; n++)
      if (mb_mid == 4'(8 + n)) mb_boot = boot_modes[n];
  end

  ss20_memctl #(.PROM_WAIT(CLK_HZ / 1_500_000)) u_mem (   // 36 at 55 MHz: ~0.65 us
    .clk, .rst(rst_m), .ram_mb_i(opt_ram_mb_i), .mid_i(mb_mid), .boot_mode_i(mb_boot),
    .req_i(mb_req), .rsp_o(mb_rsp), .snoop_o(snoop), .snoop_hold_i(snoop_hold),
    .io_req_o(io_req), .io_rsp_i(io_rsp),
    .ddr_wait_i(mm_wait), .ddr_burstcnt_o(mc_bc), .ddr_addr_o(mc_addr), .ddr_rd_o(mc_rd),
    .ddr_we_o(mc_we), .ddr_din_o(mc_din), .ddr_be_o(mc_be),
    .ddr_dout_i(mm_dout), .ddr_dout_ready_i(mm_rdv), .ram_acc_o(mem_acc), .fix_v_i(ecc_fix_v), .fix_bit_i(ecc_fix_bit), .state_o());

  // DDR3, through one rtl/mister/ddram_arb: the memory controller (or the
  // loader while it works: the machine is in reset then) first, then the
  // Ethernet mailbox. The TCX's VRAM and scan-out are on the SDRAM
  // (below).
  logic        mm_rd, mm_we, mm_wait, mm_rdv;
  logic [7:0]  mm_bc, mm_be;
  logic [28:0] mm_addr;
  logic [63:0] mm_din, mm_dout;
  always_comb begin
    if (ld_active) begin
      mm_bc = ld_bc; mm_addr = ld_addr; mm_rd = 1'b0; mm_we = ld_we; mm_din = ld_din; mm_be = ld_be;
    end else begin
      mm_bc = mc_bc; mm_addr = mc_addr; mm_rd = mc_rd; mm_we = mc_we; mm_din = mc_din; mm_be = mc_be;
    end
  end

  logic        sc_rd, sc_wait, sc_rdv;
  logic [7:0]  sc_bc;
  logic [28:0] sc_addr;
  logic [63:0] sc_dout;
  logic        vr_rd, vr_we, vr_wait, vr_rdv;
  logic [7:0]  vr_bc, vr_be;
  logic [28:0] vr_addr;
  logic [63:0] vr_din, vr_dout;
  logic        dv_rd, dv_we, dv_wait, dv_rdv;   // the Ethernet mailbox
  logic [7:0]  dv_bc, dv_be;
  logic [28:0] dv_addr;
  logic [63:0] dv_din, dv_dout;
  logic        et_rd, et_we, et_wait, et_rdv;
  logic [7:0]  et_bc, et_be;
  logic [28:0] et_addr;
  logic [63:0] et_din, et_dout;
  logic        lo_rd, lo_we, lo_wait, lo_rdv;
  logic [7:0]  lo_bc, lo_be;
  logic [28:0] lo_addr;
  logic [63:0] lo_din, lo_dout;

  assign ddr_burstcnt_o = lo_bc;
  assign ddr_addr_o     = lo_addr;
  assign ddr_rd_o       = lo_rd;
  assign ddr_we_o       = lo_we;
  assign ddr_din_o      = lo_din;
  assign ddr_be_o       = lo_be;
  assign lo_wait        = ddr_busy_i;
  assign lo_dout        = ddr_dout_i;
  assign lo_rdv         = ddr_dout_ready_i;

  ddram_arb u_arb_lo (
    .clk, .reset(rst),
    .m0_waitrequest(mm_wait), .m0_burstcount(mm_bc), .m0_address(mm_addr), .m0_read(mm_rd), .m0_write(mm_we),
    .m0_writedata(mm_din), .m0_byteenable(mm_be), .m0_readdata(mm_dout), .m0_readdatavalid(mm_rdv),
    .m1_waitrequest(dv_wait), .m1_burstcount(dv_bc), .m1_address(dv_addr), .m1_read(dv_rd), .m1_write(dv_we),
    .m1_writedata(dv_din), .m1_byteenable(dv_be), .m1_readdata(dv_dout), .m1_readdatavalid(dv_rdv),
    .s_waitrequest(lo_wait), .s_burstcount(lo_bc), .s_address(lo_addr), .s_read(lo_rd),
    .s_write(lo_we), .s_writedata(lo_din), .s_byteenable(lo_be), .s_readdata(lo_dout),
    .s_readdatavalid(lo_rdv));

  assign dv_bc = et_bc; assign dv_addr = et_addr; assign dv_rd = et_rd; assign dv_we = et_we;
  assign dv_din = et_din; assign dv_be = et_be;
  assign et_wait = dv_wait; assign et_dout = dv_dout; assign et_rdv = dv_rdv;

  // The TCX's VRAM on the SDRAM: the scan-out first, then the VRAM master
  logic        sd_req, sd_we, sd_line, sd_ack, sd_wready, sd_rvalid, sd_ready;
  logic [26:0] sd_addr;
  logic [7:0]  sd_be;
  logic [63:0] sd_wdata, sd_rdata;
  logic [1:0]  sd_rbeat;
  vram_sdram u_vsd (
    .clk, .rst,
    .s_address(sc_addr), .s_burstcount(sc_bc), .s_read(sc_rd), .s_waitrequest(sc_wait),
    .s_readdata(sc_dout), .s_readdatavalid(sc_rdv),
    .v_address(vr_addr), .v_read(vr_rd), .v_write(vr_we), .v_writedata(vr_din), .v_byteenable(vr_be),
    .v_waitrequest(vr_wait), .v_readdata(vr_dout), .v_readdatavalid(vr_rdv),
    .ram_req(sd_req), .ram_we(sd_we), .ram_line(sd_line), .ram_addr(sd_addr), .ram_be(sd_be),
    .ram_wdata(sd_wdata), .ram_ack(sd_ack), .ram_wready(sd_wready), .ram_rvalid(sd_rvalid),
    .ram_rdata(sd_rdata));
  sdram64 #(.CLK_HZ(CLK_HZ)) u_sdram (
    .clk, .clk_sdram, .rst, .rd_mode(sdram_rd_mode_i), .ready(sd_ready),
    .ram_req(sd_req), .ram_we(sd_we), .ram_line(sd_line), .ram_addr(sd_addr), .ram_be(sd_be),
    .ram_wdata(sd_wdata), .ram_ack(sd_ack), .ram_wready(sd_wready), .ram_rvalid(sd_rvalid),
    .ram_rbeat(sd_rbeat), .ram_rdata(sd_rdata),
    .SDRAM_DQ(sdram_dq), .SDRAM_A(sdram_a), .SDRAM_BA(sdram_ba), .SDRAM_DQML(sdram_dqml),
    .SDRAM_DQMH(sdram_dqmh), .SDRAM_nCS(sdram_ncs), .SDRAM_nRAS(sdram_nras), .SDRAM_nCAS(sdram_ncas),
    .SDRAM_nWE(sdram_nwe), .SDRAM_CKE(sdram_cke));

  iob_req_t    iob_q [13];
  iob_rsp_t    iob_r [13];
  logic        mts_err, mts_to;
  logic [35:0] mts_pa;
  logic [2:0]  mts_siz;
  ss20_iobridge u_io (.clk, .rst(rst_m), .req_i(io_req), .rsp_o(io_rsp), .io_o(iob_q), .io_i(iob_r),
    .mts_err_o(mts_err), .mts_to_o(mts_to), .mts_pa_o(mts_pa), .mts_siz_o(mts_siz));

  // ------------------------------------------------- the system devices --
  // interrupt sources and strobes of the devices below
  logic irq_tcx, irq_aud, irq_msi, irq_esp, irq_le, irq_fdc, irq_mem, fd_tc;
  // 0: keyboard (A) / mouse (B) ESCC, with the Sun keyboard and mouse
  // made from hps_io's PS/2 events
  logic irq_kbd, irq_ser;
  logic [7:0] kb_tx, kb_rx, ms_rx;
  logic       kb_tx_v, kb_rx_v, kb_rx_rdy, ms_rx_v, ms_rx_rdy;
  logic [3:0] kb_leds;
  logic       kb_bell, kb_click;
  logic [15:0] beep;
  escc #(.CLK_HZ(CLK_HZ)) u_escc_kbd (
    .clk, .rst(rst_m), .bus_i(iob_q[0]), .bus_o(iob_r[0]),
    .txd_a_o(), .rxd_a_i(1'b1), .dcd_a_i(1'b1), .cts_a_i(1'b1), .rts_a_o(), .dtr_a_o(),
    .txd_b_o(), .rxd_b_i(1'b1), .dcd_b_i(1'b1), .cts_b_i(1'b1), .rts_b_o(), .dtr_b_o(),
    .tx_byte_a_o(kb_tx), .tx_byte_valid_a_o(kb_tx_v),
    .rx_byte_a_i(kb_rx), .rx_byte_valid_a_i(kb_rx_v && kb_rx_rdy), .rx_byte_ready_a_o(kb_rx_rdy),
    .tx_byte_b_o(), .tx_byte_valid_b_o(),
    .rx_byte_b_i(ms_rx), .rx_byte_valid_b_i(ms_rx_v && ms_rx_rdy), .rx_byte_ready_b_o(ms_rx_rdy),
    .irq_o(irq_kbd));

  sun_kbd #(.CLK_HZ(CLK_HZ)) u_kbd (
    .clk, .rst(rst_m), .ps2_key_i, .layout_i(opt_kbd_layout_i),
    .tx_byte_i(kb_tx), .tx_byte_valid_i(kb_tx_v),
    .rx_byte_o(kb_rx), .rx_byte_valid_o(kb_rx_v), .rx_byte_ready_i(kb_rx_rdy),
    .bell_o(kb_bell), .click_o(kb_click), .leds_o(kb_leds), .any_key_o());

  kbd_beep #(.CLK_HZ(CLK_HZ)) u_beep (.clk, .rst(rst_m), .bell_i(kb_bell), .click_i(kb_click), .audio_o(beep));

  sun_mouse #(.CLK_HZ(CLK_HZ)) u_mouse (
    .clk, .rst(rst_m), .ps2_mouse_i,
    .rx_byte_o(ms_rx), .rx_byte_valid_o(ms_rx_v), .rx_byte_ready_i(ms_rx_rdy));

  // 1: ttya (A, on the MiSTer's serial line) and ttyb (B, unconnected)
  logic [7:0] ta_tx, ta_rx;
  logic       ta_tx_v, ta_rx_v, ta_rx_rdy, ta_brk;
  escc #(.CLK_HZ(CLK_HZ)) u_escc_ser (
    .clk, .rst(rst_m), .bus_i(iob_q[1]), .bus_o(iob_r[1]),
    .txd_a_o(), .rxd_a_i(!ta_brk), .dcd_a_i(1'b1), .cts_a_i(1'b1), .rts_a_o(), .dtr_a_o(),
    .txd_b_o(), .rxd_b_i(1'b1), .dcd_b_i(1'b1), .cts_b_i(1'b1), .rts_b_o(), .dtr_b_o(),
    .tx_byte_a_o(ta_tx), .tx_byte_valid_a_o(ta_tx_v),
    .rx_byte_a_i(ta_rx), .rx_byte_valid_a_i(ta_rx_v && ta_rx_rdy), .rx_byte_ready_a_o(ta_rx_rdy),
    .tx_byte_b_o(), .tx_byte_valid_b_o(), .rx_byte_b_i(8'd0), .rx_byte_valid_b_i(1'b0), .rx_byte_ready_b_o(),
    .irq_o(irq_ser));

  ss20_uart #(.CLK_HZ(CLK_HZ)) u_uart (
    .clk, .rst,
    .tx_byte_i(ta_tx), .tx_valid_i(ta_tx_v), .txd_o(con_txd),
    .rxd_i(uart_rxd_i), .rx_byte_o(ta_rx), .rx_valid_o(ta_rx_v), .rx_ready_i(ta_rx_rdy), .brk_o(ta_brk));
  // the hang reporter's line replaces ttya's while it prints
  logic con_txd, hd_txd, hd_act;
  logic [31:0] hd_x;
  always_comb begin
    hd_x = '0;
    hd_x[31:28] = irl_v[0];
    for (int k = 0; k <= NCPU && k < 5; k++) begin
      hd_x[23 + k] = bus_req[k].valid;
      hd_x[18 + k] = bus_rsp[k].ack;
    end
    hd_x[17] = snoop_hold;
    hd_x[16] = wd_reset;
    hd_x[15] = io_req.valid;
    hd_x[14] = io_rsp.ack;
    hd_x[13] = ld_active;
  end
  generate if (HANG_DUMP) begin : g_hang
    hang_dump #(.DIV(CLK_HZ / 115_200), .CBITS(CLK_HZ > 40_000_000 ? 25 : 24),
                .TBITS(CLK_HZ > 40_000_000 ? 28 : 27)) u_hang (
      .clk, .rst(rst_m), .commit_i(dbg_commit[0]), .trap_i(dbg_trap[0]), .tt_i(dbg_tt[0]),
      .pc_i(dbg_pc[0]), .psr_i(dbg_psr[0]), .w_i(dbg_w[0]), .x_i(hd_x),
      .txd_o(hd_txd), .act_o(hd_act));
  end else begin : g_nohang
    assign hd_txd = 1'b1;
    assign hd_act = 1'b0;
  end endgenerate
  assign uart_txd_o = hd_act ? hd_txd : con_txd;
  assign uart_rts_o = 1'b0;
  assign uart_dtr_o = 1'b0;

  // 2: the M48T08, its clock seeded from the MiSTer's RTC (BCD) at the
  // first update, its 8 KB kept in the image on SD slot 3 by nvram_sd
  // (which also stamps the ID PROM from ioctl index 64's serial)
  logic rtc_t, rtc_seen;
  always_ff @(posedge clk) begin
    rtc_t <= rtc_i[64];
    if (rst) rtc_seen <= 1'b0;
    else if (rtc_t != rtc_i[64]) rtc_seen <= 1'b1;
  end

  logic [23:0] seed;
  logic        seed_ok, seed_dl;
  always_ff @(posedge clk) begin
    seed_dl <= ioctl_download_i && ioctl_index_i == 8'd64;
    if (ioctl_download_i && ioctl_index_i == 8'd64 && ioctl_wr_i) begin
      if (ioctl_addr_i == 27'd4) seed[23:16] <= ioctl_dout_i[15:8];          // byte 5
      if (ioctl_addr_i == 27'd6) seed[15:0]  <= {ioctl_dout_i[7:0], ioctl_dout_i[15:8]};
      if (ioctl_addr_i == 27'd6) seed_ok <= 1'b1;
    end
  end
  initial seed_ok = 1'b0;

  logic        nv_we;
  logic [10:0] nv_addr;
  logic [3:0]  nv_be;
  logic [31:0] nv_wdata, nv_rdata;
  logic [31:0] nv_lba;
  logic [5:0]  nv_cnt;
  logic        nv_rd, nv_wr;
  logic [15:0] nv_din;
  nvram_sd #(.CLK_HZ(CLK_HZ), .SIMU(SKIP_CLEAR)) u_nvsd (
    .clk, .por(1'b0),
    .img_mounted(img_mounted_i[3]), .img_readonly(img_readonly_i), .img_size(img_size_i),
    .sd_lba(nv_lba), .sd_blk_cnt(nv_cnt), .sd_rd(nv_rd), .sd_wr(nv_wr), .sd_ack(sd_ack_i[3]),
    .sd_buff_addr(sd_buff_addr_i), .sd_buff_dout(sd_buff_dout_i), .sd_buff_din(nv_din), .sd_buff_wr(sd_buff_wr_i),
    .seed, .seed_ok(seed_ok && !seed_dl),
    .nv_we, .nv_addr, .nv_be, .nv_wdata, .nv_rdata,
    .nv_bus_req(iob_q[2]), .nv_bus_rsp(iob_r[2]),
    .ready(nv_ready));

  m48t08 #(.CLK_HZ(CLK_HZ)) u_nvram (
    .clk, .rst(rst_m), .bus_i(iob_q[2]), .bus_o(iob_r[2]),
    .img_we(nv_we), .img_addr(nv_addr), .img_be(nv_be), .img_wdata(nv_wdata), .img_rdata(nv_rdata),
    .seed_valid(rtc_seen && rtc_t != rtc_i[64]),
    .seed_sec(rtc_i[7:0]), .seed_min(rtc_i[15:8]), .seed_hour(rtc_i[23:16]), .seed_day(rtc_i[55:48]),
    .seed_date(rtc_i[31:24]), .seed_month(rtc_i[39:32]), .seed_year(rtc_i[47:40]));

  // 3: the counter/timers, 4: the interrupt controller
  logic irq_tsys;
  logic [NCPU-1:0] irq_tcpu;
  slavio_timer #(.NCPU(NCPU), .CLK_HZ(CLK_HZ)) u_timer (
    .clk, .rst(rst_m), .swr_i(rst_swr), .bus_i(iob_q[3]), .bus_o(iob_r[3]), .irq_sys(irq_tsys), .irq_cpu(irq_tcpu));

  logic [31:0] isrc;
  always_comb begin
    isrc = '0;
    isrc[SI_K] = irq_kbd;
    isrc[SI_S] = irq_ser;
    isrc[SI_T] = irq_tsys;
    isrc[SI_SBUS_LSB + 4] = irq_tcx | irq_aud;   // SBus level 5 (intr 0x39: the TCX, the audio card)
    isrc[SI_I] = irq_msi;
    isrc[SI_SC] = irq_esp;
    isrc[SI_E] = irq_le;
    isrc[SI_FL] = irq_fdc;
    isrc[SI_M] = irq_mem;
  end
  slavio_intctl #(.NCPU(NCPU)) u_intctl (
    .clk, .rst(rst_m), .bus_i(iob_q[4]), .bus_o(iob_r[4]), .src_i(isrc), .timer_cpu_i(irq_tcpu), .irl_o(irl_v));

  // 5: the system registers (LEDs, AUXIO, power, system control/status);
  // reset by a software reset too, which sets SWR_STAT (OBP 2.25 tells its
  // own soft reset from a power-on by it)
  logic [15:0] leds;
  logic        aux_led;
  slavio_misc #(.CLK_HZ(CLK_HZ)) u_misc (
    .clk, .rst(rst || !run || rst_swr), .rst_swr_i(rst_swr), .rst_switch_i(1'b0), .wd_i(wd_reset),
    .bus_i(iob_q[5]), .bus_o(iob_r[5]),
    .leds_o(leds), .led_o(aux_led), .fd_tc_o(fd_tc), .fd_density_i(1'b0), .power_off_o(),
    .pwr_fail_i(1'b0), .pwr_irq_o(), .diag_sw_i(1'b0),
    .cfg_cg3_i(opt_cg3_i), .cfg_noautoboot_i(!opt_autoboot_i), .cfg_serial_i(opt_serial_i),
    .cfg_ram_mb_i(opt_ram_mb_i), .sw_reset_o(sw_reset));

  // 6: SBus slot F, the on-board SBus devices, by PA[23:20]: 0 the MACIO
  // ID register, 4 DMA2 (ESP and LANCE channels), 8 the ESP, C the LANCE;
  // PA[27:20] = 0x48 is the parallel port (SUNW,bpp: DMA2's P registers,
  // at its +0x20); the rest reads 0
  iob_req_t f_q [4];
  iob_rsp_t f_r [4];
  logic [1:0] f_sel;
  logic       f_any;
  logic       le_bad, le_bad_r;          // (below)
  logic f_pp;
  assign f_pp = iob_q[6].addr[27:20] == 8'h48;
  always_comb begin
    f_any = 1'b1;
    case (f_pp ? 4'h4 : iob_q[6].addr[23:20])
      4'h4:    f_sel = 2'd1;
      4'h8:    f_sel = 2'd2;
      4'hC:    f_sel = 2'd3;
      default: begin f_sel = 2'd0; f_any = iob_q[6].addr[23:20] == 4'h0; end
    endcase
    for (int k = 0; k < 4; k++) begin
      f_q[k] = iob_q[6];
      f_q[k].req = iob_q[6].req && f_sel == 2'(k) && !(k == 3 && le_bad);
    end
    if (f_pp) f_q[1].addr[5] = 1'b1;     // DMA2's P registers
    iob_r[6] = le_bad_r ? {1'b0, 1'b1, 32'd0} : f_r[f_sel];   // (ack, err, rdata)
  end

  // a byte write to the LANCE's 16-bit ports is a size error: dropped,
  // an error ack (posted: the MSI's AFSR), E_CSR's SLAVE_ERR (OBP 2.25's
  // POST "LANCE Address/Data Port Tests")
  assign le_bad = iob_q[6].req && iob_q[6].we && iob_q[6].addr[23:20] == 4'hC &&
                  (iob_q[6].be == 4'b1000 || iob_q[6].be == 4'b0100 ||
                   iob_q[6].be == 4'b0010 || iob_q[6].be == 4'b0001);
  always_ff @(posedge clk) le_bad_r <= le_bad && !le_bad_r && !rst_m;

  // the MACIO ID register (the rest of page 0 reads it too)
  always_ff @(posedge clk) begin
    f_r[0] <= '0;
    f_r[0].ack <= f_q[0].req && !f_r[0].ack;
    f_r[0].rdata <= f_any ? 32'hFE81_0103 : 32'h0;
  end

  sbus_pkg::dvma_req_t le_mem;
  mem_rsp_t            le_mem_r;
  logic esp_irq, esp_dreq, esp_dtomem, esp_dack, esp_crst, le_irq, le_rst;
  logic [7:0] esp_d2m, esp_m2d;
  dma2 u_dma2 (
    .clk, .rst(rst_m), .bus_i(f_q[1]), .bus_o(f_r[1]),
    .esp_irq_i(esp_irq), .esp_dreq_i(esp_dreq), .esp_dtomem_i(esp_dtomem), .esp_ddata_i(esp_d2m),
    .esp_dack_o(esp_dack), .esp_ddata_o(esp_m2d), .esp_rst_o(esp_crst), .irq_esp_o(irq_esp),
    .esp_dvma_o(dvma_q[0]), .esp_dvma_i(dvma_r[0]),
    .le_req_i(le_mem), .le_rsp_o(le_mem_r), .le_dvma_o(dvma_q[1]), .le_dvma_i(dvma_r[1]),
    .le_irq_i(le_irq), .le_size_err_i(le_bad_r), .irq_le_o(irq_le), .le_rst_o(le_rst));

  // the SCSI targets on hps_io's SD slots 0-2: disks at IDs 3 and 1, the CD at 6
  logic [31:0] esp_lba;
  logic [5:0]  esp_cnt;
  logic [2:0]  esp_rd, esp_wr;
  logic [15:0] esp_din, cd_l, cd_r;
  logic        esp_busy;
  esp #(.CLK_HZ(CLK_HZ), .SIMU(SKIP_CLEAR)) u_esp (
    .clk, .rst(rst_m), .chip_rst_i(esp_crst), .bus_i(f_q[2]), .bus_o(f_r[2]), .irq_o(esp_irq),
    .dreq_o(esp_dreq), .dtomem_o(esp_dtomem), .ddata_o(esp_d2m), .dack_i(esp_dack), .ddata_i(esp_m2d),
    .id0_i(3'd3), .id1_i(3'd1), .id2_i(3'd6), .ena_i(3'b111), .cd2048_i(1'b0),
    .img_mounted_i(img_mounted_i[2:0]), .img_size_i, .img_readonly_i,
    .sd_lba_o(esp_lba), .sd_blk_cnt_o(esp_cnt), .sd_rd_o(esp_rd), .sd_wr_o(esp_wr), .sd_ack_i(sd_ack_i[2:0]),
    .sd_buff_addr_i, .sd_buff_dout_i, .sd_buff_din_o(esp_din), .sd_buff_wr_i({3{sd_buff_wr_i}} & sd_ack_i[2:0]),
    .busy_o(esp_busy), .cd_l_o(cd_l), .cd_r_o(cd_r));

  // the LANCE, its frames through eth_hps's mailbox in DDR3
  lance #(.CLK_HZ(CLK_HZ), .SIMU(SKIP_CLEAR)) u_lance (
    .clk, .rst(rst_m), .bus_i(f_q[3]), .bus_o(f_r[3]), .le_reset(le_rst), .irq_o(le_irq),
    .mem_o(le_mem), .mem_i(le_mem_r), .ena(opt_eth_i),
    .avl_waitrequest(et_wait), .avl_address(et_addr), .avl_read(et_rd), .avl_write(et_we),
    .avl_writedata(et_din), .avl_byteenable(et_be), .avl_burstcount(et_bc),
    .avl_readdata(et_dout), .avl_readdatavalid(et_rdv));

  // 7: slot 2, the TCX
  tcx u_tcx (
    .clk, .rst(rst_m), .bus_i(iob_q[7]), .bus_o(iob_r[7]), .irq_o(irq_tcx),
    .vram_address(vr_addr), .vram_burstcount(vr_bc), .vram_read(vr_rd), .vram_write(vr_we),
    .vram_writedata(vr_din), .vram_byteenable(vr_be), .vram_waitrequest(vr_wait),
    .vram_readdata(vr_dout), .vram_readdatavalid(vr_rdv),
    .scan_address(sc_addr), .scan_burstcount(sc_bc), .scan_read(sc_rd), .scan_waitrequest(sc_wait),
    .scan_readdata(sc_dout), .scan_readdatavalid(sc_rdv),
    .clk_vid, .vid_ce_o, .vid_r_o, .vid_g_o, .vid_b_o, .vid_hs_o, .vid_vs_o, .vid_de_o);

  // 10: slot 3, the audio card (CS4231 + APC, its FCode PROM): the
  // OpenBIOS in bios/ always declares it
  logic [15:0] aud_l, aud_r;
  cs4231 #(.CLK_HZ(CLK_HZ)) u_audio (
    .clk, .rst(rst_m), .bus_i(iob_q[10]), .bus_o(iob_r[10]), .dvma_o(dvma_q[2]), .dvma_i(dvma_r[2]),
    .irq_o(irq_aud), .audio_l_o(aud_l), .audio_r_o(aud_r));

  // 9: the floppy controller, with no drive
  fdc82077 u_fdc (.clk, .rst(rst_m), .bus_i(iob_q[9]), .bus_o(iob_r[9]), .tc_i(fd_tc), .irq_o(irq_fdc));

  // 8: the MSI: the IOMMU translating the SBus masters' DVMA, the M-to-S
  // registers, the MID register
  sbus_pkg::dvma_req_t [2:0] dvma_q;      // 0 DMA2's ESP channel, 1 its LANCE channel, 2 the APC
  mem_rsp_t        [2:0] dvma_r;
  ss20_msi u_msi (
    .clk, .rst(rst_m), .bus_i(iob_q[8]), .bus_o(iob_r[8]), .bus_mid_i(mb_mid),
    .dvma_req_i(dvma_q), .dvma_rsp_o(dvma_r), .mem_req_o(dma_req), .mem_rsp_i(dma_rsp),
    .mts_err_i(mts_err), .mts_err_to_i(mts_to), .mts_err_pa_i(mts_pa), .mts_err_siz_i(mts_siz),
    .mts_err_s_i(1'b1), .mts_err_mid_i(mb_mid), .irq_err_o(irq_msi), .arb_en_o(arb_en));

  // 12: slot E, where a real SS20 has its DBRI: only the FCode image that
  // names the node OBP 2.25's slot-e stub makes (DEC-4)
  slote_fcode u_slote (.clk, .rst(rst_m), .bus_i(iob_q[12]), .bus_o(iob_r[12]));

  // 11: the memory controller's registers (the SMC at 0xF_0000_0000),
  // watching main-memory accesses for the ECC errors firmware injects
  emc u_emc (.clk, .rst(rst_m), .bus_i(iob_q[11]), .bus_o(iob_r[11]),
    .mem_v_i(mem_acc), .mem_req_i(mb_req), .mem_mid_i(mb_mid),
    .fix_v_o(ecc_fix_v), .fix_bit_o(ecc_fix_bit), .irq_o(irq_mem));

  /* verilator lint_on PINCONNECTEMPTY */

  // ------------------------------------------------------- idle for now --
  always_comb begin
    for (int n = 0; n < 3; n++) begin
      sd_lba_o[n]      = esp_lba;
      sd_blk_cnt_o[n]  = esp_cnt;
      sd_buff_din_o[n] = esp_din;
    end
    sd_lba_o[3]      = nv_lba;
    sd_blk_cnt_o[3]  = nv_cnt;
    sd_buff_din_o[3] = nv_din;
  end
  assign sd_rd_o          = {nv_rd, esp_rd};
  assign sd_wr_o          = {nv_wr, esp_wr};
  assign kbd_led_status_o = {kb_leds[3], kb_leds[0], kb_leds[2]};   // Caps, Num, Scroll
  assign kbd_led_use_o    = 3'b111;
  // the CS4231 and CD audio at half level each, plus the keyboard's beeper
  // (small), saturated
  function automatic logic [15:0] mix3(input logic [15:0] x, input logic [15:0] y, input logic [15:0] z);
    logic signed [17:0] m;
    m = (($signed({x[15], x[15], x}) + $signed({y[15], y[15], y})) >>> 1) + $signed({z[15], z[15], z});
    if (m > 18'sd32767)  return 16'h7FFF;
    if (m < -18'sd32768) return 16'h8000;
    return m[15:0];
  endfunction
  assign audio_l_o        = mix3(aud_l, cd_l, beep);
  assign audio_r_o        = mix3(aud_r, cd_r, beep);
  assign led_disk_o       = esp_busy;
  assign led_user_o       = !aux_led;   // the Aux register's LED bit (0 = lit), as the board's LED

  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_inputs = ^{opt_l2tlb_i, uart_cts_i, uart_dsr_i,
                         leds, rtc_i[63:56], ld_state, kb_leds[1], arb_en,
                         dbg_commit, dbg_trap, dbg_tt, dbg_pc, dbg_psr, dbg_w, hd_x,  // (CPU 0's only, with HANG_DUMP)
                         vr_bc, sd_rbeat, sd_ready};   // (the VRAM master's bursts are 1; lines are aligned)
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
