// SPDX-License-Identifier: GPL-2.0-or-later
//
// iu_sim: the phase-1 harness (docs/arch/cpu.md §5): the integer unit with
// a behavioural 36-bit memory, run from the CPU test ROM, its ttya on the
// real escc block. Verilator, --binary --timing; prints the ROM's serial
// output and stops at "CPUTEST DONE" or at the cycle budget.
//
// The address map (docs/arch/memory-map.md; the SS20 target of
// tests/cpu/src/platform.h): the PROM image at PA 0xF_F000_0000 (also
// fetched at VA 0 in boot mode), 16 MB of RAM at PA 0, the ESCC at
// PA 0xF_F110_0000. The MMU is not here (phase 3): with ASI 4's control
// register E = 0 and BM = 1 instruction fetches go to the PROM and data
// accesses are physical in space 0; the bypass ASIs 0x20-0x2F give
// PA = {asi[3:0], va}. The control-space ASIs the suite's runtime touches
// are answered: ASI 4 (the control register at 0; the others read 0),
// ASI 0x38 (512 addressed 64-bit words), ASI 0x4C (a 32-bit scratch); the cache ASIs
// read 0 and take writes. An access to an empty SBus slot (0xE_0xxx_xxxx
// to 0xE_3xxx_xxxx) is a bus error.

module iu_sim
  import cpu_pkg::*;
  import iobus_pkg::*;
#(
  parameter string ROM = "tests/cpu/out/ss20/cputest.rom",
  parameter longint CYCLES = 200_000_000
);
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;

  // ---- the IU ----
  ifetch_req_t ifr;
  ifetch_rsp_t ifs;
  dmem_req_t   dmr;
  dmem_rsp_t   dms;
  logic        error, halt;
  logic [2:0]  cwp;

  fpu_pkg::fpu_req_t fpr;
  fpu_pkg::fpu_rsp_t fps;

  iu #(.HAS_FPU(1'b1)) u_iu (.clk, .rst, .ifetch_req_o(ifr), .ifetch_rsp_i(ifs), .dmem_req_o(dmr), .dmem_rsp_i(dms),
                             .fpu_req_o(fpr), .fpu_rsp_i(fps),
                             .irl_i(4'd0), .error_o(error), .cwp_o(cwp), .halt_o(halt),
                             /* verilator lint_off PINCONNECTEMPTY */
                             .dmem_nidx_o(), .dbg_commit_o(), .dbg_trap_o(), .dbg_tt_o(), .dbg_pc_o(), .dbg_psr_o(), .dbg_pipe_o());
                             /* verilator lint_on PINCONNECTEMPTY */
  fpu u_fpu (.clk, .rst, .req_i(fpr), .rsp_o(fps));

  // ---- memories ----
  logic [31:0] rom [0:65535];        // 256 KB
  logic [31:0] ram [0:4194303];      // 16 MB
  initial $readmemh(ROM, rom);        // a hex image; run.sh makes it from the .rom

  logic [31:0] mmu_ctrl = 32'h0000_4000;   // BM = 1 after reset (Viking MCNTL bit 14)
  logic [63:0] asi38 [0:511];           // 64-bit entries by va[11:3]
  initial for (int i = 0; i < 512; i++) asi38[i] = '0;
  logic [31:0] asi4c = '0;

  function automatic logic [35:0] data_pa(input logic [7:0] asi, input logic [31:0] va);
    if (asi[7:4] == 4'h2) return {asi[3:0], va};      // bypass
    return {4'h0, va};                                // MMU off: PA = VA in space 0
  endfunction

  // ---- instruction fetch: one cycle; an answer not taken (ready low) is held ----
  always_ff @(posedge clk) begin
    if (!(ifs.valid && !ifr.ready)) begin
    ifs.valid <= 1'b0;
    ifs.inst <= 32'd0;
    ifs.fault <= 2'd0;
    end
    if (ifr.valid) begin
      ifs.valid <= 1'b1;
      if (mmu_ctrl[14])                 // boot mode: the PROM
        ifs.inst <= rom[ifr.va[17:2]];
      else if (ifr.va[31:24] == 8'h00)
        ifs.inst <= ram[ifr.va[23:2]];
      else begin
        ifs.inst <= 32'd0;
        ifs.fault <= 2'd1;
      end
    end
  end

  // ---- data: one cycle, through the ESCC when addressed ----
  iob_req_t esc_req;
  iob_rsp_t esc_rsp;
  logic txd_a, txd_b, rts_a, dtr_a, rts_b, dtr_b, irq;
  logic [7:0] tx_byte_a, tx_byte_b;
  logic tx_byte_valid_a, tx_byte_valid_b, rx_byte_ready_a, rx_byte_ready_b;
  escc #(.CLK_HZ(9_830_400)) u_escc (
    .clk, .rst, .bus_i(esc_req), .bus_o(esc_rsp),
    .txd_a_o(txd_a), .rxd_a_i(1'b1), .dcd_a_i(1'b1), .cts_a_i(1'b1), .rts_a_o(rts_a), .dtr_a_o(dtr_a),
    .txd_b_o(txd_b), .rxd_b_i(1'b1), .dcd_b_i(1'b1), .cts_b_i(1'b1), .rts_b_o(rts_b), .dtr_b_o(dtr_b),
    .tx_byte_a_o(tx_byte_a), .tx_byte_valid_a_o(tx_byte_valid_a), .rx_byte_a_i(8'h00), .rx_byte_valid_a_i(1'b0), .rx_byte_ready_a_o(rx_byte_ready_a),
    .tx_byte_b_o(tx_byte_b), .tx_byte_valid_b_o(tx_byte_valid_b), .rx_byte_b_i(8'h00), .rx_byte_valid_b_i(1'b0), .rx_byte_ready_b_o(rx_byte_ready_b),
    .irq_o(irq));

  logic [35:0] pa;
  logic        is_escc, is_ram, is_rom, is_sbus_empty, is_ctl;
  logic        esc_busy;
  always_comb begin
    pa = data_pa(dmr.asi, dmr.va);
    is_ctl  = dmr.asi < 8'h08 || (dmr.asi >= 8'h0C && dmr.asi <= 8'h14) || dmr.asi == 8'h36 || dmr.asi == 8'h37 ||
              dmr.asi == 8'h38 || dmr.asi == 8'h4C;
    is_escc = !is_ctl && pa[35:20] == 16'hFF11;
    is_ram  = !is_ctl && pa[35:24] == 12'h000;
    is_rom  = !is_ctl && pa[35:20] == 16'hFF00;
    is_sbus_empty = !is_ctl && pa[35:32] == 4'hE && pa[31:30] == 2'b00;
  end

  // the ESCC request: one per IU access (not again in the IU's ack cycle)
  always_comb begin
    esc_req = IOB_REQ_IDLE;
    esc_req.req   = dmr.valid && is_escc && !esc_busy && !rsp_pending && !dms.ack;
    esc_req.we    = dmr.write;
    esc_req.addr  = {8'h0, pa[19:0]};
    case (dmr.size)
      2'd0: esc_req.be = 4'b1000 >> pa[1:0];
      2'd1: esc_req.be = pa[1] ? 4'b0011 : 4'b1100;
      default: esc_req.be = 4'b1111;
    endcase
    // the byte/half value right-aligned in the IU's word goes to its lane
    case (dmr.size)
      2'd0: esc_req.wdata = {4{dmr.wdata[7:0]}};
      2'd1: esc_req.wdata = {2{dmr.wdata[15:0]}};
      default: esc_req.wdata = dmr.wdata[31:0];
    endcase
  end

  // one-cycle responder for RAM/ROM/control space; the ESCC answers itself
  logic        rsp_pending;
  always_ff @(posedge clk) begin
    dms.ack <= 1'b0;
    dms.rdata <= '0;
    dms.fault <= 2'd0;
    esc_busy <= 1'b0;
    if (rst) begin
      rsp_pending <= 1'b0;
    end else if (dmr.valid && !rsp_pending && !dms.ack) begin   // a new access (the IU holds valid through the ack cycle)
      if (is_escc) begin
        rsp_pending <= 1'b1;             // wait for the ESCC's ack
        esc_busy <= 1'b1;
      end else begin
        rsp_pending <= 1'b0;
        dms.ack <= 1'b1;
        if (is_ctl) begin
          case (dmr.asi)
            8'h04: begin
              if (dmr.va[11:8] == 4'h0) begin
                dms.rdata[31:0] <= mmu_ctrl;
                if (dmr.write) mmu_ctrl <= dmr.wdata[31:0];
              end
            end
            8'h38: begin dms.rdata <= asi38[dmr.va[11:3]]; if (dmr.write) asi38[dmr.va[11:3]] <= dmr.wdata; end
            8'h4C: begin dms.rdata[31:0] <= asi4c; if (dmr.write) asi4c <= dmr.wdata[31:0]; end
            default: ;
          endcase
        end else if (is_sbus_empty) begin
          dms.fault <= 2'd2;
        end else if (is_ram || is_rom) begin : mem
          logic [31:0] w0, w1;
          logic [21:0] idx;
          idx = is_ram ? pa[23:2] : {6'd0, pa[17:2]};
          w0 = is_ram ? ram[idx] : rom[idx[15:0]];
          w1 = is_ram ? ram[idx | 22'd1] : rom[idx[15:0] | 16'd1];
          // read: right-aligned per size; doubleword as two words
          case (dmr.size)
            2'd0: dms.rdata[31:0] <= {24'd0, w0[8 * (3 - int'(pa[1:0])) +: 8]};
            2'd1: dms.rdata[31:0] <= {16'd0, pa[1] ? w0[15:0] : w0[31:16]};
            2'd2: dms.rdata[31:0] <= w0;
            default: dms.rdata <= {w0, w1};
          endcase
          if (dmr.write && is_ram) begin
            case (dmr.size)
              2'd0: ram[idx][8 * (3 - int'(pa[1:0])) +: 8] <= dmr.wdata[7:0];
              2'd1: if (pa[1]) ram[idx][15:0] <= dmr.wdata[15:0]; else ram[idx][31:16] <= dmr.wdata[15:0];
              2'd2: ram[idx] <= dmr.wdata[31:0];
              default: begin ram[idx] <= dmr.wdata[63:32]; ram[idx | 22'd1] <= dmr.wdata[31:0]; end
            endcase
          end
          if (dmr.atomic && is_ram) begin
            // ldstub: the byte read, 0xFF written; swap: the word exchanged
            if (dmr.size == 2'd0) ram[idx][8 * (3 - int'(pa[1:0])) +: 8] <= 8'hFF;
            else ram[idx] <= dmr.wdata[31:0];
          end
        end
      end
    end else if (rsp_pending && esc_rsp.ack) begin
      rsp_pending <= 1'b0;
      dms.ack <= 1'b1;
      // the ESCC returns its byte in every lane
      dms.rdata[31:0] <= {24'd0, esc_rsp.rdata[7:0]};
    end
  end

  // ---- ttya: the bytes the ROM writes to the ESCC's channel A data register ----
  logic quiet;
  initial quiet = $test$plusargs("dmem") || $test$plusargs("trace");
  always_ff @(posedge clk) begin
    if (u_escc.dat_wr_a && !quiet) begin
      $write("%c", u_escc.wbyte);
      $fflush();
    end
  end

  // ---- +trace: every instruction as it commits, and the traps ----
  logic trace;
  initial trace = $test$plusargs("trace");
  always_ff @(posedge clk) begin
    if (trace && u_iu.w_valid && !u_iu.w_stall) begin
      if (u_iu.w_trap)
        $display("%8d  %08x  TRAP tt=%02x  (npc %08x) cwp %0d et %0d", cyc, u_iu.w_pc, u_iu.w_tt, u_iu.w_npc, u_iu.cwp, u_iu.et);
      else
        $display("%8d  %08x  %-10s rd=%0d r=%08x  icc=%b cwp=%0d", cyc, u_iu.w_pc, u_iu.w_dec.cls.name(), u_iu.w_dec.rd,
                 u_iu.w_rdval, u_iu.icc, u_iu.cwp);
    end
  end

  // ---- +dbg: pipeline internals in a cycle window (+from=N +to=N) ----
  longint dbg_from, dbg_to;
  initial begin
    if (!$value$plusargs("from=%d", dbg_from)) dbg_from = 0;
    if (!$value$plusargs("to=%d", dbg_to)) dbg_to = -1;
  end
  always_ff @(posedge clk) begin
    if (cyc >= dbg_from && cyc <= dbg_to)
      $display("%8d D v%0d pc=%08x npc=%08x go%0d | E v%0d pc=%08x npc=%08x go%0d res%0d | M v%0d pc=%08x | W v%0d pc=%08x | F pc=%08x npc=%08x pend%0d(%08x d%0d) buf%0d(%08x) rsp%0d take%0d | redir%0d->%08x slot d%0d a%0d b%0d p%0d",
               cyc, u_iu.d_valid, u_iu.d_pc, u_iu.d_npc, u_iu.d_go, u_iu.e_valid, u_iu.e_pc, u_iu.e_npc, u_iu.e_go, u_iu.e_resolved,
               u_iu.m_valid, u_iu.m_pc, u_iu.w_valid, u_iu.w_pc,
               u_iu.f_pc, u_iu.f_npc, u_iu.f_pending, u_iu.f_pend_pc, u_iu.f_pend_discard, u_iu.f_have, u_iu.f_buf_pc, u_iu.rsp_valid, u_iu.f_take,
               u_iu.redirect, u_iu.redirect_target, u_iu.slot_in_d, u_iu.slot_arriving, u_iu.slot_in_buf, u_iu.slot_pending);
  end

  // ---- +dmem: every data access as it is acknowledged ----
  always_ff @(posedge clk) begin
    if ($test$plusargs("dmem") && dmr.valid && dms.ack)
      $display("%8d  dmem %s asi=%02x va=%08x pa=%09x size=%0d wdata=%016x rdata=%016x fault=%0d",
               cyc, dmr.write ? "W" : (dmr.atomic ? "A" : "R"), dmr.asi, dmr.va, pa, dmr.size, dmr.wdata, dms.rdata, dms.fault);
  end

  // ---- stop at the end, or on the budget / error mode ----
  string line = "";
  longint cyc = 0;
  always_ff @(posedge clk) begin
    cyc <= cyc + 1;
    if (u_escc.dat_wr_a) begin
      if (u_escc.wbyte == 8'h0A) begin
        if (line.substr(0, 11) == "CPUTEST DONE") begin
          $display("");
          $display("iu_sim: done after %0d cycles", cyc);
          $finish;
        end
        line = "";
      end else if (u_escc.wbyte != 8'h0D) line = {line, string'(u_escc.wbyte)};
    end
    if (error) begin
      $display("");
      $display("iu_sim: error mode (a trap with ET = 0) after %0d cycles, pc %08x", cyc, u_iu.w_pc);
      $finish;
    end
    if (cyc > CYCLES) begin
      $display("");
      $display("iu_sim: cycle budget exhausted; pc %08x", u_iu.f_pc);
      $finish;
    end
  end

  initial begin
    repeat (4) @(posedge clk);
    rst = 0;
  end
endmodule
