// SPDX-License-Identifier: GPL-2.0-or-later
//
// ram_sdp_bit: a simple dual-port RAM written one bit at a time and read a
// 32-bit word at a time (a mixed-width M10K: 1-bit write port, 32-bit read
// port), one clock, the read registered (data the cycle after the
// address; a read of a word being written returns its old value).
// Written as the Quartus Prime Handbook's mixed-width simple dual-port
// template (the word a packed array of its narrow elements, the write
// indexing one of them).
//
// It holds the SRMMU CAM's bit rows: an entry's bit in a row changes
// without reading the row first.

module ram_sdp_bit #(
  parameter int AW = 4                        // words: 2**AW
)(
  input  logic          clk,
  input  logic [AW+4:0] waddr,                // {word, bit}
  input  logic          we,
  input  logic          wbit,
  input  logic [AW-1:0] raddr,
  output logic [31:0]   rdata
);

  logic [31:0][0:0] mem [0:2**AW-1];

  always_ff @(posedge clk) begin
    if (we) mem[waddr[AW+4:5]][waddr[4:0]] <= wbit;
    rdata <= mem[raddr];
  end

endmodule
