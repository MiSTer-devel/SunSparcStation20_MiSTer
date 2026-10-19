// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_ram_sdp_bit: the bit-write / word-read RAM against a model: random
// writes and reads, a read of the word being written (the old value), and
// every bit of every word written and read back.

module tb_ram_sdp_bit;
  import tb_pkg::*;

  localparam int AW = 4;
  logic          clk;
  logic [AW+4:0] waddr;
  logic          we, wbit;
  logic [AW-1:0] raddr;
  logic [31:0]   rdata;
  logic [31:0]   model [2**AW];
  initial begin clk = 0; we = 0; wbit = 0; waddr = '0; raddr = '0; end
  always #5 clk = ~clk;

  ram_sdp_bit #(.AW(AW)) dut (.clk, .waddr, .we, .wbit, .raddr, .rdata);

  // one cycle: an optional write and a read; the read's data is checked
  // the cycle after against the model as it was before the write
  task automatic cyc(input logic w, input logic [AW+4:0] wa, input logic wb, input logic [AW-1:0] ra);
    logic [31:0] exp;
    we = w; waddr = wa; wbit = wb; raddr = ra;
    exp = model[ra];
    @(posedge clk); #1;
    if (w) model[wa[AW+4:5]][wa[4:0]] = wb;
    we = 1'b0;
    check32(rdata, exp, $sformatf("read word %0d", ra));
  endtask

  initial begin
    // every bit of every word cleared (the RAM starts unknown: no checks
    // yet), then read back
    for (int a = 0; a < 2**AW; a++)
      for (int b = 0; b < 32; b++) begin
        we = 1'b1; waddr = {AW'(a), 5'(b)}; wbit = 1'b0;
        @(posedge clk); #1;
      end
    we = 1'b0;
    for (int a = 0; a < 2**AW; a++) model[a] = '0;
    for (int a = 0; a < 2**AW; a++) cyc(1'b0, '0, 1'b0, AW'(a));
    for (int a = 0; a < 2**AW; a++)
      for (int b = 0; b < 32; b += 3) cyc(1'b1, {AW'(a), 5'(b)}, 1'b1, AW'(a));   // reads the old word
    for (int a = 0; a < 2**AW; a++) cyc(1'b0, '0, 1'b0, AW'(a));
    // random
    for (int i = 0; i < 20000; i++)
      cyc($urandom_range(0, 1) == 1, (AW+5)'($urandom), $urandom_range(0, 1) == 1,
          AW'($urandom));
    tb_done("tb_ram_sdp_bit");
  end

endmodule
