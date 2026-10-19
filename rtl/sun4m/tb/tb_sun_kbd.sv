// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_sun_kbd: sun_kbd against a model of the ESCC's byte port. PS/2 events
// are driven the way hps_io presents them; the byte stream, its pacing, the
// reset reply (with held keys), the layout reply, LEDs, bell and click are
// checked. The cases: a plain key, F1,
// Stop-A both ways, AltGraph, L-keys, Help, Pause, Print Screen, reset with
// Stop and A held, bell, click, plus the Sun protocol's idle byte, key
// repeats, the ESCC withholding its ready, and a sample of the key table.
// BYTE_CLKS is small here (400); the pacing checks use it.

module tb_sun_kbd;
  import tb_pkg::*;

  localparam int BYTE_CLKS = 400;

  logic        clk;
  logic        rst = 1'b1;
  logic [10:0] ps2_key = 11'd0;
  logic [7:0]  layout = 8'h21;
  logic [7:0]  tx_byte = 8'h00;
  logic        tx_valid = 1'b0;
  logic [7:0]  rx_byte;
  logic        rx_valid;
  logic        rx_ready = 1'b1;
  logic        bell, click, any_key;
  logic [3:0]  leds;


  sun_kbd #(.BYTE_CLKS(BYTE_CLKS)) dut (
    .clk, .rst, .ps2_key_i(ps2_key), .layout_i(layout),
    .tx_byte_i(tx_byte), .tx_byte_valid_i(tx_valid),
    .rx_byte_o(rx_byte), .rx_byte_valid_o(rx_valid), .rx_byte_ready_i(rx_ready),
    .bell_o(bell), .click_o(click), .leds_o(leds), .any_key_o(any_key));

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  int cyc;
  initial cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // what the ESCC received, with the cycle each byte arrived
  logic [7:0] rxq [$];
  int         rxt [$];
  int         nclick;
  initial nclick = 0;
  always @(posedge clk) begin
    if (rx_valid) begin
      rxq.push_back(rx_byte);
      rxt.push_back(cyc);
    end
    if (click) nclick <= nclick + 1;
  end

  task automatic ps2(input bit ext, input bit make, input logic [7:0] code);
    @(negedge clk);
    ps2_key = {~ps2_key[10], make, ext, code};
    repeat (30) @(posedge clk);
  endtask

  task automatic key(input bit ext, input logic [7:0] code);   // press and release
    ps2(ext, 1'b1, code);
    ps2(ext, 1'b0, code);
  endtask

  task automatic cmd(input logic [7:0] b);
    @(negedge clk);
    tx_byte = b;
    tx_valid = 1'b1;
    @(negedge clk);
    tx_valid = 1'b0;
    repeat (3) @(posedge clk);
  endtask

  task automatic settle;
    repeat (10 * BYTE_CLKS) @(posedge clk);
  endtask

  // the bytes since the last expect must be exactly these (hex, blank separated)
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

  // the extended Right Alt, the PS/2 codes used below
  localparam logic [7:0] F1 = 8'h05, F2 = 8'h06, F10 = 8'h09, F11 = 8'h78, A = 8'h1C, S = 8'h1B, Q = 8'h15;

  int k, t0;

  initial begin
    repeat (4) @(posedge clk);
    rst = 1'b0;
    // the keyboard clears its key bits in RAM for 128 cycles after reset; an
    // event meanwhile waits, a second one would be dropped (hps_io's events
    // are milliseconds apart, this bench's 30 cycles)
    repeat (140) @(posedge clk);

    // a plain key, and its pacing: the first byte BYTE_CLKS after the event,
    // the next BYTE_CLKS after that
    ps2(1'b0, 1'b1, A);
    t0 = cyc;
    ps2(1'b0, 1'b0, A);
    settle();
    check(rxq.size() == 3, "plain: three bytes");
    check(rxq[0] == 8'h4D && rxq[1] == 8'hCD && rxq[2] == 8'h7F, "plain: 4D CD 7F");
    check(rxt[0] - t0 >= BYTE_CLKS - 40 && rxt[0] - t0 <= BYTE_CLKS + 40, "plain: first byte one character time after the event");
    check(rxt[1] - rxt[0] >= BYTE_CLKS && rxt[1] - rxt[0] <= BYTE_CLKS + 4, "plain: 2nd byte paced");
    check(rxt[2] - rxt[1] >= BYTE_CLKS && rxt[2] - rxt[1] <= BYTE_CLKS + 4, "plain: 3rd byte paced");
    rxq.delete(); rxt.delete();

    key(1'b0, F1);
    expect_bytes("F1", "05 85 7F");

    // key repeats are dropped; two keys down: the idle comes with the last up
    ps2(1'b0, 1'b1, A);
    ps2(1'b0, 1'b1, A);
    ps2(1'b0, 1'b1, S);
    check(any_key, "any_key with keys down");
    // (held_o, the 128 key bits, is gone: the reset reply below lists the keys down)
    ps2(1'b0, 1'b0, A);
    ps2(1'b0, 1'b0, S);
    check(!any_key, "no key held after release");
    expect_bytes("repeat dropped, idle last", "4D 4E CD CE 7F");

    // Right Alt + F1, Right Alt up, A, F1 up: Stop-A
    ps2(1'b1, 1'b1, 8'h11);
    ps2(1'b0, 1'b1, F1);
    ps2(1'b1, 1'b0, 8'h11);
    key(1'b0, A);
    ps2(1'b0, 1'b0, F1);
    expect_bytes("Stop-A, Right Alt up first", "01 4D CD 81 7F");

    // the same with Right Alt held: no AltGraph between Stop and A
    ps2(1'b1, 1'b1, 8'h11);
    ps2(1'b0, 1'b1, F1);
    key(1'b0, A);
    ps2(1'b0, 1'b0, F1);
    ps2(1'b1, 1'b0, 8'h11);
    expect_bytes("Stop-A, Right Alt held", "01 4D CD 81 7F");

    // AltGraph goes down before the key, up with Right Alt
    ps2(1'b1, 1'b1, 8'h11);
    key(1'b0, Q);
    ps2(1'b1, 1'b0, 8'h11);
    expect_bytes("AltGraph", "0D 36 B6 8D 7F");

    // nothing for Right Alt alone; AltGraph once for two keys
    ps2(1'b1, 1'b1, 8'h11);
    ps2(1'b1, 1'b0, 8'h11);
    expect_bytes("Right Alt alone", "");
    ps2(1'b1, 1'b1, 8'h11);
    key(1'b0, Q);
    key(1'b0, S);
    ps2(1'b1, 1'b0, 8'h11);
    expect_bytes("AltGraph once", "0D 36 B6 4E CE 8D 7F");

    // L-keys and Help keep their meaning when Right Alt goes up first
    ps2(1'b1, 1'b1, 8'h11);
    ps2(1'b0, 1'b1, F2);
    ps2(1'b1, 1'b0, 8'h11);
    ps2(1'b0, 1'b0, F2);
    expect_bytes("L2 kept", "03 83 7F");
    ps2(1'b1, 1'b1, 8'h11);
    key(1'b0, F11);
    ps2(1'b1, 1'b0, 8'h11);
    expect_bytes("Help", "76 F6 7F");
    ps2(1'b1, 1'b1, 8'h11);
    key(1'b0, F10);
    ps2(1'b1, 1'b0, 8'h11);
    expect_bytes("L10", "61 E1 7F");
    // F11 without Right Alt is F11, and after a chord the plain F-key is plain again
    key(1'b0, F11);
    expect_bytes("F11", "09 89 7F");
    key(1'b0, F2);
    expect_bytes("F2 plain again", "06 86 7F");

    // Pause, Print Screen (the fake shift is ignored)
    ps2(1'b1, 1'b1, 8'h77);                 // a make only, as Main sends it
    expect_bytes("Pause: make, then its break made here", "15 95 7F");
    key(1'b1, 8'h77);                       // a release, if one came, is ignored
    expect_bytes("Pause with a release", "15 95 7F");
    ps2(1'b1, 1'b1, 8'h12);
    ps2(1'b1, 1'b1, 8'h7C);
    ps2(1'b1, 1'b0, 8'h7C);
    ps2(1'b1, 1'b0, 8'h12);
    expect_bytes("Print Screen", "16 96 7F");

    // the reset reply: nothing before one character time, then FF 04 7F
    cmd(8'h01);
    t0 = cyc;
    repeat (BYTE_CLKS - 60) @(posedge clk);
    check(rxq.size() == 0, "reset: nothing before a character time");
    settle();
    check(rxq.size() == 3 && rxq[0] == 8'hFF && rxq[1] == 8'h04 && rxq[2] == 8'h7F, "reset: FF 04 7F");
    check(rxt[0] - t0 >= BYTE_CLKS - 10 && rxt[0] - t0 <= BYTE_CLKS + 20, "reset: first byte a character time on");
    check(rxt[1] - rxt[0] >= BYTE_CLKS && rxt[2] - rxt[1] >= BYTE_CLKS, "reset: replies paced");
    rxq.delete(); rxt.delete();

    // layout, from the OSD's byte
    cmd(8'h0F);
    expect_bytes("layout 21", "FE 21");
    layout = 8'h23;
    cmd(8'h0F);
    expect_bytes("layout 23", "FE 23");

    // Stop and A held across a reset, then released (idle only after the last)
    ps2(1'b1, 1'b1, 8'h11);
    ps2(1'b0, 1'b1, F1);
    ps2(1'b0, 1'b1, A);
    expect_bytes("Stop-A down", "01 4D");
    cmd(8'h01);
    expect_bytes("reset, Stop and A held", "FF 04 01 4D 7F");
    ps2(1'b0, 1'b0, A);
    ps2(1'b0, 1'b0, F1);
    ps2(1'b1, 1'b0, 8'h11);
    expect_bytes("Stop-A up", "CD 81 7F");

    // a reset command drops what was queued
    ps2(1'b0, 1'b1, S);
    cmd(8'h01);
    ps2(1'b0, 1'b0, S);
    settle();
    check(rxq.size() >= 4 && rxq[0] == 8'hFF && rxq[1] == 8'h04, "reset drops the queue: starts with FF 04");
    rxq.delete(); rxt.delete();

    // bell, click, LEDs
    check(!bell, "bell off at start");
    cmd(8'h02);
    check(bell, "bell on");
    cmd(8'h03);
    check(!bell, "bell off");
    k = nclick;
    key(1'b0, A);
    expect_bytes("click off", "4D CD 7F");
    check(nclick == k, "no click while off");
    cmd(8'h0A);
    key(1'b0, A);
    expect_bytes("click on", "4D CD 7F");
    check(nclick == k + 1, "one click per make");
    cmd(8'h0B);
    cmd(8'h0E);
    cmd(8'h0A);                         // the LED byte, not a click-on
    check(leds == 4'hA, "LEDs: Compose and Caps");
    key(1'b0, A);
    expect_bytes("LED byte is not a command", "4D CD 7F");
    check(nclick == k + 1, "LED argument 0A did not turn the click on");
    cmd(8'h0E);
    cmd(8'h01);
    check(leds == 4'h1, "LEDs: Num");
    cmd(8'h02);
    cmd(8'h01);                         // reset: bell and LEDs off
    check(!bell && leds == 4'h0, "reset clears bell and LEDs");
    settle();
    rxq.delete(); rxt.delete();

    // the ESCC not ready (receiver off or FIFO full): the byte waits
    rx_ready = 1'b0;
    key(1'b0, A);
    settle();
    check(rxq.size() == 0, "not ready: nothing delivered");
    rx_ready = 1'b1;
    expect_bytes("ready again", "4D CD 7F");

    // a sample of the table
    begin : table_check
      logic [8:0] pc [20];
      logic [7:0] sun [20];
      pc[0]  = {1'b0, 8'h76}; sun[0]  = 8'h1D;   // Esc
      pc[1]  = {1'b0, 8'h29}; sun[1]  = 8'h79;   // Space
      pc[2]  = {1'b0, 8'h5A}; sun[2]  = 8'h59;   // Return
      pc[3]  = {1'b0, 8'h14}; sun[3]  = 8'h4C;   // Ctrl
      pc[4]  = {1'b0, 8'h12}; sun[4]  = 8'h63;   // Left Shift
      pc[5]  = {1'b0, 8'h58}; sun[5]  = 8'h77;   // Caps Lock
      pc[6]  = {1'b0, 8'h11}; sun[6]  = 8'h13;   // Left Alt
      pc[7]  = {1'b1, 8'h6B}; sun[7]  = 8'h18;   // Left
      pc[8]  = {1'b1, 8'h75}; sun[8]  = 8'h14;   // Up
      pc[9]  = {1'b1, 8'h71}; sun[9]  = 8'h42;   // Delete
      pc[10] = {1'b0, 8'h61}; sun[10] = 8'h7C;   // ISO extra key
      pc[11] = {1'b0, 8'h5D}; sun[11] = 8'h58;   // backslash
      pc[12] = {1'b0, 8'h0E}; sun[12] = 8'h2A;   // grave
      pc[13] = {1'b0, 8'h66}; sun[13] = 8'h2B;   // Backspace
      pc[14] = {1'b1, 8'h1F}; sun[14] = 8'h78;   // Left Windows -> Meta
      pc[15] = {1'b1, 8'h2F}; sun[15] = 8'h43;   // Menu -> Compose
      pc[16] = {1'b0, 8'h70}; sun[16] = 8'h5E;   // keypad 0
      pc[17] = {1'b1, 8'h5A}; sun[17] = 8'h5A;   // keypad Enter
      pc[18] = {1'b0, 8'h83}; sun[18] = 8'h10;   // F7
      pc[19] = {1'b0, 8'h45}; sun[19] = 8'h27;   // 0
      for (int i = 0; i < 20; i++) begin
        key(pc[i][8], pc[i][7:0]);
        settle();
        check(rxq.size() == 3 && rxq[0] == sun[i] && rxq[1] == (sun[i] | 8'h80),
              $sformatf("table: PS/2 %0d:%02x -> %02x", pc[i][8], pc[i][7:0], sun[i]));
        rxq.delete(); rxt.delete();
      end
    end

    tb_done("tb_sun_kbd");
  end

  initial begin
    #50_000_000;
    $display("FAIL: timeout");
    $fatal(1, "timeout");
  end

endmodule
