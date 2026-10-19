// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_srmmu: the RAM-built TLB of srmmu against the flop-CAM srmmu it
// replaced (tb_srmmu_ref below: rtl/cpu/srmmu.sv as of commit f31b4dd),
// transaction by transaction. Both run the same random sequence, each with
// its own copy of a random three-level page table (PTEs at every level,
// invalid and reserved entries, a PTD to a bus error): translations on the
// data and the instruction port with the walks and fills they cause (the
// victim and used-bit history), ASI 6 image reads and writes (VA tag,
// context, PTE with V/ACC/LVL, lock), ASI 3 flushes of every type, ASI 5
// writes, probes, context switches, the SFSR/SFAR. Every answer must agree
// (hit, miss, fault, PA, ACC, M, C; walk faults; register data), and the
// whole 64-entry image is compared now and then and at the end. Latency
// differs (the RAM TLB answers a cycle later and fills take longer), so
// the comparison is of the transactions, not of the cycles.

module tb_srmmu;
  import mmu_pkg::*;
  import tb_pkg::*;

  logic clk;
  initial clk = 0;
  logic rst = 1;
  always #5 clk = ~clk;

  tb_srmmu_h #(.REF(1'b0)) u_new (.clk, .rst);
  tb_srmmu_h #(.REF(1'b1)) u_ref (.clk, .rst);

  // ---- the page tables (PA 0-0xFFFF; above is a bus error) ----
  logic [31:0] tw [16384];
  int          n_l2, n_l3;

  function automatic logic coin();
    return ($urandom & 1) != 0;
  endfunction

  function automatic logic [31:0] ptd(input int pa);
    return 32'((pa >> 6) << 2) | 32'd1;
  endfunction

  function automatic logic [31:0] rand_pte();
    logic [31:0] p;
    p = $urandom;
    p[1:0] = 2'd2;
    return p;
  endfunction

  task automatic set_word(input int pa, input logic [31:0] w);
    tw[pa >> 2] = w;
  endtask

  function automatic int pick(input int pct_a, input int pct_b);  // 0, 1 or 2 by percentage
    int r;
    r = int'($urandom % 100);
    if (r < pct_a) return 0;
    if (r < pct_a + pct_b) return 1;
    return 2;
  endfunction

  task automatic build_tables();
    int l1, l2, l3;
    for (int i = 0; i < 16384; i++) tw[i] = 32'd0;
    n_l2 = 0; n_l3 = 0;
    for (int c = 0; c < 4; c++) begin
      l1 = 32'h2000 + c * 32'h400;
      set_word(32'h1000 + c * 4, ptd(l1));
      for (int i1 = 0; i1 < 4; i1++) begin
        case (pick(10, 15))
          0: set_word(l1 + i1 * 4, 32'd0);
          1: set_word(l1 + i1 * 4, rand_pte());
          default: begin
            if (n_l2 >= 32 || $urandom % 50 == 0) set_word(l1 + i1 * 4, ptd(32'h10_0000));   // a bus error
            else begin
              l2 = 32'h4000 + n_l2 * 32'h100; n_l2++;
              set_word(l1 + i1 * 4, ptd(l2));
              for (int i2 = 0; i2 < 6; i2++) begin
                case (pick(10, 20))
                  0: set_word(l2 + i2 * 4, coin() ? 32'd0 : 32'd3);
                  1: set_word(l2 + i2 * 4, rand_pte());
                  default: begin
                    if (n_l3 >= 64) set_word(l2 + i2 * 4, 32'd0);
                    else begin
                      l3 = 32'h8000 + n_l3 * 32'h100; n_l3++;
                      set_word(l2 + i2 * 4, ptd(l3));
                      for (int i3 = 0; i3 < 16; i3++) begin
                        case (pick(12, 5))
                          0: set_word(l3 + i3 * 4, 32'd0);
                          1: set_word(l3 + i3 * 4, coin() ? 32'd3 : ptd(32'h8000));   // reserved, or a PTD at level 3
                          default: set_word(l3 + i3 * 4, rand_pte());
                        endcase
                      end
                    end
                  end
                endcase
              end
            end
          end
        endcase
      end
    end
    for (int i = 0; i < 8192; i++) begin
      u_new.mem[i] = {tw[2 * i], tw[2 * i + 1]};
      u_ref.mem[i] = {tw[2 * i], tw[2 * i + 1]};
    end
  endtask

  // ---- the operations, on both ----
  logic [31:0] rd_n, rd_r;
  logic        f_n, f_r;

  task automatic reg_both(input logic we, input logic [7:0] asi, input logic [31:0] va, input logic [31:0] wd,
                          input logic [1:0] size, input string what);
    fork
      u_new.reg_op(we, asi, va, wd, size, rd_n, f_n);
      u_ref.reg_op(we, asi, va, wd, size, rd_r, f_r);
    join
    check(f_n == f_r, $sformatf("%s: fault %0d, reference %0d", what, f_n, f_r));
    if (!we && !f_r) check32(rd_n, rd_r, what);   // a faulting load's data is never used
  endtask

  xlat_rsp_t a_n, a_r;
  logic      wf_n, wf_r, wk_n, wk_r;
  int        n_hit, n_fault, n_walk, n_wfault;
  logic [31:0] recent [16];          // VAs that hit lately: translations again

  task automatic xlat_both(input logic iport, input logic [31:0] va, input at_t at);
    fork
      u_new.xlat(iport, va, at, a_n, wk_n, wf_n);
      u_ref.xlat(iport, va, at, a_r, wk_r, wf_r);
    join
    // the flags always; pa, acc, m, pte_c only with hit (the design forms
    // them whatever the flags say: cpu_module reads them with hit alone)
    check({a_n.hit, a_n.miss, a_n.fault, a_n.busy} == {a_r.hit, a_r.miss, a_r.fault, a_r.busy} &&
          (!a_r.hit || {a_n.pa, a_n.pte_c, a_n.acc, a_n.m} == {a_r.pa, a_r.pte_c, a_r.acc, a_r.m}) &&
          wk_n == wk_r && wf_n == wf_r,
          $sformatf("xlat %s va=%08x at=%0d: hit %0d fault %0d pa %09x acc %0d m %0d c %0d walked %0d wfault %0d; reference %0d %0d %09x %0d %0d %0d %0d %0d",
                    iport ? "I" : "D", va, at, a_n.hit, a_n.fault, a_n.pa, a_n.acc, a_n.m, a_n.pte_c, wk_n, wf_n,
                    a_r.hit, a_r.fault, a_r.pa, a_r.acc, a_r.m, a_r.pte_c, wk_r, wf_r));
    if (a_r.hit) begin n_hit++; recent[n_hit % 16] = va; end
    if (a_r.fault) n_fault++;
    if (wk_r) n_walk++;
    if (wf_r) n_wfault++;
  endtask

  task automatic compare_image(input string when);
    for (int e = 0; e < 64; e++)
      for (int s = 0; s < 4; s++)
        reg_both(1'b0, 8'h06, 32'(e << 12) | 32'(s << 8), 32'd0, 2'd2, $sformatf("image %s entry %0d sel %0d", when, e, s));
  endtask

  function automatic logic [31:0] rand_va();
    logic [31:0] v;
    v = $urandom;
    v[31:24] = 8'($urandom % 5);
    v[23:18] = $urandom % 4 == 0 ? 6'($urandom) : 6'($urandom % 7);     // all of a level-1 page too
    v[17:12] = $urandom % 4 == 0 ? 6'($urandom) : 6'($urandom % 17);    // all of a level-2 page too
    return v;
  endfunction

  // Coverage, from the reference's state: fills that clear the used
  // history, and store re-walks that replace an entry in place
  int n_hist, n_rep, n_rep_full;
  initial begin n_hist = 0; n_rep = 0; n_rep_full = 0; end
  always @(posedge clk)
    if (u_ref.g_ref.u.ws == 3'd5 && !u_ref.g_ref.u.w_probe && !u_ref.g_ref.u.w_fault) begin
      if (u_ref.g_ref.u.w_rep) n_rep <= n_rep + 1;
      if (&(u_ref.g_ref.u.used | (64'd1 << u_ref.g_ref.u.victim))) begin
        if (u_ref.g_ref.u.w_rep) n_rep_full <= n_rep_full + 1; else n_hist <= n_hist + 1;
      end
    end

  function automatic logic [31:0] dense_va();        // inside the tables: mostly mapped
    logic [31:0] v;
    v = $urandom;
    v[31:24] = 8'($urandom % 4);
    v[23:18] = 6'($urandom % 6);
    v[17:12] = 6'($urandom % 16);
    return v;
  endfunction

  int n_ops;
  initial begin
    int unsigned seed;
    if (!$value$plusargs("seed=%d", seed)) seed = 2;
    void'($urandom(seed));
    n_ops = 20000;
    void'($value$plusargs("ops=%d", n_ops));
    n_hit = 0; n_fault = 0; n_walk = 0; n_wfault = 0;
    for (int i = 0; i < 16; i++) recent[i] = 32'd0;
    build_tables();
    repeat (4) @(posedge clk);
    rst = 0;
    repeat (80) @(posedge clk);          // the image sweep
    compare_image("after reset");
    reg_both(1'b1, 8'h04, 32'h100, 32'h100, 2'd2, "CTPR");
    reg_both(1'b1, 8'h04, 32'h000, 32'h1, 2'd2, "MCNTL");
    for (int k = 0; k < n_ops; k++) begin
      int r;
      logic [31:0] va, w;
      r = int'($urandom % 1000);
      va = rand_va();
      if (r < 300) begin
        xlat_both($urandom % 4 == 0, va, at_t'($urandom % 8));
      end else if (r < 600) begin
        xlat_both($urandom % 4 == 0, recent[$urandom % 16] ^ 32'($urandom % 4096), coin() ? AT_LD_SD : at_t'($urandom % 8));
      end else if (r < 700) begin
        // an image read
        reg_both(1'b0, 8'h06, {14'd0, 6'($urandom), 1'b0, 3'($urandom % 5), 8'd0}, 32'd0, 2'd2, "ASI 6 read");
      end else if (r < 760) begin
        // an image write: tags near the page table's VAs, contexts 0-3 or other
        logic [2:0] sel;
        sel = 3'($urandom % 5);
        case (sel)
          3'd0: w = coin() ? rand_va() : recent[$urandom % 16];
          3'd1: w = $urandom % 8 == 0 ? $urandom : 32'($urandom % 5);
          3'd2: w = $urandom;
          default: w = $urandom;
        endcase
        reg_both(1'b1, 8'h06, {14'd0, coin() ? 6'(63 - $urandom % 4) : 6'($urandom), 1'b0, sel, 8'd0}, w, 2'd2, "ASI 6 write");
      end else if (r < 830) begin
        reg_both(1'b1, 8'h03, {va[31:12], 1'b0, 3'($urandom % 8), 8'd0}, 32'd0, 2'd2, "flush");
      end else if (r < 835) begin
        reg_both(1'b1, coin() ? 8'h05 : 8'h07, va, 32'd0, 2'd2, "ASI 5/7 write");
      end else if (r < 870) begin
        reg_both(1'b1, 8'h04, 32'h200, 32'($urandom % 5), 2'd2, "CTX");
      end else if (r < 900) begin
        reg_both(1'b0, 8'h03, {va[31:12], 1'b0, 3'($urandom % 8), 8'd0}, 32'd0, 2'd2, "probe");
      end else if (r < 960) begin
        reg_both(1'b0, 8'h04, coin() ? 32'h1300 : 32'h400, 32'd0, 2'd2, "SFSR/SFAR");
      end else if (r < 970) begin
        reg_both(1'b0, 8'h04, 32'h300, 32'd0, 2'd2, "SFSR read-clear");
      end else if (r < 975) begin
        reg_both(coin(), 8'h06, 32'h0, 32'd0, 2'($urandom % 2), "ASI 6 not a word");
      end else if (r < 980) begin
        reg_both(1'b1, 8'h04, 32'h000, $urandom % 3 == 0 ? 32'h3 : 32'h1, 2'd2, "MCNTL (NF)");
      end else if (r < 995) begin
        // a fill pressure burst: many distinct pages, loads and stores
        for (int j = 0; j < 200; j++) xlat_both(1'b0, dense_va(), $urandom % 4 == 0 ? AT_ST_SD : AT_LD_SD);
      end else begin
        compare_image($sformatf("at op %0d", k));
      end
    end
    compare_image("at the end");
    for (int i = 0; i < 8192; i++)
      if (u_new.mem[i] !== u_ref.mem[i]) check(1'b0, $sformatf("memory doubleword %0d differs (R/M writes)", i));
    $display("tb_srmmu: %0d ops, %0d hits, %0d permission faults, %0d walks, %0d walk faults; %0d history clears, %0d in-place refills (%0d with all used)",
             n_ops, n_hit, n_fault, n_walk, n_wfault, n_hist, n_rep, n_rep_full);
    check(n_hit > n_ops / 10 && n_walk > 100 && n_wfault > 50 && n_fault > 50, "the mix exercised hits, walks and faults");
    tb_done("tb_srmmu");
  end
endmodule

// One MMU (the new one, or the reference) with its memory and the drivers
// of a side as cpu_module behaves
module tb_srmmu_h #(parameter bit REF = 1'b0) (input logic clk, input logic rst);
  import mmu_pkg::*;

  logic        reg_valid = 0, reg_we = 0, reg_ack, reg_fault;
  logic [7:0]  reg_asi = 0;
  logic [31:0] reg_va = 0, reg_wdata = 0, reg_rdata;
  logic [1:0]  reg_size = 0;
  xlat_req_t   xi = '0, xd = '0;
  xlat_rsp_t   xi_r, xd_r;
  logic        xd_sel;
  logic        tlb_changed;
  logic        wk_req_d, wk_req_i, wk_done, wk_fault, wk_masked;
  logic [1:0]  wk_owner;
  logic        berr_masked, si_reset;
  mem_pkg::mem_req_t mreq;
  mem_pkg::mem_rsp_t mrsp;
  logic [31:0] mcntl;
  logic [7:0]  dbg;

  assign xd_sel   = xd.valid;
  assign wk_req_d = xd.valid && xd_r.miss && wk_owner == 2'd0;
  assign wk_req_i = xi.valid && xi_r.miss && !xi_r.busy && wk_owner == 2'd0;

  generate
    if (REF) begin : g_ref
      tb_srmmu_ref u (
        .clk, .rst,
        .reg_valid_i(reg_valid), .reg_we_i(reg_we), .reg_asi_i(reg_asi), .reg_va_i(reg_va), .reg_wdata_i(reg_wdata),
        .reg_size_i(reg_size), .reg_ack_o(reg_ack), .reg_fault_o(reg_fault), .reg_rdata_o(reg_rdata),
        .xi_i(xi), .xi_o(xi_r), .xd_i(xd), .xd_o(xd_r), .xd_sel_i(xd_sel), .tlb_changed_o(tlb_changed),
        .walk_req_d_i(wk_req_d), .walk_req_i_i(wk_req_i), .walk_owner_o(wk_owner),
        .walk_done_o(wk_done), .walk_fault_o(wk_fault), .walk_masked_o(wk_masked),
        .berr_valid_i(1'b0), .berr_at_i(3'd0), .berr_va_i(32'd0), .berr_no_fault_i(1'b0), .berr_masked_o(berr_masked),
        .mem_req_o(mreq), .mem_rsp_i(mrsp),
        .sysconf_i(32'h1234_5678), .mcntl_o(mcntl), .wd_i(1'b0), .si_reset_o(si_reset), .dbg_o(dbg));
    end else begin : g_new
      srmmu u (
        .clk, .rst,
        .reg_valid_i(reg_valid), .reg_we_i(reg_we), .reg_asi_i(reg_asi), .reg_va_i(reg_va), .reg_wdata_i(reg_wdata),
        .reg_size_i(reg_size), .reg_ack_o(reg_ack), .reg_fault_o(reg_fault), .reg_rdata_o(reg_rdata),
        .xi_i(xi), .xi_o(xi_r), .xd_i(xd), .xd_o(xd_r), .xd_sel_i(xd_sel), .tlb_changed_o(tlb_changed),
        .walk_req_d_i(wk_req_d), .walk_req_i_i(wk_req_i), .walk_owner_o(wk_owner),
        .walk_done_o(wk_done), .walk_fault_o(wk_fault), .walk_masked_o(wk_masked),
        .berr_valid_i(1'b0), .berr_at_i(3'd0), .berr_va_i(32'd0), .berr_no_fault_i(1'b0), .berr_masked_o(berr_masked),
        .mem_req_o(mreq), .mem_rsp_i(mrsp),
        .sysconf_i(32'h1234_5678), .cpu_idx_i(2'd0), .mcntl_o(mcntl), .wd_i(1'b0), .si_reset_o(si_reset), .dbg_o(dbg));
    end
  endgenerate

  // The memory: 64 KB, then bus errors; an ack 1-3 cycles after the request
  logic [63:0] mem [8192];
  int          mdelay;
  initial mdelay = 0;
  always @(posedge clk) begin
    mrsp <= '0;
    if (mreq.valid && !mrsp.ack) begin
      if (mdelay == 0) mdelay <= 1 + int'($urandom % 3);
      else if (mdelay == 1) begin
        mdelay <= 0;
        mrsp.ack <= 1'b1;
        if (mreq.pa >= 36'h1_0000) mrsp.err <= 1'b1;
        else if (mreq.write) begin
          for (int b = 0; b < 8; b++) if (mreq.be[b]) mem[mreq.pa[15:3]][8 * b +: 8] <= mreq.wdata[8 * b +: 8];
        end else mrsp.rdata <= mem[mreq.pa[15:3]];
      end else mdelay <= mdelay - 1;
    end
  end

  // A register access, held until the ack
  task automatic reg_op(input logic we, input logic [7:0] asi, input logic [31:0] va, input logic [31:0] wd,
                        input logic [1:0] size, output logic [31:0] rdata, output logic fault);
    @(negedge clk);
    reg_valid = 1; reg_we = we; reg_asi = asi; reg_va = va; reg_wdata = wd; reg_size = size;
    do @(negedge clk); while (!reg_ack);
    rdata = reg_rdata; fault = reg_fault;
    @(posedge clk); #1;
    reg_valid = 0;
  endtask

  // A translation as a side of cpu_module makes it: present until answered
  // (not busy); a miss starts a walk in that cycle, then present again
  task automatic xlat(input logic iport, input logic [31:0] va, input at_t at,
                      output xlat_rsp_t ans, output logic walked, output logic wfault);
    xlat_rsp_t r;
    walked = 0; wfault = 0; ans = '0;
    for (int tries = 0; tries < 8; tries++) begin
      @(negedge clk);
      if (iport) begin xi.valid = 1; xi.va = va; xi.at = {2'b01, at[0]}; xi.no_fault = 0; end
      else       begin xd.valid = 1; xd.va = va; xd.at = at; xd.no_fault = 1; end
      forever begin
        @(negedge clk);
        r = iport ? xi_r : xd_r;
        if (!r.busy) break;
      end
      @(posedge clk); #1;
      xi.valid = 0; xd.valid = 0;
      if (!r.miss) begin ans = r; ans.busy = 0; return; end
      walked = 1;
      do @(negedge clk); while (!wk_done);
      if (wk_fault) begin wfault = 1; return; end
    end
    ans = '1;                      // never settles: reported as a mismatch
  endtask

endmodule

// ---------------------------------------------------------------------------
// The reference: srmmu with the flop CAM (rtl/cpu/srmmu.sv at f31b4dd)
// ---------------------------------------------------------------------------
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
// Timing: a lookup answers in the cycle it is presented (hit/miss/fault),
// so the sides present a request for one cycle per attempt. A walk is
// started by walk_req_i for the side named; walk_done_o returns with
// walk_fault_o; on success the entry is in the TLB and the side retries.

module tb_srmmu_ref
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
  // The TLB
  // ---------------------------------------------------------------------
  tlb_entry_t  tlb [64];
  logic [63:0] used;

  /* verilator lint_off UNUSEDSIGNAL */   // the functions use the fields they need
  function automatic logic tlb_hit(input tlb_entry_t e, input logic [31:0] va, input logic [15:0] c);
    logic va_ok;
    case (e.lvl)
      2'd3:    va_ok = e.vtag == va[31:12];
      2'd2:    va_ok = e.vtag[19:6] == va[31:18];
      2'd1:    va_ok = e.vtag[19:12] == va[31:24];
      default: va_ok = 1'b1;
    endcase
    return e.v && va_ok && (e.acc[2:1] == 2'b11 || e.ctx == c);
  endfunction

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
    if (!r.valid) return a;
    if (r.at[1] && boot) begin               // boot mode: fetches go to the PROM
      a.hit = 1'b1; a.pa = {8'hFF, r.va[27:0]};
    end else if (!en) begin
      a.hit = 1'b1; a.pa = {4'h0, r.va};
    end else if (hit) begin
      if (acc_fault(r.at, e.acc) != FT_NONE) a.fault = 1'b1;
      else if (r.at[2] && !e.m) a.miss = 1'b1;   // a store to a page with M = 0: walk again
      else begin a.hit = 1'b1; a.pa = pte_pa(e, r.va); a.pte_c = e.c; a.acc = e.acc; a.m = e.m; end
    end else begin
      a.miss = 1'b1;
    end
    return a;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // The one lookup: the data side's request when it has one, else the
  // instruction side's
  xlat_req_t   lk;                     // the lookup in its second cycle (B)
  logic        h_hit;
  logic [5:0]  h_idx;
  xlat_rsp_t   h_ans;
  // The lookup takes two cycles. A: the port's request is chosen by
  // xd_sel_i (registered state in cpu_module: the data side when it may
  // look up) and the 64 entries are compared, into a registered hit vector.
  // B: the vector is encoded, the entry chosen and the answer made, for the
  // port that was looked up in A. A side holds its request until answered
  // and sees busy meanwhile; an answer is given (and a fault recorded, the
  // used bit set) only to a side still asking in B. A TLB, context or MCNTL
  // write in A spoils the lookup: B answers busy and the side asks again.
  // The sides translate in their request cycle with their own micro-TLBs
  // (cpu_module); this port serves their misses.
  xlat_req_t   lk_a;
  logic [63:0] hv;
  assign lk_a = xd_sel_i ? xd_i : xi_i;
  always_comb
    for (int i = 0; i < 64; i++) hv[i] = tlb_hit(tlb[i], lk_a.va, ctx);

  logic        tlb_mod_now;            // (assigned with the state below)
  logic [63:0] hv_q;
  logic        lk_d_q;
  always_ff @(posedge clk) begin
    hv_q <= hv;
    lk <= lk_a;
    lk_d_q <= xd_sel_i;
    if (rst || tlb_mod_now) lk.valid <= 1'b0;
  end

  logic        lk_go;                  // B: the side looked up in A still asks: it gets the answer
  assign lk_go = lk.valid && (lk_d_q ? xd_i.valid : xi_i.valid);
  always_comb begin
    h_hit = hv_q != '0;
    h_idx = '0;
    for (int i = 63; i >= 0; i--) if (hv_q[i]) h_idx = 6'(i);
  end
  assign h_ans = answer(lk, h_hit, tlb[h_idx], mmu_en, bm);
`ifndef SYNTHESIS
  always @(posedge clk) if (!rst && xd_i.valid && !xd_sel_i) $error("srmmu: a data-side lookup without xd_sel_i");
`endif
  always_comb begin
    xd_o = '0; xi_o = '0;
    if (xd_i.valid) begin
      if (lk_go && lk_d_q) xd_o = h_ans;
      else xd_o.busy = 1'b1;
    end
    if (xi_i.valid) begin
      if (lk_go && !lk_d_q) xi_o = h_ans;
      else xi_o.busy = 1'b1;
    end
  end

  // Victim: the first invalid entry, else the first unlocked entry whose
  // used bit is clear (Viking §4.11.4)
  logic [5:0] victim;
  always_comb begin
    victim = 6'd63;
    for (int i = 63; i >= 0; i--) if (!tlb[i].lock && !used[i]) victim = 6'(i);
    for (int i = 63; i >= 0; i--) if (!tlb[i].v) victim = 6'(i);
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
  typedef enum logic [2:0] {W_IDLE, W_READ, W_WAIT, W_WRITE, W_WRITE_WAIT, W_DONE} wstate_t;
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

  // The PTE to insert
  tlb_entry_t new_entry;
  assign dbg_o = {ws, w_owner, w_rep, w_fault, w_probe};
  always_comb begin
    new_entry = '0;
    new_entry.vtag = w_va[31:12];
    new_entry.ctx  = ctx;
    new_entry.ppn  = w_entry[31:8];
    new_entry.c    = w_entry[7];
    new_entry.m    = w_entry[6];
    new_entry.v    = 1'b1;
    new_entry.acc  = w_entry[4:2];
    new_entry.lvl  = w_level;
    new_entry.lock = 1'b0;
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

  logic [31:0] reg_rdata;          // the value before this access's side effects
  always_comb begin
    reg_rdata = 32'd0;
    if (reg_asi_i == 8'h04) begin
      case (reg_va_i[12:8])
        5'h00: reg_rdata = mcntl;
        5'h01: reg_rdata = ctpr;
        5'h02: reg_rdata = {16'd0, ctx};
        5'h03, 5'h13: reg_rdata = {14'd0, sfsr};
        5'h04, 5'h14: reg_rdata = sfar;
        5'h07: reg_rdata = {29'd0, wd_flag, 2'b00};
        5'h0D: reg_rdata = sysconf_i;
        5'h10: reg_rdata = trcr;
        default: reg_rdata = 32'd0;
      endcase
    end else if (reg_asi_i == 8'h06) begin
      case (img_sel)
        3'd0: reg_rdata = {tlb[img_entry].vtag, 12'd0};
        3'd1: reg_rdata = {16'd0, tlb[img_entry].ctx};
        3'd2: reg_rdata = tlb_pte_image(tlb[img_entry]);
        3'd3: reg_rdata = {31'd0, tlb[img_entry].lock};
        default: reg_rdata = 32'd0;
      endcase
    end else if (reg_asi_i == 8'h03) begin
      reg_rdata = w_result;
    end
  end

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
      if (recorded(sfsr_n, acc_fault(lk.at, tlb[h_idx].acc), lk.at)) sfar_n = lk.va;
      sfsr_n = record(sfsr_n, acc_fault(lk.at, tlb[h_idx].acc), lk.at, tlb[h_idx].lvl, 1'b1, 1'b0);
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

  // A write that can change a lookup's answer, this cycle (see the lookup)
  assign tlb_mod_now = (ws == W_DONE && !w_probe && !w_fault) ||
                       (reg_go && reg_we_i && reg_is_word &&
                        (reg_asi_i == 8'h03 || reg_asi_i == 8'h05 || reg_asi_i == 8'h06 || reg_asi_i == 8'h07 ||
                         (reg_asi_i == 8'h04 && (reg_va_i[12:8] == 5'h00 || reg_va_i[12:8] == 5'h02))));

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
      for (int i = 0; i < 64; i++) tlb[i] <= '0;
      used <= '0;
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

      // used bits: a hit sets
      if (lk_go && h_hit) used[h_idx] <= 1'b1;

      // translation caches outside drop on anything that changes a translation
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
          ws <= W_IDLE;
          if (w_probe) begin
            probe_done <= 1'b1;
          end else begin
            walk_done_o <= 1'b1;
            walk_fault_o <= w_fault;
            walk_masked_o <= w_fault && nf && w_no_fault;
            if (!w_fault && w_rep) begin
              tlb[w_rep_idx] <= new_entry;
              used[w_rep_idx] <= 1'b1;
            end else if (!w_fault) begin
              tlb[victim] <= new_entry;
              used[victim] <= 1'b1;
              if (&(used | (64'd1 << victim))) begin
                // every entry used: clear the others' history (Viking §4.11.4)
                for (int i = 0; i < 64; i++) if (6'(i) != victim && !tlb[i].lock) used[i] <= 1'b0;
              end
            end
          end
        end
        default: ws <= W_IDLE;
      endcase

      // ---- register accesses ----
      if (reg_go) begin
        reg_rdata_o <= reg_rdata;              // captured before a read-clear takes effect
        if (reg_asi_i == 8'h03) begin
          if (reg_we_i) begin
            if (reg_is_word) begin
              for (int i = 0; i < 64; i++)
                if (flush_match(tlb[i], reg_va_i[10:8], reg_va_i, ctx)) tlb[i].v <= 1'b0;
              if (reg_va_i[10:8] == 3'd4) used <= '0;
            end
            reg_ack_o <= 1'b1;
            reg_fault_o <= !reg_is_word;
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
          if (reg_is_word && reg_we_i) begin
            case (reg_asi_i)
              8'h04: begin
                case (reg_va_i[12:8])
                  5'h00: mcntl <= (MCNTL_RESET & ~MCNTL_WMASK) | (reg_wdata_i & MCNTL_WMASK);
                  5'h01: ctpr <= reg_wdata_i & 32'hFFFF_FFC0;
                  5'h02: ctx <= reg_wdata_i[15:0];
                  5'h07: if (reg_wdata_i[1]) si_reset_o <= 1'b1;
                  5'h10: trcr <= reg_wdata_i;
                  default: ;                 // 0x13/0x14 are in the SFSR/SFAR logic above
                endcase
              end
              8'h05, 8'h07: begin
                for (int i = 0; i < 64; i++) tlb[i].v <= 1'b0;
              end
              8'h06: begin
                case (img_sel)
                  3'd0: tlb[img_entry].vtag <= reg_wdata_i[31:12];
                  3'd1: tlb[img_entry].ctx  <= reg_wdata_i[15:0];
                  3'd2: begin
                    tlb[img_entry].ppn <= reg_wdata_i[31:8];
                    tlb[img_entry].c   <= reg_wdata_i[7];
                    tlb[img_entry].m   <= reg_wdata_i[6];
                    tlb[img_entry].v   <= reg_wdata_i[5];
                    tlb[img_entry].acc <= reg_wdata_i[4:2];
                    tlb[img_entry].lvl <= reg_wdata_i[1:0];
                  end
                  3'd3: tlb[img_entry].lock <= reg_wdata_i[0];
                  default: ;
                endcase
              end
              default: ;
            endcase
          end
        end
      end
    end
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, reg_va_i[7:0], w_addr[1:0], wk_pte};

endmodule
