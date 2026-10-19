// SPDX-License-Identifier: GPL-2.0-or-later
//
// ram_2r1w_be: a RAM with one byte-enabled write port (B) and two read
// ports (A, and B's own address), one clock, registered outputs (data the
// cycle after the address). The cache data and tag arrays: the lookup
// reads on A while fills, diagnostics and snoops use B. Byte lanes of
// ram_tdp8 with port A never writing: the form Quartus infers as block RAM.

module ram_2r1w_be #(
  parameter int AW = 9,                       // words: 2**AW
  parameter int BYTES = 8                     // bytes per word
)(
  input  logic                clk,

  input  logic [AW-1:0]       a_addr,
  output logic [BYTES*8-1:0]  a_rdata,

  input  logic [AW-1:0]       b_addr,
  input  logic                b_we,
  input  logic [BYTES-1:0]    b_be,
  input  logic [BYTES*8-1:0]  b_wdata,
  output logic [BYTES*8-1:0]  b_rdata
);

  genvar i;
  generate
    for (i = 0; i < BYTES; i++) begin : g_lane
      ram_tdp8 #(.AW(AW)) u (
        .clk,
        .a_addr, .a_we(1'b0), .a_wdata(8'h00), .a_rdata(a_rdata[8*i +: 8]),
        .b_addr, .b_we(b_we & b_be[i]), .b_wdata(b_wdata[8*i +: 8]), .b_rdata(b_rdata[8*i +: 8]));
    end
  endgenerate

endmodule
