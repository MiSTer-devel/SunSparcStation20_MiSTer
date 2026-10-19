// SPDX-License-Identifier: GPL-2.0-or-later
//
// iu: the SPARC V8 integer unit: a five-stage in-order pipeline (fetch,
// decode, execute, memory, write-back) with precise traps, as designed in
// docs/arch/cpu.md §1. The facts it implements are in docs/arch/iu-notes.md.
//
// From: The SPARC Architecture Manual V8: §4 (registers), §5 (instruction
//   formats), §6 (memory model: TSO; ldstub/swap atomic), §7 (traps:
//   Table 7-1 types and priorities, §7.3 trap entry — ET <- 0, PS <- S,
//   S <- 1, CWP <- CWP - 1, l1/l2 <- PC/nPC, tt, PC <- TBR; error mode on a
//   trap with ET = 0), Appendix B (every instruction's operation and its
//   traps: B.1-B.33), Appendix C (icc), Appendix F (encodings, in
//   iu_decode). QEMU target/sparc (translate.c, helper.c, win_helper.c,
//   int32_helper.c) as the behavioural cross-check; tests/cpu as the
//   acceptance suite.
//
// Stage summary:
//   F  (pc, npc) -> ifetch; one fetch outstanding, a one-entry buffer when
//      D cannot take the response. A taken DCTI in E changes the npc of its
//      delay slot (in D or still to be fetched) and drops whatever was
//      fetched after it.
//   D  iu_decode; the register file (read in the cycle the instruction is
//      taken into D, with the committed CWP); the trap tags that need only
//      the word and PSR.S/EF; the interrupt attach; stalls: load-use, a
//      serialising instruction in flight (SAVE/RESTORE/RETT/WR%psr/%wim/
//      %tbr/%y), the second half of ldd/traps in W.
//   E  operands with forwarding from E/M and M/W; iu_alu; iu_muldiv
//      (multi-cycle, the pipe holds); the address and its alignment; the
//      branch condition on the forwarded icc; SAVE/RESTORE window checks;
//      Ticc; the rett and wr %psr rules.
//   M  the dmem access, held until ack; the fault tags.
//   W  the register write (two cycles for ldd), icc/Y/PSR/WIM/TBR, the
//      trap sequence (two cycles: %l1 then %l2).
//
// The FPU (phase 2) hangs off fpu_req_o/fpu_rsp_i (fpu_pkg, docs/arch/cpu.md
// §1.7): an FP instruction waits in D while another is in E/M/W or the FPU
// is busy, so that when it reaches E the FPU's state is final: the deferred
// fp_exception, the sequence errors and the FBfcc condition are decided
// there, after the alignment check (Table 7-1: mem_address_not_aligned 10,
// fp_exception 11). An FPop is handed to the FPU when W commits it; FP
// loads write the FPU's registers (or the FSR) at W; FP stores take their
// data from the FPU in E; stdfq pops the queue at W.
//
// Left out in this version: the coprocessor (EC reads 0), FLUSH and STBAR
// as no-ops (the caches come in phase 3), the watchdog reset (error mode
// halts and raises error_o; the module resets the IU).

module iu
  import cpu_pkg::*;
#(
  parameter bit HAS_FPU = 1'b0,
  // FAST_ACK: M moves on in the cycle its memory answer arrives (a cache
  // hit: one cycle less a load or store), taking the data and fault from
  // the answer itself; else from the next cycle, from registers
  parameter bit FAST_ACK = 1'b1,
  // BPRED: a Bicc/FBfcc that branches back, BA/FBA and CALL are predicted
  // taken as they arrive from the cache (the fetch after their delay slot
  // is their target); E redirects only when the guess was wrong (to pc+8)
  parameter bit BPRED = 1'b1,
  // FP_OVERLAP: an FPop or FP load does not wait in D for the FP work ahead;
  // it waits in W, where it meets the FPU, until the FPU is idle (and takes
  // a deferred fp_exception there). FP stores, FBfcc and LDFSR still wait
  // in D: they read the FPU's registers, fcc or FSR in E.
  parameter bit FP_OVERLAP = 1'b1
)(
  input  logic        clk,
  input  logic        rst,

  output ifetch_req_t ifetch_req_o,
  input  ifetch_rsp_t ifetch_rsp_i,
  output dmem_req_t   dmem_req_o,
  output logic [8:0]  dmem_nidx_o,    // the doubleword index (VA[11:3]) M holds next cycle: the D-cache reads its RAMs ahead
  input  dmem_rsp_t   dmem_rsp_i,
  output fpu_pkg::fpu_req_t fpu_req_o,
  input  fpu_pkg::fpu_rsp_t fpu_rsp_i,

  input  logic [3:0]  irl_i,          // the interrupt controller's level, 0 = none
  output logic        error_o,        // error mode: halted after a trap with ET = 0
  output logic [2:0]  cwp_o,          // for debugging
  output logic        halt_o,         // = error_o
  // for the board's hang reporter (rtl/lib/hang_dump.sv)
  output logic        dbg_commit_o,   // an instruction commits (its PC in dbg_pc_o)
  output logic        dbg_trap_o,     // a trap is taken (tt in dbg_tt_o, PC in dbg_pc_o)
  output logic [7:0]  dbg_tt_o,
  output logic [31:0] dbg_pc_o,
  output logic [31:0] dbg_psr_o,
  output logic [15:0] dbg_pipe_o
);

  // =====================================================================
  // Architectural state
  // =====================================================================
  logic [3:0]  icc;            // n z v c
  logic        ef, s, ps, et;
  logic [3:0]  pil;
  logic [2:0]  cwp;
  logic [7:0]  wim;
  logic [19:0] tba;
  logic [7:0]  tt;
  logic [31:0] y;
  logic        error;

  assign error_o = error;
  assign halt_o  = error;
  assign cwp_o   = cwp;

  function automatic logic [31:0] psr_word(input logic [3:0] i, input logic e, input logic [3:0] p,
                                           input logic sv, input logic pv, input logic ev, input logic [2:0] c);
    return {PSR_IMPL, PSR_VER, i, 6'b0, 1'b0, e, p, sv, pv, ev, 2'b00, c};
  endfunction

  // =====================================================================
  // Pipeline registers
  // =====================================================================
  // D
  logic        d_valid;
  logic [31:0] d_inst, d_pc, d_npc;
  logic [7:0]  d_tt;           // trap tag (valid when d_trap)
  logic        d_trap;
  logic        d_annulled;     // the delay slot was annulled: a no-op
  logic        d_pred, e_pred; // BPRED: the fetch already went to this DCTI's target after its slot
  // E
  logic        e_valid;
  dec_t        e_dec;
  logic [31:0] e_inst;         // the word, for the FPU
  logic [31:0] e_pc, e_npc;
  logic        e_trap;
  logic [7:0]  e_tt;
  logic [31:0] e_rs1, e_rs2, e_rs3, e_rs4;   // register values read in D (before forwarding)
  // M
  logic        m_valid;
  dec_t        m_dec;
  logic [31:0] m_inst;
  logic [31:0] m_pc, m_npc;
  logic        m_trap;
  logic [7:0]  m_tt;
  logic [31:0] m_result;       // the ALU result / address / link / rd value; the wr %y/%psr/%wim/%tbr value
  logic [63:0] m_wdata;        // store data (rs3, rs4) after forwarding
  logic [3:0]  m_icc;
  logic        m_wicc;         // writes icc
  logic [31:0] m_y;
  logic        m_wy;
  logic [2:0]  m_newcwp;
  // W
  logic        w_valid;
  /* verilator lint_off UNUSEDSIGNAL */   // W needs only cls, rd, size, sgn, wr_rd of the decode
  dec_t        w_dec;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] w_inst;
  logic [31:0] w_pc, w_npc;
  logic        w_trap;
  logic [7:0]  w_tt;
  logic [31:0] w_result;
  logic [63:0] w_rdata;
  logic [3:0]  w_icc;
  logic        w_wicc;
  logic [31:0] w_y;
  logic        w_wy;
  logic [2:0]  w_newcwp;
  logic        w_second;       // the second cycle of ldd / of a trap (l2)
  logic        w_fp_hold, w_fp_cvt; // FP_OVERLAP: W waits for the FPU / takes the deferred trap (below)

  // =====================================================================
  // Stall and flush control
  // =====================================================================
  logic f_take;                // D takes an instruction this cycle
  logic d_go, e_go, m_go;      // the stage hands its instruction on this cycle
  logic d_stall, e_stall, m_stall, w_stall;
  logic flush;                 // a trap is taken at W: drop D/E/M and F's fetches
  logic redirect;              // E resolved a taken DCTI
  logic [31:0] redirect_target;
  logic annul_slot;            // E says: the delay slot is annulled

  // =====================================================================
  // F: fetch
  // =====================================================================
  logic [31:0] f_pc, f_npc;    // the next instruction to issue and its successor
  logic        f_pending;      // a fetch is outstanding
  logic [31:0] f_pend_pc, f_pend_npc;
  logic        f_pend_discard; // the outstanding fetch is for a dropped path
  logic        f_have;         // the one-entry buffer holds an instruction
  logic [31:0] f_buf_inst, f_buf_pc, f_buf_npc;
  logic [1:0]  f_buf_fault;
  logic        f_annul_next;   // the next instruction to enter D is an annulled delay slot
  logic        f_buf_annul;    // the buffered instruction is an annulled delay slot
  logic        f_slot_pending; // the delay slot of the DCTI in E has not entered D yet
  logic        rsp_valid;      // a usable response this cycle
  logic        can_issue;

  // A response is taken unless the buffer is full and stays full (D does
  // not take from it this cycle); one for a dropped path is always taken.
  // (f_take_buf is f_take when the buffer holds the instruction for D.)
  logic        f_take_buf, rsp_ready, rsp_taken, rsp_to_buf;
  assign rsp_ready = f_pend_discard | ~f_have | f_take_buf;
  assign rsp_taken = ifetch_rsp_i.valid & rsp_ready;
  assign rsp_valid = ifetch_rsp_i.valid & f_pending & ~f_pend_discard & (~f_have | f_take_buf);

  // BPRED: the instruction arriving now, if a DCTI predicted taken whose
  // delay slot has not been issued before this cycle (it is issued now, or
  // later): the fetch after the slot is its target. Not for a DCTI in a
  // delay slot (npc != pc + 4) nor while a redirect or trap changes the
  // stream this very cycle. Nor for a target of pc + 4 (NetBSD's locore has
  // "ba,a .+4; wr %tbr"): the slot and the target would have the same pc,
  // the slot is known by its pc, and annulling the slot annulled the target.
  // (Bits 21:0 only, for CALL too: a call that loses its guess is harmless.)
  logic        pr_ok;
  logic [31:0] pr_target, pr_target4;   // (target + 4 from pc + 4: two adders side by side, not in series)
  always_comb begin
    logic [31:0] inst;
    logic        bcc, call, back;
    inst = ifetch_rsp_i.inst;
    bcc  = inst[31:30] == 2'b00 && (inst[24:22] == 3'b010 || inst[24:22] == 3'b110);   // Bicc, FBfcc
    call = inst[31:30] == 2'b01;
    back = inst[21];                                                                 // disp22 < 0
    pr_target  = f_pend_pc + (call ? {inst[29:0], 2'b00} : {{8{inst[21]}}, inst[21:0], 2'b00});
    pr_target4 = (f_pend_pc + 32'd4) + (call ? {inst[29:0], 2'b00} : {{8{inst[21]}}, inst[21:0], 2'b00});
    pr_ok = BPRED && rsp_valid && ifetch_rsp_i.fault == 2'd0 &&
            (call || (bcc && (inst[28:25] == 4'h8 || (inst[28:25] != 4'h0 && back)))) && inst[21:0] != 22'd1 &&
            f_pend_npc == f_pend_pc + 32'd4 && f_pc == f_pend_pc + 32'd4 && !redirect && !flush;
  end
  logic        f_buf_pred;     // the buffered instruction is a predicted DCTI

  // What D would take this cycle
  logic        take_from_buf;
  logic [31:0] take_inst, take_pc, take_npc;
  logic [1:0]  take_fault;
  logic        take_pred;
  logic        take_avail;
  always_comb begin
    take_from_buf = f_have;
    take_avail = f_have | rsp_valid;
    if (f_have) begin
      take_inst = f_buf_inst; take_pc = f_buf_pc; take_npc = f_buf_npc; take_fault = f_buf_fault;
      take_pred = f_buf_pred;
    end else begin
      take_pred = pr_ok;
      take_inst = ifetch_rsp_i.inst; take_pc = f_pend_pc; take_npc = f_pend_npc; take_fault = ifetch_rsp_i.fault;
    end
  end

  // The delay slot of the DCTI resolving in E is the instruction at its npc
  // (pc + 4, or the first DCTI's target when this one sits in a delay slot:
  // the jmpl/rett couple), wherever it is: in D, arriving now, in the
  // buffer, outstanding, or not issued yet. Everything behind it is dropped
  // on a redirect.
  logic [31:0] slot_pc;
  logic        slot_in_d, slot_arriving, slot_in_buf, slot_pending;
  assign slot_pc       = e_npc;
  assign slot_in_d     = d_valid && d_pc == slot_pc;
  assign slot_arriving = !slot_in_d && rsp_valid && f_pend_pc == slot_pc;
  assign slot_in_buf   = !slot_in_d && f_have && f_buf_pc == slot_pc;
  assign slot_pending  = !slot_in_d && !slot_in_buf && f_pending && !f_pend_discard && f_pend_pc == slot_pc && !rsp_valid;

  // D takes the instruction unless a redirect drops it (it is behind the slot)
  assign f_take = take_avail & ~d_stall & ~flush & ~error & ~(redirect & ~(take_pc == slot_pc));
  assign f_take_buf = f_have & ~d_stall & ~flush & ~error & ~(redirect & ~(f_buf_pc == slot_pc));
  // the arriving response goes to the buffer unless D takes it directly
  // (it does only with the buffer empty)
  assign rsp_to_buf = rsp_valid & (f_have | ~f_take);
  logic [31:0] take_npc_eff;
  logic        take_annul;
  assign take_npc_eff = (redirect && take_pc == slot_pc) ? redirect_target : take_npc;
  assign take_annul   = f_annul_next | (annul_slot && take_pc == slot_pc) | (take_from_buf & f_buf_annul);
  // A fetch that faulted enters the pipe and will trap: no more fetches
  // until its trap flushes, so that a second fault on the same page is not
  // recorded over the first (SFSR.OW; Solaris reads OW as "re-probe" and
  // loops: t_mmu_ifault)
  // The hold lasts while that instruction is still on its way to its trap:
  // in the buffer, or in D/E/M/W with an instruction-access tt. A faulted
  // fetch that never traps — an annulled delay slot (bne,a not taken, its
  // slot on an unmapped page), or one dropped behind a taken DCTI's slot —
  // releases it; holding on would leave the pipe empty for good, and an
  // empty pipe takes no interrupt (Solaris froze at Xsun's first client,
  // 2026-10-12: #HANGC with fetch va = the annulled slot + 4).
  function automatic logic is_ifault_tt(input logic [7:0] t);
    return t == TT_INST_ACCESS_EXC || t == TT_INST_ACCESS_ERR;
  endfunction
  logic ifault_hold, ifault_live;
  logic d_annul_now;            // (assigned with D below)
  assign ifault_live = (f_have && f_buf_fault != 2'd0) ||
                       (d_valid && d_trap && is_ifault_tt(d_tt) && !d_annul_now) ||
                       (e_valid && e_trap && is_ifault_tt(e_tt)) ||
                       (m_valid && m_trap && is_ifault_tt(m_tt)) ||
                       (w_valid && w_trap && is_ifault_tt(w_tt));
  always_ff @(posedge clk) begin
    if (rst || flush) ifault_hold <= 1'b0;
    else if (rsp_valid && ifetch_rsp_i.fault != 2'd0) ifault_hold <= 1'b1;
    else if (!ifault_live) ifault_hold <= 1'b0;
  end

  // Issue a new fetch when nothing is outstanding (or its response arrives
  // now) and the buffer is empty: the arriving response then has D or the
  // buffer, and the new one, if the buffer is still full when it comes,
  // waits in the module (ready low). Registered state only, apart from
  // the response's valid, so that the cache's answer and the next request
  // are a short path.
  assign can_issue = ~error & ~flush & (~f_pending | ifetch_rsp_i.valid) & ~f_have &
                     ~ifault_hold & ~(rsp_valid & (ifetch_rsp_i.fault != 2'd0));

  assign ifetch_req_o.valid = can_issue;
  assign ifetch_req_o.va    = f_pc;
  assign ifetch_req_o.supv  = s;
  assign ifetch_req_o.ready = rsp_ready;

  always_ff @(posedge clk) begin
    if (rst) begin
      f_pc <= 32'd0;
      f_npc <= 32'd4;
      f_pending <= 1'b0;
      f_pend_pc <= '0; f_pend_npc <= '0;
      f_pend_discard <= 1'b0;
      f_have <= 1'b0;
      f_buf_inst <= '0; f_buf_pc <= '0; f_buf_npc <= '0; f_buf_fault <= '0; f_buf_pred <= 1'b0;
      f_annul_next <= 1'b0;
      f_buf_annul <= 1'b0;
      f_slot_pending <= 1'b0;
    end else begin
      // the outstanding fetch
      if (can_issue) begin
        f_pending <= 1'b1;
        f_pend_pc <= f_pc;
        f_pend_npc <= f_npc;
        f_pend_discard <= 1'b0;
        f_pc <= f_npc;
        f_npc <= f_npc + 32'd4;
      end else if (rsp_taken) begin
        f_pending <= 1'b0;
      end
      // the buffer
      if (f_take && f_have) f_have <= 1'b0;
      if (rsp_to_buf) begin
        f_have <= 1'b1;
        f_buf_inst <= ifetch_rsp_i.inst;
        f_buf_pc <= f_pend_pc;
        f_buf_npc <= f_pend_npc;
        f_buf_fault <= ifetch_rsp_i.fault;
        f_buf_pred <= pr_ok;
      end
      // BPRED: the slot is issued with the target as its npc (now), or the
      // target follows it when it is issued (later)
      if (pr_ok) begin
        if (can_issue) begin
          f_pend_npc <= pr_target;
          f_pc <= pr_target;
          f_npc <= pr_target4;
        end else begin
          f_npc <= pr_target;
        end
      end
      if (f_take && f_have) f_buf_annul <= 1'b0;
      if (rsp_to_buf) f_buf_annul <= 1'b0;          // marked below if it is the annulled slot
      // the annulled-slot marker is consumed by the next instruction into D
      if (f_take) f_annul_next <= 1'b0;

      // A taken DCTI in E: the slot keeps its place, its npc becomes the
      // target, and whatever was fetched behind it is dropped, including a
      // fetch issued in this very cycle.
      if (redirect) begin
        f_pc  <= redirect_target;
        f_npc <= redirect_target + 32'd4;
        if (can_issue && f_pc != slot_pc) f_pend_discard <= 1'b1;   // issued now, behind the slot
        if (slot_in_d || slot_arriving) begin
          if (!slot_arriving && f_pending && !rsp_taken) f_pend_discard <= 1'b1;
          if (!(slot_arriving && rsp_to_buf)) f_have <= 1'b0;
        end else if (slot_in_buf) begin
          f_buf_npc <= redirect_target;
          f_buf_pred <= 1'b0;                        // (what it predicted is dropped with the rest)
          if (f_pending && !rsp_taken) f_pend_discard <= 1'b1;
          if (f_take_buf) f_have <= 1'b0;            // the slot goes to D; a response arriving is behind it
        end else if (slot_pending) begin
          f_pend_npc <= redirect_target;
        end else if (can_issue && f_pc == slot_pc) begin
          f_pend_npc <= redirect_target;            // the slot is being issued now
        end else begin
          // not issued yet: f_pc is the slot; its successor is the target
          f_pc  <= f_pc;
          f_npc <= redirect_target;
        end
      end
      // the response of the slot arriving while D stalls goes to the buffer
      // with the new npc
      if (rsp_to_buf && redirect && slot_arriving) begin f_buf_npc <= redirect_target; f_buf_pred <= 1'b0; end
      if (annul_slot) begin
        if (slot_arriving && rsp_to_buf) f_buf_annul <= 1'b1;
        else if (slot_in_buf && !f_take_buf) f_buf_annul <= 1'b1;   // (taken now: take_annul has it)
        else if (!slot_in_d && !slot_arriving && !slot_in_buf) f_annul_next <= 1'b1;
      end

      // A trap at W: everything younger goes
      if (flush) begin
        f_pc <= {tba, tt_next, 4'b0000};
        f_npc <= {tba, tt_next, 4'b0000} + 32'd4;
        if (f_pending) f_pend_discard <= 1'b1;
        f_have <= 1'b0;
        f_annul_next <= 1'b0;
        f_buf_annul <= 1'b0;
      end
    end
  end

  // =====================================================================
  // D: decode and register read
  // =====================================================================
  dec_t  d_dec;
  logic  d_supv_for_dec;
  iu_decode u_dec (.inst_i(d_inst), .supv_i(s), .ef_i(HAS_FPU ? ef : 1'b0), .dec_o(d_dec));

  // Register file: addresses from the instruction being taken (or held)
  logic [4:0]  rf_rs1, rf_rs2, rf_rs3, rf_rs4;
  logic [31:0] rf_q1, rf_q2, rf_q3, rf_q4;
  logic        rf_we;
  logic [4:0]  rf_rd;
  logic [2:0]  rf_wcwp;
  logic [31:0] rf_wdata;
  logic [31:0] src_inst;
  assign src_inst = f_take ? take_inst : d_inst;
  assign rf_rs1 = src_inst[18:14];
  assign rf_rs2 = src_inst[4:0];
  assign rf_rs3 = src_inst[29:25];
  assign rf_rs4 = {src_inst[29:26], 1'b1};

  iu_regfile u_rf (
    .clk, .rs1_i(rf_rs1), .rs2_i(rf_rs2), .rs3_i(rf_rs3), .rs4_i(rf_rs4), .rcwp_i(cwp),
    .rs1_o(rf_q1), .rs2_o(rf_q2), .rs3_o(rf_q3), .rs4_o(rf_q4),
    .we_i(rf_we), .rd_i(rf_rd), .wcwp_i(rf_wcwp), .wdata_i(rf_wdata));

  // Serialising instructions in flight: D waits for them to commit
  function automatic logic serialising(input cls_t c);
    return c == C_SAVE || c == C_RESTORE || c == C_RETT || c == C_WRPSR ||
           c == C_WRWIM || c == C_WRTBR || c == C_WRY;
  endfunction
  function automatic logic reads_state(input cls_t c, input logic [5:0] op3);   // needs the committed Y/PSR/WIM/TBR
    return c == C_RDY || c == C_RDPSR || c == C_RDWIM || c == C_RDTBR ||
           c == C_DIV || (c == C_ALU && op3 == 6'h24);   // mulscc reads Y
  endfunction

  // ... and one cycle more after it commits: the register file is read
  // synchronously, so the read issued with the new CWP completes a cycle
  // after the write-back that set it.
  logic ser_inflight, ser_commit_q;
  always_ff @(posedge clk) begin
    if (rst) ser_commit_q <= 1'b0;
    else ser_commit_q <= w_valid && !w_stall && serialising(w_dec.cls);
  end
  assign ser_inflight = (e_valid && serialising(e_dec.cls)) || (m_valid && serialising(m_dec.cls)) ||
                        (w_valid && serialising(w_dec.cls)) || ser_commit_q;

  // Load-use: the instruction in E is a load whose rd is a source of D's —
  // or the load has moved on to M and its data has not come back yet (a
  // cache miss, a table walk, a slow bus). D must wait for that too: an
  // instruction in E re-latches its operands every cycle, but a JMPL/RETT
  // uses its target in E at once to redirect the fetch, and the forwarding
  // path only has the load's value once it is acked. (OpenBIOS:
  // ld [%g1+0x240],%g1; jmpl %g1 — without the wait the jump took the old %g1.)
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic d_uses_rd_of(input dec_t ld, input logic dbl);
    logic u;
    u = 1'b0;
    if (ld.rd != 5'd0) begin
      if (d_dec.rs1 == ld.rd) u = 1'b1;
      if (!d_dec.imm && d_dec.rs2 == ld.rd) u = 1'b1;
      if ((d_dec.cls == C_STORE || d_dec.cls == C_ATOMIC) && d_dec.rd == ld.rd) u = 1'b1;
      if (d_dec.cls == C_STORE && d_dec.size == 2'd3 && {d_dec.rd[4:1], 1'b1} == ld.rd) u = 1'b1;
      if (dbl && {ld.rd[4:1], 1'b1} == d_dec.rs1) u = 1'b1;
      if (dbl && !d_dec.imm && {ld.rd[4:1], 1'b1} == d_dec.rs2) u = 1'b1;
    end
    return u;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */
  logic e_is_load, m_load_pending;
  assign e_is_load = e_valid && (e_dec.cls == C_LOAD || e_dec.cls == C_ATOMIC);
  assign m_load_pending = m_valid && !m_trap && (m_dec.cls == C_LOAD || m_dec.cls == C_ATOMIC) &&
                          !m_acked && !dmem_rsp_i.ack;
  logic d_uses_rd_of_e;
  always_comb begin
    d_uses_rd_of_e = 1'b0;
    if (e_is_load)       d_uses_rd_of_e |= d_uses_rd_of(e_dec, e_dec.size == 2'd3);
    if (m_load_pending)  d_uses_rd_of_e |= d_uses_rd_of(m_dec, m_dec.size == 2'd3);
  end

  // FP instructions go one at a time: the next waits in D until the one
  // ahead has left W and the FPU is idle, so that the FPU's state (the
  // exception state, fcc, the registers an FP store reads) is final in E.
  function automatic logic is_fp(input cls_t c);
    return c == C_FPOP || c == C_FBFCC || c == C_FPLOAD || c == C_FPSTORE;
  endfunction
  logic fp_inflight;
  assign fp_inflight = (e_valid && is_fp(e_dec.cls)) || (m_valid && is_fp(m_dec.cls)) ||
                       (w_valid && is_fp(w_dec.cls)) || fpu_rsp_i.busy;

  // D stalls (keeps its instruction) when E cannot take it
  logic d_hazard;
  // With a serialising instruction in flight every instruction waits: the
  // window, S, ET and PIL may all change (rare enough; a later version can
  // forward the window and let the independent ones through).
  logic d_fp_quiet;            // this FP instruction needs the FP work ahead finished in E
  assign d_fp_quiet = is_fp(d_dec.cls) &&
                      (!FP_OVERLAP || d_dec.cls == C_FPSTORE || d_dec.cls == C_FBFCC || (d_dec.cls == C_FPLOAD && d_dec.fsr));
  assign d_hazard = d_valid && !d_trap && (d_uses_rd_of_e || ser_inflight || (d_fp_quiet && fp_inflight));

  assign d_go    = d_valid && !e_stall && !d_hazard;
  assign d_stall = d_valid && !d_go;

  // The interrupt attached to the instruction entering D
  logic irq_take;
  assign irq_take = et && !ser_inflight && !(d_valid && serialising(d_dec.cls)) && (irl_i == 4'd15 || irl_i > pil);

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      d_valid <= 1'b0;
      d_inst <= '0; d_pc <= '0; d_npc <= '0; d_tt <= '0; d_trap <= 1'b0; d_annulled <= 1'b0; d_pred <= 1'b0;
    end else begin
      if (f_take) begin
        d_valid <= 1'b1;
        d_inst <= take_inst;
        d_pc <= take_pc;
        d_npc <= take_npc_eff;
        d_pred <= take_pred && !(redirect && take_pc == slot_pc);
        d_annulled <= take_annul;
        // trap tags that come with the fetch, or the interrupt
        d_trap <= 1'b0;
        d_tt <= '0;
        if (take_fault == 2'd1) begin d_trap <= 1'b1; d_tt <= TT_INST_ACCESS_EXC; end
        else if (take_fault == 2'd2) begin d_trap <= 1'b1; d_tt <= TT_INST_ACCESS_ERR; end
        else if (irq_take && !take_annul) begin
          d_trap <= 1'b1; d_tt <= TT_INTERRUPT_BASE + {4'd0, irl_i};
        end
      end else if (d_go) begin
        d_valid <= 1'b0;
      end
      // the DCTI in E resolves while its delay slot sits in D (when the slot
      // leaves D at this edge, the E latch below takes these instead)
      if (slot_in_d && redirect && !d_go) begin d_npc <= redirect_target; d_pred <= 1'b0; end
      if (slot_in_d && annul_slot && !d_go) d_annulled <= 1'b1;
    end
  end

  // =====================================================================
  // E: execute
  // =====================================================================
  // An annulled instruction becomes a NOP (an assignment pattern with a
  // named member is not accepted by Quartus 17)
  function automatic dec_t nop_dec();
    dec_t d;
    d = '0;
    d.cls = C_NOP;
    return d;
  endfunction

  // The instruction in D is annulled: marked earlier, or the DCTI in E says so now
  assign d_annul_now = d_annulled | (slot_in_d & annul_slot);

  // The decoded instruction and its register values move from D
  always_ff @(posedge clk) begin
    if (rst || flush) begin
      e_valid <= 1'b0;
      // (the data -- e_inst, e_pc, e_npc, e_rs1..4 -- is not cleared: nothing
      // reads it without e_valid, and the clear cost a LUT input on each bit)
      e_dec <= '0; e_trap <= 1'b0; e_tt <= '0; e_pred <= 1'b0;
    end else if (d_go) begin
      e_valid <= 1'b1;
      e_dec <= d_annul_now ? nop_dec() : d_dec;
      e_inst <= d_inst;
      e_pc <= d_pc;
      e_npc <= (slot_in_d && redirect) ? redirect_target : d_npc;
      e_pred <= d_pred && !(slot_in_d && redirect);
      // the RF output is a cycle old: a write landing at this edge is taken here
      e_rs1 <= (rf_we && rf_rd == d_dec.rs1) ? rf_wdata : rf_q1;
      e_rs2 <= (rf_we && rf_rd == d_dec.rs2) ? rf_wdata : rf_q2;
      e_rs3 <= (rf_we && rf_rd == d_dec.rd) ? rf_wdata : rf_q3;
      e_rs4 <= (rf_we && rf_rd == {d_dec.rd[4:1], 1'b1}) ? rf_wdata : rf_q4;
      // decode-time traps, in priority order after the fetch's
      e_trap <= 1'b0;
      e_tt <= '0;
      // An annulled instruction is not executed, so it takes no trap: a
      // fetch fault or an interrupt tagged on a delay slot that the DCTI
      // annulled after the slot entered D is dropped (the interrupt, a
      // level, is taken on the next instruction). Taking it saved PC = the
      // annulled slot, and RETT then executed it: NetBSD's idle_loop ran
      // an annulled SAVE on return from a clock interrupt and continued a
      // window deeper (mutex_enter(NULL) from statclock).
      if (d_trap && !d_annul_now) begin e_trap <= 1'b1; e_tt <= d_tt; end
      else if (!d_annul_now) begin
        if (d_dec.trap_priv)             begin e_trap <= 1'b1; e_tt <= TT_PRIV_INST; end
        else if (d_dec.trap_illegal)     begin e_trap <= 1'b1; e_tt <= TT_ILLEGAL_INST; end
        else if (d_dec.trap_fp_disabled) begin e_trap <= 1'b1; e_tt <= TT_FP_DISABLED; end
        else if (d_dec.trap_cp_disabled) begin e_trap <= 1'b1; e_tt <= TT_CP_DISABLED; end
      end
    end else if (e_go) begin
      e_valid <= 1'b0;
    end else if (e_valid) begin
      e_rs1 <= a_fwd; e_rs2 <= b_fwd; e_rs3 <= rs3v; e_rs4 <= rs4v;
    end
  end

  // A load's value, extended per its size (the even register of an ldd)
  function automatic logic [31:0] ld_extend(input logic [1:0] size, input logic sgn, input logic [63:0] d);
    case (size)
      2'd0: return sgn ? {{24{d[7]}}, d[7:0]} : {24'd0, d[7:0]};
      2'd1: return sgn ? {{16{d[15]}}, d[15:0]} : {16'd0, d[15:0]};
      2'd3: return d[63:32];
      default: return d[31:0];
    endcase
  endfunction

  // Forwarding: the latest value of a register among M (with a load's data
  // once its response is in), W and the value read in D. While an
  // instruction waits in E its operands are re-latched every cycle, so a
  // value seen in W is kept after W moves on.
  function automatic logic [31:0] fwd(input logic [4:0] r, input logic [31:0] rf_val);
    logic m_is_ld;
    if (r == 5'd0) return 32'd0;
    m_is_ld = m_dec.cls == C_LOAD || m_dec.cls == C_ATOMIC;
    if (m_valid && m_dec.wr_rd && !m_trap && (!m_is_ld || m_acked)) begin
      if (m_dec.rd == r) return m_is_ld ? ld_extend(m_dec.size, m_dec.sgn, m_rdata) : m_result;
      if (m_dec.cls == C_LOAD && m_dec.size == 2'd3 && {m_dec.rd[4:1], 1'b1} == r) return m_rdata[31:0];
    end
    if (w_valid && w_dec.wr_rd && !w_trap) begin
      if (w_dec.rd == r) return w_rdval;
      if ((w_dec.cls == C_LOAD) && w_dec.size == 2'd3 && {w_dec.rd[4:1], 1'b1} == r) return w_rdata[31:0];
    end
    return rf_val;
  endfunction

  logic [31:0] w_rdval;        // what W writes to rd (first cycle)

  // The immediates, from the instruction word held in E (iu_decode's
  // fields of the same name are not carried into E: 87 flops a CPU)
  logic [31:0] e_simm13, e_disp22, e_disp30, e_imm22;
  assign e_simm13 = {{19{e_inst[12]}}, e_inst[12:0]};
  assign e_disp22 = {{8{e_inst[21]}}, e_inst[21:0], 2'b00};
  assign e_disp30 = {e_inst[29:0], 2'b00};
  assign e_imm22  = {e_inst[21:0], 10'd0};

  logic [31:0] a, b, a_fwd, b_fwd, rs3v, rs4v;
  always_comb begin
    a_fwd = fwd(e_dec.rs1, e_rs1);
    b_fwd = fwd(e_dec.rs2, e_rs2);
    a    = a_fwd;
    b    = e_dec.imm ? e_simm13 : b_fwd;
    rs3v = fwd(e_dec.rd, e_rs3);
    rs4v = fwd({e_dec.rd[4:1], 1'b1}, e_rs4);
  end

  // The icc the branch / Ticc / mulscc sees: the latest in flight
  logic [3:0] icc_fwd;
  always_comb begin
    if (m_valid && m_wicc && !m_trap)      icc_fwd = m_icc;
    else if (w_valid && w_wicc && !w_trap) icc_fwd = w_icc;
    else                                   icc_fwd = icc;
  end

  // The Y an instruction in E sees: the latest in flight. Multiplies and
  // MULSCC write Y without delay (only WR %y has one, and it serialises),
  // so the next MULSCC, RD %y or divide must see it: a 32-step MULSCC chain
  // (the software .umul) otherwise read a stale Y in two steps of three and
  // the NetBSD loader computed a disk address from a wrong product.
  logic [31:0] y_fwd;
  always_comb begin
    if (m_valid && m_wy && !m_trap)      y_fwd = m_y;
    else if (w_valid && w_wy && !w_trap) y_fwd = w_y;
    else                                 y_fwd = y;
  end

  // ALU
  logic [31:0] alu_r, alu_y;
  logic [3:0]  alu_icc;
  logic        alu_cc, alu_wy, alu_tag_trap;
  iu_alu u_alu (.op3_i(e_dec.op3), .a_i(a), .b_i(b), .y_i(y_fwd), .icc_i(icc_fwd),
                .r_o(alu_r), .icc_o(alu_icc), .cc_o(alu_cc), .y_o(alu_y), .wy_o(alu_wy), .tag_trap_o(alu_tag_trap));

  // Multiply / divide
  logic md_start, md_busy, md_done, md_v, md_dz, md_started;
  logic [31:0] md_r, md_y;
  logic e_is_md;
  assign e_is_md = e_valid && !e_trap && (e_dec.cls == C_MUL || e_dec.cls == C_DIV);
  assign md_start = e_is_md && !md_started && !md_busy && !m_stall;
  iu_muldiv u_md (.clk, .rst, .start_i(md_start), .kill_i(flush), .div_i(e_dec.cls == C_DIV), .signed_i(e_dec.sgn),
                  .a_i(a), .b_i(b), .y_i(y_fwd), .busy_o(md_busy), .done_o(md_done), .r_o(md_r), .y_o(md_y),
                  .v_o(md_v), .div_zero_o(md_dz));
  always_ff @(posedge clk) begin
    if (rst || flush) md_started <= 1'b0;
    else if (md_start) md_started <= 1'b1;
    else if (e_go) md_started <= 1'b0;
  end
  logic md_wait;
  assign md_wait = e_is_md && !md_done;

  // Branch condition (V8 Table F-7)
  function automatic logic cond_true(input logic [3:0] c, input logic [3:0] i);
    logic n, z, v, cc;
    logic r;
    {n, z, v, cc} = i;
    case (c[2:0])
      3'd0: r = 1'b0;                 // never
      3'd1: r = z;                    // e
      3'd2: r = z | (n ^ v);          // le
      3'd3: r = n ^ v;                // l
      3'd4: r = cc | z;               // leu
      3'd5: r = cc;                   // cs
      3'd6: r = n;                    // neg
      default: r = v;                 // vs
    endcase
    return c[3] ? ~r : r;             // the other eight are the negations (a: always)
  endfunction

  // FBfcc (V8 Table F-7): the fcc meanings E (0), L (1), G (2), U (3);
  // cond[3] negates as for Bicc
  function automatic logic fcond_true(input logic [3:0] c, input logic [1:0] fcc);
    logic fe, fl, fg, fu, r;
    fe = fcc == 2'd0; fl = fcc == 2'd1; fg = fcc == 2'd2; fu = fcc == 2'd3;
    case (c[2:0])
      3'd0: r = 1'b0;                 // never / always
      3'd1: r = ~fe;                  // ne / e
      3'd2: r = fl | fg;              // lg / ue
      3'd3: r = fu | fl;              // ul / ge
      3'd4: r = fl;                   // l / uge
      3'd5: r = fu | fg;              // ug / le
      3'd6: r = fg;                   // g / ule
      default: r = fu;                // u / o
    endcase
    return c[3] ? ~r : r;
  endfunction

  logic        e_taken;        // this instruction transfers control
  logic [31:0] e_target;
  logic        e_annul;
  logic [31:0] e_addr;
  logic        e_misaligned;
  logic [2:0]  e_newcwp;
  logic        e_tag_trap;
  logic [7:0]  e_tag_tt;
  logic        br_cond;
  logic [31:0] e_wrval;        // wr %y/%psr/%wim/%tbr: rs1 xor operand 2
  logic [31:0] e_pc_disp;      // the branch or call target, or pc + 8: one adder for all
  assign br_cond = cond_true(e_dec.cond, icc_fwd);
  assign e_addr  = a + b;
  assign e_wrval = a ^ b;
  // A predicted DCTI's target is already being fetched; E only needs where
  // it continues when the guess was wrong: pc + 8 (no register for it)
  assign e_pc_disp = e_pc + (e_pred ? 32'd8 : (e_dec.cls == C_CALL ? e_disp30 : e_disp22));

  always_comb begin
    e_taken  = 1'b0;
    e_target = e_addr;
    e_annul  = 1'b0;
    e_newcwp = cwp;
    e_misaligned = 1'b0;
    e_tag_trap = 1'b0;
    e_tag_tt = '0;
    case (e_dec.cls)
      C_BICC: begin
        e_taken  = br_cond;
        e_target = e_pc_disp;
        // annul: untaken with a = 1, or BA with a = 1 (never-branch BN with a also annuls)
        e_annul  = e_dec.annul && (!br_cond || e_dec.cond == 4'h8);
      end
      C_FBFCC: begin
        e_taken  = fcond_true(e_dec.cond, fpu_rsp_i.fsr[11:10]);
        e_target = e_pc_disp;
        e_annul  = e_dec.annul && (!e_taken || e_dec.cond == 4'h8);
      end
      C_CALL: begin
        e_taken  = 1'b1;
        e_target = e_pc_disp;
      end
      C_JMPL, C_RETT: begin
        e_taken  = 1'b1;
        e_target = e_addr;
        e_misaligned = |e_addr[1:0];
      end
      C_LOAD, C_STORE, C_ATOMIC, C_FPLOAD, C_FPSTORE: begin
        case (e_dec.size)
          2'd1: e_misaligned = e_addr[0];
          2'd2: e_misaligned = |e_addr[1:0];
          2'd3: e_misaligned = |e_addr[2:0];
          default: e_misaligned = 1'b0;
        endcase
      end
      C_SAVE:    e_newcwp = cwp - 3'd1;
      C_RESTORE: e_newcwp = cwp + 3'd1;
      default: ;
    endcase
    if (e_dec.cls == C_RETT) e_newcwp = cwp + 3'd1;

    // Execute-time traps, in Table 7-1 order
    if (e_dec.cls == C_RETT && et) begin
      e_tag_trap = 1'b1; e_tag_tt = TT_ILLEGAL_INST;
    end else if (e_dec.cls == C_WRPSR && e_wrval[4:0] >= 5'(NWINDOWS)) begin
      e_tag_trap = 1'b1; e_tag_tt = TT_ILLEGAL_INST;        // CWP out of range (t_wrpsr_cwp)
    end else if (e_dec.cls == C_SAVE && wim[e_newcwp]) begin
      e_tag_trap = 1'b1; e_tag_tt = TT_WINDOW_OVERFLOW;
    end else if ((e_dec.cls == C_RESTORE || e_dec.cls == C_RETT) && wim[e_newcwp]) begin
      e_tag_trap = 1'b1; e_tag_tt = TT_WINDOW_UNDERFLOW;
    end else if (e_misaligned) begin
      e_tag_trap = 1'b1; e_tag_tt = TT_MEM_ADDR_NOT_ALIGNED;
    end else if (is_fp(e_dec.cls) && fpu_rsp_i.exc_pending) begin
      e_tag_trap = 1'b1; e_tag_tt = TT_FP_EXCEPTION;      // the deferred exception
    end else if (fpu_rsp_i.exc_state && (e_dec.cls == C_FPOP || e_dec.cls == C_FBFCC || e_dec.cls == C_FPLOAD)) begin
      e_tag_trap = 1'b1; e_tag_tt = TT_FP_EXCEPTION;      // sequence error: only stores run in fp_exception
    end else if (e_dec.cls == C_FPSTORE && e_dec.fq && !fpu_rsp_i.fsr[13]) begin
      e_tag_trap = 1'b1; e_tag_tt = TT_FP_EXCEPTION;      // sequence error: stdfq on an empty queue
    end else if (alu_tag_trap && e_dec.cls == C_ALU) begin
      e_tag_trap = 1'b1; e_tag_tt = TT_TAG_OVERFLOW;
    end else if (e_dec.cls == C_DIV && md_dz) begin
      e_tag_trap = 1'b1; e_tag_tt = TT_DIV_BY_ZERO;
    end else if (e_dec.cls == C_TICC && br_cond) begin
      e_tag_trap = 1'b1; e_tag_tt = TT_TRAP_INST_BASE + {1'b0, e_addr[6:0]};
    end
  end

  // The result E hands to M
  logic [31:0] e_result;
  logic        e_wicc;
  logic [3:0]  e_icc;
  logic [31:0] e_y;
  logic        e_wy;
  always_comb begin
    e_result = alu_r;
    e_wicc = 1'b0;
    e_icc = alu_icc;
    e_y = alu_y;
    e_wy = 1'b0;
    case (e_dec.cls)
      C_ALU:   begin e_wicc = alu_cc; e_wy = alu_wy; end
      C_SETHI: e_result = e_imm22;
      C_CALL, C_JMPL: e_result = e_pc;                        // the link
      C_SAVE, C_RESTORE: e_result = e_addr;
      C_MUL: begin
        e_result = md_r; e_y = md_y; e_wy = 1'b1;
        e_wicc = e_dec.cc; e_icc = {md_r[31], md_r == 32'd0, 1'b0, 1'b0};
      end
      C_DIV: begin
        e_result = md_r;
        e_wicc = e_dec.cc; e_icc = {md_r[31], md_r == 32'd0, md_v, 1'b0};
      end
      C_RDY:   e_result = y_fwd;
      C_RDPSR: e_result = psr_word(icc, ef, pil, s, ps, et, cwp);
      C_RDWIM: e_result = {24'd0, wim};
      C_RDTBR: e_result = {tba, tt, 4'b0000};
      C_WRY, C_WRPSR, C_WRWIM, C_WRTBR: e_result = e_wrval;
      C_LOAD, C_STORE, C_ATOMIC, C_FPLOAD, C_FPSTORE: e_result = e_addr;
      default: ;
    endcase
  end

  // Control transfer resolution: once, when E first holds the instruction
  // and it is not trapping; the delay slot is in D or still to come
  logic e_resolved;
  always_ff @(posedge clk) begin
    if (rst || flush) e_resolved <= 1'b0;
    else if (e_go || !e_valid) e_resolved <= 1'b0;
    else if (e_valid) e_resolved <= 1'b1;
  end
  logic e_ctl_now;
  assign e_ctl_now = e_valid && !e_resolved && !e_trap && !e_tag_trap;
  // (a predicted DCTI that is not taken, or annulled -- a NOP here --
  // continues after its slot)
  assign redirect        = e_ctl_now && (e_pred ? !e_taken : e_taken);
  assign redirect_target = e_pred ? e_pc_disp : e_target;
  assign annul_slot      = e_ctl_now && e_annul;

  assign e_go    = e_valid && !m_stall && !md_wait;
  assign e_stall = e_valid && !e_go;

  // An FP store's data comes from the FPU: a register (or pair), the FSR,
  // or the front of the queue
  logic [63:0] fp_st_data;
  always_comb begin
    if (e_dec.fq)                fp_st_data = fpu_rsp_i.fq;
    else if (e_dec.fsr)          fp_st_data = {32'd0, fpu_rsp_i.fsr};
    else if (e_dec.size == 2'd3) fp_st_data = fpu_rsp_i.rd_data;
    else                         fp_st_data = {32'd0, e_dec.rd[0] ? fpu_rsp_i.rd_data[31:0] : fpu_rsp_i.rd_data[63:32]};
  end

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      m_valid <= 1'b0;
      m_dec <= '0; m_trap <= 1'b0; m_tt <= '0;          // (the data as in E)
      m_icc <= '0; m_wicc <= 1'b0; m_wy <= 1'b0; m_newcwp <= '0;
    end else if (e_go) begin
      m_valid <= 1'b1;
      m_dec <= e_dec;
      m_inst <= e_inst;
      m_pc <= e_pc;
      m_npc <= e_npc;
      m_trap <= e_trap | e_tag_trap;
      m_tt <= e_trap ? e_tt : e_tag_tt;
      m_result <= e_result;
      m_wdata <= (e_dec.cls == C_FPSTORE) ? fp_st_data :
                 (e_dec.size == 2'd3) ? {rs3v, rs4v} : {32'd0, rs3v};   // std: {even, odd}; else right-aligned
      m_icc <= e_icc;
      m_wicc <= e_wicc & ~e_trap & ~e_tag_trap;
      m_y <= e_y;
      m_wy <= e_wy & ~e_trap & ~e_tag_trap;
      m_newcwp <= e_newcwp;
    end else if (m_go) begin
      m_valid <= 1'b0;
    end
  end

  // =====================================================================
  // M: memory
  // =====================================================================
  logic m_is_mem;
  assign m_is_mem = m_valid && !m_trap && (m_dec.cls == C_LOAD || m_dec.cls == C_STORE || m_dec.cls == C_ATOMIC ||
                                           m_dec.cls == C_FPLOAD || m_dec.cls == C_FPSTORE);
  logic m_done;                // the access completed this cycle
  assign m_done = m_is_mem && dmem_rsp_i.ack;

  always_comb begin
    dmem_req_o = '0;
    // Not while the instruction in W is trapping: the trap flushes M, and an
    // access already begun (a table walk, a fill, a locked read) would run
    // for a squashed instruction and its answer -- even a fault -- land on
    // the next request (NetBSD at init: a walk fault for a store to user
    // page 0x24000 was delivered to a load of 0; the kernel ended in error
    // mode). Once an access starts, nothing older can trap any more.
    dmem_req_o.valid  = m_is_mem & ~m_acked & ~(w_valid & w_trap);
    dmem_req_o.write  = m_dec.cls == C_STORE || m_dec.cls == C_FPSTORE;
    dmem_req_o.atomic = m_dec.cls == C_ATOMIC;
    dmem_req_o.asi    = m_dec.alt ? m_dec.asi : (s ? ASI_SUPV_DATA : ASI_USER_DATA);
    dmem_req_o.va     = m_result;
    dmem_req_o.size   = m_dec.size;
    dmem_req_o.wdata  = (m_dec.cls == C_ATOMIC && !m_dec.swap) ? 64'h0000_0000_0000_00FF : m_wdata;
  end

  // An access is issued once; the response may come later
  logic m_acked;
  logic [63:0] m_rdata;
  logic [1:0]  m_fault;
  always_ff @(posedge clk) begin
    if (rst || flush || m_go) begin
      m_acked <= 1'b0;
    end else if (m_done) begin
      m_acked <= 1'b1;
      m_rdata <= dmem_rsp_i.rdata;
      m_fault <= dmem_rsp_i.fault;
    end
  end

  // the D-cache's lookup index for next cycle: E's address when E moves
  // on, else M's own (the cache's request path reads it in the accept
  // cycle). e_addr, not e_result: they are equal for every memory class,
  // and for any other class M makes no request next cycle, so the index
  // is not used; this keeps the result mux off the RAM address path.
  assign dmem_nidx_o = e_go ? e_addr[11:3] : m_result[11:3];

  assign m_go    = m_valid && !w_stall && (!m_is_mem || m_acked || (FAST_ACK && m_done));
  assign m_stall = m_valid && !m_go;
  // the access's fault: registered, or the answer of this cycle (FAST_ACK)
  logic [1:0] m_fault_now;
  assign m_fault_now = m_acked ? m_fault : dmem_rsp_i.fault;

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      w_valid <= 1'b0;
      w_dec <= '0; w_trap <= 1'b0; w_tt <= '0;          // (the data as in E)
      w_icc <= '0; w_wicc <= 1'b0; w_wy <= 1'b0; w_newcwp <= '0;
    end else if (m_go) begin
      w_valid <= 1'b1;
      w_dec <= m_dec;
      w_inst <= m_inst;
      w_pc <= m_pc;
      w_npc <= m_npc;
      w_result <= m_result;
      w_rdata <= m_acked ? m_rdata : dmem_rsp_i.rdata;
      w_icc <= m_icc;
      w_wicc <= m_wicc;
      w_y <= m_y;
      w_wy <= m_wy;
      w_newcwp <= m_newcwp;
      w_trap <= m_trap;
      w_tt <= m_tt;
      if (!m_trap && m_is_mem && m_fault_now != 2'd0) begin
        w_trap <= 1'b1;
        w_tt <= (m_fault_now == 2'd1) ? TT_DATA_ACCESS_EXC : TT_DATA_ACCESS_ERR;
      end
    end else if (w_fp_cvt) begin
      w_trap <= 1'b1;
      w_tt <= TT_FP_EXCEPTION;          // the deferred exception, taken on this FP instruction
    end else if (!w_stall) begin
      w_valid <= 1'b0;
    end
  end

  // =====================================================================
  // W: write-back and traps
  // =====================================================================
  // The load value, extended
  logic [31:0] w_ldval;
  assign w_ldval = ld_extend(w_dec.size, w_dec.sgn, w_rdata);
  assign w_rdval = (w_dec.cls == C_LOAD || w_dec.cls == C_ATOMIC) ? w_ldval : w_result;

  logic w_two_cycles;          // ldd, or a trap (l1 then l2)
  assign w_two_cycles = w_valid && ((w_trap && w_tt != TT_RESET) || (!w_trap && w_dec.cls == C_LOAD && w_dec.size == 2'd3));
  // FP_OVERLAP: an FPop or FP load waits in W while the FPU is busy (one
  // datapath, one register write port); with an exception pending it
  // becomes the fp_exception trap (below), as it would have in E
  assign w_fp_hold = HAS_FPU && FP_OVERLAP && w_valid && !w_trap &&
                     (w_dec.cls == C_FPOP || (w_dec.cls == C_FPLOAD && !w_dec.fsr)) &&
                     (fpu_rsp_i.busy || fpu_rsp_i.exc_pending);
  assign w_fp_cvt  = w_fp_hold && !fpu_rsp_i.busy;
  assign w_stall = (w_two_cycles && !w_second) || w_fp_hold;

  always_ff @(posedge clk) begin
    if (rst) w_second <= 1'b0;
    else w_second <= w_two_cycles && !w_second;
  end

  // The trap is taken in the second W cycle (both locals written)
  logic w_take_trap;
  assign w_take_trap = w_valid && w_trap && w_second;
  assign flush = w_take_trap;
  logic [7:0] tt_next;
  assign tt_next = w_tt;

  // Register file write
  always_comb begin
    rf_we = 1'b0;
    rf_rd = w_dec.rd;
    rf_wcwp = cwp;
    rf_wdata = w_rdval;
    if (w_valid && w_trap) begin
      // %l1 <- pc, %l2 <- npc in the trap's new window
      rf_we = 1'b1;
      rf_wcwp = cwp - 3'd1;
      rf_rd = w_second ? 5'd18 : 5'd17;
      rf_wdata = w_second ? w_npc : w_pc;
    end else if (w_valid && w_dec.wr_rd) begin
      rf_we = 1'b1;
      if (w_dec.cls == C_SAVE || w_dec.cls == C_RESTORE) rf_wcwp = w_newcwp;   // rd is in the new window
      if (w_dec.cls == C_LOAD && w_dec.size == 2'd3) begin
        rf_rd = w_second ? {w_dec.rd[4:1], 1'b1} : {w_dec.rd[4:1], 1'b0};
        rf_wdata = w_second ? w_rdata[31:0] : w_rdata[63:32];
      end
    end
  end

  // The FPU: an FPop is handed over when it commits; FP loads write the
  // registers or the FSR; stdfq pops the queue; a taken fp_exception is
  // reported (the FPU knows whether it was the pending one or a sequence
  // error). The register read for an FP store is addressed from E.
  logic w_commit;
  assign w_commit = w_valid && !w_stall && !w_trap && !error;

  assign dbg_commit_o = w_commit;
  assign dbg_trap_o   = w_take_trap;
  assign dbg_tt_o     = w_tt;
  assign dbg_pc_o     = w_pc;
  assign dbg_psr_o    = psr_word(icc, ef, pil, s, ps, et, cwp);
  assign dbg_pipe_o   = {d_valid, e_valid, m_valid, w_valid, m_is_mem, m_acked, w_stall, error,
                         d_hazard, w_trap, w_second, 1'b0, irl_i};
  always_comb begin
    fpu_req_o = '0;
    fpu_req_o.rd_addr    = e_dec.rd;
    fpu_req_o.fpop_valid = HAS_FPU && w_commit && w_dec.cls == C_FPOP;
    fpu_req_o.fpop_inst  = w_inst;
    fpu_req_o.fpop_pc    = w_pc;
    fpu_req_o.trap_taken = HAS_FPU && w_take_trap && et && w_tt == TT_FP_EXCEPTION;
    fpu_req_o.wr_valid   = HAS_FPU && w_commit && w_dec.cls == C_FPLOAD && !w_dec.fsr;
    fpu_req_o.wr_addr    = w_dec.rd;
    fpu_req_o.wr_dbl     = w_dec.size == 2'd3;
    fpu_req_o.wr_data    = w_rdata;
    fpu_req_o.fsr_wr     = HAS_FPU && w_commit && w_dec.cls == C_FPLOAD && w_dec.fsr;
    fpu_req_o.fsr_wdata  = w_rdata[31:0];
    fpu_req_o.fq_pop     = HAS_FPU && w_commit && w_dec.cls == C_FPSTORE && w_dec.fq;
  end

`ifndef SYNTHESIS
  // synthesis translate_off
  // +ctrace_from=N +ctrace_to=M (IU clock cycles): every instruction leaving
  // W (or trapping there), with the register it writes, ICC and Y
  longint ct_cyc, ct_from, ct_to;
  initial begin
    ct_cyc = 0;
    if (!$value$plusargs("ctrace_from=%d", ct_from)) ct_from = -1;
    if (!$value$plusargs("ctrace_to=%d", ct_to)) ct_to = -1;
  end
  // +ctrace_ring_pc=HEX: keep the last CT_RING commits and print them when
  // a trap is taken at that PC (once); +ctrace_ring_tt=HEX narrows it to a tt
  localparam int CT_RING = 30000;
  logic [31:0] cr_pc [CT_RING], cr_inst [CT_RING], cr_val [CT_RING], cr_y [CT_RING];
  logic [7:0]  cr_rd [CT_RING];
  logic [3:0]  cr_icc [CT_RING];
  logic [2:0]  cr_cwp [CT_RING];
  logic        cr_trap [CT_RING];
  longint      cr_cyc [CT_RING];
  int          cr_n;
  /* verilator lint_off UNUSEDSIGNAL */
  int          cr_i;                  // a loop index of the dump below
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] ring_pc;
  int          ring_tt;
  logic        ring_on, ring_done;
  initial begin
    cr_n = 0; ring_done = 1'b0;
    ring_on = $value$plusargs("ctrace_ring_pc=%h", ring_pc);
    if (!$value$plusargs("ctrace_ring_tt=%h", ring_tt)) ring_tt = -1;
  end
  always_ff @(posedge clk) begin
    if (ring_on && !ring_done && w_valid && !w_stall) begin
      cr_pc[cr_n % CT_RING] <= w_pc; cr_inst[cr_n % CT_RING] <= w_inst;
      cr_val[cr_n % CT_RING] <= rf_we ? rf_wdata : 32'hxxxxxxxx; cr_rd[cr_n % CT_RING] <= rf_we ? {3'd0, rf_rd} : 8'hff;
      cr_icc[cr_n % CT_RING] <= icc; cr_y[cr_n % CT_RING] <= y; cr_cwp[cr_n % CT_RING] <= cwp;
      cr_trap[cr_n % CT_RING] <= w_trap; cr_cyc[cr_n % CT_RING] <= ct_cyc;
      cr_n <= cr_n + 1;
      if (w_trap && w_pc == ring_pc && (ring_tt < 0 || w_tt == 8'(ring_tt))) begin
        ring_done <= 1'b1;
        $display("ctring: trap tt=%02x at pc=%08x, cycle %0d; the last %0d commits:", w_tt, w_pc, ct_cyc, cr_n < CT_RING ? cr_n : CT_RING);
        for (int k = (cr_n < CT_RING ? 0 : cr_n - CT_RING); k < cr_n; k++) begin
          /* verilator lint_off BLKSEQ */
          cr_i = k % CT_RING;
          /* verilator lint_on BLKSEQ */
          if (cr_rd[cr_i] == 8'hff)
            $display("ct %0d pc=%08x i=%08x%s rd=0(-)=00000000 icc=%x y=%08x cwp=%0d", cr_cyc[cr_i], cr_pc[cr_i], cr_inst[cr_i], cr_trap[cr_i] ? " TRAP" : "", cr_icc[cr_i], cr_y[cr_i], cr_cwp[cr_i]);
          else
            $display("ct %0d pc=%08x i=%08x%s rd=%0d=%08x icc=%x y=%08x cwp=%0d", cr_cyc[cr_i], cr_pc[cr_i], cr_inst[cr_i], cr_trap[cr_i] ? " TRAP" : "", cr_rd[cr_i], cr_val[cr_i], cr_icc[cr_i], cr_y[cr_i], cr_cwp[cr_i]);
        end
        $display("ctring: end");
        $fflush();
      end
    end
  end
  always_ff @(posedge clk) begin
    ct_cyc <= ct_cyc + 1;
    if (ct_from >= 0 && ct_cyc >= ct_from && ct_cyc <= ct_to && w_valid && !w_stall)
      $display("ct %0d pc=%08x i=%08x%s%s rd=%0d%s=%08x icc=%x y=%08x cwp=%0d %m", ct_cyc, w_pc, w_inst,
               w_trap ? " TRAP" : "", w_second ? " 2nd" : "", rf_rd, rf_we ? "" : "(-)", rf_wdata, icc, y, cwp);
  end

  // +perf: every 10M cycles (+perf_period=N), where this IU's cycles went, each cycle given
  // to the oldest stage that explains it: a commit (user/supervisor), W's
  // second cycle, M waiting on a load / a store or atomic, E waiting on
  // mul/div, D held for an FP op in flight / another hazard (load-use,
  // serialising), D empty (fetch: an I-cache miss, a redirect, a trap's
  // refill); also taken control transfers and traps.
  logic        perf_on;
  longint      pf_period;
  longint      pi_ok, pi_es, pi_md, pi_lu, pi_sr, pi_fp, pi_fr, pi_fo, pi_ot;
  int          pi_rd;
  longint      pf_cyc, pf_cu, pf_cs, pf_w2, pf_ld, pf_st, pf_md, pf_fp, pf_hz, pf_fe, pf_ot, pf_br, pf_tr;
  initial begin
    perf_on = $test$plusargs("perf");
    if (!$value$plusargs("perf_period=%d", pf_period)) pf_period = 10000000;
    pf_cyc = 0; pf_cu = 0; pf_cs = 0; pf_w2 = 0; pf_ld = 0; pf_st = 0; pf_md = 0; pf_fp = 0;
    pf_hz = 0; pf_fe = 0; pf_ot = 0; pf_br = 0; pf_tr = 0;
    pi_ok = 0; pi_es = 0; pi_md = 0; pi_lu = 0; pi_sr = 0; pi_fp = 0; pi_fr = 0; pi_fo = 0; pi_ot = 0; pi_rd = 0;
  end
  /* verilator lint_off BLKSEQ */
  always_ff @(posedge clk) begin
    if (perf_on && !rst) begin
      pf_cyc = pf_cyc + 1;
      if (w_commit)                                  begin if (s) pf_cs = pf_cs + 1; else pf_cu = pf_cu + 1; end
      else if (w_valid && w_stall)                   pf_w2 = pf_w2 + 1;
      else if (m_is_mem && !m_acked)                 begin if (m_dec.cls == C_LOAD || m_dec.cls == C_FPLOAD) pf_ld = pf_ld + 1; else pf_st = pf_st + 1; end
      else if (e_valid && md_wait)                   pf_md = pf_md + 1;
      else if (d_hazard && is_fp(d_dec.cls) && fp_inflight) pf_fp = pf_fp + 1;
      else if (d_hazard)                             pf_hz = pf_hz + 1;
      else if (!d_valid)                             pf_fe = pf_fe + 1;
      else                                           pf_ot = pf_ot + 1;
      if (redirect && e_go) pf_br = pf_br + 1;
      // the issue slot (D to E): taken, or lost and why
      if (redirect) pi_rd = 3; else if (pi_rd != 0) pi_rd = pi_rd - 1;
      if (d_go)                                      pi_ok = pi_ok + 1;
      else if (d_valid && e_stall)                   begin if (md_wait) pi_md = pi_md + 1; else pi_es = pi_es + 1; end
      else if (d_valid && d_hazard && d_uses_rd_of_e) pi_lu = pi_lu + 1;
      else if (d_valid && d_hazard && ser_inflight)  pi_sr = pi_sr + 1;
      else if (d_valid && d_hazard)                  pi_fp = pi_fp + 1;
      else if (!d_valid && pi_rd != 0)               pi_fr = pi_fr + 1;
      else if (!d_valid)                             pi_fo = pi_fo + 1;
      else                                           pi_ot = pi_ot + 1;
      if (w_valid && !w_stall && w_trap) pf_tr = pf_tr + 1;
      if (pf_cyc % pf_period == 0) begin
        $display("perf %m %0dM: commit user %0d sup %0d | w2 %0d | mem ld %0d st %0d | muldiv %0d | fp %0d | hazard %0d | fetch %0d | other %0d | taken %0d traps %0d",
                 pf_cyc / 1000000, pf_cu, pf_cs, pf_w2, pf_ld, pf_st, pf_md, pf_fp, pf_hz, pf_fe, pf_ot, pf_br, pf_tr);
        pf_cu = 0; pf_cs = 0; pf_w2 = 0; pf_ld = 0; pf_st = 0; pf_md = 0; pf_fp = 0; pf_hz = 0;
        pf_fe = 0; pf_ot = 0; pf_br = 0; pf_tr = 0;
        $display("pissue %m: ok %0d | E held %0d muldiv %0d | load-use %0d | serialising %0d | fp %0d | fetch after redirect %0d | fetch other %0d | other %0d",
                 pi_ok, pi_es, pi_md, pi_lu, pi_sr, pi_fp, pi_fr, pi_fo, pi_ot);
        pi_ok = 0; pi_es = 0; pi_md = 0; pi_lu = 0; pi_sr = 0; pi_fp = 0; pi_fr = 0; pi_fo = 0; pi_ot = 0;
      end
    end
  end
  /* verilator lint_on BLKSEQ */
  // +pcsample=N: every N cycles, the PC of the last instruction to leave W
  // (and PSR.S/PIL/ET), from +pcsample_from=C on: where a quiet machine is
  longint ps_period, ps_from, ps_cyc;
  logic [31:0] ps_lastpc;
  initial begin
    if (!$value$plusargs("pcsample=%d", ps_period)) ps_period = 0;
    if (!$value$plusargs("pcsample_from=%d", ps_from)) ps_from = 0;
    ps_cyc = 0; ps_lastpc = '0;
  end
  always_ff @(posedge clk) begin
    ps_cyc <= ps_cyc + 1;
    if (w_valid && !w_stall) ps_lastpc <= w_pc;
    if (ps_period > 0 && ps_cyc >= ps_from && ps_cyc % ps_period == 0)
      $display("pcs %0d pc=%08x s=%0d et=%0d pil=%0d %m", ps_cyc, ps_lastpc, s, et, pil);
  end
  // +pipetrace=N: the pipeline, one line a cycle, for 120 cycles from cycle N
  longint pt_start, pt_cyc;
  initial begin if (!$value$plusargs("pipetrace=%d", pt_start)) pt_start = -1; pt_cyc = 0; end
  always_ff @(posedge clk) begin
    pt_cyc <= pt_cyc + 1;
    if (pt_start >= 0 && pt_cyc >= pt_start && pt_cyc < pt_start + 120)
      $display("PT %0d D%0d:%08x E%0d:%08x M%0d:%08x W%0d:%08x | hz%0d fpi%0d estl%0d mstl%0d wstl%0d com%0d ack%0d redir%0d ins %08x",
        pt_cyc, d_valid, d_pc, e_valid, e_pc, m_valid, m_pc, w_valid, w_pc, d_hazard, fp_inflight, e_stall, m_stall, w_stall, w_commit,
        dmem_rsp_i.ack, redirect, d_inst);
  end
  // synthesis translate_on
`endif

  // Architectural state updates
  always_ff @(posedge clk) begin
    if (rst) begin
      icc <= '0; ef <= 1'b0; s <= 1'b1; ps <= 1'b0; et <= 1'b0; pil <= '0; cwp <= '0;
      wim <= '0; tba <= '0; tt <= '0; y <= '0; error <= 1'b0;
    end else if (w_valid && !w_stall) begin
      if (w_trap) begin
        if (!et) begin
          error <= 1'b1;                      // a trap with ET = 0: error mode
`ifndef SYNTHESIS
          $display("%0t iu: error mode (a trap with ET=0): tt=%02x pc=%08x npc=%08x s=%0d ps=%0d cwp=%0d wim=%02x",
                   $time, w_tt, w_pc, w_npc, s, ps, cwp, wim); $fflush();
`endif
        end else begin
          et <= 1'b0;
          ps <= s;
          s <= 1'b1;
          cwp <= cwp - 3'd1;
          tt <= w_tt;
`ifndef SYNTHESIS
          // every trap but the window spills/fills and interrupts (noise)
          if (w_tt != 8'h05 && w_tt != 8'h06 && !(w_tt >= 8'h11 && w_tt <= 8'h1f))
            $display("iu: trap tt=%02x pc=%08x npc=%08x s=%0d cwp=%0d wim=%02x tba=%05x", w_tt, w_pc, w_npc, s, cwp, wim, tba); $fflush();
`endif
        end
      end else begin
        if (w_wicc) icc <= w_icc;
        if (w_wy) y <= w_y;
        // (a wr's value, rs1 xor operand 2, travels as the result: e_result)
        case (w_dec.cls)
          C_WRY:   y <= w_result;
          C_WRWIM: wim <= w_result[7:0];
          C_WRTBR: tba <= w_result[31:12];
          C_WRPSR: begin
            icc <= w_result[23:20];
            ef  <= HAS_FPU ? w_result[12] : 1'b0;
            pil <= w_result[11:8];
            s   <= w_result[7];
            ps  <= w_result[6];
            et  <= w_result[5];
            cwp <= w_result[2:0];
          end
          C_SAVE, C_RESTORE: cwp <= w_newcwp;
          C_RETT: begin
            cwp <= w_newcwp;
            et <= 1'b1;
            s <= ps;
          end
          default: ;
        endcase
      end
    end
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, d_supv_for_dec, take_from_buf, m_dec.opf, e_dec.opf, f_slot_pending,
                       e_rs4[0], src_inst[31:30], src_inst[24:19], src_inst[13:5],
                       e_dec.simm13, e_dec.disp22, e_dec.disp30, e_dec.imm22,
                       reads_state(d_dec.cls, d_dec.op3)};
  assign d_supv_for_dec = s;

endmodule
