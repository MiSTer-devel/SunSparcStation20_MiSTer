// SPDX-License-Identifier: MIT
//
// Vendored from Wish7990 (MIT, rtl/sun4m/LICENSE.wish7990; MelkhiorVintageComputing,
// https://github.com/MelkhiorVintageComputing/Wish7990, commit 8610ef5,
// src/sync_fifo.sv, as pinned by Sun-3_FPGA). Local changes: the module and
// the modules it instantiates take a wish7990_ prefix. See
// rtl/sun4m/lance.sv for how the SS20 uses it.
//
// Simple synchronous FIFO used by the MAC datapath (Tx/Rx staging between the
// Wishbone DMA side and the MII side once both run off the same clock domain).
// DEPTH must be a power of two.

module wish7990_sync_fifo #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 16
) (
    input  logic             clk,
    input  logic             rst,
    input  logic             flush,

    input  logic             wr_en,
    input  logic [WIDTH-1:0] wr_data,
    output logic             full,

    input  logic             rd_en,
    output logic [WIDTH-1:0] rd_data,
    output logic             empty,

    output logic [$clog2(DEPTH):0] level
);

  localparam int AW = $clog2(DEPTH);

  initial begin
    if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0)
      $fatal(1, "sync_fifo: DEPTH must be a power of two >= 2");
  end

  logic [WIDTH-1:0] mem [DEPTH];
  logic [AW:0] wr_ptr, rd_ptr;

  wire do_wr = wr_en && !full;
  wire do_rd = rd_en && !empty;

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
    end else begin
      if (do_wr) wr_ptr <= wr_ptr + 1'b1;
      if (do_rd) rd_ptr <= rd_ptr + 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (do_wr) mem[wr_ptr[AW-1:0]] <= wr_data;
  end

  // First-word-fall-through read port.
  assign rd_data = mem[rd_ptr[AW-1:0]];
  assign empty   = (wr_ptr == rd_ptr);
  assign full    = (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]) && (wr_ptr[AW] != rd_ptr[AW]);
  assign level   = wr_ptr - rd_ptr;

endmodule
