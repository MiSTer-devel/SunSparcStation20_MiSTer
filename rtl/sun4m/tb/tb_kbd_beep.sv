// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_kbd_beep: silence, the bell's square wave and its period, a click's
// length.

`timescale 1ns/1ps
module tb_kbd_beep;
  import tb_pkg::*;

  // 1 MHz, a 10 kHz tone (half period 50 clocks), a 300 us click
  logic clk, rst, bell, click;
  logic [15:0] a;
  initial begin clk = 0; rst = 1; bell = 0; click = 0; end
  always #5 clk = ~clk;

  kbd_beep #(.CLK_HZ(1_000_000), .TONE_HZ(10_000), .CLICK_US(300)) dut (
    .clk, .rst, .bell_i(bell), .click_i(click), .audio_o(a));

  task automatic cycles(input int n); repeat (n) @(posedge clk); #1; endtask

  int edges, sounding;
  logic [15:0] last;
  initial begin
    cycles(3); rst = 0;
    cycles(500);
    check(a == 16'd0, "silent with no bell and no click");

    bell = 1; cycles(2);
    edges = 0; last = a;
    for (int i = 0; i < 1000; i++) begin cycles(1); if (a != last) edges++; last = a; end
    check(edges >= 19 && edges <= 21, $sformatf("bell: a 10 kHz square, %0d edges in 1 ms", edges));
    check(a == 16'sd6000 || a == -16'sd6000, "bell: the amplitude");
    bell = 0; cycles(1);
    check(a == 16'd0, "bell off: silent");

    click = 1; cycles(1); click = 0;
    sounding = 0;
    for (int i = 0; i < 600; i++) begin cycles(1); if (a != 16'd0) sounding++; end
    check(sounding >= 298 && sounding <= 301, $sformatf("a click sounds 300 us (%0d)", sounding));
    tb_done("tb_kbd_beep");
  end
endmodule
