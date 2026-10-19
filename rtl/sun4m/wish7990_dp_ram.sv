// SPDX-License-Identifier: MIT
//
// Vendored from Wish7990 (MIT, rtl/sun4m/LICENSE.wish7990; MelkhiorVintageComputing,
// https://github.com/MelkhiorVintageComputing/Wish7990, commit 8610ef5,
// src/dp_ram.sv, as pinned by Sun-3_FPGA). Local changes: the module and
// the modules it instantiates take a wish7990_ prefix. See
// rtl/sun4m/lance.sv for how the SS20 uses it.
//
// Simple dual port RAM: one write port, one read port, each with its own
// clock.  The read is registered, which is what block RAM on an FPGA gives
// you.  Used to stage a frame between the command unit filling it from host
// memory and the MII transmitter clocking it out.

module wish7990_dp_ram #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 2048
) (
    input  logic                     wclk,
    input  logic                     wr_en,
    input  logic [$clog2(DEPTH)-1:0] wr_addr,
    input  logic [WIDTH-1:0]         wr_data,

    input  logic                     rclk,
    input  logic [$clog2(DEPTH)-1:0] rd_addr,
    output logic [WIDTH-1:0]         rd_data
);

  logic [WIDTH-1:0] mem [DEPTH];

  always_ff @(posedge wclk) begin
    if (wr_en) mem[wr_addr] <= wr_data;
  end

  always_ff @(posedge rclk) begin
    rd_data <= mem[rd_addr];
  end

endmodule
