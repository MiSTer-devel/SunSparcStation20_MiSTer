// SPDX-License-Identifier: GPL-2.0-or-later
//
// ram_sdp_be: a simple dual-port RAM of 64-bit words with byte enables,
// one clock: a write port (address, byte enables, data) and a read port
// with a registered output (data the cycle after the address; a read of
// the word being written returns its old value). Written exactly as the
// Quartus Prime Handbook's byte-enabled simple dual-port template (bytes
// a packed dimension, one if per byte, no attribute): a for loop over the
// bytes, or a ramstyle attribute, and Quartus 17 builds it in flip-flops.

module ram_sdp_be #(
  parameter int AW = 4                        // words: 2**AW
)(
  input  logic          clk,
  input  logic [AW-1:0] waddr,
  input  logic          we,
  input  logic [7:0]    be,
  input  logic [63:0]   wdata,
  input  logic [AW-1:0] raddr,
  output logic [63:0]   rdata
);

  logic [7:0][7:0] mem [0:2**AW-1];

  always_ff @(posedge clk) begin
    if (we) begin
      if (be[0]) mem[waddr][0] <= wdata[7:0];
      if (be[1]) mem[waddr][1] <= wdata[15:8];
      if (be[2]) mem[waddr][2] <= wdata[23:16];
      if (be[3]) mem[waddr][3] <= wdata[31:24];
      if (be[4]) mem[waddr][4] <= wdata[39:32];
      if (be[5]) mem[waddr][5] <= wdata[47:40];
      if (be[6]) mem[waddr][6] <= wdata[55:48];
      if (be[7]) mem[waddr][7] <= wdata[63:56];
    end
    rdata <= mem[raddr];
  end

endmodule
