// SPDX-License-Identifier: GPL-2.0-or-later
//============================================================================
//
//  SPARCstation 20 for MiSTer: the framework glue.
//
//  This is the emu module of Template_MiSTer. It makes the clocks, talks to
//  Main through hps_io, decodes the OSD, and wires rtl/machine/ss20_machine
//  to the framework's DDR3, video, audio and UART. Nothing of the machine is
//  here, so the simulation (sim/sim_top.sv), which wraps the same machine,
//  covers all but this file.
//
//  Compatibility (docs/VERILOG-PLAN.md §1.2): Main's support/sun recognises
//  the core by CONF_STR's first field, sends the boot PROM as ioctl index 0
//  and the ID PROM seed as index 64, serves the disks, the CD and the NVRAM
//  image on SD slots 0-3, and reads the network mode from status[26:24].
//  Users' .CFG files hold the status bits below. None of that may change.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
`ifdef MISTER_DUAL_SDRAM
assign {SDRAM2_CLK, SDRAM2_A, SDRAM2_BA, SDRAM2_DQ, SDRAM2_nCS,
        SDRAM2_nCAS, SDRAM2_nRAS, SDRAM2_nWE} = 'Z;
`endif

assign VGA_SL         = 2'd0;
assign VGA_F1         = 1'b0;
assign VGA_SCALER     = 1'b0;
assign VGA_DISABLE    = 1'b0;
assign HDMI_FREEZE    = 1'b0;
assign HDMI_BLACKOUT  = 1'b0;
assign HDMI_BOB_DEINT = 1'b0;

assign AUDIO_S   = 1'b1;
assign AUDIO_MIX = 2'd0;

assign LED_POWER = 2'd0;
assign BUTTONS   = 2'd0;

//////////////////////////////////////////////////////////////////////////////
// OSD
//
// The layout is the computer cores' OSD standard (hp9000-715_MiSTer
// docs/osd-standard.md): the top page holds the media, Memory and Network
// interface, the submenus (P2 Video, P3 Input, P5 Advanced) and Apply and
// reset. The media and the Input page act at once; every other setting is
// taken at the next reset (ss20_osd latches it), and "Changes pending"
// shows until then.
//
// The status bits are fixed (rtl/machine/ss20_osd.sv lists them, with the
// retired ones that must stay unused), so users' .CFG files keep working. Option text may change; a
// bit's meaning may not.
//
// "F0" is Load ROM: not remembered, so a normal start loads
// games/SunSparcStation/boot0.rom or boot.rom, and Load ROM or an MGL picks
// another ROM for that session. Keep its extension list to ROM alone: a
// second extension would be sent as index 0x40 | 0 = 64, the ID PROM's
// index. It stays on the top page: an MGL finds only the rows drawn there.
// "SC0"-"SC3": the C makes Main remember the image (config/<core>.s<n>) and
// mount it again at the next start. Slots 0 and 1 are the disks at SCSI IDs
// 3 and 1, slot 2 the CD at ID 6 (Main's sun_cdrom translates CUE/CHD),
// slot 3 the NVRAM image.

`include "build_id.v"
localparam CONF_STR = {
	"SunSparcStation;;",
	"-;",
	"SC0,VHDIMGHDARAW,Pri. disk (ID 3);",
	"SC1,VHDIMGHDARAW,Disk (ID 1);",
	"SC2,ISOCUECHD,CD-ROM (ID 6);",
	"F0,ROM,Load ROM;",
	"-;",
	"O[23:22],Memory,464MB,256MB,128MB,64MB;",
	"O[26:24],Network interface,eth0,None,eth1,macvlan,tap0;",
	"-;",
	"P2,Video;",
	"P3,Input;",
	"P5,Advanced;",
	"-;",
	"h0-,Changes pending;",
	"R[0],Apply and reset;",

	"P2O[9],Display,Graphics,Serial console;",
	"P2O[7:6],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P2O[30:28],Scale,V-Integer,Normal,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",

	"P3O[13:12],Keyboard layout,US,French,German,Spanish;",
	"P3O[27],Swap Alt/Win keys,No,Yes;",

	"P5O[8],Autoboot,On,Off;",
	"P5-;",
	"P5SC3,NVR,NVRAM image;",

	"V,v",`BUILD_DATE
};

wire         clk_sys, clk_vid, clk_sdram, pll_locked;
wire [127:0] status;
wire         osd_pending;
wire   [1:0] buttons;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;
wire        ioctl_wait;

wire  [3:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;
wire [31:0] sd_lba[4];
wire  [5:0] sd_blk_cnt[4];
wire  [3:0] sd_rd;
wire  [3:0] sd_wr;
wire  [3:0] sd_ack;
wire [12:0] sd_buff_addr;
wire [15:0] sd_buff_dout;
wire [15:0] sd_buff_din[4];
wire        sd_buff_wr;

wire [64:0] rtc;
wire [10:0] ps2_key;
wire [24:0] ps2_mouse;
wire  [2:0] kbd_led_status, kbd_led_use;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1), .VDNUM(4), .BLKSZ(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.buttons(buttons),
	.status(status),
	.status_menumask({15'd0, osd_pending}),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),

	.RTC(rtc),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),
	.ps2_kbd_led_status(kbd_led_status),
	.ps2_kbd_led_use(kbd_led_use)
);

//////////////////////////////////////////////////////////////////////////////
// Clocks and reset

pll pll
(
	.refclk(CLK_50M),
	.rst(1'b0),
	.outclk_0(clk_sys),
	.outclk_1(clk_vid),
	.outclk_2(clk_sdram),
	.locked(pll_locked)
);

// SDRAM_CLK: clk_sdram (clk_sys + 270 degrees) through a DDIO output
// register, as every MiSTer core drives it
altddio_out #(
	.extend_oe_disable("OFF"), .intended_device_family("Cyclone V"), .invert_output("OFF"),
	.lpm_hint("UNUSED"), .lpm_type("altddio_out"), .oe_reg("UNREGISTERED"), .power_up_high("OFF"), .width(1)
) sdramclk_ddr (
	.datain_h(1'b1), .datain_l(1'b0), .outclock(clk_sdram), .dataout(SDRAM_CLK),
	.aclr(1'b0), .aset(1'b0), .oe(1'b1), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
);

// RESET and the OSD's Reset are asynchronous to clk_sys; the machine wants
// a synchronous reset.
reg [1:0] reset_s = 2'b11;
always @(posedge clk_sys) reset_s <= {reset_s[0], RESET | status[0] | buttons[1] | ~pll_locked};
wire reset = reset_s[1];

// The OSD's options: the settings latched at reset, the Input rows live.
wire        opt_autoboot, opt_serial, opt_cg3, opt_l2tlb, opt_eth;
wire  [7:0] opt_kbd_layout;
wire  [9:0] opt_ram_mb;
wire  [1:0] ar;
wire  [2:0] scale;
wire [10:0] ps2_key_m;

ss20_osd osd
(
	.clk(clk_sys),
	.rst(reset),
	.status_i(status),
	.ps2_key_i(ps2_key),
	.pending_o(osd_pending),
	.autoboot_o(opt_autoboot),
	.serial_o(opt_serial),
	.cg3_o(opt_cg3),
	.kbd_layout_o(opt_kbd_layout),
	.ps2_key_o(ps2_key_m),
	.l2tlb_o(opt_l2tlb),
	.ram_mb_o(opt_ram_mb),
	.eth_o(opt_eth),
	.ar_o(ar),
	.scale_o(scale)
);

//////////////////////////////////////////////////////////////////////////////
// The machine

wire       vid_ce, vid_hs, vid_vs, vid_de;
wire [7:0] vid_r, vid_g, vid_b;
wire       led_disk, led_user;

ss20_machine machine
(
	.clk(clk_sys),
	.rst(reset),
	.clk_vid(clk_vid),

	.opt_autoboot_i(opt_autoboot),
	.opt_serial_i(opt_serial),
	.opt_cg3_i(opt_cg3),
	.opt_kbd_layout_i(opt_kbd_layout),
	.opt_l2tlb_i(opt_l2tlb),
	.opt_ram_mb_i(opt_ram_mb),
	.opt_eth_i(opt_eth),

	.ddr_busy_i(DDRAM_BUSY),
	.ddr_burstcnt_o(DDRAM_BURSTCNT),
	.ddr_addr_o(DDRAM_ADDR),
	.ddr_rd_o(DDRAM_RD),
	.ddr_we_o(DDRAM_WE),
	.ddr_din_o(DDRAM_DIN),
	.ddr_be_o(DDRAM_BE),
	.ddr_dout_i(DDRAM_DOUT),
	.ddr_dout_ready_i(DDRAM_DOUT_READY),

	// the SDRAM module (the TCX's VRAM). status[33:32], not in the OSD:
	// sdram64's read capture point, for bring-up at 55 MHz (0 = clk edge 3,
	// as at 64 MHz on the HP core; scripts/setopt.sh sdram_rd=0..3)
	.clk_sdram(clk_sdram),
	.sdram_rd_mode_i(status[33:32]),
	.sdram_dq(SDRAM_DQ),
	.sdram_a(SDRAM_A),
	.sdram_ba(SDRAM_BA),
	.sdram_dqml(SDRAM_DQML),
	.sdram_dqmh(SDRAM_DQMH),
	.sdram_ncs(SDRAM_nCS),
	.sdram_nras(SDRAM_nRAS),
	.sdram_ncas(SDRAM_nCAS),
	.sdram_nwe(SDRAM_nWE),
	.sdram_cke(SDRAM_CKE),

	.ioctl_download_i(ioctl_download),
	.ioctl_index_i(ioctl_index[7:0]),
	.ioctl_wr_i(ioctl_wr),
	.ioctl_addr_i(ioctl_addr),
	.ioctl_dout_i(ioctl_dout),
	.ioctl_wait_o(ioctl_wait),

	.img_mounted_i(img_mounted),
	.img_readonly_i(img_readonly),
	.img_size_i(img_size),
	.sd_lba_o(sd_lba),
	.sd_blk_cnt_o(sd_blk_cnt),
	.sd_rd_o(sd_rd),
	.sd_wr_o(sd_wr),
	.sd_ack_i(sd_ack),
	.sd_buff_addr_i(sd_buff_addr),
	.sd_buff_dout_i(sd_buff_dout),
	.sd_buff_din_o(sd_buff_din),
	.sd_buff_wr_i(sd_buff_wr),

	.rtc_i(rtc),

	.uart_txd_o(UART_TXD),
	.uart_rxd_i(UART_RXD),
	.uart_rts_o(UART_RTS),
	.uart_cts_i(UART_CTS),
	.uart_dtr_o(UART_DTR),
	.uart_dsr_i(UART_DSR),

	.ps2_key_i(ps2_key_m),
	.ps2_mouse_i(ps2_mouse),
	.kbd_led_status_o(kbd_led_status),
	.kbd_led_use_o(kbd_led_use),

	.vid_ce_o(vid_ce),
	.vid_r_o(vid_r),
	.vid_g_o(vid_g),
	.vid_b_o(vid_b),
	.vid_hs_o(vid_hs),
	.vid_vs_o(vid_vs),
	.vid_de_o(vid_de),

	.audio_l_o(AUDIO_L),
	.audio_r_o(AUDIO_R),

	.led_disk_o(led_disk),
	.led_user_o(led_user)
);

assign DDRAM_CLK = clk_sys;
assign LED_DISK  = {1'b0, led_disk};
assign LED_USER  = led_user;

//////////////////////////////////////////////////////////////////////////////
// Video

assign CLK_VIDEO = clk_vid;
assign CE_PIXEL  = vid_ce;
assign VGA_R     = vid_r;
assign VGA_G     = vid_g;
assign VGA_B     = vid_b;
assign VGA_HS    = vid_hs;
assign VGA_VS    = vid_vs;

// Aspect ratio and integer scaling for the HDMI scaler (ss20_osd takes
// them at reset). The screen is 1024x768 with square pixels, so "Original"
// is 4:3.

video_freak video_freak
(
	.CLK_VIDEO(clk_vid),
	.CE_PIXEL(vid_ce),
	.VGA_VS(vid_vs),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),

	.VGA_DE_IN(vid_de),
	.ARX((!ar) ? 12'd4 : (ar - 1'd1)),
	.ARY((!ar) ? 12'd3 : 12'd0),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(scale)
);

endmodule
