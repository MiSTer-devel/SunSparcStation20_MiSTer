// SPDX-License-Identifier: GPL-2.0-or-later
//
// iu_alu: the single-cycle integer operations of the SPARC V8 IU, selected
// by the instruction's op3 field: add/sub with and without carry, the
// logical operations, shifts, the tagged add/sub (and their trapping
// forms), mulscc, and the condition codes they produce. Multiply and
// divide are iu_muldiv.
//
// From: The SPARC Architecture Manual V8 §B.1 (add), §B.2 (tagged add),
//   §B.11 (logical), §B.12 (shift), §B.17 (mulscc), §B.20 (subtract),
//   §B.21 (tagged subtract), Appendix C (the icc definitions: for add
//   V = (a & b & ~r | ~a & ~b & r)[31], C = (a & b | ~r & (a | b))[31];
//   for sub V = (a & ~b & ~r | ~a & b & r)[31], C = (~a & b | ~(a ^ b) &
//   r)[31]); the op3 encodings of Table F-3 (Appendix F). The test
//   suite's model (tests/cpu/gen_alu.py) agrees.
//
// Tagged ops: V is also set when either operand has bits 1:0 set; the
// trapping forms (taddcctv/tsubcctv) report tag_trap and leave the result
// and icc unchanged. mulscc: op1 = {N xor V, a[31:1]}, op2 = Y[0] ? b : 0,
// r = op1 + op2 with add flags, Y = {a[0], Y[31:1]}.
//
// op3 values (format 3, op = 2) handled: 0x00-0x08, 0x0C, 0x10-0x18, 0x1C,
// 0x20-0x27. Others give r = a + b with no cc (the adder is what jmpl,
// rett, save, restore and the loads/stores need for their address).

module iu_alu
  import cpu_pkg::*;
(
  input  logic [5:0]  op3_i,
  input  logic [31:0] a_i,
  input  logic [31:0] b_i,
  input  logic [31:0] y_i,
  input  logic [3:0]  icc_i,         // {n, z, v, c}

  output logic [31:0] r_o,
  output logic [3:0]  icc_o,         // the new icc (valid when cc_o)
  output logic        cc_o,          // this op writes icc
  output logic [31:0] y_o,           // the new Y (valid when wy_o)
  output logic        wy_o,          // mulscc writes Y
  output logic        tag_trap_o     // taddcctv/tsubcctv overflow: tt 0x0A
);

  logic n_in, z_in, v_in, c_in;
  assign {n_in, z_in, v_in, c_in} = icc_i;

  // The operands of the adder
  logic [31:0] op1, op2;
  logic        sub, cin;
  logic [31:0] sum;
  logic        is_tagged, is_tv, is_mulscc, is_logic, is_shift, cc;

  always_comb begin
    is_tagged = op3_i[5:2] == 4'b1000;             // 0x20-0x23
    is_tv     = is_tagged & op3_i[1];
    is_mulscc = op3_i == 6'h24;
    is_shift  = op3_i[5:2] == 4'b1001 && op3_i[1:0] != 2'b00;   // 0x25-0x27
    is_logic  = (op3_i[3:0] >= 4'h1 && op3_i[3:0] <= 4'h3) || (op3_i[3:0] >= 4'h5 && op3_i[3:0] <= 4'h7);
    cc        = op3_i[4] && (op3_i[5] == 1'b0);     // 0x10-0x1F
    if (is_tagged || is_mulscc) cc = 1'b1;

    // Adder inputs
    op1 = a_i;
    op2 = b_i;
    sub = 1'b0;
    cin = 1'b0;
    if (is_mulscc) begin
      op1 = {n_in ^ v_in, a_i[31:1]};
      op2 = y_i[0] ? b_i : 32'd0;
    end else if (is_tagged) begin
      sub = op3_i[0];
    end else if (op3_i[5] == 1'b0) begin
      case (op3_i[3:0])
        4'h4:    sub = 1'b1;                        // sub
        4'h8:    cin = c_in;                        // addx
        4'hC:    begin sub = 1'b1; cin = c_in; end  // subx
        default: ;
      endcase
    end
    // one carry chain: a - b - c = a + ~b + !c
    sum = op1 + (op2 ^ {32{sub}}) + 32'(sub ^ cin);
  end

  // Flags of the adder (Appendix C)
  logic add_v, add_c, sub_v, sub_c, tag_v;
  always_comb begin
    add_v = (op1[31] & op2[31] & ~sum[31]) | (~op1[31] & ~op2[31] & sum[31]);
    add_c = (op1[31] & op2[31]) | (~sum[31] & (op1[31] | op2[31]));
    sub_v = (op1[31] & ~op2[31] & ~sum[31]) | (~op1[31] & op2[31] & sum[31]);
    sub_c = (~op1[31] & op2[31]) | (~(op1[31] ^ op2[31]) & sum[31]);
    tag_v = (sub ? sub_v : add_v) | (|a_i[1:0]) | (|b_i[1:0]);
  end

  // The result
  logic [31:0] r;
  logic        v, c;
  always_comb begin
    r = sum;
    v = sub ? sub_v : add_v;
    c = sub ? sub_c : add_c;
    if (is_logic && !is_tagged && !is_mulscc && !is_shift) begin
      case (op3_i[2:0])
        3'd1: r = a_i & b_i;
        3'd2: r = a_i | b_i;
        3'd3: r = a_i ^ b_i;
        3'd5: r = a_i & ~b_i;
        3'd6: r = a_i | ~b_i;
        3'd7: r = ~(a_i ^ b_i);
        default: r = sum;
      endcase
      v = 1'b0;
      c = 1'b0;
    end
    if (is_shift) begin
      // srl and sra share one right shifter: sra shifts in a_i[31]
      if (op3_i[1:0] == 2'd1) r = a_i << b_i[4:0];
      else                    r = 32'($signed({op3_i[0] & a_i[31], a_i}) >>> b_i[4:0]);
      v = 1'b0;
      c = 1'b0;
    end
    if (is_tagged) v = tag_v;
  end

  assign tag_trap_o = is_tv & tag_v;

  always_comb begin
    r_o   = r;                                      // (a tag trap writes and forwards nothing)
    icc_o = {r[31], r == 32'd0, v, c};
    cc_o  = cc & ~tag_trap_o;
    y_o   = {a_i[0], y_i[31:1]};
    wy_o  = is_mulscc;
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, z_in};

endmodule
