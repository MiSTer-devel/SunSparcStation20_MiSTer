// SPDX-License-Identifier: GPL-2.0-or-later
//
// sim_top: the machine as the Verilator harness (sim_main.cpp) sees it.
//
// rtl/machine/ss20_machine with the MiSTer side flattened to plain ports:
// the DDR3 Avalon port, the hps_io download and SD-block interfaces, the
// RTC, ttya and the video signals. The OSD status word goes through the
// same decoder as on the board (ss20_osd), so the harness sets options the
// way a user does. sim_main.cpp models everything beyond these ports.
//
// One clock: the machine's clock and the pixel clock are the same here, so
// a frame takes 1344 x 806 cycles.

module sim_top #(parameter int NCPU = 2)
(
	input         clk,
	input         reset,

	// DDR3, 64-bit words in the FPGA's window
	input         ddr_busy,
	output  [7:0] ddr_burstcnt,
	output [28:0] ddr_addr,
	output        ddr_rd,
	output        ddr_we,
	output [63:0] ddr_din,
	output  [7:0] ddr_be,
	input  [63:0] ddr_dout,
	input         ddr_dout_ready,

	// hps_io: downloads
	input         ioctl_download,
	input   [7:0] ioctl_index,
	input         ioctl_wr,
	input  [24:0] ioctl_addr,
	input  [15:0] ioctl_dout,
	output        ioctl_wait,

	// hps_io: SD blocks, slots 0/1 disks, 2 CD, 3 NVRAM
	input   [3:0] img_mounted,
	input         img_readonly,
	input  [63:0] img_size,
	output [31:0] sd_lba0,
	output [31:0] sd_lba1,
	output [31:0] sd_lba2,
	output [31:0] sd_lba3,
	output  [3:0] sd_rd,
	output  [3:0] sd_wr,
	input   [3:0] sd_ack,
	output  [5:0] sd_blk_cnt,      // the disks' (slots 0-2 share it; slot 3 is one block)
	input  [12:0] sd_buff_addr,
	input  [15:0] sd_buff_dout,
	output [15:0] sd_buff_din0,
	output [15:0] sd_buff_din1,
	output [15:0] sd_buff_din2,
	output [15:0] sd_buff_din3,
	input         sd_buff_wr,

	input  [64:0] rtc,

	// ttya
	output        uart_txd,
	input         uart_rxd,

	// the OSD status word (status[127:0] of hps_io)
	input [127:0] status,

	// video
	output  [7:0] vga_r,
	output  [7:0] vga_g,
	output  [7:0] vga_b,
	output        vga_hs,
	output        vga_vs,
	output        vga_de,

	output        led_disk,
	output        led_user
);

wire       opt_autoboot, opt_serial, opt_cg3, opt_l2tlb, opt_eth;
wire [7:0] opt_kbd_layout;
wire [9:0] opt_ram_mb;

// The video options and the pending flag have no use here.
/* verilator lint_off UNUSEDSIGNAL */
wire        osd_pending;
wire  [1:0] osd_ar;
wire  [2:0] osd_scale;
wire [10:0] osd_ps2_key;
/* verilator lint_on UNUSEDSIGNAL */

ss20_osd osd
(
	.clk(clk),
	.rst(reset),
	.status_i(status),
	.ps2_key_i(11'd0),
	.pending_o(osd_pending),
	.autoboot_o(opt_autoboot),
	.serial_o(opt_serial),
	.cg3_o(opt_cg3),
	.kbd_layout_o(opt_kbd_layout),
	.ps2_key_o(osd_ps2_key),
	.l2tlb_o(opt_l2tlb),
	.ram_mb_o(opt_ram_mb),
	.eth_o(opt_eth),
	.ar_o(osd_ar),
	.scale_o(osd_scale)
);

wire [31:0] sd_lba[4];
wire  [5:0] sd_blk_cnt_a[4];
wire [15:0] sd_buff_din[4];

assign sd_lba0 = sd_lba[0];
assign sd_lba1 = sd_lba[1];
assign sd_lba2 = sd_lba[2];
assign sd_lba3 = sd_lba[3];
assign sd_buff_din0 = sd_buff_din[0];
assign sd_buff_din1 = sd_buff_din[1];
assign sd_buff_din2 = sd_buff_din[2];
assign sd_buff_din3 = sd_buff_din[3];
// The harness serves the lowest requesting slot first and reads its count
// here; pick the same slot.
wire [3:0] sd_req = sd_rd | sd_wr;
assign sd_blk_cnt = sd_req[0] ? sd_blk_cnt_a[0] :
                    sd_req[1] ? sd_blk_cnt_a[1] : sd_blk_cnt_a[2];

wire       vid_ce, uart_rts, uart_dtr;
wire [2:0] kbd_led_status, kbd_led_use;
wire [15:0] audio_l, audio_r;

// The SDRAM module's first rank (sim/sdram_chip.sv: protocol and timing
// checked, an error printed)
wire  [15:0] sdram_dq;
wire  [12:0] sdram_a;
wire   [1:0] sdram_ba;
wire         sdram_dqml, sdram_dqmh, sdram_ncs, sdram_nras, sdram_ncas, sdram_nwe;
/* verilator lint_off UNUSEDSIGNAL */
wire         sdram_cke;
/* verilator lint_on UNUSEDSIGNAL */
sdram_chip #(.INV_CS(0)) sdram
(
	.clk(clk), .nCS(sdram_ncs), .nRAS(sdram_nras), .nCAS(sdram_ncas), .nWE(sdram_nwe),
	.ba(sdram_ba), .a(sdram_a), .dqmh(sdram_dqmh), .dqml(sdram_dqml), .dq(sdram_dq),
	.ctl_drives(machine.u_sdram.dq_oe)
);

ss20_machine #(.SKIP_CLEAR(1'b1), .NCPU(NCPU)) machine
(
	.clk(clk),
	.rst(reset),
	.clk_vid(clk),

	.opt_autoboot_i(opt_autoboot),
	.opt_serial_i(opt_serial),
	.opt_cg3_i(opt_cg3),
	.opt_kbd_layout_i(opt_kbd_layout),
	.opt_l2tlb_i(opt_l2tlb),
	.opt_ram_mb_i(opt_ram_mb),
	.opt_eth_i(opt_eth),

	.ddr_busy_i(ddr_busy),
	.ddr_burstcnt_o(ddr_burstcnt),
	.ddr_addr_o(ddr_addr),
	.ddr_rd_o(ddr_rd),
	.ddr_we_o(ddr_we),
	.ddr_din_o(ddr_din),
	.ddr_be_o(ddr_be),
	.ddr_dout_i(ddr_dout),
	.ddr_dout_ready_i(ddr_dout_ready),

	// the SDRAM (the TCX's VRAM): the chip model below, its clock in phase
	// with clk, so the capture point is rd_mode 3 (sdram64's notes)
	.clk_sdram(clk),
	.sdram_rd_mode_i(2'd3),
	.sdram_dq(sdram_dq),
	.sdram_a(sdram_a),
	.sdram_ba(sdram_ba),
	.sdram_dqml(sdram_dqml),
	.sdram_dqmh(sdram_dqmh),
	.sdram_ncs(sdram_ncs),
	.sdram_nras(sdram_nras),
	.sdram_ncas(sdram_ncas),
	.sdram_nwe(sdram_nwe),
	.sdram_cke(sdram_cke),

	.ioctl_download_i(ioctl_download),
	.ioctl_index_i(ioctl_index),
	.ioctl_wr_i(ioctl_wr),
	.ioctl_addr_i({2'b00, ioctl_addr}),
	.ioctl_dout_i(ioctl_dout),
	.ioctl_wait_o(ioctl_wait),

	.img_mounted_i(img_mounted),
	.img_readonly_i(img_readonly),
	.img_size_i(img_size),
	.sd_lba_o(sd_lba),
	.sd_blk_cnt_o(sd_blk_cnt_a),
	.sd_rd_o(sd_rd),
	.sd_wr_o(sd_wr),
	.sd_ack_i(sd_ack),
	.sd_buff_addr_i(sd_buff_addr),
	.sd_buff_dout_i(sd_buff_dout),
	.sd_buff_din_o(sd_buff_din),
	.sd_buff_wr_i(sd_buff_wr),

	.rtc_i(rtc),

	.uart_txd_o(uart_txd),
	.uart_rxd_i(uart_rxd),
	.uart_rts_o(uart_rts),
	.uart_cts_i(1'b0),
	.uart_dtr_o(uart_dtr),
	.uart_dsr_i(1'b0),

	// no keyboard or mouse events yet
	.ps2_key_i(11'd0),
	.ps2_mouse_i(25'd0),
	.kbd_led_status_o(kbd_led_status),
	.kbd_led_use_o(kbd_led_use),

	.vid_ce_o(vid_ce),
	.vid_r_o(vga_r),
	.vid_g_o(vga_g),
	.vid_b_o(vga_b),
	.vid_hs_o(vga_hs),
	.vid_vs_o(vga_vs),
	.vid_de_o(vga_de),

	.audio_l_o(audio_l),
	.audio_r_o(audio_r),

	.led_disk_o(led_disk),
	.led_user_o(led_user)
);

endmodule
