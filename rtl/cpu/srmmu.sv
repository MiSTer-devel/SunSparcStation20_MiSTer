// SPDX-License-Identifier: GPL-2.0-or-later
//
// srmmu: the SPARC Reference MMU of the CPU module as the SuperSPARC
// presents it (docs/arch/mmu.md §2): the ASI 4 registers, a 64-entry
// fully associative TLB with two lookup ports (instruction and data) and
// the ASI 6 diagnostic image, the three-level table walker with the R/M
// updates, the fault registers with V8's overwrite rules, probe and flush
// (ASI 3).
//
// From: The SPARC Architecture Manual V8 Appendix H (§H.3 tables, walk and
//   PA formation; §H.4 control register; §H.5 SFSR: FT, AT, L, FAV, OW and
//   the overwrite classes; §H.6 SFAR; §H.7 R/M updates; Tables H-2/H-3
//   flush matches, H-4 probe results); the Viking (TMS390Z50) user
//   documentation §4.11 (MCNTL bits and reset value, the 64-entry TLB, its
//   hit rule — context ignored for ACC 6-7 — and replacement, the ASI 6
//   image SEL 0-3, the MFSR aliases 0x1300/0x1400, EM); Sun-4M System
//   Architecture §4 (the reset register 0x700); tests/cpu (t_mmu,
//   t_mmu_diag, t_mmu_fault_regs, t_mmu_ifault, t_buserr, wdtest) as the
//   acceptance tests. docs/arch/mmu-notes.md is the digest.
//
// Deviations noted: probes always walk (never answer from the TLB) and set
// no R; an R-only update is a plain word write (Viking uses an atomic
// swap); no L2 TLB (MCNTL bit 6 is stored); 0x500/0x600 read 0. VA 0xD00
// is the project's SYSCONF word (RAM size, CPU count), which the test suite
// reads to tell the core from QEMU (docs/arch/mmu.md §0).
//
// The TLB is built from RAM (docs/VERILOG-PLAN.md §2 "TLB"; a CAM of flops
// was half the CPU). The image (VA tag, context, the PTE fields) is three
// 64-word RAMs; V, lock and used are flops (the lookup, the victim and the
// demap-all need all 64 at once). The CAM: the 36 compared bits {VA[31:12],
// CTX} in nine 4-bit slices, each a 16-row RAM whose row r holds the
// 64-bit vector of the entries that match nibble value r; a lookup reads
// one row per slice and ANDs the nine vectors with V. What the flop CAM
// decided per lookup is decided when an entry is written: the bits a
// level above 3 ignores, and the context of an ACC 6-7 entry, are written
// as "match every row". Writing entry e therefore rewrites bit e of all 16
// rows of every slice (read-modify-write, 17 cycles), from the image: on a
// fill, and on an ASI 6 write of SEL 0-2 (VA tag, context, PTE: ACC and
// LVL). The CAM is only meaningful where V is set; V is set only by those
// two writes, so it is always consistent where it matters. Flushes by
// match (ASI 3 types 0-3) walk the image, 65 cycles; demap-all and ASI
// 5/7 writes clear V at once. While the CAM/image engine runs, lookups
// answer busy and further TLB register accesses wait.
//
// Timing: a lookup takes three cycles: A the port's request is chosen
// (xd_sel_i) and addresses the CAM; B the vectors are ANDed and encoded
// and the image addressed; C the answer (hit/miss/fault) for the side,
// given only if it still presents the same VA and access type. A walk is
// started by walk_req_i for the side named; walk_done_o returns with
// walk_fault_o; on success the entry is in the TLB and the side retries.

module srmmu
  import mmu_pkg::*;
(
  input  logic        clk,
  input  logic        rst,

  // Register space: ASI 3 (probe/flush), 4, 5, 6, 7. One access at a time,
  // held until ack; a size other than a word is a control-space error.
  input  logic        reg_valid_i,
  input  logic        reg_we_i,
  input  logic [7:0]  reg_asi_i,
  input  logic [31:0] reg_va_i,
  input  logic [31:0] reg_wdata_i,
  input  logic [1:0]  reg_size_i,
  output logic        reg_ack_o,
  output logic        reg_fault_o,     // with ack: data_access_exception (CS)
  output logic [31:0] reg_rdata_o,

  // Translation lookups: one CAM, the data side first; the instruction
  // side is told busy and retries (it keeps a small translation cache of
  // its own in cpu_module)
  input  xlat_req_t   xi_i,
  output xlat_rsp_t   xi_o,
  input  xlat_req_t   xd_i,
  output xlat_rsp_t   xd_o,
  input  logic        xd_sel_i,        // the data side may look up this cycle (registered state only;
                                       // covers xd_i.valid): the CAM takes its VA
  output logic        tlb_changed_o,   // a flush, an ASI 5/6/7 write, a CTX/CTPR/MCNTL write: translation caches drop

  // The walker, for the side that missed (its request fields are used):
  // the data side wins when both ask in one cycle; walk_owner_o says
  // whose walk runs (0 none, 1 data, 2 instruction) and walk_done_o ends it
  input  logic        walk_req_d_i,
  input  logic        walk_req_i_i,
  output logic [1:0]  walk_owner_o,
  output logic        walk_done_o,
  output logic        walk_fault_o,    // the SFSR was written; trap unless masked
  output logic        walk_masked_o,   // NF masked it: no trap

  // Bus errors found by the sides on their own accesses (FT 5)
  input  logic        berr_valid_i,
  input  at_t         berr_at_i,
  input  logic [31:0] berr_va_i,
  input  logic        berr_no_fault_i,
  output logic        berr_masked_o,   // NF: record only

  // The memory port of the walker
  output mem_pkg::mem_req_t mem_req_o,
  input  mem_pkg::mem_rsp_t mem_rsp_i,

  // State
  input  logic [31:0] sysconf_i,       // ASI 4 VA 0xD00: the suite's "which machine" register
  input  logic [1:0]  cpu_idx_i,       // this module's CPU number (MID - 8): MCNTL bits 3:2 read it
  output logic [31:0] mcntl_o,
  input  logic        wd_i,            // a watchdog reset is taken: EM, BM
  output logic        si_reset_o,      // software-internal reset requested (0x700 bit 1)
  output logic [7:0]  dbg_o            // walker state, for the board's hang reporter
);

  // ---------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------
  logic [31:0] mcntl, ctpr, trcr;
  logic [15:0] ctx;
  logic [17:0] sfsr, sfsr_n;   // {EM, CS, SB, P, UD, UC, TO, BE, L[1:0], AT[2:0], FT[2:0], FAV, OW}
  logic [31:0] sfar, sfar_n;
  logic        wd_flag;
  assign mcntl_o = mcntl;

  localparam int SF_EM = 17, SF_CS = 16, SF_TO = 11, SF_FAV = 1, SF_OW = 0;
  logic        mmu_en, bm, nf;
  assign mmu_en = mcntl[MC_EN];
  assign bm     = mcntl[MC_BM];
  assign nf     = mcntl[MC_NF];

  // ---------------------------------------------------------------------
  // The TLB: flops for V, lock, used; the image and the CAM in RAM
  // ---------------------------------------------------------------------
  logic [63:0] tv, tlock, used;

  // The image RAMs: one write port, one registered read port each. The
  // PTE word is {PPN, C, M, ACC, LVL}; V lives in tv.
  logic [5:0]  im_raddr, im_waddr;
  logic        im_we_vtag, im_we_ctx, im_we_pte;
  logic [19:0] im_wvtag, im_rvtag;
  logic [15:0] im_wctx, im_rctx;
  logic [30:0] im_wpte, im_rpte;
  (* ramstyle = "no_rw_check" *) logic [19:0] im_vtag [64];
  (* ramstyle = "no_rw_check" *) logic [15:0] im_ctx [64];
  (* ramstyle = "no_rw_check" *) logic [30:0] im_pte [64];
  always_ff @(posedge clk) begin
    if (im_we_vtag) im_vtag[im_waddr] <= im_wvtag;
    if (im_we_ctx)  im_ctx[im_waddr]  <= im_wctx;
    if (im_we_pte)  im_pte[im_waddr]  <= im_wpte;
    im_rvtag <= im_vtag[im_raddr];
    im_rctx  <= im_ctx[im_raddr];
    im_rpte  <= im_pte[im_raddr];
  end

  /* verilator lint_off UNUSEDSIGNAL */   // R (bit 5) is not kept; LVL comes apart
  function automatic logic [30:0] pte_word(input logic [31:0] w, input logic [1:0] lvl);
    return {w[31:8], w[7], w[6], w[4:2], lvl};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // The entry read from the image (fields the RAM keeps; V and lock apart)
  tlb_entry_t im_e;
  always_comb begin
    im_e = '0;
    im_e.vtag = im_rvtag;
    im_e.ctx  = im_rctx;
    {im_e.ppn, im_e.c, im_e.m, im_e.acc, im_e.lvl} = im_rpte;
    im_e.v    = 1'b1;
  end

  // The CAM slices: slice s compares key bits [35-4s -: 4] of {VA[31:12],
  // CTX}: 0-4 the VA, 5-8 the context. A slice is 16 rows (the 4-bit key
  // value) of 64 entry bits, in two RAMs of 32 (entries 0-31, 32-63)
  // written a bit at a time (ram_sdp_bit): a rewrite changes one entry's
  // bit in each row without reading the row. The read port is always the
  // lookup's (lookups are spoiled while the engine runs).
  logic [3:0]  cam_raddr [9];
  logic [63:0] cam_rd [9];
  logic        cam_bit [9];              // the entry's bit in row cam_row of slice s
  logic        cam_we;
  logic [3:0]  cam_row;
  genvar gs;
  generate
    for (gs = 0; gs < 9; gs++) begin : g_cam
      ram_sdp_bit #(.AW(4)) u_lo (
        .clk, .waddr({cam_row, e_idx[4:0]}), .we(cam_we && !e_idx[5]), .wbit(cam_bit[gs]),
        .raddr(cam_raddr[gs]), .rdata(cam_rd[gs][31:0]));
      ram_sdp_bit #(.AW(4)) u_hi (
        .clk, .waddr({cam_row, e_idx[4:0]}), .we(cam_we && e_idx[5]), .wbit(cam_bit[gs]),
        .raddr(cam_raddr[gs]), .rdata(cam_rd[gs][63:32]));
    end
  endgenerate

  // The key bits a slice compares for an entry: the VA bits below the
  // entry's level, and the context of an ACC 6-7 entry, match anything
  function automatic logic [3:0] slice_care(input int s, input logic [1:0] lvl, input logic glob);
    logic [3:0] c;
    int thr;
    c = 4'h0;
    case (lvl)
      2'd3:    thr = 12;
      2'd2:    thr = 18;
      2'd1:    thr = 24;
      default: thr = 32;
    endcase
    if (s >= 5) c = glob ? 4'h0 : 4'hF;
    else for (int b = 0; b < 4; b++) c[b] = (28 - 4 * s + b) >= thr;
    return c;
  endfunction

  /* verilator lint_off UNUSEDSIGNAL */   // the functions use the fields they need
  function automatic logic [35:0] pte_pa(input tlb_entry_t e, input logic [31:0] va);
    case (e.lvl)
      2'd3:    return {e.ppn, va[11:0]};
      2'd2:    return {e.ppn[23:6], va[17:0]};
      2'd1:    return {e.ppn[23:12], va[23:0]};
      default: return {e.ppn[23:20], va[31:0]};
    endcase
  endfunction

  // Flush match (V8 Table H-2 with Viking's LVL conditions)
  function automatic logic flush_match(input tlb_entry_t e, input logic [2:0] t, input logic [31:0] va, input logic [15:0] c);
    logic ctx_ok;
    ctx_ok = e.acc[2:1] == 2'b11 || e.ctx == c;
    case (t)
      3'd0: return ctx_ok && e.lvl == 2'd3 && e.vtag == va[31:12];
      3'd1: return ctx_ok && e.lvl[1] && e.vtag[19:6] == va[31:18];
      3'd2: return ctx_ok && e.lvl != 2'd0 && e.vtag[19:12] == va[31:24];
      3'd3: return e.acc[2:1] != 2'b11 && e.ctx == c;
      3'd4: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  // The entry address at a level below the root
  function automatic logic [35:0] level_addr(input logic [1:0] lvl, input logic [31:0] ptd, input logic [31:0] va);
    logic [35:0] base;
    base = {ptd[31:2], 6'b000000};
    case (lvl)
      2'd1:    return base + 36'(va[31:24]) * 36'd4;
      2'd2:    return base + 36'(va[23:18]) * 36'd4;
      default: return base + 36'(va[17:12]) * 36'd4;
    endcase
  endfunction

  // The answer of a lookup port
  function automatic xlat_rsp_t answer(input xlat_req_t r, input logic hit, input tlb_entry_t e,
                                       input logic en, input logic boot);
    xlat_rsp_t a;
    a = '0;
    // pa, pte_c, acc and m are meaningful only with hit (cpu_module reads
    // them with hit alone), so they are formed whatever the flags say: no
    // gating muxes on the address path
    if (r.at[1] && boot) a.pa = {8'hFF, r.va[27:0]};   // boot mode: fetches go to the PROM
    else if (!en)        a.pa = {4'h0, r.va};
    else                 a.pa = pte_pa(e, r.va);
    a.pte_c = e.c; a.acc = e.acc; a.m = e.m;
    if (!r.valid) return a;
    if ((r.at[1] && boot) || !en) begin
      a.hit = 1'b1;
    end else if (hit) begin
      if (acc_fault(r.at, e.acc) != FT_NONE) a.fault = 1'b1;
      else if (r.at[2] && !e.m) a.miss = 1'b1;   // a store to a page with M = 0: walk again
      else a.hit = 1'b1;
    end else begin
      a.miss = 1'b1;
    end
    return a;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // The engine: everything that writes the image or the CAM, or walks the
  // image, one at a time. Lookups are spoiled while it runs.
  typedef enum logic [2:0] {E_CLR, E_IDLE, E_FLUSH, E_IMG, E_CAM} estate_t;
  estate_t     es;
  logic [6:0]  ecnt;
  logic        e_reg;          // the operation is a register access: ack at its end
  logic        e_gone;         // ... which was abandoned (watchdog): no ack
  logic [5:0]  e_idx;          // the entry the CAM rewrite is for
  logic [35:0] e_key;          // its {VA tag, CTX}
  logic [1:0]  e_lvl;
  logic        e_glob;         // ACC 6-7: any context

  // The CAM row write of the rewrite: bit e_idx of row ecnt-1 of each
  // slice (rows 0-15 in E_CAM's cycles 1-16, as when a row was read first)
  assign cam_row   = 4'(ecnt - 7'd1);
  assign cam_we    = es == E_CAM && ecnt != 7'd0;
  always_comb
    for (int s = 0; s < 9; s++)
      cam_bit[s] = ((cam_row ^ e_key[35 - 4 * s -: 4]) & slice_care(s, e_lvl, e_glob)) == 4'h0;

  // ---------------------------------------------------------------------
  // The lookup
  // ---------------------------------------------------------------------
  // A: the port's request is chosen by xd_sel_i (registered state in
  // cpu_module: the data side when it may look up) and its key addresses
  // the CAM. B: the nine row vectors and V are ANDed, the first match
  // encoded, the image read at it. C: the answer, for the port looked up in
  // A, if it still presents that request (a side holds its request until
  // answered and sees busy meanwhile; it may present another one soon
  // after, which must not get this answer); a fault is recorded and the
  // used bit set only then. A change to the TLB, the context or MCNTL, or
  // the engine running, in A or B spoils the lookup: C answers busy and the
  // side asks again. The sides translate in their request cycle with their
  // own micro-TLBs (cpu_module); this port serves their misses.
  xlat_req_t   lk_a, lk_b, lk;     // lk: the lookup in C
  logic        lk_d_b, lk_d_q;
  logic [35:0] lk_key;
  assign lk_a   = xd_sel_i ? xd_i : xi_i;
  assign lk_key = {lk_a.va[31:12], ctx};
  always_comb
    for (int s = 0; s < 9; s++) cam_raddr[s] = lk_key[35 - 4 * s -: 4];

  logic [63:0] hv;
  logic        hb_hit, h_hit;
  logic [5:0]  hb_idx, h_idx;
  always_comb begin
    hv = tv;
    for (int s = 0; s < 9; s++) hv = hv & cam_rd[s];
    hb_hit = hv != '0;
    hb_idx = '0;
    for (int i = 63; i >= 0; i--) if (hv[i]) hb_idx = 6'(i);
  end

  logic        spoil;                  // (assigned with the register decode below)
  always_ff @(posedge clk) begin
    lk_b <= lk_a;
    lk_d_b <= xd_sel_i;
    lk <= lk_b;
    lk_d_q <= lk_d_b;
    h_hit <= hb_hit;
    h_idx <= hb_idx;
    if (rst || spoil) begin lk_b.valid <= 1'b0; lk.valid <= 1'b0; end
  end

  logic        lk_go;                  // C: the side looked up in A still asks the same: it gets the answer
  assign lk_go = lk.valid && (lk_d_q ? xd_i.valid && xd_i.va == lk.va && xd_i.at == lk.at
                                     : xi_i.valid && xi_i.va == lk.va && xi_i.at == lk.at);
  xlat_rsp_t   h_ans;
  assign h_ans = answer(lk, h_hit, im_e, mmu_en, bm);
`ifndef SYNTHESIS
  always @(posedge clk) if (!rst && xd_i.valid && !xd_sel_i) $error("srmmu: a data-side lookup without xd_sel_i");
`endif
  always_comb begin
    // the flags steered to the port served; the payload to both (it is
    // read only with hit)
    xd_o = h_ans; xi_o = h_ans;
    {xd_o.hit, xd_o.miss, xd_o.fault, xd_o.busy} = '0;
    {xi_o.hit, xi_o.miss, xi_o.fault, xi_o.busy} = '0;
    if (xd_i.valid) begin
      if (lk_go && lk_d_q) {xd_o.hit, xd_o.miss, xd_o.fault} = {h_ans.hit, h_ans.miss, h_ans.fault};
      else xd_o.busy = 1'b1;
    end
    if (xi_i.valid) begin
      if (lk_go && !lk_d_q) {xi_o.hit, xi_o.miss, xi_o.fault} = {h_ans.hit, h_ans.miss, h_ans.fault};
      else xi_o.busy = 1'b1;
    end
  end

  // Victim: the first invalid entry, else the first unlocked entry whose
  // used bit is clear (Viking §4.11.4); 63 when there is none. One priority
  // encoder over the vector that applies (two encoders cost ~130 ALUTs more)
  logic [5:0]  victim;
  logic [63:0] vsel;
  assign vsel = (tv != '1) ? ~tv : (~tlock & ~used);
  always_comb begin
    victim = 6'd63;
    for (int i = 63; i >= 0; i--) if (vsel[i]) victim = 6'(i);
  end

  // ---------------------------------------------------------------------
  // Fault recording (V8 §H.5 classes and OW rules): a function applied to
  // the running value of the SFSR, in priority order, in one cycle
  // ---------------------------------------------------------------------
  typedef enum logic [1:0] {FC_INST, FC_DATA, FC_TRANS} fclass_t;

  function automatic fclass_t fclass_of(input logic [2:0] ft, input logic inst);
    if (ft == FT_TRANS) return FC_TRANS;
    return inst ? FC_INST : FC_DATA;
  endfunction

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic recorded(input logic [17:0] cur, input logic [2:0] ft, input at_t at);
    fclass_t pc, nc;
    if (cur[4:2] == FT_NONE) return 1'b1;
    pc = fclass_of(cur[4:2], cur[6]);
    nc = fclass_of(ft, at[1]);
    if (nc == pc) return 1'b1;
    if (nc == FC_TRANS) return 1'b1;
    if (pc == FC_TRANS) return 1'b0;
    if (nc == FC_INST && pc == FC_DATA) return 1'b0;
    return 1'b1;                              // data over instruction
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  function automatic logic [17:0] record(input logic [17:0] cur, input logic [2:0] ft, input at_t at,
                                         input logic [1:0] l, input logic fav, input logic to);
    logic [17:0] n;
    logic ow;
    if (!recorded(cur, ft, at)) return cur;
    ow = (cur[4:2] != FT_NONE) && (fclass_of(cur[4:2], cur[6]) == fclass_of(ft, at[1]));
    n = '0;
    n[SF_EM] = cur[SF_EM];
    n[SF_TO] = to;
    n[9:8] = l;
    n[7:5] = at;
    n[4:2] = ft;
    n[SF_FAV] = fav;
    n[SF_OW] = ow;
    return n;
  endfunction

  // ---------------------------------------------------------------------
  // The walker (also the probe)
  // ---------------------------------------------------------------------
  typedef enum logic [2:0] {W_IDLE, W_READ, W_WAIT, W_WRITE, W_WRITE_WAIT, W_DONE, W_FILL} wstate_t;
  wstate_t     ws;
  logic        w_probe;        // this walk is a probe
  logic [2:0]  w_ptype;        // probe type
  logic [31:0] w_va;
  at_t         w_at;
  logic        w_no_fault;
  logic [1:0]  w_level;
  logic [35:0] w_addr;         // the entry being read
  logic [31:0] w_entry;        // the word read (then the word written back)
  logic [31:0] w_result;       // the probe's answer
  logic        w_fault;
  logic        probe_done;
  // the owner of the running walk, held through the cycle of walk_done_o
  logic [1:0]  w_owner;
  // A walk started because a store hit an entry with M = 0 writes its result
  // back into that entry. Inserting it elsewhere left the stale entry
  // matching: the lookup takes the lowest matching index, every hit marks
  // it used so it is never the victim, and each store walked again forever
  // with no interrupt taken (NetBSD hung silently at init, its first store
  // to a page it had only read).
  logic        w_rep;
  logic [5:0]  w_rep_idx;
  assign walk_owner_o = w_owner;

  // the word within the doubleword the port returns
  logic [31:0] mem_word;
  assign mem_word = w_addr[2] ? mem_rsp_i.rdata[31:0] : mem_rsp_i.rdata[63:32];

  always_comb begin
    mem_req_o = '0;
    // held from the request until the ack (the arbiter follows valid)
    mem_req_o.valid = (ws == W_READ) || (ws == W_WAIT) || (ws == W_WRITE) || (ws == W_WRITE_WAIT);
    mem_req_o.write = (ws == W_WRITE) || (ws == W_WRITE_WAIT);
    mem_req_o.pa    = {w_addr[35:3], 3'b000};
    mem_req_o.be    = w_addr[2] ? 8'h0F : 8'hF0;
    mem_req_o.wdata = w_addr[2] ? {32'd0, w_entry} : {w_entry, 32'd0};
  end

  // What this walk step finds (valid in W_WAIT with ack, for a translation walk)
  logic       wk_step;         // a step completes this cycle
  logic [2:0] wk_ft;           // the fault it raises, FT_NONE for none
  logic       wk_pte;          // a PTE was found
  logic       wk_ptd;          // a PTD was found (walk on)
  logic       wk_rm;           // the PTE needs R/M written
  always_comb begin
    wk_step = ws == W_WAIT && mem_rsp_i.ack;
    wk_ft = FT_NONE; wk_pte = 1'b0; wk_ptd = 1'b0; wk_rm = 1'b0;
    if (mem_rsp_i.err) wk_ft = FT_TRANS;
    else case (mem_word[1:0])
      2'd0: wk_ft = FT_INVALID;
      2'd3: wk_ft = FT_TRANS;
      2'd1: begin if (w_level == 2'd3) wk_ft = FT_TRANS; else wk_ptd = 1'b1; end
      default: begin
        wk_pte = 1'b1;
        wk_ft = acc_fault(w_at, mem_word[4:2]);
        wk_rm = !mem_word[5] || (w_at[2] && !mem_word[6]);
      end
    endcase
  end

  assign dbg_o = {ws, w_owner, w_rep, w_fault, w_probe};

  // The fill: a translation walk ended without a fault and the engine is free
  logic        fill_go;
  logic [5:0]  fill_idx;
  assign fill_go  = ws == W_DONE && !w_probe && !w_fault && es == E_IDLE;
  assign fill_idx = w_rep ? w_rep_idx : victim;

  // ---------------------------------------------------------------------
  // The write ports of the flop vectors: one indexed write per vector per
  // cycle (the fill, the flush sweep and the ASI 6 writes are exclusive by
  // state), so that each vector costs one 6-to-64 decoder, not one per
  // writer (~450 ALUTs a CPU, 2026-10-17). The whole-vector clears are in
  // the state machine below.
  // ---------------------------------------------------------------------
  logic        tv_we, tv_wv, lk_we, lk_wv, used_we, used_hist_clr;
  logic [5:0]  tv_wi, lk_wi, used_wi;
  logic [63:0] victim_oh;
  assign victim_oh = 64'd1 << victim;
  always_comb begin
    tv_we = 1'b0; tv_wi = img_entry; tv_wv = reg_wdata_i[5];
    lk_we = 1'b0; lk_wi = img_entry; lk_wv = reg_wdata_i[0];
    if (fill_go) begin
      tv_we = 1'b1; tv_wi = fill_idx; tv_wv = 1'b1;
      lk_we = 1'b1; lk_wi = fill_idx; lk_wv = 1'b0;
    end else if (es == E_FLUSH) begin
      // (abandoned when the register access is gone: nothing cleared)
      if (reg_valid_i && ecnt != 7'd0 && flush_match(im_e, reg_va_i[10:8], reg_va_i, ctx)) begin
        tv_we = 1'b1; tv_wi = 6'(ecnt - 7'd1); tv_wv = 1'b0;
      end
    end else if (es == E_IMG && reg_valid_i && reg_we_i) begin
      tv_we = img_sel == 3'd2;                   // SEL 2: V with the PTE word
      lk_we = img_sel == 3'd3;                   // SEL 3: the lock bit
    end
    // used: a hit marks its entry, a fill its new one (the fill's when both
    // come in one cycle: a hit's mark is replacement history only); a fill
    // that finds every entry used clears the others' history (Viking
    // §4.11.4), the locked ones' kept
    used_we       = fill_go || (lk_go && h_hit);
    used_wi       = fill_go ? fill_idx : h_idx;
    used_hist_clr = fill_go && !w_rep && &(used | victim_oh);
  end

  // ---------------------------------------------------------------------
  // Register access decode
  // ---------------------------------------------------------------------
  logic        reg_is_word, reg_go;
  assign reg_is_word = reg_size_i == 2'd2;
  assign reg_go = reg_valid_i && !reg_ack_o;
  logic        probe_start;
  assign probe_start = reg_go && !reg_we_i && reg_asi_i == 8'h03 && reg_is_word && ws == W_IDLE && !probe_done &&
                       !walk_req_d_i && !walk_req_i_i;

  logic [5:0]  img_entry;
  logic [2:0]  img_sel;
  assign img_entry = reg_va_i[17:12];
  assign img_sel   = reg_va_i[10:8];

  // A word access that changes or reads the TLB (ASI 3/5/7 stores, ASI 6):
  // it waits for the engine; tlb_start is the cycle it is taken
  logic        tlb_op, tlb_start;
  assign tlb_op    = reg_go && reg_is_word &&
                     ((reg_we_i && (reg_asi_i == 8'h03 || reg_asi_i == 8'h05 || reg_asi_i == 8'h07)) || reg_asi_i == 8'h06);
  assign tlb_start = tlb_op && es == E_IDLE && !fill_go;

  // The image's ports
  always_comb begin
    im_raddr = hb_idx;                         // the lookup's B
    if (es == E_FLUSH) im_raddr = ecnt[5:0];
    else if (tlb_start) im_raddr = img_entry;
    im_waddr = fill_go ? fill_idx : es == E_CLR ? ecnt[5:0] : img_entry;
    im_wvtag = fill_go ? w_va[31:12] : es == E_CLR ? 20'd0 : reg_wdata_i[31:12];
    im_wctx  = fill_go ? ctx : es == E_CLR ? 16'd0 : reg_wdata_i[15:0];
    im_wpte  = fill_go ? pte_word(w_entry, w_level) : es == E_CLR ? 31'd0 : pte_word(reg_wdata_i, reg_wdata_i[1:0]);
    im_we_vtag = fill_go || es == E_CLR || (es == E_IMG && reg_we_i && img_sel == 3'd0);
    im_we_ctx  = fill_go || es == E_CLR || (es == E_IMG && reg_we_i && img_sel == 3'd1);
    im_we_pte  = fill_go || es == E_CLR || (es == E_IMG && reg_we_i && img_sel == 3'd2);
  end

  logic [31:0] reg_rdata;          // the value before this access's side effects
  always_comb begin
    reg_rdata = 32'd0;
    if (reg_asi_i == 8'h04) begin
      case (reg_va_i[12:8])
        // bits 3:2 (reserved on a SuperSPARC) are the CPU number: the CPU
        // suite's runtime and the OpenBIOS in bios/ send every CPU but 0 to
        // park by it
        5'h00: reg_rdata = {mcntl[31:4], cpu_idx_i, mcntl[1:0]};
        5'h01: reg_rdata = ctpr;
        5'h02: reg_rdata = {16'd0, ctx};
        5'h03, 5'h13: reg_rdata = {14'd0, sfsr};
        5'h04, 5'h14: reg_rdata = sfar;
        5'h07: reg_rdata = {29'd0, wd_flag, 2'b00};
        5'h0D: reg_rdata = sysconf_i;
        5'h10: reg_rdata = trcr;
        default: reg_rdata = 32'd0;
      endcase
    end else if (reg_asi_i == 8'h03) begin
      reg_rdata = w_result;
    end
  end

  // The ASI 6 image word, in E_IMG (the RAM read in the cycle before)
  logic [31:0] img_rdata;
  always_comb
    case (img_sel)
      3'd0: img_rdata = {im_rvtag, 12'd0};
      3'd1: img_rdata = {16'd0, im_rctx};
      3'd2: img_rdata = {im_rpte[30:5], tv[img_entry], im_rpte[4:0]};
      3'd3: img_rdata = {31'd0, tlock[img_entry]};
      default: img_rdata = 32'd0;
    endcase

  // The register-access control-space error (not a word)
  logic cs_error;
  assign cs_error = reg_go && !reg_is_word && reg_asi_i != 8'h03;

  // ---------------------------------------------------------------------
  // The next SFSR/SFAR: every source applied in order in one cycle
  // ---------------------------------------------------------------------
  logic lk_fault_now;
  assign lk_fault_now = lk_go && h_ans.fault;

  always_comb begin
    sfsr_n = sfsr;
    sfar_n = sfar;
    if (wd_i) sfsr_n[SF_EM] = 1'b1;
    // a permission fault on a hit
    if (lk_fault_now) begin
      if (recorded(sfsr_n, acc_fault(lk.at, im_e.acc), lk.at)) sfar_n = lk.va;
      sfsr_n = record(sfsr_n, acc_fault(lk.at, im_e.acc), lk.at, im_e.lvl, 1'b1, 1'b0);
    end
    // bus errors of the sides: FT 5 with TO; FAV and the SFAR for data only
    if (berr_valid_i) begin
      if (recorded(sfsr_n, FT_BUS, berr_at_i) && !berr_at_i[1]) sfar_n = berr_va_i;
      sfsr_n = record(sfsr_n, FT_BUS, berr_at_i, 2'd0, !berr_at_i[1], 1'b1);
    end
    // the walker's faults
    if (wk_step && !w_probe && wk_ft != FT_NONE) begin
      if (recorded(sfsr_n, wk_ft, w_at)) sfar_n = w_va;
      sfsr_n = record(sfsr_n, wk_ft, w_at, w_level, 1'b1, mem_rsp_i.err);
`ifndef SYNTHESIS
      $display("srmmu: walk fault ft=%0d at=%0d level=%0d va=%08x entry@%09x = %08x (err=%0d) ctx=%0d ctpr=%08x",
               wk_ft, w_at, w_level, w_va, w_addr, mem_word, mem_rsp_i.err, ctx, ctpr); $fflush();
`endif
    end
    // register accesses
    if (cs_error) begin
      sfsr_n = '0;
      sfsr_n[SF_EM] = sfsr[SF_EM];
      sfsr_n[SF_CS] = 1'b1;
      sfsr_n[4:2] = FT_INTERNAL;
      sfsr_n[7:5] = reg_we_i ? AT_ST_SD : AT_LD_SD;
      sfsr_n[SF_FAV] = 1'b1;
      sfar_n = reg_va_i;
    end else if (reg_go && reg_is_word && reg_asi_i == 8'h04) begin
      if (!reg_we_i && reg_va_i[12:8] == 5'h03) sfsr_n = '0;          // read clears, EM included
      if (reg_we_i && reg_va_i[12:8] == 5'h13) sfsr_n = reg_wdata_i[17:0];
      if (reg_we_i && reg_va_i[12:8] == 5'h14) sfar_n = reg_wdata_i;
    end
  end

  // What spoils a lookup in A or B (see the lookup): the engine, a fill, a
  // TLB register access waiting or taken, a CTX or MCNTL write
  assign spoil = es != E_IDLE || fill_go || tlb_op ||
                 (reg_go && reg_we_i && reg_is_word && reg_asi_i == 8'h04 &&
                  (reg_va_i[12:8] == 5'h00 || reg_va_i[12:8] == 5'h02));

  // ---------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------
  always_ff @(posedge clk) begin
    reg_ack_o <= 1'b0;
    reg_fault_o <= 1'b0;
    si_reset_o <= 1'b0;
    tlb_changed_o <= 1'b0;
    walk_done_o <= 1'b0;
    walk_fault_o <= 1'b0;
    walk_masked_o <= 1'b0;
    berr_masked_o <= 1'b0;
    if (rst) begin
      mcntl <= MCNTL_RESET;
      ctpr <= '0; ctx <= '0; trcr <= '0;
      sfsr <= '0; sfar <= '0;
      wd_flag <= 1'b0; reg_rdata_o <= '0;
      tv <= '0; tlock <= '0; used <= '0;
      es <= E_CLR; ecnt <= '0;             // the image RAMs are cleared by a sweep
      e_reg <= 1'b0; e_gone <= 1'b0; e_idx <= '0; e_key <= '0; e_lvl <= '0; e_glob <= 1'b0;
      ws <= W_IDLE;
      w_probe <= 1'b0; w_ptype <= '0; w_va <= '0; w_at <= '0; w_no_fault <= 1'b0; w_rep <= 1'b0; w_rep_idx <= '0;
      w_level <= '0; w_addr <= '0; w_entry <= '0; w_result <= '0; w_fault <= 1'b0;
      probe_done <= 1'b0; w_owner <= 2'd0;
    end else begin
      sfsr <= sfsr_n;
      sfar <= sfar_n;
      if (wd_i) begin
        mcntl[MC_BM] <= 1'b1;
        wd_flag <= 1'b1;
      end
      if (berr_valid_i) berr_masked_o <= nf && berr_no_fault_i;

      // translation caches outside drop on anything that changes a
      // translation (held while a TLB access waits or runs)
      tlb_changed_o <= wd_i ||
                       (reg_go && reg_we_i && reg_is_word &&
                        (reg_asi_i == 8'h03 || reg_asi_i == 8'h05 || reg_asi_i == 8'h06 || reg_asi_i == 8'h07 ||
                         (reg_asi_i == 8'h04 && reg_va_i[12:8] <= 5'h02)));

      // ---- the walker ----
      case (ws)
        W_IDLE: begin
          if (!reg_valid_i) probe_done <= 1'b0;   // an abandoned probe (watchdog)
          w_owner <= 2'd0;
          if (walk_req_d_i || walk_req_i_i) begin
            w_probe <= 1'b0;
            w_owner <= walk_req_d_i ? 2'd1 : 2'd2;
            w_va <= walk_req_d_i ? xd_i.va : xi_i.va;
            w_at <= walk_req_d_i ? xd_i.at : xi_i.at;
            w_no_fault <= walk_req_d_i ? xd_i.no_fault : xi_i.no_fault;
            w_rep <= walk_req_d_i && h_hit;      // lk is the data side's lookup in this cycle
            w_rep_idx <= h_idx;
            w_level <= 2'd0;
            w_addr <= {ctpr, 4'b0000} + {18'd0, ctx, 2'b00};
            w_fault <= 1'b0;
            ws <= W_READ;
          end else if (probe_start) begin
            w_probe <= 1'b1;
            w_rep <= 1'b0;
            w_ptype <= reg_va_i[10:8];
            w_va <= reg_va_i;
            w_at <= AT_LD_SD;
            w_level <= 2'd0;
            w_addr <= {ctpr, 4'b0000} + {18'd0, ctx, 2'b00};
            w_result <= 32'd0;
            if (reg_va_i[10:8] > 3'd4) probe_done <= 1'b1;     // types 5-7: 0
            else ws <= W_READ;
          end
        end
        W_READ: ws <= W_WAIT;
        W_WAIT: begin
          if (mem_rsp_i.ack) begin
            w_entry <= mem_word;
            if (w_probe) begin
              // Probe (V8 Table H-4): types 0-3 return the entry at their
              // level; type 4 the PTE wherever it is; errors give 0
              w_result <= 32'd0;
              ws <= W_DONE;
              if (!mem_rsp_i.err) begin
                if (w_ptype == 3'd4) begin
                  if (mem_word[1:0] == 2'd2) w_result <= mem_word;
                  else if (mem_word[1:0] == 2'd1 && w_level != 2'd3) begin
                    w_level <= w_level + 2'd1; w_addr <= level_addr(w_level + 2'd1, mem_word, w_va); ws <= W_READ;
                  end
                end else if (w_level == 2'd3 - 2'(w_ptype)) begin
                  if (mem_word[1:0] != 2'd3) w_result <= mem_word;    // the entry itself, reserved → 0
                end else if (mem_word[1:0] == 2'd1) begin
                  w_level <= w_level + 2'd1; w_addr <= level_addr(w_level + 2'd1, mem_word, w_va); ws <= W_READ;
                end
              end
            end else if (wk_ft != FT_NONE) begin
              w_fault <= 1'b1;
              ws <= W_DONE;
            end else if (wk_ptd) begin
              w_level <= w_level + 2'd1;
              w_addr <= level_addr(w_level + 2'd1, mem_word, w_va);
              ws <= W_READ;
            end else if (wk_rm) begin
              // set R (and M for a store) in memory, then insert
              w_entry <= mem_word | 32'h0000_0020 | (w_at[2] ? 32'h0000_0040 : 32'h0);
              ws <= W_WRITE;
            end else begin
              ws <= W_DONE;
            end
          end
        end
        W_WRITE: ws <= W_WRITE_WAIT;
        W_WRITE_WAIT: begin
          if (mem_rsp_i.ack) ws <= W_DONE;      // a failed R/M write is the chipset's to report
        end
        W_DONE: begin
          if (w_probe) begin
            probe_done <= 1'b1;
            ws <= W_IDLE;
          end else if (w_fault) begin
            walk_done_o <= 1'b1;
            walk_fault_o <= 1'b1;
            walk_masked_o <= nf && w_no_fault;
            ws <= W_IDLE;
          end else if (fill_go) begin
            // insert: the image is written now (im_* above), V, lock and
            // used by the write ports (tv_we, lk_we, used_we), the CAM by
            // the engine
            es <= E_CAM; ecnt <= '0; e_reg <= 1'b0;
            e_idx <= fill_idx; e_key <= {w_va[31:12], ctx}; e_lvl <= w_level; e_glob <= w_entry[4:3] == 2'b11;
            ws <= W_FILL;
          end
          // else the engine is busy: wait
        end
        W_FILL: begin
          if (es == E_IDLE) begin
            walk_done_o <= 1'b1;
            ws <= W_IDLE;
          end
        end
        default: ws <= W_IDLE;
      endcase

      // ---- the TLB's flop vectors (the write ports above; the clears of
      // the TLB accesses below come after and win) ----
      if (tv_we) tv[tv_wi] <= tv_wv;
      if (lk_we) tlock[lk_wi] <= lk_wv;
      if (used_hist_clr) used <= (used & tlock) | victim_oh;
      else if (used_we) used[used_wi] <= 1'b1;

      // ---- register accesses other than the TLB's ----
      if (reg_go && !tlb_op) begin
        reg_rdata_o <= reg_rdata;              // captured before a read-clear takes effect
        if (reg_asi_i == 8'h03) begin
          if (reg_we_i) begin                  // not a word (a word store is a TLB access)
            reg_ack_o <= 1'b1;
            reg_fault_o <= 1'b1;
          end else if (probe_done) begin
            reg_ack_o <= 1'b1;
            probe_done <= 1'b0;
          end else if (!reg_is_word) begin
            reg_ack_o <= 1'b1;
            reg_fault_o <= 1'b1;
          end
          // else the probe walk runs; the ack comes with probe_done
        end else begin
          reg_ack_o <= 1'b1;
          reg_fault_o <= !reg_is_word;
          if (reg_is_word && reg_we_i && reg_asi_i == 8'h04) begin
            case (reg_va_i[12:8])
              5'h00: mcntl <= (MCNTL_RESET & ~MCNTL_WMASK) | (reg_wdata_i & MCNTL_WMASK);
              5'h01: ctpr <= reg_wdata_i & 32'hFFFF_FFC0;
              5'h02: ctx <= reg_wdata_i[15:0];
              5'h07: if (reg_wdata_i[1]) si_reset_o <= 1'b1;
              5'h10: trcr <= reg_wdata_i;
              default: ;                 // 0x13/0x14 are in the SFSR/SFAR logic above
            endcase
          end
        end
      end

      // ---- TLB accesses, taken when the engine is free ----
      if (tlb_start) begin
        if (reg_asi_i == 8'h06) begin
          es <= E_IMG;                         // the image is read this cycle
        end else if (reg_asi_i == 8'h03 && reg_va_i[10:8] < 3'd4) begin
          es <= E_FLUSH; ecnt <= '0;           // flush by match: walk the image
          e_reg <= 1'b1; e_gone <= 1'b0;
        end else begin
          // demap-all, ASI 5/7: every V at once; flush types 5-7 match nothing
          if (reg_asi_i != 8'h03 || reg_va_i[10:8] == 3'd4) tv <= '0;
          if (reg_asi_i == 8'h03 && reg_va_i[10:8] == 3'd4) used <= '0;
          reg_ack_o <= 1'b1;
        end
      end

      // ---- the engine ----
      case (es)
        E_CLR: begin
          ecnt <= ecnt + 7'd1;
          if (ecnt == 7'd63) es <= E_IDLE;
        end
        E_FLUSH: begin
          if (!reg_valid_i) begin
            es <= E_IDLE;                      // abandoned (watchdog)
          end else begin
            ecnt <= ecnt + 7'd1;                 // (a match clears V: tv_we above)
            if (ecnt == 7'd64) begin es <= E_IDLE; reg_ack_o <= 1'b1; end
          end
        end
        E_IMG: begin
          es <= E_IDLE;
          if (!reg_valid_i) begin
            // abandoned (watchdog)
          end else if (!reg_we_i) begin
            reg_rdata_o <= img_rdata;
            reg_ack_o <= 1'b1;
          end else begin
            // SEL 0-2: the image word is written now (im_* above); the CAM
            // is rewritten from the image as it now is
            e_idx <= img_entry; e_reg <= 1'b1; e_gone <= 1'b0; ecnt <= '0;
            e_key <= {im_rvtag, im_rctx};
            e_lvl <= im_rpte[1:0];
            e_glob <= im_rpte[4:3] == 2'b11;
            case (img_sel)                       // (SEL 2 writes V, SEL 3 the lock: tv_we, lk_we above)
              3'd0: begin e_key[35:16] <= reg_wdata_i[31:12]; es <= E_CAM; end
              3'd1: begin e_key[15:0] <= reg_wdata_i[15:0]; es <= E_CAM; end
              3'd2: begin
                e_lvl <= reg_wdata_i[1:0]; e_glob <= reg_wdata_i[4:3] == 2'b11;
                es <= E_CAM;
              end
              3'd3: reg_ack_o <= 1'b1;
              default: reg_ack_o <= 1'b1;
            endcase
          end
        end
        E_CAM: begin
          ecnt <= ecnt + 7'd1;
          if (e_reg && !reg_valid_i) e_gone <= 1'b1;
          if (ecnt == 7'd16) begin
            es <= E_IDLE;
            if (e_reg && !e_gone && reg_valid_i) reg_ack_o <= 1'b1;
          end
        end
        default: ;
      endcase
    end
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, reg_va_i[7:0], w_addr[1:0], wk_pte, lk.no_fault};

endmodule
