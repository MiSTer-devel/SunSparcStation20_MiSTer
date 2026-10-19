// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_vram_sdram: the TCX's VRAM on SDRAM (vram_sdram + sdram64 + the
// behavioural chip, sim/sdram_chip.sv) as tcx and tcx_scan drive it:
// scan-out bursts of 32 beats racing doubleword reads and byte-enabled
// writes, all checked against a reference copy of the 1 MB VRAM; Avalon
// rules (a command held while waitrequest; data in order).

`include "sim/sdram_chip.sv"           // (rtl/tb/run.sh runs from the repository root)

module tb_vram_sdram;
  import tb_pkg::*;
  import ss20_ddr_pkg::*;

  logic clk, rst;
  initial begin clk = 0; rst = 1; end
  always #9.0909 clk = ~clk;          // 55 MHz

  localparam logic [28:0] VW = ddr_word(VRAM_BASE);   // the VRAM's first DDR word

  logic [28:0] s_address, v_address;
  logic [7:0]  s_burstcount, v_byteenable;
  logic        s_read, s_waitrequest, s_readdatavalid;
  logic [63:0] s_readdata;
  logic        v_read, v_write, v_waitrequest, v_readdatavalid;
  logic [63:0] v_writedata, v_readdata;
  logic        ram_req, ram_we, ram_line, ram_ack, ram_wready, ram_rvalid, ready;
  logic [26:0] ram_addr;
  logic [7:0]  ram_be;
  logic [63:0] ram_wdata, ram_rdata;
  logic [1:0]  ram_rbeat;
  wire  [15:0] DQ;
  logic [12:0] A;
  logic [1:0]  BA;
  logic        DQML, DQMH, nCS, nRAS, nCAS, nWE, CKE;

  vram_sdram dut (.clk, .rst, .s_address, .s_burstcount, .s_read, .s_waitrequest, .s_readdata,
    .s_readdatavalid, .v_address, .v_read, .v_write, .v_writedata, .v_byteenable, .v_waitrequest,
    .v_readdata, .v_readdatavalid, .ram_req, .ram_we, .ram_line, .ram_addr, .ram_be, .ram_wdata,
    .ram_ack, .ram_wready, .ram_rvalid, .ram_rdata);
  sdram64 #(.CLK_HZ(55_000_000)) u_sd (.clk, .clk_sdram(clk), .rst, .rd_mode(2'd3), .ready,
    .ram_req, .ram_we, .ram_line, .ram_addr, .ram_be, .ram_wdata, .ram_ack, .ram_wready,
    .ram_rvalid, .ram_rbeat, .ram_rdata,
    .SDRAM_DQ(DQ), .SDRAM_A(A), .SDRAM_BA(BA), .SDRAM_DQML(DQML), .SDRAM_DQMH(DQMH),
    .SDRAM_nCS(nCS), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_nWE(nWE), .SDRAM_CKE(CKE));
  // (as the board: the byte masks ignored)
  sdram_chip #(.INV_CS(0), .IGNORE_DQM(1)) rank0 (.clk, .nCS, .nRAS, .nCAS, .nWE, .ba(BA), .a(A),
    .dqmh(DQMH), .dqml(DQML), .dq(DQ), .ctl_drives(u_sd.dq_oe));

  // the reference VRAM (a doubleword not yet written reads all ones, as
  // the chip model's unwritten words do)
  logic [63:0] vref [int];
  function automatic logic [63:0] vrd(input int dw);
    return vref.exists(dw) ? vref[dw] : '1;
  endfunction

  // the scan-out master: a burst of 32 from a 256-byte-aligned address,
  // the command held while waitrequest; its beats checked in order
  // against the reference (the CPU side writes elsewhere meanwhile)
  int s_bursts = 0;
  initial begin s_read = 0; s_address = '0; s_burstcount = 8'd32; end
  logic s_waitrequest_q;
  always @(posedge clk) s_waitrequest_q <= s_waitrequest || !s_read;
  task automatic scan_burst(input int line32);
    int base, got;
    base = line32 * 32; got = 0;
    @(negedge clk);
    s_address = VW + 29'(base); s_burstcount = 8'd32; s_read = 1;
    do @(negedge clk); while (s_waitrequest_q);
    s_read = 0;
    while (got < 32) begin
      if (s_readdatavalid) begin
        check(s_readdata === vrd(base + got),
              $sformatf("scan beat %0d of dw %0d: %016x, wanted %016x", got, base, s_readdata, vrd(base + got)));
        got++;
      end
      @(negedge clk);
    end
    s_bursts++;
  endtask

  // the VRAM master: one doubleword, the command held while waitrequest
  initial begin v_read = 0; v_write = 0; v_address = '0; v_writedata = '0; v_byteenable = '0; end
  task automatic v_wr(input int dw, input logic [63:0] d, input logic [7:0] be);
    logic [63:0] m;
    @(negedge clk);
    v_address = VW + 29'(dw); v_writedata = d; v_byteenable = be; v_write = 1;
    do @(negedge clk); while (v_waitrequest_q);
    v_write = 0;
    m = vrd(dw);
    for (int b = 0; b < 8; b++) if (be[b]) m[8*b +: 8] = d[8*b +: 8];
    vref[dw] = m;
  endtask
  task automatic v_rd(input int dw);
    @(negedge clk);
    v_address = VW + 29'(dw); v_read = 1;
    do @(negedge clk); while (v_waitrequest_q);
    v_read = 0;
    while (!v_readdatavalid) @(negedge clk);
    check(v_readdata === vrd(dw), $sformatf("read dw %0d: %016x, wanted %016x", dw, v_readdata, vrd(dw)));
  endtask
  // waitrequest as seen at the last rising edge (the command was taken there when low)
  logic v_waitrequest_q;
  always @(posedge clk) v_waitrequest_q <= v_waitrequest || !(v_read || v_write);

  initial begin
    repeat (10) @(negedge clk);
    rst = 0;
    wait (ready);
    // fill the first 64 KB with known words, read them back by scan and singly
    for (int dw = 0; dw < 256; dw++) v_wr(dw, {32'(dw), ~32'(dw)}, 8'hFF);
    for (int l = 0; l < 8; l++) scan_burst(l);
    for (int dw = 0; dw < 256; dw += 7) v_rd(dw);
    // random byte writes and reads in dw 1024-1279 while scan bursts read
    // dw 0-255 (written above, not touched now)
    fork
      for (int k = 0; k < 40; k++) scan_burst($urandom_range(0, 7));
      for (int it = 0; it < 3000; it++) begin
        int dw;
        dw = 1024 + $urandom_range(0, 255);
        if ($urandom_range(0, 1) == 0) v_wr(dw, {$urandom, $urandom}, 8'($urandom_range(1, 255)));
        else                           v_rd(dw);
      end
    join
    for (int dw = 1024; dw < 1280; dw++) v_rd(dw);
    repeat (20) @(posedge clk);
    check(rank0.errors == 0, $sformatf("the chip's protocol and timing checks: %0d errors", rank0.errors));
    check(s_bursts == 48, $sformatf("scan bursts done: %0d", s_bursts));
    tb_done("tb_vram_sdram");
  end

endmodule
