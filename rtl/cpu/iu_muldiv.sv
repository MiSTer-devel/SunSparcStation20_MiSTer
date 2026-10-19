// SPDX-License-Identifier: GPL-2.0-or-later
//
// iu_muldiv: the SPARC V8 integer multiply and divide: umul/smul(cc) as a
// pipelined 32x32 multiplier (the low word to rd, the high word to Y), and
// udiv/sdiv(cc), the 64-bit (Y:rs1) by 32-bit divide with the saturated
// result and V on overflow, one quotient bit per cycle.
//
// From: The SPARC Architecture Manual V8 §B.18 (multiply: the 64-bit
//   product, Y gets the high word; cc: N and Z from the low word, V = C =
//   0), §B.9 (divide: the dividend is Y:rs1; divide by zero traps, tt 0x2A;
//   an unsigned quotient above 2^32-1 gives 0xFFFFFFFF with V = 1, a signed
//   quotient outside [-2^31, 2^31-1] gives the nearest limit with V = 1;
//   cc: N and Z from the result, V as said, C = 0; the signed quotient is
//   truncated toward zero). The test suite's model agrees
//   (tests/cpu/gen_alu.py; QEMU's sdiv with a negative divisor does not,
//   tests/cpu/README.md deviation 1).
//
// start_i for one cycle with the operation; busy_o until done_o, one
// cycle, with the result. The multiplier takes 4 cycles, the divider 35.

module iu_muldiv (
  input  logic        clk,
  input  logic        rst,

  input  logic        start_i,
  input  logic        kill_i,         // abandon the operation in progress (a trap flushed it)
  input  logic        div_i,          // 0 multiply, 1 divide
  input  logic        signed_i,       // smul / sdiv
  input  logic [31:0] a_i,            // rs1
  input  logic [31:0] b_i,            // rs2 or simm13
  input  logic [31:0] y_i,

  output logic        busy_o,
  output logic        done_o,
  output logic [31:0] r_o,
  output logic [31:0] y_o,            // multiply: the high word; divide: unchanged
  output logic        v_o,            // divide overflow
  output logic        div_zero_o      // tt 0x2A (nothing written)
);

  // ---------------------------------------------------------------------
  // Multiplier: 33x33 signed, so one multiplier serves both forms
  // ---------------------------------------------------------------------
  logic signed [32:0] ma, mb;
  logic signed [65:0] p1;
  logic [3:0] mstage;        // the product is read four edges after start (ma and mb hold
                             // until the next start, so p1 is settled long before)

  always_ff @(posedge clk) begin
    if (rst) begin
      mstage <= '0;
      p1 <= '0;
      ma <= '0; mb <= '0;
    end else begin
      mstage <= kill_i ? 4'b0 : {mstage[2:0], start_i & ~div_i};
      if (start_i & ~div_i) begin
        ma <= {signed_i & a_i[31], a_i};
        mb <= {signed_i & b_i[31], b_i};
      end
      p1 <= ma * mb;
    end
  end

  // ---------------------------------------------------------------------
  // Divider: restoring, on magnitudes
  // ---------------------------------------------------------------------
  logic        drun;
  logic [5:0]  dcnt;
  // nq: the low word of |dividend|, shifted out MSB first, while the
  // quotient bits come in at the bottom: after 32 steps it is the quotient
  logic [31:0] nq;
  logic [31:0] den;          // |divisor|
  logic [31:0] rem;          // the partial remainder (always < den)
  logic        qneg;         // the quotient is negative
  logic        ovf_pre;      // |N| >> 32 >= |D|: the quotient needs more than 32 bits
  logic        dsigned;
  logic        ddone;
  logic        dz;

  logic [63:0] n_abs;
  logic [31:0] d_abs;
  logic        n_neg, d_neg;
  always_comb begin
    n_neg = signed_i & y_i[31];
    d_neg = signed_i & b_i[31];
    n_abs = n_neg ? -{y_i, a_i} : {y_i, a_i};
    d_abs = d_neg ? -b_i : b_i;
  end

  always_ff @(posedge clk) begin
    ddone <= 1'b0;
    dz    <= 1'b0;
    if (rst) begin
      drun <= 1'b0;
      dcnt <= '0;
      nq <= '0; den <= '0; rem <= '0;
      qneg <= 1'b0; ovf_pre <= 1'b0; dsigned <= 1'b0;
    end else if (kill_i) begin
      drun <= 1'b0;
    end else if (start_i & div_i) begin
      if (b_i == 32'd0) begin
        dz <= 1'b1;
      end else begin
        drun    <= 1'b1;
        dcnt    <= 6'd32;
        nq      <= n_abs[31:0];
        den     <= d_abs;
        rem     <= n_abs[63:32];
        qneg    <= n_neg ^ d_neg;
        ovf_pre <= n_abs[63:32] >= d_abs;
        dsigned <= signed_i;
      end
    end else if (drun) begin
      if (dcnt == 6'd0) begin
        drun  <= 1'b0;
        ddone <= 1'b1;
      end else begin : step
        // one subtractor: its borrow is the compare (trial < den)
        logic [32:0] trial;
        /* verilator lint_off UNUSEDSIGNAL */   // diff[32]: 0 whenever it is used (trial >= den)
        logic [33:0] diff;
        /* verilator lint_on UNUSEDSIGNAL */
        trial = {rem, nq[31]};
        diff  = {1'b0, trial} - {2'b00, den};
        rem   <= diff[33] ? trial[31:0] : diff[31:0];
        nq    <= {nq[30:0], ~diff[33]};
        dcnt <= dcnt - 6'd1;
      end
    end
  end

  // The divide result: saturate on overflow, apply the sign
  logic [31:0] dres;
  logic        dovf;
  always_comb begin
    if (!dsigned) begin
      dovf = ovf_pre;
      dres = ovf_pre ? 32'hFFFF_FFFF : nq;
    end else if (qneg) begin
      dovf = ovf_pre || nq > 32'h8000_0000;
      dres = dovf ? 32'h8000_0000 : -nq;
    end else begin
      dovf = ovf_pre || nq > 32'h7FFF_FFFF;
      dres = dovf ? 32'h7FFF_FFFF : nq;
    end
  end

  // ---------------------------------------------------------------------
  // Outputs
  // ---------------------------------------------------------------------
  assign busy_o     = drun | (|mstage);
  assign done_o     = ddone | mstage[3] | dz;
  assign div_zero_o = dz;
  always_comb begin
    if (ddone) begin
      r_o = dres;
      y_o = y_i;
      v_o = dovf;
    end else begin
      r_o = p1[31:0];
      y_o = p1[63:32];
      v_o = 1'b0;
    end
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, p1[65:64]};

endmodule
