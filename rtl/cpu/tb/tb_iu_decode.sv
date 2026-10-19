// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_iu_decode: hand-assembled instruction words (V8 Appendix F, §5)
// against the classes, fields and trap tags the decoder must give.

module tb_iu_decode;
  import cpu_pkg::*;
  import tb_pkg::*;

  logic [31:0] inst;
  logic supv = 1, ef = 1;
  dec_t d;

  iu_decode dut (.inst_i(inst), .supv_i(supv), .ef_i(ef), .dec_o(d));

  // Encoders (V8 §5.2: formats 1, 2, 3)
  function automatic logic [31:0] f3(input logic [1:0] op, input logic [4:0] rd, input logic [5:0] op3,
                                     input logic [4:0] rs1, input logic i, input logic [12:0] low);
    return {op, rd, op3, rs1, i, low};
  endfunction
  function automatic logic [31:0] f3r(input logic [1:0] op, input logic [4:0] rd, input logic [5:0] op3,
                                      input logic [4:0] rs1, input logic [7:0] asi, input logic [4:0] rs2);
    return {op, rd, op3, rs1, 1'b0, asi, rs2};
  endfunction
  function automatic logic [31:0] f2b(input logic a, input logic [3:0] cond, input logic [2:0] op2, input logic [21:0] disp);
    return {2'b00, a, cond, op2, disp};
  endfunction

  task automatic expect_cls(input logic [31:0] w, input cls_t c, input string what, input logic s = 1, input logic e = 1);
    inst = w; supv = s; ef = e;
    #1;
    check(d.cls == c, $sformatf("%s (%08x): class %0d expected %0d", what, w, d.cls, c));
  endtask

  initial begin
    // ---- arithmetic (format 3, op 2) ----
    expect_cls(f3(2, 5'd1, 6'h00, 5'd2, 1, 13'd4), C_ALU, "add %o2, 4, %g1... (add)");
    inst = f3(2, 5'd1, 6'h00, 5'd2, 1, 13'h1FFC); #1;
    check(d.rd == 1 && d.rs1 == 2 && d.imm && d.simm13 == 32'hFFFF_FFFC && d.wr_rd, "add fields, simm13 sign-extended");
    inst = f3r(2, 5'd9, 6'h14, 5'd10, 8'h00, 5'd11); #1;
    check(d.cls == C_ALU && d.rs2 == 11 && !d.imm && d.op3 == 6'h14, "subcc register form");
    expect_cls(f3(2, 5'd0, 6'h02, 5'd0, 1, 0), C_ALU, "or %g0, 0, %g0 (a nop by another name)");
    expect_cls(f3(2, 5'd1, 6'h0A, 5'd2, 0, 13'd3), C_MUL, "umul");
    inst = f3(2, 5'd1, 6'h1B, 5'd2, 0, 13'd3); #1; check(d.cls == C_MUL && d.cc && d.sgn, "smulcc flags");
    inst = f3(2, 5'd1, 6'h1E, 5'd2, 0, 13'd3); #1; check(d.cls == C_DIV && d.cc && !d.sgn, "udivcc flags");
    expect_cls(f3(2, 5'd1, 6'h24, 5'd2, 0, 13'd3), C_ALU, "mulscc");
    expect_cls(f3(2, 5'd1, 6'h25, 5'd2, 1, 13'd3), C_ALU, "sll");
    expect_cls(f3(2, 5'd1, 6'h22, 5'd2, 0, 13'd3), C_ALU, "taddcctv");
    expect_cls(f3(2, 5'd1, 6'h09, 5'd2, 0, 13'd3), C_ILLEGAL, "op3 0x09 is unassigned");
    expect_cls(f3(2, 5'd1, 6'h2C, 5'd2, 0, 13'd3), C_ILLEGAL, "op3 0x2C is unassigned");
    expect_cls(f3(2, 5'd1, 6'h3E, 5'd2, 0, 13'd3), C_ILLEGAL, "op3 0x3E is unassigned");
    check(d.trap_illegal, "an unassigned op3 is tagged illegal");

    // ---- sethi and branches (format 2) ----
    inst = {2'b00, 5'd1, 3'b100, 22'h3FFFFF}; #1;
    check(d.cls == C_SETHI && d.imm22 == 32'hFFFF_FC00 && d.wr_rd, "sethi %hi(0xfffffc00), %g1");
    inst = {2'b00, 5'd0, 3'b100, 22'h0}; #1;
    check(d.cls == C_SETHI && d.rd == 0, "nop (sethi 0, %g0)");
    inst = f2b(1, 4'h8, 3'b010, 22'h3FFFF0); #1;
    check(d.cls == C_BICC && d.annul && d.cond == 8 && d.disp22 == 32'hFFFF_FFC0, "ba,a -64");
    inst = f2b(0, 4'h1, 3'b010, 22'd5); #1;
    check(d.cls == C_BICC && !d.annul && d.cond == 1 && d.disp22 == 32'd20, "be +20");
    expect_cls(f2b(0, 4'h8, 3'b110, 22'd1), C_FBFCC, "fba");
    expect_cls(f2b(0, 4'h8, 3'b110, 22'd1), C_FBFCC, "fba with EF off", 1, 0);
    check(d.trap_fp_disabled, "fbfcc with EF = 0 is fp_disabled");
    expect_cls(f2b(0, 4'h8, 3'b000, 22'd1), C_ILLEGAL, "unimp");
    expect_cls(f2b(0, 4'h8, 3'b001, 22'd1), C_ILLEGAL, "op2 = 1 unassigned");
    inst = f2b(0, 4'h8, 3'b111, 22'd1); #1;
    check(d.trap_cp_disabled && !d.trap_illegal, "cbccc: cp_disabled, not illegal");

    // ---- call ----
    inst = {2'b01, 30'h3FFFFFFF}; #1;
    check(d.cls == C_CALL && d.disp30 == 32'hFFFF_FFFC && d.rd == 15 && d.wr_rd, "call -4 links %o7");

    // ---- control registers ----
    expect_cls(f3(2, 5'd1, 6'h28, 5'd0, 0, 0), C_RDY, "rd %y");
    inst = f3(2, 5'd0, 6'h28, 5'd15, 0, 0); #1; check(d.cls == C_RDY && d.stbar, "stbar (rd %asr15, %g0)");
    inst = f3(2, 5'd3, 6'h28, 5'd2, 0, 0); #1; check(d.cls == C_RDY && !d.stbar, "rd %asr2 reads Y");
    expect_cls(f3(2, 5'd1, 6'h29, 5'd0, 0, 0), C_RDPSR, "rd %psr");
    check(d.priv && !d.trap_priv, "rd %psr privileged, allowed in supervisor mode");
    expect_cls(f3(2, 5'd1, 6'h29, 5'd0, 0, 0), C_RDPSR, "rd %psr from user mode", 0);
    check(d.trap_priv, "rd %psr from user mode: privileged_instruction");
    expect_cls(f3(2, 5'd1, 6'h2A, 5'd0, 0, 0), C_RDWIM, "rd %wim");
    expect_cls(f3(2, 5'd1, 6'h2B, 5'd0, 0, 0), C_RDTBR, "rd %tbr");
    expect_cls(f3(2, 5'd0, 6'h30, 5'd1, 0, 0), C_WRY, "wr %y");
    expect_cls(f3(2, 5'd16, 6'h30, 5'd1, 0, 0), C_NOP, "wr %asr16 is a no-op");
    expect_cls(f3(2, 5'd0, 6'h31, 5'd1, 1, 13'h0E0), C_WRPSR, "wr %psr");
    expect_cls(f3(2, 5'd0, 6'h32, 5'd1, 0, 0), C_WRWIM, "wr %wim");
    expect_cls(f3(2, 5'd0, 6'h33, 5'd1, 0, 0), C_WRTBR, "wr %tbr");
    expect_cls(f3(2, 5'd0, 6'h31, 5'd1, 0, 0), C_WRPSR, "wr %psr from user", 0);
    check(d.trap_priv, "wr %psr from user: privileged");

    // ---- control transfer ----
    inst = f3(2, 5'd15, 6'h38, 5'd1, 1, 13'd8); #1; check(d.cls == C_JMPL && d.wr_rd && d.rd == 15, "jmpl %g1+8, %o7");
    expect_cls(f3(2, 5'd0, 6'h39, 5'd17, 1, 13'd8), C_RETT, "rett");
    check(d.priv, "rett privileged");
    inst = f3(2, 5'd0, {1'b0, 1'b0, 4'h0} | 6'h3A, 5'd0, 1, 13'd3); inst[28:25] = 4'h8; #1;
    check(d.cls == C_TICC && d.cond == 8, "ta 3");
    expect_cls(f3(2, 5'd0, 6'h3B, 5'd1, 0, 0), C_FLUSH, "flush");
    expect_cls(f3(2, 5'd14, 6'h3C, 5'd14, 1, 13'h1FA0), C_SAVE, "save %sp, -96, %sp");
    expect_cls(f3(2, 5'd0, 6'h3D, 5'd0, 0, 0), C_RESTORE, "restore");
    expect_cls(f3(2, 5'd0, 6'h34, 5'd0, 0, 0), C_FPOP, "fpop1");
    expect_cls(f3(2, 5'd0, 6'h35, 5'd0, 0, 0), C_FPOP, "fpop2 with EF off", 1, 0);
    check(d.trap_fp_disabled, "fpop with EF = 0: fp_disabled");
    inst = f3(2, 5'd0, 6'h36, 5'd0, 0, 0); #1; check(d.trap_cp_disabled && !d.trap_illegal && d.cls == C_NOP, "cpop1: cp_disabled, not illegal");

    // ---- loads and stores ----
    inst = f3(3, 5'd1, 6'h00, 5'd2, 1, 13'd4); #1;
    check(d.cls == C_LOAD && d.size == 2 && !d.sgn && !d.alt && d.wr_rd, "ld [%o2+4], %g1");
    inst = f3(3, 5'd1, 6'h09, 5'd2, 1, 13'd4); #1; check(d.cls == C_LOAD && d.size == 0 && d.sgn, "ldsb");
    inst = f3(3, 5'd1, 6'h02, 5'd2, 1, 13'd4); #1; check(d.cls == C_LOAD && d.size == 1 && !d.sgn, "lduh");
    inst = f3(3, 5'd2, 6'h03, 5'd2, 1, 13'd4); #1; check(d.cls == C_LOAD && d.size == 3, "ldd");
    inst = f3(3, 5'd1, 6'h04, 5'd2, 1, 13'd4); #1; check(d.cls == C_STORE && d.size == 2 && !d.wr_rd, "st");
    inst = f3(3, 5'd1, 6'h05, 5'd2, 1, 13'd4); #1; check(d.cls == C_STORE && d.size == 0, "stb");
    inst = f3(3, 5'd1, 6'h07, 5'd2, 1, 13'd4); #1; check(d.cls == C_STORE && d.size == 3, "std");
    inst = f3(3, 5'd1, 6'h0D, 5'd2, 1, 13'd4); #1; check(d.cls == C_ATOMIC && d.size == 0 && !d.swap, "ldstub");
    inst = f3(3, 5'd1, 6'h0F, 5'd2, 1, 13'd4); #1; check(d.cls == C_ATOMIC && d.size == 2 && d.swap, "swap");
    inst = f3r(3, 5'd1, 6'h10, 5'd2, 8'h20, 5'd3); #1;
    check(d.cls == C_LOAD && d.alt && d.asi == 8'h20 && d.priv && !d.trap_priv, "lda [%o2+%g3] 0x20 (supervisor)");
    inst = f3r(3, 5'd1, 6'h10, 5'd2, 8'h20, 5'd3); supv = 0; #1;
    check(d.trap_priv, "lda from user mode: privileged");
    supv = 1;
    inst = f3r(3, 5'd1, 6'h14, 5'd2, 8'h0B, 5'd3); #1; check(d.cls == C_STORE && d.alt && d.asi == 8'h0B, "sta");
    inst = f3r(3, 5'd1, 6'h1D, 5'd2, 8'h0A, 5'd3); #1; check(d.cls == C_ATOMIC && d.alt, "ldstuba");
    inst = f3r(3, 5'd1, 6'h1F, 5'd2, 8'h0A, 5'd3); #1; check(d.cls == C_ATOMIC && d.alt && d.swap, "swapa");
    expect_cls(f3(3, 5'd1, 6'h08, 5'd2, 1, 13'd4), C_ILLEGAL, "op3 0x08 (memory) unassigned");
    expect_cls(f3(3, 5'd1, 6'h0C, 5'd2, 1, 13'd4), C_ILLEGAL, "op3 0x0C unassigned");
    expect_cls(f3(3, 5'd1, 6'h0E, 5'd2, 1, 13'd4), C_ILLEGAL, "op3 0x0E unassigned");
    // FP and coprocessor loads/stores
    inst = f3(3, 5'd1, 6'h20, 5'd2, 1, 13'd4); #1; check(d.cls == C_FPLOAD && d.size == 2 && !d.fsr, "ldf");
    inst = f3(3, 5'd0, 6'h21, 5'd2, 1, 13'd4); #1; check(d.cls == C_FPLOAD && d.fsr, "ldfsr");
    inst = f3(3, 5'd2, 6'h23, 5'd2, 1, 13'd4); #1; check(d.cls == C_FPLOAD && d.size == 3, "lddf");
    inst = f3(3, 5'd1, 6'h24, 5'd2, 1, 13'd4); #1; check(d.cls == C_FPSTORE && d.size == 2, "stf");
    inst = f3(3, 5'd0, 6'h25, 5'd2, 1, 13'd4); #1; check(d.cls == C_FPSTORE && d.fsr, "stfsr");
    inst = f3(3, 5'd0, 6'h26, 5'd2, 1, 13'd4); #1; check(d.cls == C_FPSTORE && d.fq && d.priv, "stdfq, privileged");
    inst = f3(3, 5'd2, 6'h27, 5'd2, 1, 13'd4); #1; check(d.cls == C_FPSTORE && d.size == 3, "stdf");
    inst = f3(3, 5'd1, 6'h20, 5'd2, 1, 13'd4); ef = 0; #1; check(d.trap_fp_disabled, "ldf with EF = 0: fp_disabled");
    ef = 1;
    expect_cls(f3(3, 5'd1, 6'h22, 5'd2, 1, 13'd4), C_ILLEGAL, "op3 0x22 (memory) unassigned");
    inst = f3(3, 5'd1, 6'h30, 5'd2, 1, 13'd4); #1; check(d.trap_cp_disabled && !d.trap_illegal && d.cls == C_NOP, "ldc: cp_disabled, no access (IU-3)");
    inst = f3(3, 5'd1, 6'h34, 5'd2, 1, 13'd4); supv = 0; #1;
    check(d.trap_cp_disabled && !d.trap_priv, "stc from user mode: cp_disabled, not privileged");
    supv = 1;
    expect_cls(f3(3, 5'd1, 6'h32, 5'd2, 1, 13'd4), C_ILLEGAL, "op3 0x32 unassigned");

    tb_done("tb_iu_decode");
  end
endmodule
