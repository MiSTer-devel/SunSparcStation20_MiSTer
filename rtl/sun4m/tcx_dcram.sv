// SPDX-License-Identifier: GPL-2.0-or-later
//
// tcx_dcram: a simple dual-port RAM with its two ports in different clocks:
// one write port (wclk) and one read port (rclk), the read data registered
// (the word at raddr is in rdata the rclk cycle after). The form Quartus
// infers as a dual-clock M10K. The TCX's line buffer, palette and cursor
// bitmaps: written from the machine clock, read in the pixel clock.
//
// A read of a word being written in the other clock returns old or new data
// (the caller never depends on which). Every word powers up 0 (Verilator
// and Quartus both take the initial block); the TCX loads the palette's
// reset values itself.

module tcx_dcram #(
  parameter int AW = 8,
  parameter int DW = 64
)(
  input  logic          wclk,
  input  logic          we,
  input  logic [AW-1:0] waddr,
  input  logic [DW-1:0] wdata,

  input  logic          rclk,
  input  logic [AW-1:0] raddr,
  output logic [DW-1:0] rdata
);

  logic [DW-1:0] mem [2**AW];

  initial begin
    for (int i = 0; i < 2**AW; i++) mem[i] = '0;
  end

  always_ff @(posedge wclk)
    if (we) mem[waddr] <= wdata;

  always_ff @(posedge rclk)
    rdata <= mem[raddr];

endmodule
