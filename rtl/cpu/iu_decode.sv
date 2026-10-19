// SPDX-License-Identifier: GPL-2.0-or-later
//
// iu_decode: a SPARC V8 instruction word to the control signals of the
// pipeline: its class, operands, the privilege and legality checks that
// need nothing but the word and the PSR's S/EF bits.
//
// From: The SPARC Architecture Manual V8 Appendix F (the opcode maps:
//   Table F-1 op, F-2 op2, F-3 op3 for op = 2, F-4 op3 for op = 3, F-7 the
//   Bicc/FBfcc/CBccc conditions), §5 (the formats and fields), §B.*
//   (which instructions are privileged, what traps they raise: Table 7-1
//   illegal_instruction 0x02, privileged_instruction 0x03, fp_disabled
//   0x04, cp_disabled 0x24, unimplemented_FLUSH 0x25), §B.29 (Ticc's
//   trap number), §4.2 (PSR.S and EF).
//
// Combinational. Conditions the decoder cannot know (window overflow and
// underflow, alignment, the rett ET rule, the wrpsr CWP range, divide by
// zero, tagged overflow) are the pipeline's, from the register values.

module iu_decode
  import cpu_pkg::*;
(
  input  logic [31:0] inst_i,
  input  logic        supv_i,         // PSR.S
  input  logic        ef_i,           // PSR.EF
  output dec_t        dec_o
);

  logic [1:0] op;
  logic [2:0] op2;
  logic [5:0] op3;
  logic [4:0] rd, rs1, rs2;
  logic       i;
  logic [7:0] asi;
  logic [12:0] simm13;
  logic [3:0] cond;
  logic       annul;
  logic [8:0] opf;

  always_comb begin
    op     = inst_i[31:30];
    op2    = inst_i[24:22];
    op3    = inst_i[24:19];
    rd     = inst_i[29:25];
    rs1    = inst_i[18:14];
    rs2    = inst_i[4:0];
    i      = inst_i[13];
    asi    = inst_i[12:5];
    simm13 = inst_i[12:0];
    cond   = inst_i[28:25];
    annul  = inst_i[29];
    opf    = inst_i[13:5];
  end

  always_comb begin
    dec_o = '0;
    dec_o.rd  = rd;
    dec_o.rs1 = rs1;
    dec_o.rs2 = rs2;
    dec_o.imm = i;
    dec_o.simm13 = {{19{simm13[12]}}, simm13};
    dec_o.cond = cond;
    dec_o.annul = annul;
    dec_o.asi = asi;
    dec_o.op3 = op3;
    dec_o.opf = opf;
    dec_o.disp30 = {inst_i[29:0], 2'b00};
    dec_o.disp22 = {{8{inst_i[21]}}, inst_i[21:0], 2'b00};
    dec_o.imm22  = {inst_i[21:0], 10'd0};
    dec_o.cls = C_ILLEGAL;

    case (op)
      // ---- format 2: sethi, branches, unimp ----
      2'b00: begin
        case (op2)
          3'b000: dec_o.cls = C_ILLEGAL;              // UNIMP
          3'b010: dec_o.cls = C_BICC;
          3'b100: begin
            dec_o.cls = C_SETHI;                       // rd = 0, imm22 = 0 is NOP
            dec_o.wr_rd = 1'b1;
          end
          3'b110: begin
            dec_o.cls = C_FBFCC;
            if (!ef_i) dec_o.trap_fp_disabled = 1'b1;
          end
          3'b111: begin dec_o.cls = C_NOP; dec_o.trap_cp_disabled = 1'b1; end   // CBccc: no coprocessor
          default: dec_o.cls = C_ILLEGAL;
        endcase
      end
      // ---- call ----
      2'b01: begin
        dec_o.cls = C_CALL;
        dec_o.wr_rd = 1'b1;                            // %o7
        dec_o.rd = 5'd15;
      end
      // ---- format 3: arithmetic and control ----
      2'b10: begin
        case (op3)
          6'h00, 6'h01, 6'h02, 6'h03, 6'h04, 6'h05, 6'h06, 6'h07, 6'h08, 6'h0C,
          6'h10, 6'h11, 6'h12, 6'h13, 6'h14, 6'h15, 6'h16, 6'h17, 6'h18, 6'h1C,
          6'h20, 6'h21, 6'h22, 6'h23, 6'h24, 6'h25, 6'h26, 6'h27: begin
            dec_o.cls = C_ALU;
            dec_o.wr_rd = 1'b1;
          end
          6'h0A, 6'h0B, 6'h1A, 6'h1B: begin            // umul smul umulcc smulcc
            dec_o.cls = C_MUL;
            dec_o.wr_rd = 1'b1;
            dec_o.cc = op3[4];
            dec_o.sgn = op3[0];
          end
          6'h0E, 6'h0F, 6'h1E, 6'h1F: begin            // udiv sdiv udivcc sdivcc
            dec_o.cls = C_DIV;
            dec_o.wr_rd = 1'b1;
            dec_o.cc = op3[4];
            dec_o.sgn = op3[0];
          end
          6'h28: begin                                 // rd %y / rd %asr / stbar
            dec_o.cls = C_RDY;
            dec_o.wr_rd = 1'b1;
            dec_o.stbar = (rs1 == 5'd15) && (rd == 5'd0);
            // %asr1-15 other than stbar: read Y; %asr16-31 too (t_rdasr)
          end
          6'h29: begin dec_o.cls = C_RDPSR; dec_o.wr_rd = 1'b1; dec_o.priv = 1'b1; end
          6'h2A: begin dec_o.cls = C_RDWIM; dec_o.wr_rd = 1'b1; dec_o.priv = 1'b1; end
          6'h2B: begin dec_o.cls = C_RDTBR; dec_o.wr_rd = 1'b1; dec_o.priv = 1'b1; end
          6'h30: begin                                 // wr %y / wr %asr (a no-op for ASRs)
            dec_o.cls = (rd == 5'd0) ? C_WRY : C_NOP;
          end
          6'h31: begin dec_o.cls = C_WRPSR; dec_o.priv = 1'b1; end
          6'h32: begin dec_o.cls = C_WRWIM; dec_o.priv = 1'b1; end
          6'h33: begin dec_o.cls = C_WRTBR; dec_o.priv = 1'b1; end
          6'h34, 6'h35: begin                          // FPop1, FPop2
            dec_o.cls = C_FPOP;
            if (!ef_i) dec_o.trap_fp_disabled = 1'b1;
          end
          6'h36, 6'h37: begin dec_o.cls = C_NOP; dec_o.trap_cp_disabled = 1'b1; end   // CPop
          6'h38: begin dec_o.cls = C_JMPL; dec_o.wr_rd = 1'b1; end
          6'h39: begin dec_o.cls = C_RETT; dec_o.priv = 1'b1; end
          6'h3A: dec_o.cls = C_TICC;
          6'h3B: dec_o.cls = C_FLUSH;
          6'h3C: begin dec_o.cls = C_SAVE; dec_o.wr_rd = 1'b1; end
          6'h3D: begin dec_o.cls = C_RESTORE; dec_o.wr_rd = 1'b1; end
          default: dec_o.cls = C_ILLEGAL;
        endcase
      end
      // ---- format 3: memory ----
      2'b11: begin
        dec_o.alt = op3[4];                            // alternate space: privileged
        case (op3[3:0])
          4'h0: begin dec_o.cls = C_LOAD;  dec_o.size = 2'd2; dec_o.wr_rd = 1'b1; end            // ld
          4'h1: begin dec_o.cls = C_LOAD;  dec_o.size = 2'd0; dec_o.wr_rd = 1'b1; end            // ldub
          4'h2: begin dec_o.cls = C_LOAD;  dec_o.size = 2'd1; dec_o.wr_rd = 1'b1; end            // lduh
          4'h3: begin dec_o.cls = C_LOAD;  dec_o.size = 2'd3; dec_o.wr_rd = 1'b1; end            // ldd
          4'h4: begin dec_o.cls = C_STORE; dec_o.size = 2'd2; end                                 // st
          4'h5: begin dec_o.cls = C_STORE; dec_o.size = 2'd0; end                                 // stb
          4'h6: begin dec_o.cls = C_STORE; dec_o.size = 2'd1; end                                 // sth
          4'h7: begin dec_o.cls = C_STORE; dec_o.size = 2'd3; end                                 // std
          4'h9: begin dec_o.cls = C_LOAD;  dec_o.size = 2'd0; dec_o.sgn = 1'b1; dec_o.wr_rd = 1'b1; end  // ldsb
          4'hA: begin dec_o.cls = C_LOAD;  dec_o.size = 2'd1; dec_o.sgn = 1'b1; dec_o.wr_rd = 1'b1; end  // ldsh
          4'hD: begin dec_o.cls = C_ATOMIC; dec_o.size = 2'd0; dec_o.wr_rd = 1'b1; end            // ldstub
          4'hF: begin dec_o.cls = C_ATOMIC; dec_o.size = 2'd2; dec_o.wr_rd = 1'b1; dec_o.swap = 1'b1; end  // swap
          default: dec_o.cls = C_ILLEGAL;
        endcase
        if (op3[5]) begin
          // FP (0x20-0x27) and coprocessor (0x30-0x37) loads and stores:
          // none writes an integer register
          dec_o.cls = C_ILLEGAL;
          dec_o.wr_rd = 1'b0;
          dec_o.sgn = 1'b0;
          dec_o.swap = 1'b0;
          if (!op3[4]) begin
            case (op3[3:0])
              4'h0: begin dec_o.cls = C_FPLOAD;  dec_o.size = 2'd2; end                 // ldf
              4'h1: begin dec_o.cls = C_FPLOAD;  dec_o.size = 2'd2; dec_o.fsr = 1'b1; end   // ldfsr
              4'h3: begin dec_o.cls = C_FPLOAD;  dec_o.size = 2'd3; end                 // lddf
              4'h4: begin dec_o.cls = C_FPSTORE; dec_o.size = 2'd2; end                 // stf
              4'h5: begin dec_o.cls = C_FPSTORE; dec_o.size = 2'd2; dec_o.fsr = 1'b1; end   // stfsr
              4'h6: begin dec_o.cls = C_FPSTORE; dec_o.size = 2'd3; dec_o.fq = 1'b1; dec_o.priv = 1'b1; end  // stdfq
              4'h7: begin dec_o.cls = C_FPSTORE; dec_o.size = 2'd3; end                 // stdf
              default: dec_o.cls = C_ILLEGAL;
            endcase
            if (dec_o.cls != C_ILLEGAL && !ef_i) dec_o.trap_fp_disabled = 1'b1;
          end else begin
            case (op3[3:0])
              4'h0, 4'h1, 4'h3, 4'h4, 4'h5, 4'h6, 4'h7: begin dec_o.cls = C_NOP; dec_o.trap_cp_disabled = 1'b1; end   // ldc stcsr ... (IU-3)
              default: dec_o.cls = C_ILLEGAL;
            endcase
          end
        end else if (dec_o.alt && dec_o.cls != C_ILLEGAL) begin
          dec_o.priv = 1'b1;                           // lda/sta/ldstuba/swapa
        end
      end
      default: ;
    endcase

    // Trap tags the decoder decides
    if (dec_o.cls == C_ILLEGAL) dec_o.trap_illegal = 1'b1;
    if (dec_o.priv && !supv_i) dec_o.trap_priv = 1'b1;
    // A coprocessor instruction from user mode is cp_disabled, not privileged
  end

endmodule
