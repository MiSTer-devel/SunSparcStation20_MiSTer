// SPDX-License-Identifier: GPL-2.0-or-later
//
// fp_round: normalise, round and pack a wide result to binary32 or
// binary64, with the IEEE exception flags.
//
// From: IEEE 754-1985 §4 (rounding: nearest-even, toward zero, toward
//   +inf, toward -inf), §7.3 overflow (the result is infinity or the
//   largest finite number by rounding mode, always with inexact), §7.4
//   underflow, §7.5 inexact; V8 §4.4 cexc bit order (NV OF UF DZ NX),
//   V8 App. N.5/N.6 and the conventions in tests/fpu/README.md: tininess
//   is detected AFTER rounding (as the SuperSPARC and QEMU do: the result
//   rounded to the precision as if the exponent were unbounded lies below
//   the smallest normal); the UF flag is raised when the result is tiny
//   and inexact, or tiny with the underflow trap enabled. Subnormal
//   results are rounded at their own position: the significand is shifted
//   down first, with the shifted-out bits kept as sticky.
//
// Input: sign, exp and a 58-bit significand whose leading one may be
// anywhere, value = man * 2^(exp - 55) (so a normalised input has its
// leading one at bit 55), plus a sticky bit for everything below.
//
// Two stages: normalisation and the tininess test are registered, the
// rounding and packing follow in the next cycle, so the result appears one
// clock after v_i (dbl_i, rd_i and uf_trap_i must hold for both cycles;
// the FPU keeps them for the whole operation). A tiny result is shifted
// down to the subnormal position in the stage register, a bit a cycle,
// while hold_i is up (busy_o until it is there, at most 58 cycles; tiny
// results are rare and a barrel shifter with its sticky costs ~250 ALUTs).

module fp_round
  import fpu_pkg::*;
(
  input  logic        clk,
  input  fp_wide_t    v_i,
  input  logic        dbl_i,
  input  logic [1:0]  rd_i,
  input  logic        uf_trap_i,     // TEM.UF: tiny alone raises UF
  input  logic        hold_i,        // keep the stage register (denormalise it), do not load
  output logic        busy_o,        // hold_i: the denormalisation is not over
  output logic [63:0] bits_o,        // the single in [63:32]
  output logic [4:0]  flags_o        // NV OF UF DZ NX (NV, DZ are the caller's)
);

  // Round a 58-bit significand (leading one at 57) at the precision,
  // returning the 53-bit rounded significand (left-aligned), the carry
  // out (it became 2.0) and whether anything was dropped.
  function automatic logic round_up_f(input logic [1:0] rd, input logic sgn, input logic lsb,
                                      input logic guard, input logic sticky);
    case (rd)
      RD_NEAREST: return guard && (sticky || lsb);
      RD_PINF:    return (guard || sticky) && !sgn;
      RD_MINF:    return (guard || sticky) && sgn;
      default:    return 1'b0;
    endcase
  endfunction

  // 1. Normalise: leading one to bit 57
  logic [5:0]  lz;
  logic [57:0] mn1;
  logic signed [13:0] en1;
  logic        is_zero1;

  always_comb begin
    lz = 6'd0;
    is_zero1 = v_i.man == '0;
    for (int i = 57; i >= 0; i--) begin
      if (v_i.man[i]) begin lz = 6'(57 - i); break; end
    end
    mn1 = v_i.man << lz;
    en1 = v_i.exp + 14'sd2 - 14'(lz);    // leading one at 57: value = mn * 2^(en - 57)
  end

  // 2. Tininess after rounding: round at the precision as a normal and
  //    look at the exponent that results.
  logic signed [13:0] emin, emax;
  logic [52:0] kept_n;
  logic        guard_n, sticky_n, up_n, carry_n;
  logic        tiny1;

  always_comb begin
    emin = dbl_i ? -14'sd1022 : -14'sd126;
    emax = dbl_i ?  14'sd1023 :  14'sd127;
    if (dbl_i) begin
      kept_n = mn1[57:5]; guard_n = mn1[4]; sticky_n = (|mn1[3:0]) | v_i.sticky;
    end else begin
      kept_n = {mn1[57:34], 29'd0}; guard_n = mn1[33]; sticky_n = (|mn1[32:0]) | v_i.sticky;
    end
    up_n = round_up_f(rd_i, v_i.sign, dbl_i ? kept_n[0] : kept_n[29], guard_n, sticky_n);
    carry_n = up_n && (dbl_i ? (&kept_n) : (&kept_n[52:29]));
    tiny1 = !is_zero1 && ((en1 < emin - 14'sd1) || (en1 == emin - 14'sd1 && !carry_n));
  end

  // The stage register; held, a tiny value moves down a bit a cycle to
  // emin, what falls off into the sticky bit (all of it gone: the
  // exponent no longer matters)
  logic [57:0] mn;
  logic signed [13:0] en;
  logic        is_zero, tiny, sign, sticky_in;
  logic        dn_step;
  assign dn_step = tiny && en < emin && mn != '0;
  assign busy_o  = dn_step;
  always_ff @(posedge clk) begin
    if (!hold_i) begin
      mn <= mn1; en <= en1; is_zero <= is_zero1; tiny <= tiny1;
      sign <= v_i.sign; sticky_in <= v_i.sticky;
    end else if (dn_step) begin
      mn <= mn >> 1; en <= en + 14'sd1; sticky_in <= sticky_in | mn[0];
    end
  end

  // 3. The real rounding (a tiny result is at the subnormal position by
  //    now: the stage register's denormalisation)
  logic [57:0] ms;
  logic        sticky_s;
  logic [52:0] kept;
  logic        guard, sticky;
  logic [52:0] kept_r;
  logic        carry;
  logic signed [13:0] e_r;
  logic        round_up;
  logic        inexact;
  logic        of;

  always_comb begin
    ms = mn;
    sticky_s = sticky_in;
    if (dbl_i) begin
      kept   = ms[57:5];
      guard  = ms[4];
      sticky = (|ms[3:0]) | sticky_s;
    end else begin
      kept   = {ms[57:34], 29'd0};
      guard  = ms[33];
      sticky = (|ms[32:0]) | sticky_s;
    end
    inexact = guard | sticky;
    round_up = round_up_f(rd_i, sign, dbl_i ? kept[0] : kept[29], guard, sticky);
    {carry, kept_r} = {1'b0, kept} + (round_up ? (dbl_i ? 54'd1 : (54'd1 << 29)) : 54'd0);
    e_r = tiny ? emin : en;
    // The significand became 2.0: one more in the exponent. Its kept bits
    // are all zero either way, so they need no renormalising shift (the
    // implicit bit, kept_r[52], is read as carry | kept_r[52] below).
    if (carry) e_r = e_r + 14'sd1;
    of = !is_zero && !tiny && (e_r > emax);
  end

  // 4. Pack
  logic [10:0] ebits;
  logic [51:0] fbits;
  logic        subnormal_out;

  always_comb begin
    flags_o = '0;
    bits_o = '0;
    ebits = '0;
    fbits = '0;
    subnormal_out = tiny && !(kept_r[52] | carry);   // rounding may have made it the smallest normal
    if (is_zero) begin
      bits_o = {sign, 63'd0};
      flags_o[FX_NX] = sticky_in;
    end else if (of) begin
      flags_o[FX_OF] = 1'b1;
      flags_o[FX_NX] = 1'b1;
      case (rd_i)
        RD_ZERO: bits_o = dbl_i ? {sign, 11'h7FE, {52{1'b1}}} : {sign, 8'hFE, {23{1'b1}}, 32'd0};
        RD_PINF: bits_o = sign ? (dbl_i ? {1'b1, 11'h7FE, {52{1'b1}}} : {1'b1, 8'hFE, {23{1'b1}}, 32'd0})
                                   : (dbl_i ? {1'b0, 11'h7FF, 52'd0} : {1'b0, 8'hFF, 23'd0, 32'd0});
        RD_MINF: bits_o = sign ? (dbl_i ? {1'b1, 11'h7FF, 52'd0} : {1'b1, 8'hFF, 23'd0, 32'd0})
                                   : (dbl_i ? {1'b0, 11'h7FE, {52{1'b1}}} : {1'b0, 8'hFE, {23{1'b1}}, 32'd0});
        default: bits_o = dbl_i ? {sign, 11'h7FF, 52'd0} : {sign, 8'hFF, 23'd0, 32'd0};
      endcase
    end else begin
      flags_o[FX_NX] = inexact;
      flags_o[FX_UF] = tiny && (inexact || uf_trap_i);
      if (subnormal_out) begin
        ebits = 11'd0;
      end else begin
        ebits = dbl_i ? 11'(e_r + 14'sd1023) : 11'(e_r + 14'sd127);
      end
      fbits = kept_r[51:0];
      bits_o = dbl_i ? {sign, ebits, fbits} : {sign, ebits[7:0], fbits[51:29], 32'd0};
    end
  end

endmodule
