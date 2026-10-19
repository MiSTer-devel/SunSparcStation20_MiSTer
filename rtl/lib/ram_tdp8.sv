// SPDX-License-Identifier: GPL-2.0-or-later
//
// ram_tdp8: a true dual-port RAM, 8 bits wide, one clock, registered
// outputs (data the cycle after the address), a read during a write on the
// same port returning the new data. Exactly the form Quartus infers as a
// block RAM (the Quartus Prime Handbook's "True Dual-Port RAM, single
// clock" template); byte-enabled RAMs are built from lanes of it, because
// Quartus 17 does not infer a byte-enabled true dual-port RAM from a
// two-dimensional array ("unsupported read-during-write behavior").

module ram_tdp8 #(
  parameter int AW = 11                       // bytes: 2**AW
)(
  input  logic          clk,

  input  logic [AW-1:0] a_addr,
  input  logic          a_we,
  input  logic [7:0]    a_wdata,
  output logic [7:0]    a_rdata,

  input  logic [AW-1:0] b_addr,
  input  logic          b_we,
  input  logic [7:0]    b_wdata,
  output logic [7:0]    b_rdata
);

  logic [7:0] mem [2**AW];

  always_ff @(posedge clk) begin
    if (a_we) begin
      mem[a_addr] <= a_wdata;
      a_rdata <= a_wdata;
    end else begin
      a_rdata <= mem[a_addr];
    end
  end

  always_ff @(posedge clk) begin
    if (b_we) begin
      mem[b_addr] <= b_wdata;
      b_rdata <= b_wdata;
    end else begin
      b_rdata <= mem[b_addr];
    end
  end

endmodule
