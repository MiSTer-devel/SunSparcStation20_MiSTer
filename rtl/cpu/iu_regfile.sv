// SPDX-License-Identifier: GPL-2.0-or-later
//
// iu_regfile: the SPARC register file with its windows: 8 globals and
// NWINDOWS x 16 windowed registers (ins, locals, outs), three read ports
// and one write port, in block RAM.
//
// From: The SPARC Architecture Manual V8 §4.1 (windowed r registers: a
//   window's ins r[24..31], locals r[16..23], outs r[8..15]; the outs of
//   window w are the ins of window w-1; %g0 reads 0), docs/arch/cpu.md
//   §1.3 (the mapping: physical = 16*cwp + (r - 8) mod 16*NWINDOWS).
//
// Reads are synchronous: the address is given in one cycle (with the
// window to use), the data is there in the next. A write in the same cycle
// as a read of the same register is forwarded, so the read sees the new
// value (the pipeline's W stage writes while D reads).
//
// Four copies of the RAM, each with the one write port and one read
// port (a Cyclone V M10K is dual-port): 4 x 136 x 32 bits.

module iu_regfile
  import cpu_pkg::*;
(
  input  logic        clk,

  // Read ports: the register number (0-31) and the window to map it in
  input  logic [4:0]  rs1_i,
  input  logic [4:0]  rs2_i,
  input  logic [4:0]  rs3_i,              // store data (rd)
  input  logic [4:0]  rs4_i,              // the second of a pair (rd | 1)
  input  logic [2:0]  rcwp_i,
  output logic [31:0] rs1_o,
  output logic [31:0] rs2_o,
  output logic [31:0] rs3_o,
  output logic [31:0] rs4_o,

  // Write port
  input  logic        we_i,
  input  logic [4:0]  rd_i,
  input  logic [2:0]  wcwp_i,
  input  logic [31:0] wdata_i
);

  localparam int NREG = 8 + 16 * NWINDOWS;   // 136
  localparam int AW = $clog2(NREG);

  // Physical index: globals 0-7 as they are; r8-r31 in window cwp at
  // 8 + (16*cwp + r - 8) mod 128.
  function automatic logic [AW-1:0] phys(input logic [4:0] r, input logic [2:0] cwp);
    logic [6:0] w;
    if (r < 5'd8) return AW'(r);
    w = {cwp, 4'd0} + 7'(r - 5'd8);          // mod 128 by the width
    return AW'(8) + AW'(w);
  endfunction

  logic [AW-1:0] ra1, ra2, ra3, ra4, wa;
  assign ra1 = phys(rs1_i, rcwp_i);
  assign ra2 = phys(rs2_i, rcwp_i);
  assign ra3 = phys(rs3_i, rcwp_i);
  assign ra4 = phys(rs4_i, rcwp_i);
  assign wa  = phys(rd_i, wcwp_i);

  logic we;
  assign we = we_i && rd_i != 5'd0;        // %g0 is never written

  // The RAM copies
  logic [31:0] mem1 [NREG];
  logic [31:0] mem2 [NREG];
  logic [31:0] mem3 [NREG];
  logic [31:0] mem4 [NREG];
  logic [31:0] q1, q2, q3, q4;

  always_ff @(posedge clk) begin
    if (we) mem1[wa] <= wdata_i;
    q1 <= mem1[ra1];
  end
  always_ff @(posedge clk) begin
    if (we) mem2[wa] <= wdata_i;
    q2 <= mem2[ra2];
  end
  always_ff @(posedge clk) begin
    if (we) mem3[wa] <= wdata_i;
    q3 <= mem3[ra3];
  end
  always_ff @(posedge clk) begin
    if (we) mem4[wa] <= wdata_i;
    q4 <= mem4[ra4];
  end

  // Forwarding of a same-cycle write, and %g0
  logic fwd1, fwd2, fwd3, fwd4, z1, z2, z3, z4;
  logic [31:0] wdata_q;
  always_ff @(posedge clk) begin
    fwd1 <= we && wa == ra1;
    fwd2 <= we && wa == ra2;
    fwd3 <= we && wa == ra3;
    fwd4 <= we && wa == ra4;
    z1 <= rs1_i == 5'd0;
    z2 <= rs2_i == 5'd0;
    z3 <= rs3_i == 5'd0;
    z4 <= rs4_i == 5'd0;
    wdata_q <= wdata_i;
  end

  assign rs1_o = z1 ? 32'd0 : fwd1 ? wdata_q : q1;
  assign rs2_o = z2 ? 32'd0 : fwd2 ? wdata_q : q2;
  assign rs3_o = z3 ? 32'd0 : fwd3 ? wdata_q : q3;
  assign rs4_o = z4 ? 32'd0 : fwd4 ? wdata_q : q4;

endmodule
