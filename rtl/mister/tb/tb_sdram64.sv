// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_sdram64: rtl/mister/sdram64.sv at 55 MHz against two ranks of the
// behavioural SDRAM (sim/sdram_chip.sv, which checks the command protocol
// and timing): random line and doubleword reads and writes with random
// byte enables, checked against a reference memory; the critical
// doubleword first in a line read; refresh happens. After the HP 9000/715
// core's bench of the same controller (same author).

`include "sim/sdram_chip.sv"           // (rtl/tb/run.sh runs from the repository root)

module tb_sdram64;
  import tb_pkg::*;

  logic clk;
  initial clk = 0;
  always #9.0909 clk = ~clk;          // 55 MHz

  logic        rst;
  logic        ready;
  logic        ram_req, ram_we, ram_line;
  logic [26:0] ram_addr;
  logic [7:0]  ram_be;
  logic [63:0] ram_wdata;
  logic        ram_ack, ram_wready, ram_rvalid;
  logic [1:0]  ram_rbeat;
  logic [63:0] ram_rdata;
  wire  [15:0] DQ;
  logic [12:0] A;
  logic [1:0]  BA;
  logic        DQML, DQMH, nCS, nRAS, nCAS, nWE, CKE;
  initial begin
    rst = 1; ram_req = 0; ram_we = 0; ram_line = 0; ram_addr = 0; ram_be = 0; ram_wdata = 0;
  end

  sdram64 #(.CLK_HZ(55_000_000)) dut (
    .clk, .clk_sdram(clk), .rst, .rd_mode(2'd3), .ready,
    .ram_req, .ram_we, .ram_line, .ram_addr, .ram_be, .ram_wdata, .ram_ack, .ram_wready,
    .ram_rvalid, .ram_rbeat, .ram_rdata,
    .SDRAM_DQ(DQ), .SDRAM_A(A), .SDRAM_BA(BA), .SDRAM_DQML(DQML), .SDRAM_DQMH(DQMH),
    .SDRAM_nCS(nCS), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_nWE(nWE), .SDRAM_CKE(CKE));

  sdram_chip #(.INV_CS(0)) rank0 (.clk, .nCS, .nRAS, .nCAS, .nWE, .ba(BA), .a(A),
    .dqmh(DQMH), .dqml(DQML), .dq(DQ), .ctl_drives(dut.dq_oe));
  sdram_chip #(.INV_CS(1)) rank1 (.clk, .nCS, .nRAS, .nCAS, .nWE, .ba(BA), .a(A),
    .dqmh(DQMH), .dqml(DQML), .dq(DQ), .ctl_drives(dut.dq_oe));

  // reference memory over the addresses the test uses
  logic [63:0] ref_mem [int];
  function automatic logic [63:0] ref_rd(input logic [26:3] dw);
    return ref_mem.exists(int'(dw)) ? ref_mem[int'(dw)] : 64'hFFFF_FFFF_FFFF_FFFF;
  endfunction

  // the test's addresses: 2 ranks x 4 banks x 3 rows x 4 lines, plus column bit 9
  function automatic logic [26:0] rnd_line();
    logic [26:0] a;
    a = 27'd0;
    a[26] = 1'($urandom_range(0, 1));
    a[24:23] = 2'($urandom_range(0, 3));
    a[22:10] = 13'($urandom_range(0, 2) * 4099);
    a[25] = 1'($urandom_range(0, 1));
    a[9:5] = 5'($urandom_range(0, 3) * 9);
    return a;
  endfunction

  // The bench drives and samples on the falling edge: the DUT's registered
  // outputs are stable there, and what the bench sets is what the DUT sees
  // at the next rising edge. ram_wready high at a falling edge means the
  // DUT takes ram_wdata at the rising edge that follows.
  task automatic do_write(input logic [26:0] a, input logic line, input logic [7:0] be, input logic [63:0] d [4]);
    int n;
    bit taken;
    @(negedge clk);
    ram_req = 1; ram_we = 1; ram_line = line; ram_addr = a; ram_be = line ? 8'hFF : be;
    ram_wdata = d[0];
    n = 0; taken = 0;
    while (n < (line ? 4 : 1) || taken) begin
      @(negedge clk);
      if (taken && n < 4) ram_wdata = d[n];
      taken = 0;
      if (ram_ack) ram_req = 0;
      if (ram_wready) begin n++; taken = 1; end
      if (n == (line ? 4 : 1) && taken) begin taken = 0; break; end
    end
    ram_req = 0;
    for (int i = 0; i < (line ? 4 : 1); i++) begin
      logic [26:3] dw;
      logic [63:0] m;
      dw = line ? {a[26:5], 2'(i)} : a[26:3];
      m = ref_rd(dw);
      for (int b = 0; b < 8; b++) if (line || be[b]) m[8*b +: 8] = d[i][8*b +: 8];
      ref_mem[int'(dw)] = m;
    end
  endtask

  task automatic do_read(input logic [26:0] a, input logic line);
    int n;
    logic [3:0] seen;
    @(negedge clk);
    ram_req = 1; ram_we = 0; ram_line = line; ram_addr = a;
    n = 0; seen = 0;
    while (n < (line ? 4 : 1)) begin
      @(negedge clk);
      if (ram_ack) ram_req = 0;
      if (ram_rvalid) begin
        logic [26:3] dw;
        if (n == 0) check(ram_rbeat == a[4:3], $sformatf("read %07x: the critical doubleword first", a));
        check(!seen[ram_rbeat], $sformatf("read %07x: beat %0d once", a, ram_rbeat));
        seen[ram_rbeat] = 1'b1;
        dw = {a[26:5], ram_rbeat};
        check(ram_rdata === ref_rd(dw),
              $sformatf("%s read %07x beat %0d: %016x, wanted %016x", line ? "line" : "dw",
                        a, ram_rbeat, ram_rdata, ref_rd(dw)));
        n++;
      end
    end
    ram_req = 0;
  endtask

  initial begin
    logic [63:0] d [4];
    repeat (10) @(negedge clk);
    rst = 0;
    wait (ready);
    for (int it = 0; it < 4000; it++) begin
      logic [26:0] a;
      a = rnd_line();
      a[4:3] = 2'($urandom_range(0, 3));
      for (int i = 0; i < 4; i++) d[i] = {$urandom, $urandom};
      case ($urandom_range(0, 3))
        0: do_write(a, 1'b1, 8'hFF, d);
        1: do_write(a, 1'b0, 8'($urandom_range(1, 255)), d);
        2: do_read(a, 1'b1);
        default: do_read(a, 1'b0);
      endcase
    end
    repeat (20) @(posedge clk);
    check(rank0.errors == 0 && rank1.errors == 0,
          $sformatf("the chips' protocol and timing checks: %0d + %0d errors", rank0.errors, rank1.errors));
    check(rank0.n_refresh > 0 && rank1.n_refresh > 0, "both ranks refreshed");
    tb_done("tb_sdram64");
  end

endmodule
