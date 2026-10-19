// SPDX-License-Identifier: GPL-2.0-or-later
//
// ss20_osd: the OSD status word decoded into the machine's options. Shared
// by the MiSTer top (SunSparcStation.sv) and sim/sim_top.sv, so the
// simulation sees the options exactly as the board does.
//
// The OSD follows the computer cores' OSD standard (hp9000-715_MiSTer
// docs/osd-standard.md): the media and Input settings act at once, every
// other setting is latched here at reset (Apply and reset, the board's
// reset, a core reload) and `pending_o` says when the OSD differs from
// what the machine runs.
//
// The bit assignments are a compatibility contract (VERILOG-PLAN.md §1.2):
// users' config/SunSparcStation.CFG files and Main's support/sun read them,
// so a bit keeps its meaning; a setting whose value list changes moves to
// new bits. scripts/setopt.sh writes the same bits; keep the three in step
// with CONF_STR.
//
//   [0]      Apply and reset (the top uses it)   [13:12]  keyboard layout: US,
//   [7:6]    aspect ratio                                 French, German, Spanish
//   [8]      Autoboot: 0 On, 1 Off               [23:22]  memory: 464, 256, 128, 64 MB
//   [9]      display: 0 graphics, 1 ttya         [26:24]  network: eth0, None, eth1,
//   [27]     Swap Alt/Win keys: 0 No, 1 Yes               macvlan, tap0 (Main
//   [30:28]  scale: V-Integer, Normal, Narrower           sun_enet.cpp reads them)
//            HV-Integer, Wider HV-Integer,
//            HV-Integer
//
// Not offered, meaning kept: [10] graphics 0 TCX / 1 CG3 (no CG3 in this
// core: forced to TCX), [17] L2 TLB 0 On / 1 Off (no L2 TLB yet), [21:20]
// IOMMU rev (unused: the SS20's is fixed).
// Retired, never to be reused for something else (old .CFG files may still
// have them set): [1], [4], [5], [11], [15:14] (the old Scale, Normal
// first), [16], [18], [19].

module ss20_osd (
  input  logic         clk,
  input  logic         rst,            // the machine's reset: the settings are taken here
  input  logic [127:0] status_i,       // hps_io's status, live
  input  logic [10:0]  ps2_key_i,      // hps_io's ps2_key
  output logic         pending_o,      // an OSD setting differs from the running one
  output logic         autoboot_o,     // the PROM boots without waiting at ok
  output logic         serial_o,       // console on ttya rather than the screen
  output logic         cg3_o,          // CG3 instead of TCX
  output logic [7:0]   kbd_layout_o,   // the layout byte the keyboard reports
  output logic [10:0]  ps2_key_o,      // ps2_key with Alt and Win swapped if asked
  output logic         l2tlb_o,        // the MMU's second-level TLB enabled
  output logic [9:0]   ram_mb_o,       // main memory size in MB
  output logic         eth_o,          // the Ethernet mailbox runs
  output logic [1:0]   ar_o,           // aspect ratio, video_freak's encoding
  output logic [2:0]   scale_o         // video_freak's SCALE
);

  // The settings the machine runs with, taken from the OSD at every reset.
  logic [127:0] cfg;
  always_ff @(posedge clk) if (rst) cfg <= status_i;

  // The latched settings: [9:6] aspect, Autoboot, display; [23:22] memory;
  // [30:28] scale. Network (Main reads it live), the Input rows and the
  // reset bit stay out.
  assign pending_o = {status_i[9:6], status_i[23:22], status_i[30:28]}
                  != {cfg[9:6],      cfg[23:22],      cfg[30:28]};

  assign autoboot_o = ~cfg[8];
  assign serial_o   = cfg[9];
  assign cg3_o      = 1'b0;
  assign l2tlb_o    = ~cfg[17];
  // Value 1 is None; every other value is a host interface Main drives.
  // Live, like Main's side of it.
  assign eth_o      = (status_i[26:24] != 3'd1);
  assign ar_o       = cfg[7:6];

  // The OSD lists V-Integer first; video_freak counts 0 Normal, 1 V-Integer,
  // 2 Narrower HV, 3 Wider HV, 4 HV-Integer.
  always_comb begin
    case (cfg[30:28])
      3'd0:    scale_o = 3'd1;
      3'd1:    scale_o = 3'd0;
      3'd2:    scale_o = 3'd2;
      3'd3:    scale_o = 3'd3;
      default: scale_o = 3'd4;
    endcase
  end

  // Sun Type 5 layout codes (OpenBIOS's and Solaris's keyboard tables):
  // US5 0x21, France5 0x23, Germany5 0x25, Spain5 0x2A. Input: live.
  always_comb begin
    case (status_i[13:12])
      2'd0:    kbd_layout_o = 8'h21;
      2'd1:    kbd_layout_o = 8'h23;
      2'd2:    kbd_layout_o = 8'h25;
      default: kbd_layout_o = 8'h2A;
    endcase
  end

  // Swap Alt/Win keys (Input: live): Left Alt (11) <-> Left Win (E0 1F),
  // Right Alt (E0 11) <-> Right Win (E0 27), before sun_kbd sees them, so
  // Right Alt's AltGraph and Stop chords move with the key code.
  always_comb begin
    ps2_key_o = ps2_key_i;
    if (status_i[27]) begin
      case ({ps2_key_i[8], ps2_key_i[7:0]})
        9'h011: ps2_key_o[8:0] = 9'h11F;
        9'h11F: ps2_key_o[8:0] = 9'h011;
        9'h111: ps2_key_o[8:0] = 9'h127;
        9'h127: ps2_key_o[8:0] = 9'h111;
        default: ;
      endcase
    end
  end

  // 464 MB is seven 64 MB SIMMs and a 16 MB one, the core's maximum:
  // the rest of the FPGA's 512 MB DDR3 window holds the PROM image, the
  // VRAM and the framework's scaler buffers.
  always_comb begin
    case (cfg[23:22])
      2'd0:    ram_mb_o = 10'd464;
      2'd1:    ram_mb_o = 10'd256;
      2'd2:    ram_mb_o = 10'd128;
      default: ram_mb_o = 10'd64;
    endcase
  end

  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_cfg = ^{cfg[127:31], cfg[27:24], cfg[21:18], cfg[16:10], cfg[5:0]};
  wire unused_status = ^{status_i[127:31], status_i[21:14], status_i[11:10],
                         status_i[5:0]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
