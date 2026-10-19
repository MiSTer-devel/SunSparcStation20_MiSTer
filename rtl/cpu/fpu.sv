// SPDX-License-Identifier: GPL-2.0-or-later
//
// fpu: the SPARC V8 floating-point unit of the CPU module (docs/arch/cpu.md
// §2): 32 single registers (pairs for doubles), the FSR, a one-entry
// floating-point queue, the deferred-trap state machine, and a multi-cycle
// datapath: add/sub, multiply, divide, square root, compare, conversions,
// in single and double precision; quad traps as unimplemented.
//
// From: The SPARC Architecture Manual V8 §4.4 (the FSR and the FQ: LDFSR
//   does not touch ftt or qne; every FPop that does not trap clears ftt and
//   sets cexc; an IEEE trap leaves aexc, fcc and the destination alone),
//   §4.5 and App. L/M (the FPU states fp_execute, fp_exception_pending,
//   fp_exception; the trap is taken on a later FP instruction and the FQ
//   holds the faulting FPop's address and word; in fp_exception only FP
//   stores run; an FPop, FP load or FBfcc there is a sequence_error),
//   §B.6-B.10 (the FPop definitions), App. N (the NaN rules: a signalling
//   NaN raises invalid and wins over a quiet one, otherwise rs2's NaN is
//   returned quieted; the default NaN 0x7FFFFFFF... for invalid results;
//   F?TOi out of range gives 0x7FFFFFFF or 0x80000000 by sign, a NaN
//   0x7FFFFFFF), §7 Table 7-1 (fp_exception priority 11); IEEE 754-1985
//   for the arithmetic (fp_round.sv); tests/fpu/README.md for the
//   conventions chosen (tininess after rounding, as the SuperSPARC and
//   QEMU), tests/fpu/vectors as the unit test, tests/cpu/src/t_fpu.S and
//   t_iu2.S (t_fpu_trap_prio, t_fpu_fq) as the acceptance tests.
//
// The IU interface (fpu_pkg: fpu_req_t / fpu_rsp_t, docs/arch/cpu.md
// §1.7): the IU hands an FPop over when it commits it; the FPU is busy
// while it executes and the IU holds every later FP instruction. The IU
// reads the registers for FP stores (rd_addr), writes them for FP loads,
// writes the FSR (ldfsr), pops the queue (stdfq). exc_pending says a
// deferred fp_exception waits: the IU traps on its next FP instruction
// and reports trap_taken, and the FPU enters fp_exception; the IU also
// reports trap_taken for a sequence error it detected (an FPop/FBfcc/FP
// load in fp_exception, an stdfq on an empty queue): then ftt <- 4.

module fpu
  import fpu_pkg::*;
(
  input  logic     clk,
  input  logic     rst,
  input  fpu_req_t req_i,
  output fpu_rsp_t rsp_o
);

  // ---------------------------------------------------------------------
  // Registers: 16 pairs, as two 16 x 32 halves (even, odd register) in
  // MLAB with asynchronous reads, one copy per read port (the store's rd,
  // the FPop's rs1 and rs2): in flops with 16:1 muxes they cost ~1k ALMs.
  // One write port: the IU serialises FP instructions and holds an FP load
  // while the FPU is busy (dp_wr included), so a load and the datapath
  // never write in the same cycle (the datapath would win).
  // ---------------------------------------------------------------------
  logic        dp_wr;                  // the datapath's write: the latched FPop's rd and result
  logic [4:0]  dp_wr_addr;             // (they hold until the next FPop, which waits for dp_wr)
  logic        dp_wr_dbl;
  logic [63:0] dp_wr_data;             // a single in [63:32]

  logic        rf_we_hi, rf_we_lo;
  logic [3:0]  rf_wa;
  logic [31:0] rf_wd_hi, rf_wd_lo;
  logic        rf_we, rf_dbl, rf_odd;
  logic [63:0] rf_d;                   // a double, or the single in [31:0]
  always_comb begin
    if (dp_wr) begin
      rf_we = 1'b1; rf_wa = dp_wr_addr[4:1]; rf_dbl = dp_wr_dbl; rf_odd = dp_wr_addr[0];
      rf_d = dp_wr_dbl ? dp_wr_data : {32'd0, dp_wr_data[63:32]};
    end else begin
      rf_we = req_i.wr_valid; rf_wa = req_i.wr_addr[4:1]; rf_dbl = req_i.wr_dbl; rf_odd = req_i.wr_addr[0];
      rf_d = req_i.wr_data;
    end
    rf_we_hi = rf_we && (rf_dbl || !rf_odd);
    rf_we_lo = rf_we && (rf_dbl || rf_odd);
    rf_wd_hi = rf_dbl ? rf_d[63:32] : rf_d[31:0];
    rf_wd_lo = rf_d[31:0];
  end

  // (module-level arrays: Quartus ignores ramstyle on arrays declared in a
  // generate block)
  logic [3:0]  rf_ra [3];
  logic [63:0] rf_rd [3];
  (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] rf_hi0 [16];
  (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] rf_lo0 [16];
  (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] rf_hi1 [16];
  (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] rf_lo1 [16];
  (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] rf_hi2 [16];
  (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] rf_lo2 [16];
  always_ff @(posedge clk) begin
    if (rf_we_hi) begin rf_hi0[rf_wa] <= rf_wd_hi; rf_hi1[rf_wa] <= rf_wd_hi; rf_hi2[rf_wa] <= rf_wd_hi; end
    if (rf_we_lo) begin rf_lo0[rf_wa] <= rf_wd_lo; rf_lo1[rf_wa] <= rf_wd_lo; rf_lo2[rf_wa] <= rf_wd_lo; end
  end
  assign rf_rd[0] = {rf_hi0[rf_ra[0]], rf_lo0[rf_ra[0]]};
  assign rf_rd[1] = {rf_hi1[rf_ra[1]], rf_lo1[rf_ra[1]]};
  assign rf_rd[2] = {rf_hi2[rf_ra[2]], rf_lo2[rf_ra[2]]};

  // ---------------------------------------------------------------------
  // FSR, the queue, the state
  // ---------------------------------------------------------------------
  logic [1:0] fsr_rd;
  logic [4:0] fsr_tem, fsr_aexc, fsr_cexc;
  logic [2:0] fsr_ftt;
  logic [1:0] fsr_fcc;
  logic [63:0] fq;                     // the latched FPop: frozen while qne (no FPop runs
                                       // in fp_exception_pending or fp_exception)
  logic        qne;

  typedef enum logic [1:0] {FP_EXECUTE, FP_PENDING, FP_EXCEPTION} fstate_t;
  fstate_t state;

  typedef enum logic [2:0] {S_IDLE, S_NORM, S_START, S_WAIT, S_ROUND, S_DONE} exstate_t;
  exstate_t ex;

  always_comb begin
    rsp_o = '0;
    rsp_o.busy        = (ex != S_IDLE) | dp_wr;
    rsp_o.exc_pending = state == FP_PENDING;
    rsp_o.exc_state   = state == FP_EXCEPTION;
    rsp_o.rd_data     = rf_rd[0];
    rsp_o.fsr         = {fsr_rd, 2'b00, fsr_tem, 1'b0, 2'b00, 3'b000, fsr_ftt, qne, 1'b0, fsr_fcc, fsr_aexc, fsr_cexc};
    rsp_o.fq          = fq;
  end

  // ---------------------------------------------------------------------
  // The FPop: decode
  // ---------------------------------------------------------------------
  logic [8:0] opf;
  logic [4:0] rd;
  logic       is_fpop2;
  assign opf = req_i.fpop_inst[13:5];
  assign rd  = req_i.fpop_inst[29:25];
  assign is_fpop2 = req_i.fpop_inst[19];        // op3 0x35

  typedef enum logic [3:0] {
    O_MOV, O_NEG, O_ABS, O_ADD, O_SUB, O_MUL, O_DIV, O_SQRT, O_CMP, O_CMPE,
    O_ITOF, O_FTOI, O_FTOF, O_UNIMPL
  } fop_t;

  fop_t       op;
  logic       src_dbl, dst_dbl;        // operand / result precision

  always_comb begin
    op = O_UNIMPL; src_dbl = 1'b0; dst_dbl = 1'b0;
    case (opf)
      OPF_FMOVS:  op = O_MOV;
      OPF_FNEGS:  op = O_NEG;
      OPF_FABSS:  op = O_ABS;
      OPF_FSQRTS: op = O_SQRT;
      OPF_FSQRTD: begin op = O_SQRT; src_dbl = 1'b1; dst_dbl = 1'b1; end
      OPF_FADDS:  op = O_ADD;
      OPF_FADDD:  begin op = O_ADD; src_dbl = 1'b1; dst_dbl = 1'b1; end
      OPF_FSUBS:  op = O_SUB;
      OPF_FSUBD:  begin op = O_SUB; src_dbl = 1'b1; dst_dbl = 1'b1; end
      OPF_FMULS:  op = O_MUL;
      OPF_FMULD:  begin op = O_MUL; src_dbl = 1'b1; dst_dbl = 1'b1; end
      OPF_FSMULD: begin op = O_MUL; src_dbl = 1'b0; dst_dbl = 1'b1; end
      OPF_FDIVS:  op = O_DIV;
      OPF_FDIVD:  begin op = O_DIV; src_dbl = 1'b1; dst_dbl = 1'b1; end
      OPF_FITOS:  op = O_ITOF;
      OPF_FITOD:  begin op = O_ITOF; dst_dbl = 1'b1; end
      OPF_FSTOI:  op = O_FTOI;
      OPF_FDTOI:  begin op = O_FTOI; src_dbl = 1'b1; end
      OPF_FSTOD:  begin op = O_FTOF; dst_dbl = 1'b1; end
      OPF_FDTOS:  begin op = O_FTOF; src_dbl = 1'b1; end
      OPF_FCMPS:  op = O_CMP;
      OPF_FCMPD:  begin op = O_CMP; src_dbl = 1'b1; end
      OPF_FCMPES: op = O_CMPE;
      OPF_FCMPED: begin op = O_CMPE; src_dbl = 1'b1; end
      default:    op = O_UNIMPL;         // the quad forms and anything else
    endcase
    if (is_fpop2 && !(op == O_CMP || op == O_CMPE)) op = O_UNIMPL;
    if (!is_fpop2 && (op == O_CMP || op == O_CMPE)) op = O_UNIMPL;
  end

  // Operands: the pair, a single taken from its half into [63:32]. Idle,
  // the registers the FPop presented names; running, the latched FPop's
  // (the registers do not change until its result is written), so the
  // operand patterns are read again rather than kept. Both operands are
  // unpacked as the FPop is taken (two unpackers).
  logic [63:0] a_bits, b_bits, a_pair, b_pair;
  logic        idle, o_dbl, o_a_odd, o_b_odd;
  logic [4:0]  o_rs1, o_rs2;
  assign idle    = ex == S_IDLE;
  assign o_rs1   = idle ? req_i.fpop_inst[18:14] : c_inst[18:14];
  assign o_rs2   = idle ? req_i.fpop_inst[4:0] : c_inst[4:0];
  assign o_dbl   = idle ? src_dbl : c_src_dbl;
  assign o_a_odd = o_rs1[0];
  assign o_b_odd = o_rs2[0];
  assign rf_ra[0] = req_i.rd_addr[4:1];
  assign rf_ra[1] = o_rs1[4:1];
  assign rf_ra[2] = o_rs2[4:1];
  assign a_pair = rf_rd[1];
  assign b_pair = rf_rd[2];
  always_comb begin
    a_bits = o_dbl ? a_pair : (o_a_odd ? {a_pair[31:0], 32'd0} : {a_pair[63:32], 32'd0});
    b_bits = o_dbl ? b_pair : (o_b_odd ? {b_pair[31:0], 32'd0} : {b_pair[63:32], 32'd0});
  end

  // Two unpackers: rs2's and rs1's operands both as the FPop is taken
  fp_t u_v, u_va;
  fp_unpack u_unp  (.dbl_i(o_dbl), .bits_i(b_bits), .v_o(u_v));
  fp_unpack u_unpa (.dbl_i(o_dbl), .bits_i(a_bits), .v_o(u_va));

  logic two_op;
  assign two_op = op == O_ADD || op == O_SUB || op == O_MUL || op == O_DIV || op == O_CMP || op == O_CMPE;

  // A subnormal operand is normalised in S_NORM, a bit a cycle
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic denorm(input fp_t v);
    return !v.man[52] && !v.zero && !v.inf && !v.nan;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // ---------------------------------------------------------------------
  // The execution: a small state machine around the datapath
  // ---------------------------------------------------------------------
  // Latched operation
  fop_t        c_op;
  logic        c_src_dbl, c_dst_dbl;
  logic [4:0]  c_rd;
  logic [31:0] c_inst, c_pc;
  fp_t         c_a, c_b;
  logic        c_two;                  // a two-operand op: c_a is an operand
  logic [63:0] c_a_bits, c_b_bits;     // = a_bits, b_bits while running
  assign c_a_bits = a_bits;
  assign c_b_bits = b_bits;

  // Datapath results
  fp_wide_t    wide;                   // what goes to the rounder
  logic [63:0] res_bits;               // a direct result (NaN, inf, zero, compare, moves)
  logic [4:0]  res_flags;
  logic        res_direct;             // res_bits is final (no rounding)
  logic [1:0]  res_fcc;
  logic        res_is_cmp;

  // Rounder
  logic [63:0] rnd_bits;
  logic [4:0]  rnd_flags;
  fp_wide_t    wide_q;
  logic [63:0] res_bits_q;
  logic [4:0]  res_flags_q;
  logic        res_direct_q, res_is_cmp_q;
  logic [1:0]  res_fcc_q;
  logic     rnd_busy;
  fp_round u_round (.clk, .v_i(wide_q), .dbl_i(c_dst_dbl), .rd_i(fsr_rd), .uf_trap_i(fsr_tem[FX_UF]),
                    .hold_i(ex == S_ROUND), .busy_o(rnd_busy),
                    .bits_o(rnd_bits), .flags_o(rnd_flags));

  // Divide / square root
  logic     ds_start, ds_busy, ds_done;
  fp_wide_t ds_r;
  fp_divsqrt u_ds (.clk, .rst, .start_i(ds_start), .sqrt_i(c_op == O_SQRT), .a_i(c_a), .b_i(c_b),
                   .busy_o(ds_busy), .done_o(ds_done), .r_o(ds_r));

  // Multiply: 53x53, registered (c_a and c_b hold for the whole operation:
  // the product is settled one cycle after S_START, well before it is used)
  // the product's top 58 bits and whether the low 48 are non-zero (they
  // only feed the sticky bit: one register, not 48; the low bits settle
  // first)
  logic [105:0] mul_p;
  logic [105:48] mul_p1;
  logic         mul_p1_lo;
  assign mul_p = c_a.man * c_b.man;
  always_ff @(posedge clk) begin
    mul_p1    <= mul_p[105:48];
    mul_p1_lo <= |mul_p[47:0];
  end

  // Add/sub: align to the larger exponent, 58-bit significands with the
  // leading one at 55 (three guard bits below), a sticky for what falls
  // off; the sticky enters the sum as a half-ulp below so that a
  // subtraction borrows (the result's bit 0 is then the new sticky).
  // Two stages, align then add, each registered: the operands hold for
  // the whole operation, so each register settles one cycle after the
  // one before it (the state machine's wait covers them).
  logic        sub_eff1, a_bigger1, al_sticky1;
  logic signed [13:0] e_big1;
  logic [57:0] ma, mb, m_big1, m_small, m_small_al1;
  logic [13:0] ediff;
  // F?TOi uses the same shifter: rs2's significand down by 52 - exp
  // (below, with the result in m_small_al[34:3]).
  logic        al_b;                   // shift b
  always_comb begin
    // (a compare subtracts too: with equal signs a == b is then sum == 0)
    sub_eff1 = (c_op == O_SUB || c_op == O_CMP || c_op == O_CMPE) ^ c_a.sign ^ c_b.sign;
    a_bigger1 = (c_a.exp > c_b.exp) || (c_a.exp == c_b.exp && c_a.man >= c_b.man);
    al_b = a_bigger1 || c_op == O_FTOI;
    ma = {2'b0, c_a.man, 3'b0};
    mb = {2'b0, c_b.man, 3'b0};
    e_big1  = a_bigger1 ? c_a.exp : c_b.exp;
    m_big1  = a_bigger1 ? ma : mb;
    m_small = al_b ? mb : ma;
    if (c_op == O_FTOI) ediff = 14'sd52 - c_b.exp;
    else ediff = 14'(a_bigger1 ? (c_a.exp - c_b.exp) : (c_b.exp - c_a.exp));
    al_sticky1 = 1'b0;
    if (ediff > 14'd60) begin
      m_small_al1 = '0;
      al_sticky1 = m_small != '0;
    end else begin
      // a shifter in six stages, each ORing what it drops into the sticky:
      // the OR of m_small[ediff-1:0] without a 58-way compare
      m_small_al1 = m_small;
      for (int k = 0; k < 6; k++)
        if (ediff[k]) begin
          al_sticky1  = al_sticky1 | (|(m_small_al1 & ((58'd1 << (1 << k)) - 58'd1)));
          m_small_al1 = m_small_al1 >> (1 << k);
        end
    end
  end

  logic        sub_eff, a_bigger, al_sticky;
  logic signed [13:0] e_big;
  logic [57:0] m_big, m_small_al;
  logic [58:0] sum;
  always_ff @(posedge clk) begin
    sub_eff <= sub_eff1; a_bigger <= a_bigger1; al_sticky <= al_sticky1;
    e_big <= e_big1; m_big <= m_big1; m_small_al <= m_small_al1;
    if (sub_eff) sum <= {m_big, 1'b0} - {m_small_al, al_sticky};
    else         sum <= {m_big, 1'b0} + {m_small_al, al_sticky};
  end

  // NaN handling (V8 App. N): a signalling NaN wins, else rs2's; quieted
  function automatic logic [63:0] quiet(input logic [63:0] bits, input logic dbl);
    return dbl ? (bits | 64'h0008_0000_0000_0000) : (bits | 64'h0040_0000_0000_0000);
  endfunction
  // widen or narrow a NaN pattern between the precisions (the fraction's top bits are kept)
  function automatic logic [63:0] conv_nan(input logic [63:0] bits, input logic sd, input logic dd);
    if (sd == dd) return bits;
    if (dd) return {bits[63], 11'h7FF, bits[54:32], 29'd0};
    return {bits[63], 8'hFF, bits[51:29], 32'd0};
  endfunction
  // the NaN result of a two-operand op in the source precision
  logic [63:0] nan2;
  always_comb begin
    if (c_src_dbl != c_dst_dbl)              // fsmuld: both operands widened first (QEMU)
      nan2 = c_b.nan ? c_b_bits : c_a_bits;
    else if (c_b.snan)                       nan2 = c_b_bits;
    else if (c_a.snan)                       nan2 = c_a_bits;
    else if (c_b.nan)                        nan2 = c_b_bits;
    else                                     nan2 = c_a_bits;
  end

  // Integer conversions
  logic [31:0] itof_abs;
  logic [31:0] ftoi_iv;
  logic        ftoi_inexact;
  always_comb begin
    itof_abs = c_b_bits[63] ? (32'd0 - c_b_bits[63:32]) : c_b_bits[63:32];
    // value = man * 2^(exp - 52), 0 <= exp <= 31: integer part = man >> (52 - exp),
    // from the aligner ({man, 3'b0} shifted: the integer at [34:3], what fell off
    // in [2:0] and the sticky)
    ftoi_iv = m_small_al[34:3];
    ftoi_inexact = al_sticky | (|m_small_al[2:0]);
  end

  // The rounder's operand, by the op alone: with a direct result (NaN, inf,
  // zero operands) the rounder's answer is not used (f_bits/f_flags take
  // res_*_q and S_ROUND does not wait for rnd_busy), so those cases need not
  // be in this mux.
  always_comb begin
    wide = '0;
    case (c_op)
      O_ADD, O_SUB: begin
        // an exact cancellation (sum == 0): +0, -0 in round-to-minus
        wide.exp    = e_big;
        wide.sign   = (sum == '0) ? (fsr_rd == RD_MINF) : (a_bigger ? c_a.sign : (c_b.sign ^ (c_op == O_SUB)));
        wide.man    = sum[58:1];
        wide.sticky = sum[0];
      end
      O_MUL: begin
        // p = man_a * man_b in [2^104, 2^106): value = p * 2^(ea + eb - 104);
        // the top 58 bits, the rest sticky: man * 2^(ea + eb - 56) = man * 2^(exp - 55)
        wide.sign   = c_a.sign ^ c_b.sign;
        wide.man    = mul_p1[105:48];
        wide.sticky = mul_p1_lo;
        wide.exp    = c_a.exp + c_b.exp - 14'sd1;
      end
      O_DIV, O_SQRT: wide = ds_r;
      O_ITOF: begin
        // the 32-bit integer in b_bits[63:32]: value = |i| * 2^(55 - 55)
        wide.sign   = c_b_bits[63];
        wide.man    = 58'(itof_abs);
        wide.exp    = 14'sd55;
        wide.sticky = 1'b0;
      end
      O_FTOF: begin
        wide.sign   = c_b.sign;
        wide.man    = {2'b0, c_b.man, 3'b0};    // leading one at 55: value = man * 2^(exp - 55)
        wide.exp    = c_b.exp;
        wide.sticky = 1'b0;
      end
      default: ;
    endcase
  end

  // The direct results, per op, as a small datapath: an operand (a, b or
  // the NaN rule's choice; a NaN converted to the result precision and
  // quieted; its sign kept, flipped or cleared), a constant in the result
  // precision ({sign, exponent all ones or zero, fraction all ones or
  // zero}: the default NaN, an infinity, a zero; FTOI's saturations are
  // the single default NaN and -0), or FTOI's integer. Each op's rules
  // below only choose; the result is formed once (a priority chain of ~30
  // 64-bit inputs before).
  typedef enum logic [1:0] {RK_CONST, RK_OPND, RK_INT} rkind_t;
  typedef enum logic [1:0] {SEL_A, SEL_B, SEL_NAN2} rsel_t;
  typedef enum logic [1:0] {SG_KEEP, SG_FLIP, SG_CLR} rsgn_t;
  rkind_t r_kind;
  rsel_t  r_sel;
  rsgn_t  r_sgn;
  logic   r_fix, r_cs, r_ce, r_cf;
  logic [63:0] r_opnd;
  always_comb begin
    case (r_sel)
      SEL_A:   r_opnd = c_a_bits;
      SEL_B:   r_opnd = c_b_bits;
      default: r_opnd = nan2;
    endcase
    // (ADD/SUB/DIV/SQRT have src == dst: conv_nan is the identity there)
    if (r_fix) r_opnd = quiet(conv_nan(r_opnd, c_src_dbl, c_dst_dbl), c_dst_dbl);
    case (r_sgn)
      SG_FLIP: r_opnd[63] = ~r_opnd[63];
      SG_CLR:  r_opnd[63] = 1'b0;
      default: ;
    endcase
    case (r_kind)
      RK_OPND: res_bits = r_opnd;
      RK_INT:  res_bits = {c_b.sign ? (32'd0 - ftoi_iv) : ftoi_iv, 32'd0};
      default: res_bits = c_dst_dbl ? {r_cs, {11{r_ce}}, {52{r_cf}}} : {r_cs, {8{r_ce}}, {23{r_cf}}, 32'd0};
    endcase
  end

  // ... and the rules, per op
  always_comb begin
    r_kind = RK_CONST; r_sel = SEL_B; r_fix = 1'b0; r_sgn = SG_KEEP;
    r_cs = 1'b0; r_ce = 1'b0; r_cf = 1'b0;        // (+0)
    res_flags = '0;
    res_direct = 1'b0;
    res_fcc = 2'd0;
    res_is_cmp = 1'b0;
    case (c_op)
      O_MOV: begin res_direct = 1'b1; r_kind = RK_OPND; r_sel = SEL_B; end
      O_NEG: begin res_direct = 1'b1; r_kind = RK_OPND; r_sel = SEL_B; r_sgn = SG_FLIP; end
      O_ABS: begin res_direct = 1'b1; r_kind = RK_OPND; r_sel = SEL_B; r_sgn = SG_CLR; end

      O_ADD, O_SUB: begin
        if (c_a.nan || c_b.nan) begin
          res_direct = 1'b1;
          res_flags[FX_NV] = c_a.snan | c_b.snan;
          r_kind = RK_OPND; r_sel = SEL_NAN2; r_fix = 1'b1;
        end else if (c_a.inf && c_b.inf) begin
          res_direct = 1'b1;
          if (sub_eff) begin res_flags[FX_NV] = 1'b1; r_ce = 1'b1; r_cf = 1'b1; end
          else r_cs = c_a.sign; r_ce = 1'b1;
        end else if (c_a.inf) begin res_direct = 1'b1; r_cs = c_a.sign; r_ce = 1'b1; end
        else if (c_b.inf) begin res_direct = 1'b1; r_cs = c_b.sign ^ (c_op == O_SUB); r_ce = 1'b1; end
        else if (c_a.zero && c_b.zero) begin
          res_direct = 1'b1;
          // the sum of two zeros: the common sign, else +0 (-0 in round-to-minus)
          if (sub_eff) r_cs = fsr_rd == RD_MINF;
          else         r_cs = c_a.sign;
        end else if (c_a.zero) begin res_direct = 1'b1; r_kind = RK_OPND; r_sel = SEL_B; r_sgn = (c_op == O_SUB) ? SG_FLIP : SG_KEEP; end
        else if (c_b.zero) begin res_direct = 1'b1; r_kind = RK_OPND; r_sel = SEL_A; end
      end

      O_MUL: begin
        if (c_a.nan || c_b.nan) begin
          res_direct = 1'b1;
          res_flags[FX_NV] = c_a.snan | c_b.snan;
          r_kind = RK_OPND; r_sel = SEL_NAN2; r_fix = 1'b1;
        end else if ((c_a.inf && c_b.zero) || (c_a.zero && c_b.inf)) begin
          res_direct = 1'b1; res_flags[FX_NV] = 1'b1; r_ce = 1'b1; r_cf = 1'b1;
        end else if (c_a.inf || c_b.inf) begin
          res_direct = 1'b1; r_cs = c_a.sign ^ c_b.sign; r_ce = 1'b1;
        end else if (c_a.zero || c_b.zero) begin
          res_direct = 1'b1; r_cs = c_a.sign ^ c_b.sign;
        end
      end

      O_DIV: begin
        if (c_a.nan || c_b.nan) begin
          res_direct = 1'b1;
          res_flags[FX_NV] = c_a.snan | c_b.snan;
          r_kind = RK_OPND; r_sel = SEL_NAN2; r_fix = 1'b1;
        end else if ((c_a.inf && c_b.inf) || (c_a.zero && c_b.zero)) begin
          res_direct = 1'b1; res_flags[FX_NV] = 1'b1; r_ce = 1'b1; r_cf = 1'b1;
        end else if (c_a.inf) begin res_direct = 1'b1; r_cs = c_a.sign ^ c_b.sign; r_ce = 1'b1; end
        else if (c_b.inf) begin res_direct = 1'b1; r_cs = c_a.sign ^ c_b.sign; end
        else if (c_b.zero) begin
          res_direct = 1'b1; res_flags[FX_DZ] = 1'b1; r_cs = c_a.sign ^ c_b.sign; r_ce = 1'b1;
        end else if (c_a.zero) begin res_direct = 1'b1; r_cs = c_a.sign ^ c_b.sign; end
      end

      O_SQRT: begin
        if (c_b.nan) begin
          res_direct = 1'b1; res_flags[FX_NV] = c_b.snan; r_kind = RK_OPND; r_sel = SEL_B; r_fix = 1'b1;
        end else if (c_b.zero) begin res_direct = 1'b1; r_kind = RK_OPND; r_sel = SEL_B; end
        else if (c_b.sign) begin res_direct = 1'b1; res_flags[FX_NV] = 1'b1; r_ce = 1'b1; r_cf = 1'b1; end
        else if (c_b.inf) begin res_direct = 1'b1; r_kind = RK_OPND; r_sel = SEL_B; end
      end

      O_CMP, O_CMPE: begin
        res_direct = 1'b1;
        res_is_cmp = 1'b1;
        if (c_a.nan || c_b.nan) begin
          res_fcc = 2'd3;
          res_flags[FX_NV] = (c_op == O_CMPE) | c_a.snan | c_b.snan;
        end else if (c_a.zero && c_b.zero) res_fcc = 2'd0;
        else if (c_a.sign != c_b.sign)      res_fcc = c_a.sign ? 2'd1 : 2'd2;
        else if (c_a.inf && c_b.inf)        res_fcc = 2'd0;
        else if (c_a.inf)                   res_fcc = c_a.sign ? 2'd1 : 2'd2;
        else if (c_b.inf)                   res_fcc = c_b.sign ? 2'd2 : 2'd1;
        else if (c_a.zero)                  res_fcc = c_b.sign ? 2'd2 : 2'd1;
        else if (c_b.zero)                  res_fcc = c_a.sign ? 2'd1 : 2'd2;
        else if (sum == '0)                 res_fcc = 2'd0;   // equal (the signs are, here: |a| - |b|, the sticky in)
        else if (a_bigger)                  res_fcc = c_a.sign ? 2'd1 : 2'd2;
        else                                res_fcc = c_a.sign ? 2'd2 : 2'd1;
      end

      O_ITOF: ;                                 // always rounded: the operand is above

      O_FTOI: begin
        // round toward zero; out of range (beyond int32 after truncation) or NaN: invalid
        res_direct = 1'b1;
        if (c_b.nan) begin
          res_flags[FX_NV] = 1'b1; r_ce = 1'b1; r_cf = 1'b1;     // 7FFFFFFF: the single default NaN pattern
        end else if (c_b.inf || c_b.exp > 14'sd31 ||
                     (c_b.exp == 14'sd31 && !(c_b.sign && ftoi_iv == 32'h8000_0000))) begin
          // (a negative value that truncates to exactly -2^31 is in range)
          res_flags[FX_NV] = 1'b1;
          r_cs = c_b.sign; r_ce = !c_b.sign; r_cf = !c_b.sign;   // 80000000 = -0, 7FFFFFFF
        end else if (c_b.zero || c_b.exp < 14'sd0) begin
          // +0 (the default)
          res_flags[FX_NX] = !c_b.zero;
        end else begin
          r_kind = RK_INT;
          res_flags[FX_NX] = ftoi_inexact;
        end
      end

      O_FTOF: begin
        if (c_b.nan) begin
          res_direct = 1'b1; res_flags[FX_NV] = c_b.snan;
          r_kind = RK_OPND; r_sel = SEL_B; r_fix = 1'b1;
        end else if (c_b.inf) begin res_direct = 1'b1; r_cs = c_b.sign; r_ce = 1'b1; end
        else if (c_b.zero) begin res_direct = 1'b1; r_cs = c_b.sign; end
      end

      default: ;
    endcase
  end

  // The per-op result, registered (the rounder's first stage follows)
  always_ff @(posedge clk) begin
    wide_q <= wide;
    res_bits_q <= res_bits; res_flags_q <= res_flags; res_direct_q <= res_direct;
    res_fcc_q <= res_fcc; res_is_cmp_q <= res_is_cmp;
  end

  // ---------------------------------------------------------------------
  // Control
  // ---------------------------------------------------------------------
  logic [63:0] fin_bits;
  logic [63:0] f_bits;                 // the result as S_ROUND finishes
  logic [4:0]  f_flags;
  assign f_bits  = res_direct_q ? res_bits_q : rnd_bits;
  assign f_flags = res_direct_q ? res_flags_q : (rnd_flags | res_flags_q);
  assign dp_wr_addr = c_rd;
  assign dp_wr_dbl  = c_dst_dbl;
  assign dp_wr_data = fin_bits;
  assign fq         = {c_pc, c_inst};
  logic [1:0]  wait_cnt;
  logic        ds_ok;                  // the divide/square-root unit finished

  always_ff @(posedge clk) begin
    dp_wr <= 1'b0;
    ds_start <= 1'b0;
    if (rst) begin
      ex <= S_IDLE;
      state <= FP_EXECUTE;
      fsr_rd <= '0; fsr_tem <= '0; fsr_aexc <= '0; fsr_cexc <= '0; fsr_ftt <= '0; fsr_fcc <= '0;
      qne <= 1'b0;
      c_op <= O_UNIMPL; c_src_dbl <= 1'b0; c_dst_dbl <= 1'b0; c_rd <= '0; c_inst <= '0; c_pc <= '0;
      c_a <= '0; c_b <= '0; c_two <= 1'b0;
      wait_cnt <= '0; ds_ok <= 1'b0;
      fin_bits <= '0;
    end else begin
      // ldfsr: everything but ver, ftt, qne and the reserved bits
      if (req_i.fsr_wr) begin
        fsr_rd   <= req_i.fsr_wdata[31:30];
        fsr_tem  <= req_i.fsr_wdata[27:23];
        fsr_fcc  <= req_i.fsr_wdata[11:10];
        fsr_aexc <= req_i.fsr_wdata[9:5];
        fsr_cexc <= req_i.fsr_wdata[4:0];
      end
      // stdfq: the queue empties and fp_exception ends
      if (req_i.fq_pop) begin
        qne <= 1'b0;
        if (state == FP_EXCEPTION) state <= FP_EXECUTE;
      end
      // the IU took fp_exception: the pending one, or a sequence error
      if (req_i.trap_taken) begin
        if (state == FP_PENDING) state <= FP_EXCEPTION;
        else fsr_ftt <= FTT_SEQUENCE;
      end

      case (ex)
        S_IDLE: begin
          if (req_i.fpop_valid) begin
            c_op <= op; c_src_dbl <= src_dbl; c_dst_dbl <= dst_dbl; c_rd <= rd;
            c_inst <= req_i.fpop_inst; c_pc <= req_i.fpop_pc;
            c_b <= u_v;
            c_a <= u_va;
            c_two <= two_op;
            ex <= (denorm(u_v) || (two_op && denorm(u_va))) ? S_NORM : S_START;
          end
        end
        S_NORM: begin
          if (c_two && denorm(c_a)) begin
            c_a.man <= {c_a.man[51:0], 1'b0}; c_a.exp <= c_a.exp - 14'sd1;
          end else if (denorm(c_b)) begin
            c_b.man <= {c_b.man[51:0], 1'b0}; c_b.exp <= c_b.exp - 14'sd1;
          end else begin
            ex <= S_START;
          end
        end
        S_START: begin
          // operands latched: start the long units, or wait for the pipeline
          ds_ok <= 1'b0;
          if (c_op == O_UNIMPL) begin
            ex <= S_DONE;
          end else if ((c_op == O_DIV || c_op == O_SQRT) && !res_direct) begin
            ds_start <= 1'b1;
            ex <= S_WAIT;
          end else begin
            wait_cnt <= 2'd2;              // align/add/select/normalise, the multiplier's two registers
            ex <= S_WAIT;
          end
        end
        S_WAIT: begin
          // the pipeline after the operands: align, add, result select,
          // normalise (mul_p1 is ready before the add); then S_ROUND packs.
          // A divide or square root waits for its unit, then for the
          // result select and normalise registers.
          if ((c_op == O_DIV || c_op == O_SQRT) && !res_direct && !ds_ok) begin
            if (ds_done) begin ds_ok <= 1'b1; wait_cnt <= 2'd1; end
          end else if (wait_cnt != '0) begin
            wait_cnt <= wait_cnt - 2'd1;
          end else begin
            ex <= S_ROUND;
          end
        end
        S_ROUND: begin
          // (a tiny result: the rounder denormalises it first); the result
          // is final now: the FSR and the state, the register write next
          // cycle
          if (res_direct_q || !rnd_busy) begin
            ex <= S_IDLE;
            fin_bits <= f_bits;
            if ((f_flags & fsr_tem) != 5'd0) begin
              fsr_ftt <= FTT_IEEE;
              fsr_cexc <= f_flags;
              qne <= 1'b1;
              state <= FP_PENDING;
            end else begin
              fsr_ftt <= FTT_NONE;
              fsr_cexc <= f_flags;
              fsr_aexc <= fsr_aexc | f_flags;
              if (res_is_cmp_q) fsr_fcc <= res_fcc_q;
              else dp_wr <= 1'b1;
            end
          end
        end
        S_DONE: begin
          // entered from S_START only, for an unimplemented FPop
          ex <= S_IDLE;
          fsr_ftt <= FTT_UNIMPLEMENTED;
          qne <= 1'b1;
          state <= FP_PENDING;
        end
        default: ex <= S_IDLE;
      endcase
    end
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, ds_busy, req_i.rd_addr[0], req_i.fsr_wdata[29:28], req_i.fsr_wdata[22:12],
                       m_small_al[57:56]};

endmodule
