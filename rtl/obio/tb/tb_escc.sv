// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_escc: the SCC against the Am85C30 manual, with a serial line model.
// CLK_HZ is twice PCLK here, so PCLK is every second clock and a bit at
// time constant TC in x16 mode is 64*(TC+2) clocks: 256 at 38400, 1024 at
// 9600.

module tb_escc;
  import iobus_pkg::*;
  import tb_pkg::*;

  localparam int PCLK_HZ = 4_915_200;
  localparam int CLK_HZ = 2 * PCLK_HZ;
  localparam int BIT38400 = 256;
  localparam int BIT9600 = 1024;

  localparam logic [2:0] B_CTL = 3'd0, B_DAT = 3'd2, A_CTL = 3'd4, A_DAT = 3'd6;
  localparam bit A = 1, B = 0;

  logic clk, rst;
  initial begin clk = 0; rst = 1; end
  always #5 clk = ~clk;

  iob_req_t req = IOB_REQ_IDLE;
  iob_rsp_t rsp;
  logic txd_a, txd_b, rts_a, dtr_a, rts_b, dtr_b, irq;
  logic rxd_a = 1, rxd_b = 1, dcd_a = 0, cts_a = 0, dcd_b = 0, cts_b = 0;

  logic [7:0] tx_byte_a, tx_byte_b;
  logic tx_byte_valid_a, tx_byte_valid_b, rx_byte_ready_a, rx_byte_ready_b;
  escc #(.CLK_HZ(CLK_HZ), .PCLK_HZ(PCLK_HZ)) dut (
    .clk, .rst, .bus_i(req), .bus_o(rsp),
    .txd_a_o(txd_a), .rxd_a_i(rxd_a), .dcd_a_i(dcd_a), .cts_a_i(cts_a), .rts_a_o(rts_a), .dtr_a_o(dtr_a),
    .txd_b_o(txd_b), .rxd_b_i(rxd_b), .dcd_b_i(dcd_b), .cts_b_i(cts_b), .rts_b_o(rts_b), .dtr_b_o(dtr_b),
    .tx_byte_a_o(tx_byte_a), .tx_byte_valid_a_o(tx_byte_valid_a), .rx_byte_a_i(8'h00), .rx_byte_valid_a_i(1'b0), .rx_byte_ready_a_o(rx_byte_ready_a),
    .tx_byte_b_o(tx_byte_b), .tx_byte_valid_b_o(tx_byte_valid_b), .rx_byte_b_i(8'h00), .rx_byte_valid_b_i(1'b0), .rx_byte_ready_b_o(rx_byte_ready_b),
    .irq_o(irq));

  task automatic cycles(input int n);
    repeat (n) @(posedge clk);
    #1;
  endtask

  // ---- bus: one byte at offset o ----
  task automatic wr8(input logic [2:0] o, input logic [7:0] d);
    req.req = 1; req.we = 1; req.addr = 28'(o); req.be = 4'b1000 >> o[1:0]; req.wdata = {4{d}};
    do cycles(1); while (!rsp.ack);
    req.req = 0; req.we = 0;
    cycles(1);
  endtask

  task automatic rd8(input logic [2:0] o, output logic [7:0] d);
    req.req = 1; req.we = 0; req.addr = 28'(o); req.be = 4'b1000 >> o[1:0];
    do cycles(1); while (!rsp.ack);
    d = rsp.rdata[8 * (3 - int'(o[1:0])) +: 8];
    req.req = 0;
    cycles(1);
  endtask

  function automatic logic [2:0] ctl(input bit ch); return ch ? A_CTL : B_CTL; endfunction
  function automatic logic [2:0] dat(input bit ch); return ch ? A_DAT : B_DAT; endfunction

  task automatic wr(input bit ch, input int r, input logic [7:0] d);
    if (r != 0) wr8(ctl(ch), 8'(r & 7) | (r >= 8 ? 8'h08 : 8'h00));
    wr8(ctl(ch), d);
  endtask

  task automatic rd(input bit ch, input int r, output logic [7:0] d);
    if (r != 0) wr8(ctl(ch), 8'(r & 7) | (r >= 8 ? 8'h08 : 8'h00));
    rd8(ctl(ch), d);
  endtask

  task automatic expect_reg(input bit ch, input int r, input logic [7:0] exp, input string what);
    logic [7:0] v;
    rd(ch, r, v);
    check(v == exp, $sformatf("%s: RR%0d%s = %02x, expected %02x", what, r, ch ? "A" : "B", v, exp));
  endtask

  // ---- the line: send a frame into rxd ----
  task automatic send_frame(input bit ch, input logic [7:0] d, input int bit_clks,
                            input int nbits = 8, input bit stop = 1, input bit use_parity = 0, input bit parity = 0);
    // start
    if (ch) rxd_a = 0; else rxd_b = 0;
    cycles(bit_clks);
    for (int i = 0; i < nbits; i++) begin
      if (ch) rxd_a = d[i]; else rxd_b = d[i];
      cycles(bit_clks);
    end
    if (use_parity) begin
      if (ch) rxd_a = parity; else rxd_b = parity;
      cycles(bit_clks);
    end
    if (ch) rxd_a = stop; else rxd_b = stop;
    cycles(bit_clks);
    if (ch) rxd_a = 1; else rxd_b = 1;
    cycles(bit_clks / 2);
  endtask

  // ---- the line: receive a frame from txd, measuring the bit time ----
  task automatic recv_frame(input bit ch, input int bit_clks, output logic [7:0] d, output int frame_clks, input int bound = 100000);
    int n;
    n = 0;
    while ((ch ? txd_a : txd_b) && n < bound) begin cycles(1); n++; end
    check(n < bound, "a start bit arrived");
    frame_clks = 0;
    cycles(bit_clks / 2);  frame_clks += bit_clks / 2;    // middle of the start bit
    check((ch ? txd_a : txd_b) == 0, "start bit low at its middle");
    for (int i = 0; i < 8; i++) begin
      cycles(bit_clks); frame_clks += bit_clks;
      d[i] = ch ? txd_a : txd_b;
    end
    cycles(bit_clks); frame_clks += bit_clks;              // middle of the stop bit
    check((ch ? txd_a : txd_b) == 1, "stop bit high");
    // wait for the line to stay high until the next start, measuring
    n = 0;
    while ((ch ? txd_a : txd_b) && n < 3 * bit_clks) begin cycles(1); n++; end
    frame_clks += n;
  endtask

  // Sun-style asynchronous init: x16, 8 bits, 1 stop, BRG from PCLK, Rx/Tx
  // clocks from the BRG, interrupts on every Rx character and on Tx empty.
  task automatic init_async(input bit ch, input int tc, input logic [7:0] wr4v = 8'h44);
    wr(ch, 4, wr4v);
    wr(ch, 3, 8'hC0);
    wr(ch, 5, 8'h60);
    wr(ch, 11, 8'h50);                 // Rx and Tx clock = BRG
    wr(ch, 12, 8'(tc));
    wr(ch, 13, 8'(tc >> 8));
    wr(ch, 14, 8'h02);                 // BRG source PCLK
    wr(ch, 14, 8'h03);                 // BRG enable
    wr(ch, 3, 8'hC1);                  // Rx enable
    wr(ch, 5, 8'h68);                  // Tx enable
    wr(ch, 15, 8'h00);                 // no external/status sources yet
    wr(ch, 0, 8'h10); wr(ch, 0, 8'h10);
    wr(ch, 1, 8'h12);                  // Rx int on all chars, Tx int
  endtask

  logic [7:0] v, d;
  int fl, n;

  initial begin
    cycles(3);
    rst = 0;
    cycles(3);

    // ---- reset values (Table 7-3) ----
    rd8(A_CTL, v);  check(v == 8'h44, $sformatf("RR0A after reset: Tx empty and underrun (%02x)", v));
    expect_reg(A, 1, 8'h07, "reset");
    expect_reg(A, 3, 8'h00, "reset");
    expect_reg(A, 15, 8'hF8, "reset");
    expect_reg(B, 15, 8'hF8, "reset");
    expect_reg(B, 3, 8'h00, "RR3 reads 0 in channel B");
    check(irq == 0 && rts_a == 0 && dtr_a == 0 && txd_a == 1 && txd_b == 1, "quiet after reset");

    // ---- the pointer is shared and returns to 0 ----
    wr(A, 12, 8'h5A);  wr(A, 13, 8'h01);
    expect_reg(A, 12, 8'h5A, "WR12 reads back as RR12");
    expect_reg(A, 13, 8'h01, "WR13 reads back as RR13");
    wr8(A_CTL, 8'h08 | 8'h04);          // point high + 4 = register 12, set from channel A
    rd8(B_CTL, v);  check(v == 8'h00, "pointer set in A applies to B (RR12B)");
    rd8(B_CTL, v);  check(v == 8'h44, "and is back at 0 (RR0B)");
    wr(B, 2, 8'h20);                    // the vector register, from either channel
    expect_reg(A, 2, 8'h20, "WR2 read in A is the plain vector");
    expect_reg(B, 2, 8'h26, "RR2 in B with nothing pending: status 011");

    // ---- transmit at 38400 (TC 2) ----
    wr(A, 9, 8'hC0);                    // force hardware reset
    cycles(4);
    expect_reg(A, 2, 8'h20, "a hardware reset leaves WR2 (Table 7-3)");
    init_async(A, 2);
    wr(A, 2, 8'h00);
    wr(A, 9, 8'h08);                    // MIE
    rd8(A_CTL, v);  check(v[2] == 1, "Tx buffer empty before sending");
    wr8(A_DAT, 8'h55);
    rd8(A_CTL, v);  check(v[2] == 0, "Tx buffer full right after the write");
    recv_frame(A, BIT38400, d, fl);
    check(d == 8'h55, $sformatf("transmitted 55, got %02x", d));
    check(fl >= 10 * BIT38400 - 4 && fl <= 10 * BIT38400 + 4 + 3 * BIT38400,
          $sformatf("frame of 10 bits at 38400 (%0d clocks)", fl));
    check(irq == 1, "Tx empty interrupt");
    expect_reg(A, 3, 8'h10, "RR3: Tx A IP");
    expect_reg(B, 2, 8'h08, "RR2B: Ch A Tx buffer empty (100)");
    wr(A, 0, 8'h28);                    // Reset Tx INT pending
    check(irq == 0, "Tx IP cleared by the command");
    cycles(12 * BIT38400);
    expect_reg(A, 1, 8'h07, "all sent");
    // two stop bits: an 11-bit frame
    wr(A, 4, 8'h4C);
    wr8(A_DAT, 8'hA3);
    recv_frame(A, BIT38400, d, fl);
    check(d == 8'hA3, "second character");
    check(fl >= 11 * BIT38400 - 4, $sformatf("frame of 11 bits with two stop bits (%0d clocks)", fl));
    wr(A, 0, 8'h28);
    wr(A, 4, 8'h44);
    cycles(2 * BIT38400);
    // back to back: the second character goes in once the buffer empties
    wr8(A_DAT, 8'h0F);
    do rd8(A_CTL, v); while (!v[2]);
    wr8(A_DAT, 8'hF0);
    recv_frame(A, BIT38400, d, fl);  check(d == 8'h0F, "first of two");
    recv_frame(A, BIT38400, d, fl);  check(d == 8'hF0, "second of two");
    wr(A, 0, 8'h28);
    check(irq == 0, "quiet");

    // ---- receive ----
    send_frame(A, 8'hA5, BIT38400);
    rd8(A_CTL, v);  check(v[0] == 1, "Rx character available");
    check(irq == 1, "Rx interrupt");
    expect_reg(A, 3, 8'h20, "RR3: Rx A IP");
    expect_reg(B, 2, 8'h0C, "RR2B: Ch A Rx character available (110)");
    rd8(A_DAT, d);  check(d == 8'hA5, $sformatf("received A5, got %02x", d));
    check(irq == 0, "reading the character clears the interrupt");
    expect_reg(A, 1, 8'h07, "no errors");
    // FIFO of three, in order
    send_frame(A, 8'h11, BIT38400);
    send_frame(A, 8'h22, BIT38400);
    send_frame(A, 8'h33, BIT38400);
    rd8(A_DAT, d);  check(d == 8'h11, "FIFO 1");
    rd8(A_DAT, d);  check(d == 8'h22, "FIFO 2");
    rd8(A_DAT, d);  check(d == 8'h33, "FIFO 3");
    rd8(A_CTL, v);  check(v[0] == 0, "FIFO empty");
    // overrun: a fourth character overwrites the newest; special condition
    send_frame(A, 8'h41, BIT38400);
    send_frame(A, 8'h42, BIT38400);
    send_frame(A, 8'h43, BIT38400);
    send_frame(A, 8'h44, BIT38400);
    rd(A, 1, v);     check(v[5] == 1, "RR1: receiver overrun");
    expect_reg(B, 2, 8'h0E, "RR2B: Ch A special receive condition (111)");
    rd8(A_DAT, d);  check(d == 8'h41, "overrun: oldest kept");
    rd8(A_DAT, d);  check(d == 8'h42, "overrun: second kept");
    rd8(A_DAT, d);  check(d == 8'h44, "overrun: the newest was overwritten");
    rd(A, 1, v);     check(v[5] == 1, "overrun stays latched");
    wr(A, 0, 8'h30);                    // Error Reset
    rd(A, 1, v);     check(v[5] == 0, "Error Reset clears it");
    // framing error travels with its character
    send_frame(A, 8'h77, BIT38400, 8, 0);   // stop bit low
    cycles(2 * BIT38400);
    send_frame(A, 8'h78, BIT38400);
    rd(A, 1, v);     check(v[6] == 1, "RR1: framing error on the top character");
    expect_reg(B, 2, 8'h0E, "framing error is a special condition");
    rd8(A_DAT, d);  check(d == 8'h77, "the character with the framing error");
    rd(A, 1, v);     check(v[6] == 0, "framing error gone with its character");
    rd8(A_DAT, d);  check(d == 8'h78, "the next one");
    expect_reg(B, 2, 8'h06, "nothing pending: 011");

    // ---- break and the external/status interrupt ----
    wr(A, 15, 8'h80);                   // Break/Abort IE
    wr(A, 0, 8'h10); wr(A, 0, 8'h10);
    wr(A, 1, 8'h13);                    // + Ext INT enable
    rxd_a = 0;
    cycles(12 * BIT38400);
    rd8(A_CTL, v);  check(v[7] == 1, "RR0: break");
    check(irq == 1, "break interrupts");
    expect_reg(A, 3, 8'h28, "RR3: Ext A IP (and the null character's Rx IP)");
    // the break's null character carries a framing error: a special receive
    // condition, which outranks Ext A
    expect_reg(B, 2, 8'h0E, "Rx A special outranks Ext A in the vector");
    rd8(A_DAT, d);  check(d == 8'h00, "the break leaves one null character");
    expect_reg(B, 2, 8'h0A, "RR2B: Ch A external/status (101)");
    wr(A, 0, 8'h10);                    // Reset External/Status Interrupts
    check(irq == 0, "ext IP cleared");
    rd8(A_CTL, v);  check(v[7] == 1, "break still on");
    rxd_a = 1;
    cycles(2 * BIT38400);
    rd8(A_CTL, v);  check(v[7] == 0, "break over");
    check(irq == 1, "the end of the break interrupts too");
    wr(A, 0, 8'h10);
    rd8(A_CTL, v);  check(v[0] == 0, "no stray characters after the break");
    // DCD: latched on change when enabled, live otherwise
    wr(A, 15, 8'h08);                   // DCD IE only
    wr(A, 0, 8'h10);
    dcd_a = 1; cycles(3);
    rd8(A_CTL, v);  check(v[3] == 1, "RR0: DCD latched high");
    check(irq == 1, "DCD change interrupts");
    dcd_a = 0; cycles(3);
    rd8(A_CTL, v);  check(v[3] == 1, "latched: still shows the change");
    wr(A, 0, 8'h10);
    rd8(A_CTL, v);  check(v[3] == 0, "after Reset Ext/Status: live");
    check(irq == 0, "quiet");
    wr(A, 15, 8'h00);
    cts_a = 1; cycles(3);
    rd8(A_CTL, v);  check(v[5] == 1 && irq == 0, "CTS not enabled: live, no interrupt");
    cts_a = 0;

    // ---- interrupt control ----
    send_frame(A, 8'h99, BIT38400);
    check(irq == 1, "pending");
    wr(A, 9, 8'h00);                    // MIE off
    check(irq == 0, "MIE off: no INT");
    expect_reg(A, 3, 8'h20, "but RR3 still shows it");
    wr(A, 9, 8'h18);                    // MIE, status high
    check(irq == 1, "MIE on");
    expect_reg(B, 2, 8'h30, "status high: 110 reversed into bits 6:4 (011)");
    wr(A, 9, 8'h08);
    rd8(A_DAT, d);
    // first-character mode: one interrupt per arming
    wr(A, 1, 8'h08);                    // Rx INT on first character
    send_frame(A, 8'h01, BIT38400);
    check(irq == 1, "first character interrupts");
    rd8(A_DAT, d);
    send_frame(A, 8'h02, BIT38400);
    check(irq == 0, "the next one does not");
    rd8(A_DAT, d);  check(d == 8'h02, "but is there");
    wr(A, 0, 8'h20);                    // Enable INT on next Rx character
    send_frame(A, 8'h03, BIT38400);
    check(irq == 1, "re-armed");
    rd8(A_DAT, d);
    wr(A, 1, 8'h12);

    // ---- parity ----
    wr(A, 4, 8'h45);                    // odd parity
    send_frame(A, 8'h41, BIT38400, 8, 1, 1, 1);   // 'A' has two ones: odd parity bit 1
    rd(A, 1, v);     check(v[4] == 0, "good parity");
    rd8(A_DAT, d);  check(d == 8'h41, "parity: data");
    send_frame(A, 8'h41, BIT38400, 8, 1, 1, 0);   // wrong
    rd(A, 1, v);     check(v[4] == 1, "RR1: parity error, latched");
    rd8(A_DAT, d);
    rd(A, 1, v);     check(v[4] == 1, "still latched after the read");
    wr(A, 0, 8'h30);
    rd(A, 1, v);     check(v[4] == 0, "Error Reset clears it");
    // transmitted parity
    wr8(A_DAT, 8'h41);
    begin
      logic p;
      // start, 8 data, parity, stop
      n = 0; while (txd_a && n < 10000) begin cycles(1); n++; end
      cycles(BIT38400 / 2);
      for (int i = 0; i < 8; i++) begin cycles(BIT38400); d[i] = txd_a; end
      cycles(BIT38400); p = txd_a;
      cycles(BIT38400);
      check(d == 8'h41 && p == 1 && txd_a == 1, "transmitted odd parity bit and stop");
    end
    wr(A, 0, 8'h28);
    wr(A, 4, 8'h44);
    cycles(2 * BIT38400);

    // ---- local loopback ----
    wr(A, 14, 8'h13);
    wr8(A_DAT, 8'h3C);
    cycles(14 * BIT38400);
    rd8(A_CTL, v);  check(v[0] == 1, "loopback: character received");
    rd8(A_DAT, d);  check(d == 8'h3C, "loopback: the character sent");
    wr(A, 14, 8'h03);
    wr(A, 0, 8'h28);

    // ---- channel B at 9600, independent, and the channel reset ----
    init_async(B, 14);
    send_frame(B, 8'h5A, BIT9600);
    rd8(B_CTL, v);  check(v[0] == 1, "B: character available");
    rd8(A_CTL, v);  check(v[0] == 0, "A: nothing");
    expect_reg(A, 3, 8'h04, "RR3: Rx B IP");
    expect_reg(B, 2, 8'h04, "RR2B: Ch B Rx (010)");
    rd8(B_DAT, d);  check(d == 8'h5A, "B: the character");
    wr8(B_DAT, 8'hC3);
    recv_frame(B, BIT9600, d, fl);
    check(d == 8'hC3 && fl >= 10 * BIT9600 - 4, "B transmits at 9600");
    check(irq == 1, "B Tx IP");
    wr(B, 9, 8'h40);                    // Channel Reset B
    cycles(4);
    check(irq == 0, "channel reset clears its IPs");
    rd8(B_CTL, v);  check(v == 8'h44, "RR0B back to reset");
    expect_reg(B, 15, 8'hF8, "WR15B back to reset");
    rd8(A_CTL, v);  check(v[2] == 1, "A untouched");
    // the modem outputs
    wr(A, 5, 8'hEA);                    // DTR, RTS, Tx enable
    check(rts_a == 1 && dtr_a == 1, "RTS and DTR follow WR5");
    wr(A, 5, 8'h68);
    check(rts_a == 0 && dtr_a == 0, "and release");

    tb_done("tb_escc");
  end

  initial begin
    #40_000_000;
    $display("FAIL: timeout");
    $fatal(1, "timeout");
  end
endmodule
