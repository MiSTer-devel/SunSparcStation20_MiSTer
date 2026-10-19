// SPDX-License-Identifier: GPL-2.0-or-later
//
// Throughput: master 0 streams 4-beat reads into a fixed-latency slave.
// Prints cycles per burst; run with -P tb.L=<latency>.
`timescale 1ns/1ps
module tb;
parameter L = 10;
reg clk=0, reset=1; always #5 clk=~clk;
wire w0,w1; wire [63:0] rd0,rd1; wire v0,v1;
reg r0=0; wire s_wait=0; wire [7:0] s_bc; wire [28:0] s_addr; wire s_rd,s_wr; wire [63:0] s_wd; wire [7:0] s_be;
reg [63:0] s_rdata=0; reg s_rvalid=0;
ddram_arb dut(.clk(clk),.reset(reset),
 .m0_waitrequest(w0),.m0_burstcount(8'd4),.m0_address(29'd0),.m0_read(r0),.m0_write(1'b0),.m0_writedata(64'd0),.m0_byteenable(8'hff),.m0_readdata(rd0),.m0_readdatavalid(v0),
 .m1_waitrequest(w1),.m1_burstcount(8'd1),.m1_address(29'd0),.m1_read(1'b0),.m1_write(1'b0),.m1_writedata(64'd0),.m1_byteenable(8'hff),.m1_readdata(rd1),.m1_readdatavalid(v1),
 .s_waitrequest(s_wait),.s_burstcount(s_bc),.s_address(s_addr),.s_read(s_rd),.s_write(s_wr),.s_writedata(s_wd),.s_byteenable(s_be),.s_readdata(s_rdata),.s_readdatavalid(s_rvalid));
// fixed-latency pipelined slave: data beat k of a command appears L+k cycles after acceptance
integer t=0, q[$]; integer i;
always @(posedge clk) begin t=t+1; s_rvalid<=0;
  if (s_rd && !s_wait) for (i=0;i<4;i=i+1) q.push_back(t+L+i);
  if (q.size() && q[0]<=t) begin void'(q.pop_front()); s_rvalid<=1; end
end
integer bursts=0, beats=0, t0;
always @(posedge clk) if (v0) begin beats=beats+1; if (beats%4==0) bursts=bursts+1; end
initial begin repeat(3) @(posedge clk); reset<=0; r0<=1; t0=t; repeat(10000) @(posedge clk);
  $display("L=%0d: %0.2f cycles per 4-beat burst", L, 10000.0/bursts); $finish; end
endmodule
