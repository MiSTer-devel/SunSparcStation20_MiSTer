// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_ss20_osd: the OSD decoder against the OSD standard
// (hp9000-715_MiSTer docs/osd-standard.md) and the status bits ss20_osd.sv
// lists: the settings are taken at reset, "Changes pending" follows the
// live OSD, the Input rows and the network act at once.

module tb_ss20_osd;
  import tb_pkg::*;

  logic         clk, rst;
  logic [127:0] status;
  logic [10:0]  key_in;
  initial begin clk = 0; rst = 1; status = '0; key_in = '0; end
  always #5 clk = ~clk;

  logic        pending, autoboot, serial, cg3, l2tlb, eth;
  logic [7:0]  layout;
  logic [10:0] key_out;
  logic [9:0]  ram_mb;
  logic [1:0]  ar;
  logic [2:0]  scale;

  ss20_osd dut (
    .clk, .rst, .status_i(status), .ps2_key_i(key_in), .pending_o(pending),
    .autoboot_o(autoboot), .serial_o(serial), .cg3_o(cg3), .kbd_layout_o(layout),
    .ps2_key_o(key_out), .l2tlb_o(l2tlb), .ram_mb_o(ram_mb), .eth_o(eth),
    .ar_o(ar), .scale_o(scale));

  task automatic cycles(input int n);
    repeat (n) @(posedge clk);
    #1;
  endtask

  task automatic reset_pulse();
    rst = 1; cycles(2); rst = 0; cycles(1);
  endtask

  // a key through the swap: {E0, code} in, {E0, code} expected
  task automatic key(input logic [8:0] k, input logic [8:0] exp, input string what);
    key_in = {2'b11, k}; #1;
    check32(32'(key_out), {21'd0, 2'b11, exp}, what);
  endtask

  initial begin
    // ---- defaults: status 0 is every row's first value
    cycles(2); rst = 0; cycles(1);
    check(!pending, "defaults: nothing pending");
    check(autoboot, "defaults: Autoboot On");
    check(!serial, "defaults: Display Graphics");
    check(!cg3, "defaults: TCX");
    check(l2tlb, "defaults: L2 TLB bit 0 = On");
    check(eth, "defaults: Network interface eth0");
    check32(32'(ram_mb), 464, "defaults: Memory 464 MB");
    check32(32'(ar), 0, "defaults: Aspect ratio Original");
    check32(32'(scale), 1, "defaults: Scale V-Integer (video_freak 1)");
    check32(32'(layout), 32'h21, "defaults: keyboard US5");

    // ---- a latched setting changes only at reset, pending meanwhile
    status[23:22] = 2'd2;                  // Memory 128 MB
    cycles(1);
    check(pending, "Memory changed: pending");
    check32(32'(ram_mb), 464, "Memory changed: the machine keeps 464 MB");
    reset_pulse();
    check(!pending, "after reset: not pending");
    check32(32'(ram_mb), 128, "after reset: 128 MB");
    status[23:22] = 2'd0; cycles(1);
    check(pending, "back to 464 MB in the OSD: pending again");
    status[23:22] = 2'd2; cycles(1);
    check(!pending, "OSD back to the running value: not pending");

    // ---- every latched field counts
    status[8] = 1;  cycles(1); check(pending, "Autoboot: pending");
    check(autoboot, "Autoboot: still On until reset");
    status[9] = 1;  cycles(1);
    status[7:6] = 2'd1; status[30:28] = 3'd4; cycles(1);
    check32(32'(scale), 1, "Scale: still V-Integer until reset");
    reset_pulse();
    check(!pending, "Autoboot, Display, Aspect, Scale applied");
    check(!autoboot, "Autoboot Off");
    check(serial, "Display Serial console");
    check32(32'(ar), 1, "Aspect ratio Full Screen");
    check32(32'(scale), 4, "Scale HV-Integer");
    status[30:28] = 3'd1; reset_pulse();
    check32(32'(scale), 0, "Scale Normal (video_freak 0)");
    status[30:28] = 3'd2; reset_pulse();
    check32(32'(scale), 2, "Scale Narrower HV-Integer");
    status[30:28] = 3'd3; reset_pulse();
    check32(32'(scale), 3, "Scale Wider HV-Integer");

    // ---- the network, the Input rows and the reset bit act at once
    status[26:24] = 3'd1; cycles(1);
    check(!eth, "Network interface None: at once");
    check(!pending, "Network interface: not pending");
    status[26:24] = 3'd4; cycles(1);
    check(eth, "Network interface tap0");
    status[13:12] = 2'd2; cycles(1);
    check32(32'(layout), 32'h25, "Keyboard layout German: at once");
    status[13:12] = 2'd3; cycles(1);
    check32(32'(layout), 32'h2A, "Keyboard layout Spanish");
    status[27] = 1; cycles(1);
    check(!pending, "Swap Alt/Win, layout: not pending");
    status[0] = 1; cycles(1);
    check(!pending, "the reset bit: not pending");
    status[0] = 0;

    // ---- the retired and unoffered bits change nothing
    status[10] = 1; status[17] = 1; status[15:14] = 2'd3; status[5:1] = '1;
    cycles(1);
    check(!pending, "retired bits: not pending");
    reset_pulse();
    check(!cg3, "an old CFG's CG3 bit: still TCX");
    check(!l2tlb, "L2 TLB bit kept: Off");
    check32(32'(scale), 3, "the old Scale bits are ignored");

    // ---- Swap Alt/Win keys (status[27] = 1 here)
    key(9'h011, 9'h11F, "swap: Left Alt -> Left Win");
    key(9'h11F, 9'h011, "swap: Left Win -> Left Alt");
    key(9'h111, 9'h127, "swap: Right Alt -> Right Win");
    key(9'h127, 9'h111, "swap: Right Win -> Right Alt");
    key(9'h01C, 9'h01C, "swap: A untouched");
    key(9'h01F, 9'h01F, "swap: unextended 1F untouched");
    key(9'h027, 9'h027, "swap: unextended 27 untouched");
    status[27] = 0; cycles(1);
    key(9'h011, 9'h011, "no swap: Left Alt");
    key(9'h127, 9'h127, "no swap: Right Win");

    tb_done("tb_ss20_osd");
  end

endmodule
