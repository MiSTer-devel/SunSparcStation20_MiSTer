// SPDX-License-Identifier: GPL-2.0-or-later
//
// A master abandons a write burst (reset mid-burst). The arbiter must finish
// the burst with the byte enables off after its watchdog (WTO = 6 here), then
// let the other master through, and the abandoned beats must not write.
`timescale 1ns/1ps
module tb;
reg clk = 0; always #5 clk = ~clk;
reg reset = 1;
reg [7:0] bc0 = 0, bc1 = 0; reg [28:0] a0 = 0, a1 = 0;
reg rd0 = 0, wr0 = 0, rd1 = 0, wr1 = 0; reg [63:0] wd0 = 0, wd1 = 0;
wire w0, w1, v0, v1; wire [63:0] q0, q1;
wire [7:0] s_bc, s_be; wire [28:0] s_addr; wire s_rd, s_wr; wire [63:0] s_wd;
reg [63:0] s_q = 0; reg s_v = 0;
ddram_arb #(.WTO(6)) dut (.clk(clk), .reset(reset),
 .m0_waitrequest(w0), .m0_burstcount(bc0), .m0_address(a0), .m0_read(rd0), .m0_write(wr0), .m0_writedata(wd0), .m0_byteenable(8'hff), .m0_readdata(q0), .m0_readdatavalid(v0),
 .m1_waitrequest(w1), .m1_burstcount(bc1), .m1_address(a1), .m1_read(rd1), .m1_write(wr1), .m1_writedata(wd1), .m1_byteenable(8'hff), .m1_readdata(q1), .m1_readdatavalid(v1),
 .s_waitrequest(1'b0), .s_burstcount(s_bc), .s_address(s_addr), .s_read(s_rd), .s_write(s_wr), .s_writedata(s_wd), .s_byteenable(s_be), .s_readdata(s_q), .s_readdatavalid(s_v));
// slave: burst writes, fixed-latency reads
reg [63:0] mem [0:63]; integer i, wb = 0, wl = 0; reg [28:0] wa; integer rq[$];
initial for (i = 0; i < 64; i = i + 1) mem[i] = 64'h1111_0000_0000_0000 | i;
always @(posedge clk) begin
  s_v <= 0;
  if (s_wr) begin
    if (wb == 0) begin wa = s_addr; wl = s_bc; end
    for (i = 0; i < 8; i = i + 1) if (s_be[i]) mem[(wa + wb) & 63][i*8 +: 8] = s_wd[i*8 +: 8];
    wb = wb + 1; if (wb == wl) wb = 0;
  end
  if (s_rd) rq.push_back(s_addr);
  if (rq.size()) begin s_q <= mem[rq[0] & 63]; s_v <= 1; void'(rq.pop_front()); end
end
integer errors = 0;
initial begin
  repeat (3) @(posedge clk); reset <= 0;
  // master 0: 4-beat write at 8, only 2 beats, then gone
  @(posedge clk); wr0 <= 1; a0 <= 8; bc0 <= 4; wd0 <= 64'hAAAA;
  @(posedge clk); wd0 <= 64'hBBBB;
  @(posedge clk); wr0 <= 0;
  // master 1 wants a write at 20 and a read of 9 meanwhile
  wr1 <= 1; a1 <= 20; bc1 <= 1; wd1 <= 64'hCCCC;
  @(posedge clk); while (w1) @(posedge clk); wr1 <= 0;
  rd1 <= 1; a1 <= 9; bc1 <= 1;
  @(posedge clk); while (w1) @(posedge clk); rd1 <= 0;
  while (!v1) @(posedge clk);
  if (q1 !== 64'hBBBB) begin errors = errors + 1; $display("FAIL read 9 = %h", q1); end
  repeat (4) @(posedge clk);
  if (mem[8]  !== 64'hAAAA) begin errors = errors + 1; $display("FAIL mem[8]  = %h", mem[8]); end
  if (mem[10] !== (64'h1111_0000_0000_0000 | 10)) begin errors = errors + 1; $display("FAIL mem[10] written by the flush: %h", mem[10]); end
  if (mem[11] !== (64'h1111_0000_0000_0000 | 11)) begin errors = errors + 1; $display("FAIL mem[11] written by the flush: %h", mem[11]); end
  if (mem[20] !== 64'hCCCC) begin errors = errors + 1; $display("FAIL mem[20] = %h", mem[20]); end
  $display("abandon: %0d errors", errors);
  if (errors) $display("FAIL"); else $display("PASS");
  $finish;
end
initial begin #200000; $display("FAIL: timeout (deadlock)"); $finish; end
endmodule
