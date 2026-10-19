// SPDX-License-Identifier: GPL-2.0-or-later
//
// fp_unpack: a binary32 or binary64 pattern to the FPU's internal form:
// sign, unbiased exponent, a 53-bit significand (the hidden one at bit 52)
// and the class. A subnormal comes out unnormalised: {0, fraction} with
// the minimum exponent (the same value); the FPU normalises it a bit a
// cycle (subnormal operands are rare: a leading-zero count and a shifter
// here cost ~300 ALUTs).
//
// From: IEEE 754-1985 §3 (the formats: bias 127/1023, exponent all ones
//   = infinity or NaN, all zeros = zero or subnormal), V8 §4.4 (a quiet NaN
//   has the top fraction bit set, a signalling NaN clear).

module fp_unpack
  import fpu_pkg::*;
(
  input  logic        dbl_i,
  input  logic [63:0] bits_i,     // a single in [63:32]
  output fp_t         v_o
);

  logic        sign;
  logic [10:0] e;
  logic [51:0] f;
  logic        e_zero, e_ones, f_zero;

  always_comb begin
    if (dbl_i) begin
      sign = bits_i[63];
      e = bits_i[62:52];
      f = bits_i[51:0];
    end else begin
      sign = bits_i[63];
      e = {3'b0, bits_i[62:55]};
      f = {bits_i[54:32], 29'd0};        // the 23 fraction bits at the top
    end
    e_zero = e == '0;
    e_ones = dbl_i ? (e == 11'h7FF) : (e == 11'h0FF);
    f_zero = f == '0;

    v_o = '0;
    v_o.sign = sign;
    v_o.zero = e_zero & f_zero;
    v_o.inf  = e_ones & f_zero;
    v_o.nan  = e_ones & ~f_zero;
    v_o.snan = e_ones & ~f_zero & ~f[51];
    if (e_zero) begin
      // zero or subnormal: value = f * 2^(emin - 52)
      v_o.man = {1'b0, f};
      v_o.exp = dbl_i ? -14'sd1022 : -14'sd126;
    end else begin
      v_o.man = {1'b1, f};
      v_o.exp = 14'(e) - (dbl_i ? 14'sd1023 : 14'sd127);
    end
    if (v_o.zero || v_o.inf || v_o.nan) v_o.man = {1'b0, f};
  end

endmodule
