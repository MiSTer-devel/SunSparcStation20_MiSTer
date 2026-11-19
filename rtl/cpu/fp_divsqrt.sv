// SPDX-License-Identifier: GPL-2.0-or-later
//
// fp_divsqrt: the significand divide and square root, two result bits per
// cycle (two restoring steps in series: 29 cycles for the 58 bits), on the
// FPU's unpacked operands; exact (a sticky bit says whether the remainder
// was non-zero).
//
// From: IEEE 754-1985 §5 (correctly rounded division and square root:
//   enough quotient bits plus a sticky bit give the exact rounding); the
//   restoring digit recurrences.
//
// Divide: q = floor(a * 2^57 / b), a and b the 53-bit significands in
// [2^52, 2^53): a/b in (1/2, 2), so q in (2^56, 2^58): 58 restoring
// steps, the first (rem - b, no doubling) giving the top bit, a >= b.
// The remainder is kept doubled (rem = 2r): every step is then
// 2 rem - 2b, the first one too (rem loaded with a), so the first needs
// no step of its own; the quotient bits are the same and rem != 0 still
// says whether anything is left.
// Square root: the radicand is a * 2^60 (or a * 2^61 for an odd exponent,
// which makes the exponent even), at most 114 bits; its integer root is
// formed over 58 iterations (two radicand bits each), q in [2^56, 2^57).
// The result goes to fp_round as a 58-bit significand with the exponent
// such that value = q * 2^(exp - 55).

module fp_divsqrt
  import fpu_pkg::*;
(
  input  logic     clk,
  input  logic     rst,
  input  logic     start_i,
  input  logic     sqrt_i,
  input  fp_t      a_i,           // the dividend (rs1)
  input  fp_t      b_i,           // the divisor, or the square root's operand (rs2)
  output logic     busy_o,
  output logic     done_o,
  output fp_wide_t r_o
);

  logic         run, is_sqrt;
  logic [5:0]   cnt;
  logic [61:0]  rem;        // the working remainder
  logic [115:0] rad;        // the radicand still to consume (sqrt)
  logic [57:0]  q;
  logic         sign;
  logic signed [13:0] exp;  // the result's exponent (value = q * 2^(exp - 55))
  // the divisor is kept in rad at the even square root's alignment
  // (rad[112:60]): a divide does not use rad otherwise
  logic [52:0]  den;
  assign den = rad[112:60];

  // One step of either recurrence: sqrt, two radicand bits down minus
  // (4q + 1); divide, 2 rem - 2b (rem doubled, above). Two steps a cycle,
  // the second on the first one's remainder and quotient.
  /* verilator lint_off UNUSEDSIGNAL */   // r1[61] (the second step shifts it out)
  logic [61:0] t1, s1, r1, t2, s2, r2;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [57:0] q1, q2;
  always_comb begin
    t1 = is_sqrt ? {rem[59:0], rad[115:114]} : {rem[60:0], 1'b0};
    s1 = t1 - (is_sqrt ? {2'b00, q, 2'b01} : {8'd0, den, 1'b0});
    r1 = s1[61] ? t1 : s1;
    q1 = {q[56:0], ~s1[61]};
    t2 = is_sqrt ? {r1[59:0], rad[113:112]} : {r1[60:0], 1'b0};
    s2 = t2 - (is_sqrt ? {2'b00, q1, 2'b01} : {8'd0, den, 1'b0});
    r2 = s2[61] ? t2 : s2;
    q2 = {q1[56:0], ~s2[61]};
  end

  always_ff @(posedge clk) begin
    done_o <= 1'b0;
    if (rst) begin                      // (the datapath needs no reset: start_i loads it)
      run <= 1'b0;
      cnt <= '0;
    end else if (start_i) begin
      run <= 1'b1;
      is_sqrt <= sqrt_i;
      if (sqrt_i) begin
        cnt <= 6'd29;
        q <= '0;
        rem <= '0;
        sign <= 1'b0;
        // the square root's operand is rs2 (b)
        // value = q * 2^(exp' - 56) = q * 2^((exp' - 1) - 55)
        if (b_i.exp[0]) begin
          rad <= 116'(b_i.man) << 61;
          exp <= ((b_i.exp - 14'sd1) >>> 1) - 14'sd1;
        end else begin
          rad <= 116'(b_i.man) << 60;
          exp <= (b_i.exp >>> 1) - 14'sd1;
        end
      end else begin
        cnt <= 6'd29;
        sign <= a_i.sign ^ b_i.sign;
        rad <= 116'(b_i.man) << 60;    // den
        rem <= 62'(a_i.man);
        q <= '0;
        // value = q * 2^(ea - eb - 57) = q * 2^((ea - eb - 2) - 55)
        exp <= a_i.exp - b_i.exp - 14'sd2;
      end
    end else if (run) begin
      if (cnt == 6'd0) begin
        run <= 1'b0;
        done_o <= 1'b1;
      end else begin
        cnt <= cnt - 6'd1;
        if (is_sqrt) rad <= rad << 4;
        rem <= r2;
        q <= q2;
      end
    end
  end

  assign busy_o = run;

  always_comb begin
    r_o = '0;
    r_o.sign = sign;
    r_o.man = q;
    r_o.sticky = rem != '0;
    r_o.exp = exp;
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, a_i.zero, a_i.inf, a_i.nan, a_i.snan, b_i.zero, b_i.inf, b_i.nan, b_i.snan};

endmodule
