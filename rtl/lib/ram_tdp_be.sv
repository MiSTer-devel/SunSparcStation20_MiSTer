// SPDX-License-Identifier: GPL-2.0-or-later
//
// ram_tdp_be: a true dual-port RAM, 32 bits wide with byte enables, one
// clock, registered outputs (data the cycle after the address): four byte
// lanes of ram_tdp8, which is the form Quartus infers as block RAM (a
// byte-enabled two-dimensional array it does not, see ram_tdp8).

module ram_tdp_be #(
  parameter int AW = 11                       // words: 2**AW
)(
  input  logic          clk,

  input  logic [AW-1:0] a_addr,
  input  logic          a_we,
  input  logic [3:0]    a_be,
  input  logic [31:0]   a_wdata,
  output logic [31:0]   a_rdata,

  input  logic [AW-1:0] b_addr,
  input  logic          b_we,
  input  logic [3:0]    b_be,
  input  logic [31:0]   b_wdata,
  output logic [31:0]   b_rdata
);

  genvar i;
  generate
    for (i = 0; i < 4; i++) begin : g_lane
      ram_tdp8 #(.AW(AW)) u (
        .clk,
        .a_addr, .a_we(a_we & a_be[i]), .a_wdata(a_wdata[8*i +: 8]), .a_rdata(a_rdata[8*i +: 8]),
        .b_addr, .b_we(b_we & b_be[i]), .b_wdata(b_wdata[8*i +: 8]), .b_rdata(b_rdata[8*i +: 8]));
    end
  endgenerate

endmodule
