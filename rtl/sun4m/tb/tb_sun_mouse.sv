// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_sun_mouse: sun_mouse against a model of the ESCC's byte port. PS/2
// packets are driven as hps_io presents them (bytes 0-2 and a toggle);
// checked: the 5-byte packet (buttons active low in bits 2:0 as L, M, R,
// dx, dy, the second halves), the clamp and split of large motion, motion
// accumulated while a packet is on the line, a packet on a button change
// alone, none for an empty report, the 1200 baud pacing (BYTE_CLKS, small
// here) and a byte held back while the ESCC is not ready.

module tb_sun_mouse;
  import tb_pkg::*;

  localparam int BYTE_CLKS = 400;

  logic        clk;
  logic        rst;
  logic [24:0] ps2m;
  logic [7:0]  rx_byte;
  logic        rx_valid;
  logic        rx_ready;

  sun_mouse #(.BYTE_CLKS(BYTE_CLKS)) dut (
    .clk, .rst, .ps2_mouse_i(ps2m),
    .rx_byte_o(rx_byte), .rx_byte_valid_o(rx_valid), .rx_byte_ready_i(rx_ready));

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  int cyc;
  initial cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  logic [7:0] rxq [$];
  int         rxt [$];
  always @(posedge clk) if (rx_valid) begin
    rxq.push_back(rx_byte);
    rxt.push_back(cyc);
  end

  // one PS/2 packet: buttons {M, R, L}, 9-bit signed deltas, overflow flags
  task automatic report(input logic [2:0] btn_mrl, input int dx, input int dy,
                        input bit xovf = 1'b0, input bit yovf = 1'b0);
    logic [8:0] x9, y9;
    x9 = 9'(dx);
    y9 = 9'(dy);
    @(negedge clk);
    ps2m = {~ps2m[24],
            y9[7:0], x9[7:0], yovf, xovf, y9[8], x9[8], 1'b1, btn_mrl};
    repeat (4) @(posedge clk);
  endtask

  task automatic settle(input int chars = 14);
    repeat (chars * BYTE_CLKS) @(posedge clk);
  endtask

  task automatic expect_bytes(input string name, input string hex = "");
    int e [$];
    int v, pos, n;
    string rest;
    rest = hex;
    while (rest.len() > 0) begin
      n = $sscanf(rest, "%h", v);
      if (n != 1) break;
      e.push_back(v);
      pos = 0;
      while (pos < rest.len() && rest[pos] != " ") pos++;
      rest = (pos >= rest.len()) ? "" : rest.substr(pos + 1, rest.len() - 1);
    end
    settle();
    check(rxq.size() == e.size(), $sformatf("%s: %0d bytes, expected %0d", name, rxq.size(), e.size()));
    for (int i = 0; i < e.size() && i < rxq.size(); i++)
      check(int'(rxq[i]) == e[i], $sformatf("%s: byte %0d is %02x, expected %02x", name, i, rxq[i], e[i]));
    rxq.delete();
    rxt.delete();
  endtask

  int t0, sum_x, sum_y;

  initial begin
    rst = 1'b1;
    ps2m = 25'd0;
    rx_ready = 1'b1;
    repeat (4) @(posedge clk);
    rst = 1'b0;
    repeat (4) @(posedge clk);

    // motion only: right 5, up 3 (PS/2's dy positive is up, as the Sun's)
    t0 = cyc;
    report(3'b000, 5, 3);
    settle();
    check(rxq.size() == 5, "motion: five bytes");
    check(rxq[0] == 8'h87 && rxq[1] == 8'h05 && rxq[2] == 8'h03 && rxq[3] == 8'h00 && rxq[4] == 8'h00,
          "motion: 87 05 03 00 00");
    check(rxt[0] - t0 >= BYTE_CLKS - 10 && rxt[0] - t0 <= BYTE_CLKS + 20, "pacing: first byte a character time on");
    for (int i = 1; i < 5; i++)
      check(rxt[i] - rxt[i-1] >= BYTE_CLKS && rxt[i] - rxt[i-1] <= BYTE_CLKS + 4, "pacing: 1200 baud between bytes");
    rxq.delete(); rxt.delete();

    // negative motion; left button down
    report(3'b001, -4, -9);
    expect_bytes("left down, left/down", "83 FC F7 00 00");
    // a button change alone: left up
    report(3'b000, 0, 0);
    expect_bytes("left up", "87 00 00 00 00");
    // an empty report: nothing
    report(3'b000, 0, 0);
    expect_bytes("empty report");
    // middle and right together
    report(3'b110, 0, 0);
    expect_bytes("middle and right", "84 00 00 00 00");
    report(3'b010, 0, 0);
    expect_bytes("middle released (right stays)", "86 00 00 00 00");
    report(3'b100, 1, 0);
    expect_bytes("middle alone, with motion", "85 01 00 00 00");
    report(3'b000, 0, 0);
    expect_bytes("all up", "87 00 00 00 00");

    // large motion: 200 right, 200 down, split 127 + 73
    report(3'b000, 200, -200);
    expect_bytes("split", "87 7F 81 49 B7");

    // motion while a packet is on the line accumulates into the next one
    report(3'b000, 10, 0);
    repeat (BYTE_CLKS * 2) @(posedge clk);
    report(3'b000, 20, 5);
    report(3'b000, 3, 6);
    expect_bytes("accumulated", "87 0A 00 00 00 87 17 0B 00 00");

    // beyond 254 in one report: the remainder follows in more packets
    report(3'b000, 255, 255, 1'b1, 1'b1);   // overflow flags: saturates at +-255
    report(3'b000, 255, 255, 1'b1, 1'b1);
    report(3'b000, 255, 255, 1'b1, 1'b1);
    settle(40);
    sum_x = 0;
    sum_y = 0;
    check(rxq.size() % 5 == 0 && rxq.size() >= 15, "large: whole packets");
    for (int i = 0; i + 4 < rxq.size(); i += 5) begin
      check(rxq[i] == 8'h87, "large: header");
      sum_x += int'($signed(rxq[i+1])) + int'($signed(rxq[i+3]));
      sum_y += int'($signed(rxq[i+2])) + int'($signed(rxq[i+4]));
    end
    check(sum_x == 765 && sum_y == 765, $sformatf("large: motion adds up (%0d, %0d)", sum_x, sum_y));
    rxq.delete(); rxt.delete();

    // the ESCC not ready: the byte waits, the packet continues after
    rx_ready = 1'b0;
    report(3'b000, 7, 7);
    settle();
    check(rxq.size() == 0, "not ready: nothing delivered");
    rx_ready = 1'b1;
    expect_bytes("ready again", "87 07 07 00 00");

    tb_done("tb_sun_mouse");
  end

  initial begin
    #50_000_000;
    $display("FAIL: timeout");
    $fatal(1, "timeout");
  end

endmodule
