// SPDX-License-Identifier: GPL-2.0-or-later
//
// cpu_module: one SPARC processor module of the SS20 (docs/arch/cpu.md §4,
// docs/arch/mmu.md §1 and §4): the integer unit, the FPU, the SRMMU, the
// two L1 caches, the instruction and data sides that join them, the ASI
// decode of the data side, the memory-port arbiter, the SuperSPARC
// breakpoint/counter/ACTION registers, and the watchdog reset.
//
// From: The SPARC Architecture Manual V8 Appendix I (the ASI assignments);
//   the Viking (TMS390Z50) user documentation §4.11 (ASIs 3-7, 0x20-0x2F
//   bypass with PA[35:32] = ASI[3:0]), §4.7.6/§4.8.6 (0x0C-0x0F, 0x36/37),
//   §4.14 (ASI 0x38 breakpoint registers, 0x49-0x4B counters, 0x4C
//   ACTION), §4.13.2 (watchdog reset: boot mode, EM); Sun-4M System
//   Architecture §12 (resets); tests/cpu as the acceptance suite.
//
// Reserved ASIs read 0 and ignore writes (docs/arch/mmu.md §0). The data
// side runs one access at a time, as the IU issues them.

module cpu_module
  import cpu_pkg::*;
#(
  parameter bit HAS_FPU = 1'b1,
  parameter bit          SS20    = 1'b1,    // SYSCONF (ASI 4 VA 0xD00, a private register read by
                                            // OpenBIOS and the suite): RAM MB (ram_mb_i) in 31:20, SS20 in bit 4,
  parameter logic [1:0]  NCPU_M1 = 2'd0     // the CPU count minus one in 1:0
)(
  input  logic        clk,
  input  logic        rst,

  input  logic [3:0]  mid_i,
  input  logic [3:0]  irl_i,
  input  logic        cache_en_i,     // 0: both caches off whatever MCNTL says (the OSD's Cachena)
  input  logic [11:0] ram_mb_i,       // installed memory in MB, for SYSCONF (the OSD's option)

  output mem_pkg::mem_req_t mem_req_o,
  input  mem_pkg::mem_rsp_t mem_rsp_i,
  input  mem_pkg::snoop_t   snoop_i,
  output logic              snoop_hold_o,   // a cache's snoop queue is nearly full: deliver no snoop

  output logic        wd_reset_o,     // a watchdog reset was taken (one cycle)
  output logic        si_reset_o,     // software-internal reset requested (one cycle)
  output logic        halt_o,         // the IU is in error mode (until the watchdog)
  output logic        boot_mode_o,    // MCNTL.BM: fetches go to the boot PROM (the memory controller's PROM timing)

  // for the board's hang reporter (rtl/lib/hang_dump.sv)
  output logic        dbg_commit_o,
  output logic        dbg_trap_o,
  output logic [7:0]  dbg_tt_o,
  output logic [31:0] dbg_pc_o,
  output logic [31:0] dbg_psr_o,
  output logic [5:0][31:0] dbg_w_o
);

  import mmu_pkg::*;
  import mem_pkg::*;
  import fpu_pkg::*;

  // ---------------------------------------------------------------------
  // The IU and the FPU
  // ---------------------------------------------------------------------
  ifetch_req_t ifr;
  ifetch_rsp_t ifs;
  dmem_req_t   dmr;
  dmem_rsp_t   dms;
  fpu_req_t    fpr;
  fpu_rsp_t    fps;
  logic        iu_error, iu_halt;
  logic [2:0]  iu_cwp;
  logic        iu_rst;              // reset or the watchdog

  logic        ic_fast;                // (the I-cache has no fast path)
  logic [15:0] dbg_pipe;
  logic [8:0]  d_nidx;                 // the IU's next M index: the D-cache's RAMs are read a cycle ahead
  logic [7:0]  dbg_mmu, dbg_ic, dbg_dc;

  iu #(.HAS_FPU(HAS_FPU)) u_iu (
    .clk, .rst(iu_rst), .ifetch_req_o(ifr), .ifetch_rsp_i(ifs), .dmem_req_o(dmr), .dmem_nidx_o(d_nidx), .dmem_rsp_i(dms),
    .fpu_req_o(fpr), .fpu_rsp_i(fps), .irl_i, .error_o(iu_error), .cwp_o(iu_cwp), .halt_o(iu_halt),
    .dbg_commit_o, .dbg_trap_o, .dbg_tt_o, .dbg_pc_o, .dbg_psr_o, .dbg_pipe_o(dbg_pipe));

  generate
    if (HAS_FPU) begin : g_fpu
      fpu u_fpu (.clk, .rst(iu_rst), .req_i(fpr), .rsp_o(fps));
    end else begin : g_nofpu
      assign fps = '0;
    end
  endgenerate

  // The watchdog: error mode resets the IU (PC 0, S = 1, ET = 0) into boot
  // mode with SFSR.EM set; everything else keeps its state
  logic error_q, wd_now;
  always_ff @(posedge clk) begin
    if (rst) error_q <= 1'b0;
    else error_q <= iu_error;
  end
  assign wd_now = iu_error && !error_q;
  assign iu_rst = rst | wd_now;
  assign wd_reset_o = wd_now;
  assign halt_o = iu_error;
  assign boot_mode_o = mcntl[MC_BM];

  // ---------------------------------------------------------------------
  // The MMU
  // ---------------------------------------------------------------------
  logic        rg_valid, rg_we, rg_ack, rg_fault;
  logic [7:0]  rg_asi;
  logic [31:0] rg_va, rg_wdata, rg_rdata;
  logic [1:0]  rg_size;
  xlat_req_t   xi, xd;
  xlat_rsp_t   xi_r, xd_r;
  logic        xd_sel;              // the data side has the MMU's lookup port this cycle (see srmmu)
  logic        wk_req_d, wk_req_i, wk_done, wk_fault, wk_masked;
  logic [1:0]  wk_owner;
  logic        tlb_changed;
  logic        be_valid, be_no_fault, be_masked;
  at_t         be_at;
  logic [31:0] be_va;
  mem_req_t    mem_w;
  mem_rsp_t    mem_w_r;
  logic [31:0] mcntl;

  srmmu u_mmu (
    .clk, .rst,
    .reg_valid_i(rg_valid), .reg_we_i(rg_we), .reg_asi_i(rg_asi), .reg_va_i(rg_va), .reg_wdata_i(rg_wdata),
    .reg_size_i(rg_size), .reg_ack_o(rg_ack), .reg_fault_o(rg_fault), .reg_rdata_o(rg_rdata),
    .xi_i(xi), .xi_o(xi_r), .xd_i(xd), .xd_o(xd_r), .xd_sel_i(xd_sel), .tlb_changed_o(tlb_changed),
    .walk_req_d_i(wk_req_d), .walk_req_i_i(wk_req_i), .walk_owner_o(wk_owner),
    .walk_done_o(wk_done), .walk_fault_o(wk_fault), .walk_masked_o(wk_masked),
    .berr_valid_i(be_valid), .berr_at_i(be_at), .berr_va_i(be_va), .berr_no_fault_i(be_no_fault), .berr_masked_o(be_masked),
    .mem_req_o(mem_w), .mem_rsp_i(mem_w_r),
    .sysconf_i({ram_mb_i, 12'd0, 3'd0, SS20, 2'b00, NCPU_M1}), .cpu_idx_i(mid_i[1:0]),
    .mcntl_o(mcntl), .wd_i(wd_now), .si_reset_o(si_reset_o), .dbg_o(dbg_mmu));

  logic ie, de, nf;
  assign ie = mcntl[MC_IE] && cache_en_i;
  assign de = mcntl[MC_DE] && cache_en_i;
  assign nf = mcntl[MC_NF];

  // MCNTL.SE (snoop enable) gates the snooping of the other processors'
  // writes (t_smp_nosnoop, C-4); DVMA's writes (MID 0) and this module's
  // own are always snooped, so DMA stays coherent whatever the PROM sets
  mem_pkg::snoop_t snoop_m;
  always_comb begin
    snoop_m = snoop_i;
    if (!mcntl[MC_SE] && snoop_i.mid != mid_i && snoop_i.mid != 4'd0) snoop_m.valid = 1'b0;
  end

  // ---------------------------------------------------------------------
  // The caches
  // ---------------------------------------------------------------------
  logic        ic_req, ic_taken, ic_done, ic_err;
  logic [35:0] ic_pa;
  logic [8:0]  ic_idx;
  logic        ic_cacheable;
  logic [63:0] ic_rdata;
  logic        ic_inval, dc_inval;
  logic [35:5] inval_line;
  logic        ic_flash_v, ic_flash_l, dc_flash_v, dc_flash_l;
  logic        ic_flash_busy, dc_flash_busy;
  logic        ic_dg_req, ic_dg_done, dc_dg_req, dc_dg_done;
  logic [63:0] ic_dg_rdata, dc_dg_rdata;
  mem_req_t    mem_i, mem_d;
  logic        dc_wb_empty;            // the D-cache's write buffer is empty (the arbiter waits for it)
  logic        ic_wb_empty;            // (the I-cache has none)
  mem_rsp_t    mem_i_r, mem_d_r;
  logic        ic_hold, dc_hold;
  assign snoop_hold_o = ic_hold | dc_hold;

  l1cache #(.ICACHE(1'b1)) u_ic (
    .clk, .rst, .enable_i(ie), .mid_i,
    .req_i(ic_req), .freq_i(1'b0), .we_i(1'b0), .atomic_i(1'b0), .cacheable_i(ic_cacheable), .pa_i(ic_pa), .idx_i(ic_idx), .be_i(8'hFF), .wdata_i(64'd0),
    .taken_o(ic_taken), .done_o(ic_done), .fast_o(ic_fast), .rdata_o(ic_rdata), .err_o(ic_err),
    .inval_i(ic_inval), .inval_line_i(inval_line), .snoop_i(snoop_m), .snoop_hold_o(ic_hold),
    .flash_v_i(ic_flash_v), .flash_l_i(ic_flash_l), .flash_busy_o(ic_flash_busy),
    .diag_req_i(ic_dg_req), .diag_we_i(dmr.write), .diag_tag_i(!dmr.asi[0]), .diag_va_i(dmr.va), .diag_wdata_i(diag_wdata),
    .diag_done_o(ic_dg_done), .diag_rdata_o(ic_dg_rdata),
    .mem_req_o(mem_i), .mem_rsp_i(mem_i_r), .wb_empty_o(ic_wb_empty), .dbg_o(dbg_ic));

  logic        dc_req, dc_we, dc_atomic, dc_cacheable, dc_done, dc_err;
  logic        dc_fast;                // a read hit answered in its request cycle (D_IDLE)
  logic        d_hit_now;              // a normal-ASI request translated by the micro-TLB this cycle (below)
  /* verilator lint_off UNUSEDSIGNAL */
  logic        dc_taken;               // (the data side needs no such flag: its index is the VA's)
  /* verilator lint_on UNUSEDSIGNAL */
  logic [35:0] dc_pa;
  logic [8:0]  dc_idx;
  logic [7:0]  dc_be;
  logic [63:0] dc_wdata, dc_rdata;

  // The walker's R/M writes are this module's own, which the D-cache does
  // not take from the snoop broadcast: drop the line they hit explicitly
  logic        walk_wr_ack;
  logic        dc_inval_any;
  logic [35:5] dc_inval_line;
  assign walk_wr_ack   = owner == 2'd1 && mem_rsp_i.ack && mem_w.write;
  assign dc_inval_any  = dc_inval | walk_wr_ack;
  assign dc_inval_line = walk_wr_ack ? mem_w.pa[35:5] : inval_line;

  l1cache #(.ICACHE(1'b0), .FAST_HIT(1'b1)) u_dc (
    .clk, .rst, .enable_i(de), .mid_i,
    .req_i(dc_req), .freq_i(d_hit_now), .we_i(dc_we), .atomic_i(dc_atomic), .cacheable_i(dc_cacheable), .pa_i(dc_pa), .idx_i(dc_idx), .be_i(dc_be), .wdata_i(dc_wdata),
    .taken_o(dc_taken), .done_o(dc_done), .fast_o(dc_fast), .rdata_o(dc_rdata), .err_o(dc_err),
    .inval_i(dc_inval_any), .inval_line_i(dc_inval_line), .snoop_i(snoop_m), .snoop_hold_o(dc_hold),
    .flash_v_i(dc_flash_v), .flash_l_i(dc_flash_l), .flash_busy_o(dc_flash_busy),
    .diag_req_i(dc_dg_req), .diag_we_i(dmr.write), .diag_tag_i(!dmr.asi[0]), .diag_va_i(dmr.va), .diag_wdata_i(diag_wdata),
    .diag_done_o(dc_dg_done), .diag_rdata_o(dc_dg_rdata),
    .mem_req_o(mem_d), .mem_rsp_i(mem_d_r), .wb_empty_o(dc_wb_empty), .dbg_o(dbg_dc));

  // ---------------------------------------------------------------------
  // The memory-port arbiter: walker > data > instruction; the owner keeps
  // the port while its request is valid, and through a locked pair. The
  // walker and the I-cache are given the port only while the D-cache's
  // write buffer is empty (they must not read memory a buffered store is
  // about to change: a PTE, code); the data side drains it meanwhile.
  // ---------------------------------------------------------------------
  logic [1:0] owner_q, owner;        // 0 none, 1 walker, 2 data, 3 instruction
  logic       owner_busy, locked_q;
  always_comb begin
    case (owner_q)
      2'd1: owner_busy = mem_w.valid;
      2'd2: owner_busy = mem_d.valid | locked_q;
      2'd3: owner_busy = mem_i.valid;
      default: owner_busy = 1'b0;
    endcase
    if (owner_busy) owner = owner_q;
    else if (mem_w.valid && dc_wb_empty) owner = 2'd1;
    else if (mem_d.valid) owner = 2'd2;
    else if (mem_i.valid && dc_wb_empty) owner = 2'd3;
    else owner = 2'd0;
    case (owner)
      2'd1: mem_req_o = mem_w;
      2'd2: mem_req_o = mem_d;
      2'd3: mem_req_o = mem_i;
      default: mem_req_o = '0;
    endcase
    // the data goes to all three (each reads it only with its ack); ack
    // and err are steered to the owner
    mem_w_r = '0; mem_d_r = '0; mem_i_r = '0;
    mem_w_r.rdata = mem_rsp_i.rdata; mem_d_r.rdata = mem_rsp_i.rdata; mem_i_r.rdata = mem_rsp_i.rdata;
    case (owner)
      2'd1: begin mem_w_r.ack = mem_rsp_i.ack; mem_w_r.err = mem_rsp_i.err; end
      2'd2: begin mem_d_r.ack = mem_rsp_i.ack; mem_d_r.err = mem_rsp_i.err; end
      2'd3: begin mem_i_r.ack = mem_rsp_i.ack; mem_i_r.err = mem_rsp_i.err; end
      default: ;
    endcase
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      owner_q <= 2'd0;
      locked_q <= 1'b0;
    end else begin
      owner_q <= owner;
      // a locked read keeps the port for the owner until its write completes;
      // a failed read has no write to wait for (an atomic to an empty slot)
      if (mem_req_o.valid && mem_rsp_i.ack) begin
        if (mem_req_o.lock && !mem_req_o.write && !mem_rsp_i.err) locked_q <= 1'b1;
        else if (mem_req_o.write || mem_rsp_i.err) locked_q <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------
  // The instruction side. A request is translated in the cycle it is made
  // only by the instruction micro-TLB below (or directly with the MMU off
  // or in boot mode) and the cache indexed at once; a cache hit answers in
  // the next cycle, in which the IU's next request is taken, so that
  // fetches run one per cycle on hits. A micro-TLB miss goes to the MMU's
  // TLB from a register in the next cycle (I_XLAT), and the cache request
  // follows one cycle later still from the registered PA (I_CACHE): the
  // IU's request valid arrives late in the cycle (it depends on E's branch
  // resolution), so nothing long may hang off it — the address the
  // lookups use is chosen by the state alone.
  // ---------------------------------------------------------------------
  typedef enum logic [2:0] {I_IDLE, I_XLAT, I_WALK, I_WALK_WAIT, I_CACHE} istate_t;
  istate_t     is;
  logic [31:0] i_va;
  logic        i_supv;
  logic [35:0] ic_pa_q;
  logic        ic_cacheable_q;
  ifetch_rsp_t ifs_q;

  logic        i_new, i_hit_now;
  logic [31:0] i_va_now;
  logic        i_supv_now;
  assign i_new      = ifr.valid && (is == I_IDLE || (is == I_CACHE && ic_done));
  assign i_va_now   = ifr.va;          // the request's address (a register in the IU)
  assign i_supv_now = ifr.supv;
  at_t         i_at;
  assign i_at = {1'b0, 1'b1, i_supv};

  // Untranslated fetches: boot mode sends them to the PROM, the MMU off
  // passes the VA (srmmu.sv's answer() for the same cases)
  logic        i_direct;
  logic [35:0] i_direct_pa;
  assign i_direct    = !mcntl[MC_EN] || mcntl[MC_BM];
  assign i_direct_pa = mcntl[MC_BM] ? {8'hFF, i_va_now[27:0]} : {4'h0, i_va_now};

  // The instruction side's own translation cache: the last eight pages
  // translated through the MMU. A hit must still pass the permission check
  // (else the MMU records the fault); everything is dropped whenever a
  // translation may have changed (tlb_changed).
  // The PPNs are in MLAB (asynchronous read at the hit's index: off the
  // critical paths, which run through the tag compare to the hit).
  localparam int UT = 8;
  logic        ut_v [UT];
  logic [19:0] ut_vtag [UT];
  (* ramstyle = "MLAB, no_rw_check" *) logic [23:0] ut_ppn [UT];
  logic [2:0]  ut_acc [UT];
  logic [2:0]  ut_wp;
  logic        ut_hit, ut_ok;
  logic [35:0] ut_pa;
  logic [2:0]  ut_acc_hit, ut_k;
  always_comb begin
    ut_hit = 1'b0; ut_k = '0; ut_acc_hit = '0;
    for (int k = 0; k < UT; k++) begin
      if (ut_v[k] && ut_vtag[k] == i_va_now[31:12]) begin
        ut_hit = 1'b1; ut_k = 3'(k); ut_acc_hit = ut_acc[k];
      end
    end
    ut_pa = {ut_ppn[ut_k], i_va_now[11:0]};
    ut_ok = i_direct || (ut_hit && acc_fault({1'b0, 1'b1, i_supv_now}, ut_acc_hit) == FT_NONE);
  end
  logic [35:0] i_fast_pa;
  assign i_fast_pa = i_direct ? i_direct_pa : ut_pa;

  // The fill happens one cycle after the MMU's answer, from a registered
  // copy of it (the TLB's CAM → PTE mux → the entry is long). A
  // translation change in between drops the fill.
  logic        ut_fill, ut_fill_q;
  logic [19:0] ut_fill_vtag;
  logic [23:0] ut_fill_ppn;
  logic [2:0]  ut_fill_acc;
  assign ut_fill = is == I_XLAT && xi_r.hit && !xi_r.busy && mcntl[MC_EN] && !mcntl[MC_BM];
  always_ff @(posedge clk)
    if (!(rst || tlb_changed) && ut_fill_q) ut_ppn[ut_wp] <= ut_fill_ppn;
  always_ff @(posedge clk) begin
    ut_fill_vtag <= i_va[31:12];
    ut_fill_ppn  <= xi_r.pa[35:12];
    ut_fill_acc  <= xi_r.acc;
    if (rst || tlb_changed) begin
      for (int k = 0; k < UT; k++) ut_v[k] <= 1'b0;
      ut_wp <= '0;
      ut_fill_q <= 1'b0;
    end else begin
      ut_fill_q <= ut_fill;
      if (ut_fill_q) begin
        ut_v[ut_wp]    <= 1'b1;
        ut_vtag[ut_wp] <= ut_fill_vtag;
        ut_acc[ut_wp]  <= ut_fill_acc;
        ut_wp <= ut_wp + 3'd1;
      end
    end
  end

  // The MMU's lookup port, from the registered VA only
  always_comb begin
    xi = '0;
    xi.valid = is == I_XLAT;
    xi.va = i_va;
    xi.at = {1'b0, 1'b1, i_supv};
    xi.no_fault = 1'b0;
    wk_req_i = xi.valid && xi_r.miss && !xi_r.busy && wk_owner == 2'd0;
  end
  assign i_hit_now    = i_new && ut_ok;
  assign ic_req       = i_hit_now || (is == I_CACHE && !ic_done);   // held until done
  // The address the cache sees: the registered one while a request in
  // I_CACHE waits to be taken (after the MMU's lookup, or the cache was
  // busy), else this cycle's fast translation. Chosen by state only: the
  // request valid (i_hit_now) is late.
  logic        i_pend_q;
  logic        ic_use_q;
  assign ic_use_q     = is == I_CACHE && i_pend_q;
  assign ic_pa        = ic_use_q ? ic_pa_q : i_fast_pa;
  assign ic_cacheable = ic_use_q ? ic_cacheable_q : cacheable_pa(i_fast_pa);
  assign ic_idx       = ic_use_q ? ic_pa_q[11:3] : i_va_now[11:3];

  // The response: a cache answer the cycle it comes, a fault from the
  // register; one the IU does not take (ready low: its buffer is full) is
  // held here and offered until it does (the IU issues nothing meanwhile)
  ifetch_rsp_t ifs_now, ifs_hold;
  logic        ifs_hold_v;
  always_comb begin
    ifs_now = ifs_q;
    if (is == I_CACHE && ic_done) begin
      ifs_now.valid = 1'b1;
      ifs_now.inst  = ic_pa_q[2] ? ic_rdata[31:0] : ic_rdata[63:32];
      ifs_now.fault = ic_err ? 2'd2 : 2'd0;
    end
  end
  assign ifs = ifs_hold_v ? ifs_hold : ifs_now;
  always_ff @(posedge clk) begin
    if (iu_rst) ifs_hold_v <= 1'b0;
    else if (ifs.valid && !ifr.ready) begin ifs_hold_v <= 1'b1; ifs_hold <= ifs; end
    else if (ifr.ready) ifs_hold_v <= 1'b0;
  end

  always_ff @(posedge clk) begin
    ifs_q <= '0;
    if (iu_rst) begin
      is <= I_IDLE;
      i_va <= '0; i_supv <= 1'b0;
      ic_pa_q <= '0; ic_cacheable_q <= 1'b0; i_pend_q <= 1'b0;
    end else begin
      if (ic_taken) i_pend_q <= 1'b0;
      case (is)
        I_IDLE, I_CACHE: begin
          if (is == I_CACHE && !ic_done) begin
            // waiting for the cache
          end else if (i_new) begin
            i_va <= ifr.va; i_supv <= ifr.supv;
            if (ut_ok) begin
              ic_pa_q <= i_fast_pa;
              ic_cacheable_q <= cacheable_pa(i_fast_pa);
              i_pend_q <= !ic_taken;      // the cache was busy: the registered PA from now on
              is <= I_CACHE;
            end else begin
              is <= I_XLAT;                // the micro-TLB missed: the MMU's TLB next
            end
          end else begin
            is <= I_IDLE;
          end
        end
        I_XLAT: begin
          if (xi_r.busy) begin
            // the data side had the lookup: again next cycle
          end else if (xi_r.hit) begin
            ic_pa_q <= xi_r.pa;
            ic_cacheable_q <= cacheable_pa(xi_r.pa);
            i_pend_q <= 1'b1;
            is <= I_CACHE;                 // the cache request goes out next cycle, from the register
          end else if (xi_r.fault) begin
            ifs_q.valid <= 1'b1; ifs_q.fault <= 2'd1;
            is <= I_IDLE;
          end else if (wk_req_i) begin
            is <= I_WALK;
          end else begin
            is <= I_WALK_WAIT;             // the walker is busy for the data side
          end
        end
        I_WALK: begin
          if (wk_done && wk_owner == 2'd2) begin
            if (wk_fault) begin ifs_q.valid <= 1'b1; ifs_q.fault <= 2'd1; is <= I_IDLE; end
            else is <= I_XLAT;
          end else if (wk_owner != 2'd2) begin
            is <= I_WALK_WAIT;             // the data side took the walker
          end
        end
        I_WALK_WAIT: begin
          if (wk_owner == 2'd0) is <= I_XLAT;
        end
        default: is <= I_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------
  // The data side
  // ---------------------------------------------------------------------
  // Byte lanes (big-endian: byte 0 of the doubleword is data[63:56])
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [7:0] lanes_be(input logic [1:0] size, input logic [2:0] a);
    case (size)
      2'd0: return 8'h80 >> a;
      2'd1: return 8'hC0 >> {a[2:1], 1'b0};
      2'd2: return a[2] ? 8'h0F : 8'hF0;
      default: return 8'hFF;
    endcase
  endfunction
  function automatic logic [63:0] lanes_wdata(input logic [1:0] size, input logic [63:0] w);
    case (size)
      2'd0: return {8{w[7:0]}};
      2'd1: return {4{w[15:0]}};
      2'd2: return {2{w[31:0]}};
      default: return w;
    endcase
  endfunction
  function automatic logic [63:0] lanes_rdata(input logic [1:0] size, input logic [2:0] a, input logic [63:0] r);
    logic [63:0] sh;
    sh = r << (a * 8);                         // the addressed byte to the top
    case (size)
      2'd0: return {56'd0, sh[63:56]};
      2'd1: return {48'd0, sh[63:48]};
      2'd2: return {32'd0, sh[63:32]};
      default: return r;
    endcase
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  typedef enum logic [3:0] {
    D_IDLE, D_XLAT, D_WALK, D_WALK_WAIT, D_CACHE, D_REG, D_DIAG_I, D_DIAG_D, D_FLUSH_XLAT, D_FLUSH_WALK, D_FLUSH_WAIT,
    D_FLASH, D_WD
  } dstate_t;
  dstate_t     ds;
  logic        d_normal, d_bypass, d_flushasi;
  at_t         d_at;
  logic        d_no_fault;
  logic [35:0] d_pa;
  logic        d_cacheable;

  // ASI 0x38 (the four breakpoint registers: value and mask 36 bits,
  // control 7, status 4, cleared by a read), 0x49-0x4B (the counters: 32,
  // 2, 2 bits) and 0x4C (ACTION, 13 bits): eight words in MLAB, read a
  // cycle ahead of the answer at the request's index, written masked to
  // each word's width. Reset clears all eight, the watchdog control,
  // status, the counter controls and ACTION, by a sweep (D_WD: the data
  // side takes nothing meanwhile; the IU's first access comes later). In
  // flops with their muxes they cost ~250 ALUTs a CPU.
  (* ramstyle = "MLAB, no_rw_check" *) logic [35:0] bk_m [8];
  logic [2:0]  bk_idx;                  // the request's word
  logic        bk_sel;                  // the request is one of these registers
  logic        bk_wr;                   // ... written now (the access is taken)
  logic [35:0] bk_q;                    // the word read
  logic        bk_sel_q;                // the answer is bk_q
  logic        bk_rdclr;                // the status word is cleared after its read (the ack cycle)
  logic [2:0]  wd_idx;                  // the sweep's word
  logic [7:0]  wd_clr;                  // the words it clears
  always_comb begin
    bk_sel = 1'b1;
    case (dmr.asi)
      8'h38:   bk_idx = {1'b0, dmr.va[9:8]};
      8'h49:   bk_idx = 3'd4;
      8'h4A:   bk_idx = 3'd5;
      8'h4B:   bk_idx = 3'd6;
      8'h4C:   bk_idx = 3'd7;
      default: begin bk_idx = 3'd0; bk_sel = 1'b0; end
    endcase
  end
  function automatic logic [35:0] bk_wmask(input logic [2:0] i);
    case (i)
      3'd0, 3'd1: return 36'hF_FFFF_FFFF;
      3'd2:       return 36'h7F;
      3'd3:       return 36'hF;
      3'd4:       return 36'hFFFF_FFFF;
      3'd5, 3'd6: return 36'h3;
      default:    return 36'h1FFF;
    endcase
  endfunction
  // One write port (the sweep, a write, the status read-clear: exclusive,
  // in that priority), so Quartus can infer the MLAB.
  logic        bk_we;
  logic [2:0]  bk_wa;
  logic [35:0] bk_wd;
  always_comb begin
    if (ds == D_WD) begin
      bk_we = wd_clr[wd_idx]; bk_wa = wd_idx; bk_wd = '0;
    end else if (bk_wr) begin
      bk_we = 1'b1;           bk_wa = bk_idx; bk_wd = dmr.wdata[35:0] & bk_wmask(bk_idx);
    end else begin
      bk_we = bk_rdclr;       bk_wa = 3'd3;   bk_wd = '0;
    end
  end
  always_ff @(posedge clk) begin
    bk_q <= bk_m[bk_idx];
    if (bk_we) bk_m[bk_wa] <= bk_wd;
  end

  assign d_normal   = dmr.asi[7:2] == 6'b000010;              // 0x08-0x0B
  assign d_bypass   = dmr.asi[7:4] == 4'h2;                   // 0x20-0x2F
  assign d_flushasi = (dmr.asi[7:3] == 5'b00010 && dmr.asi[2:0] <= 3'd4) ||   // 0x10-0x14
                      (dmr.asi[7:3] == 5'b00011 && dmr.asi[2:0] <= 3'd4);     // 0x18-0x1C
  assign d_at       = {dmr.write | dmr.atomic, ~dmr.asi[1], dmr.asi[0]};
  assign d_no_fault = dmr.asi != 8'h09;

  // The data side translates a normal-ASI request in the cycle it arrives
  // only by its micro-TLB below, or directly (MMU off; boot mode for the
  // instruction-space ASIs), and the cache takes it at once; a miss, or a
  // hit the permission check or a clear M bit refuses, goes to the MMU's
  // TLB (D_XLAT: two cycles from registered state), the cache request then
  // follows from the registered PA. Line flushes look up in D_FLUSH_XLAT.
  dmem_rsp_t   dms_q;                   // the registered part of the answer
  logic        d_new, d_bypass_now;     // (d_hit_now: above, the D-cache's freq_i)
  assign d_new        = ds == D_IDLE && dmr.valid && !dms_q.ack && d_normal;
  assign d_bypass_now = ds == D_IDLE && dmr.valid && !dms_q.ack && d_bypass;

  logic        d_direct;
  logic [35:0] d_direct_pa;
  assign d_direct    = !mcntl[MC_EN] || (mcntl[MC_BM] && d_at[1]);
  assign d_direct_pa = (mcntl[MC_BM] && d_at[1]) ? {8'hFF, dmr.va[27:0]} : {4'h0, dmr.va};

  localparam int DUT = 8;
  logic        dut_v [DUT];
  logic [19:0] dut_vtag [DUT];
  (* ramstyle = "MLAB, no_rw_check" *) logic [23:0] dut_ppn [DUT];   // as ut_ppn
  logic [2:0]  dut_acc [DUT];
  logic        dut_m [DUT];
  logic [2:0]  dut_wp;
  logic        dut_hit, dut_ok, dut_m_hit;
  logic [35:0] dut_pa;
  logic [2:0]  dut_acc_hit, dut_k;
  always_comb begin
    dut_hit = 1'b0; dut_k = '0; dut_acc_hit = '0; dut_m_hit = 1'b0;
    for (int k = 0; k < DUT; k++) begin
      if (dut_v[k] && dut_vtag[k] == dmr.va[31:12]) begin
        dut_hit = 1'b1; dut_k = 3'(k); dut_acc_hit = dut_acc[k]; dut_m_hit = dut_m[k];
      end
    end
    dut_pa = {dut_ppn[dut_k], dmr.va[11:0]};
    dut_ok = d_direct || (dut_hit && acc_fault(d_at, dut_acc_hit) == FT_NONE && (!d_at[2] || dut_m_hit));
  end
  logic [35:0] d_fast_pa;
  assign d_fast_pa = d_direct ? d_direct_pa : dut_pa;

  // Filled one cycle after the MMU's answer, from a registered copy
  logic        dut_fill, dut_fill_q;
  logic [19:0] dut_fill_vtag;
  logic [23:0] dut_fill_ppn;
  logic [2:0]  dut_fill_acc;
  logic        dut_fill_m;
  assign dut_fill = ds == D_XLAT && xd_r.hit && !d_direct;
  // A page already held whose copy refused the access (M clear for a store,
  // or the permission check: the MMU then faults, and fills nothing) is
  // replaced in place: the entry that matched when the request left D_IDLE
  // for the MMU (dut_dup, remembered then) is the one to replace; nothing
  // else can hold the page, since a request fills only after a miss there
  logic        dut_dup;
  logic [2:0]  dut_dup_idx;
  always_ff @(posedge clk)
    if (!(rst || tlb_changed) && dut_fill_q) dut_ppn[dut_dup ? dut_dup_idx : dut_wp] <= dut_fill_ppn;
  always_ff @(posedge clk) begin
    dut_fill_vtag <= dmr.va[31:12];
    dut_fill_ppn  <= xd_r.pa[35:12];
    dut_fill_acc  <= xd_r.acc;
    dut_fill_m    <= xd_r.m;
    if (ds == D_IDLE) begin dut_dup <= dut_hit && !d_direct; dut_dup_idx <= dut_k; end
    if (rst || tlb_changed) begin
      for (int k = 0; k < DUT; k++) dut_v[k] <= 1'b0;
      dut_wp <= '0;
      dut_fill_q <= 1'b0;
      dut_dup <= 1'b0;
    end else begin
      dut_fill_q <= dut_fill;
      if (dut_fill_q) begin
        // a page already held (its copy refused a store: M was clear) is replaced in place
        if (dut_dup) begin
          dut_acc[dut_dup_idx] <= dut_fill_acc; dut_m[dut_dup_idx] <= dut_fill_m;
        end else begin
          dut_v[dut_wp]    <= 1'b1;
          dut_vtag[dut_wp] <= dut_fill_vtag;
          dut_acc[dut_wp]  <= dut_fill_acc;
          dut_m[dut_wp]    <= dut_fill_m;
          dut_wp <= dut_wp + 3'd1;
        end
      end
    end
  end

  always_comb begin
    xd = '0;
    xd.va = dmr.va;
    if (ds == D_XLAT) begin
      xd.valid = 1'b1; xd.at = d_at; xd.no_fault = d_no_fault;
    end else if (ds == D_FLUSH_XLAT) begin
      xd.valid = 1'b1; xd.at = AT_LD_SD; xd.no_fault = 1'b1;
    end
    wk_req_d = xd.valid && xd_r.miss && wk_owner == 2'd0;
  end
  assign d_hit_now = d_new && dut_ok;
  assign xd_sel = ds == D_XLAT || ds == D_FLUSH_XLAT;

  // Requests to the blocks: the cache in the request cycle on the fast
  // paths, else from the registered PA (chosen by state: the request valid is late)
  logic d_fast_sel;
  assign d_fast_sel = ds == D_IDLE;
  assign dc_req   = d_hit_now || d_bypass_now || (ds == D_CACHE && !dc_done);
  assign dc_we    = dmr.write;
  assign dc_atomic = dmr.atomic;
  assign dc_pa    = !d_fast_sel ? d_pa : d_bypass ? {dmr.asi[3:0], dmr.va} : d_fast_pa;
  assign dc_cacheable = !d_fast_sel ? d_cacheable : d_bypass ? 1'b0 : cacheable_pa(d_fast_pa);
  assign dc_idx   = d_nidx;            // the next cycle's VA[11:3] (= the PA's, the page offset): no wait for the TLB
  assign dc_be    = lanes_be(dmr.size, dc_pa[2:0]);     // from the PA of this cycle, not the latched one
  assign dc_wdata = lanes_wdata(dmr.size, dmr.wdata);
  assign rg_valid = ds == D_REG;
  assign rg_we    = dmr.write;
  assign rg_asi   = dmr.asi;
  assign rg_va    = dmr.va;
  assign rg_wdata = dmr.wdata[31:0];
  assign rg_size  = dmr.size;
  assign ic_dg_req = ds == D_DIAG_I;
  assign dc_dg_req = ds == D_DIAG_D;
  // a breakpoint/counter register write: the access is taken now (the
  // state machine's D_IDLE case below, bk_sel branch; not under reset or
  // the watchdog, which take the state instead)
  assign bk_wr = ds == D_IDLE && dmr.valid && !dms_q.ack && bk_sel && dmr.write &&
                 !(dmr.asi == 8'h38 && dmr.size != 2'd3) && !rst && !wd_now;
  // a diagnostic access as a doubleword, or a word in its half
  logic [63:0] diag_wdata;
  assign diag_wdata = (dmr.size == 2'd3) ? dmr.wdata : (dmr.va[2] ? {32'd0, dmr.wdata[31:0]} : {dmr.wdata[31:0], 32'd0});
  function automatic logic [63:0] diag_rd(input logic [63:0] d);
    if (dmr.size == 2'd3) return d;
    return dmr.va[2] ? {32'd0, d[31:0]} : {32'd0, d[63:32]};
  endfunction

  // Bus errors: reported when a cache says so (the data side first)
  // a plain store is posted: its error is the chipset's to report (AFSR,
  // a level-15 interrupt), never a trap here; atomics are reads too
  logic d_berr, i_berr;
  assign d_berr = ds == D_CACHE && dc_done && dc_err && !(dmr.write && !dmr.atomic);
  assign i_berr = is == I_CACHE && ic_done && ic_err;
  assign be_valid = d_berr | i_berr;
  assign be_at    = d_berr ? d_at : i_at;
  assign be_va    = d_berr ? dmr.va : i_va;
  assign be_no_fault = d_berr ? d_no_fault : 1'b0;

  logic d_masked;                 // NF masks this access's faults
  assign d_masked = nf && d_no_fault;

  // The answer to the IU: the cache's in its own cycle, the rest registered.
  // The cache's doubleword is aligned once, by the VA's low bits (a PA's
  // low bits are the VA's, on the fast path and from the register alike:
  // one shifter, not one per path).
  logic [63:0] dc_lanes;
  assign dc_lanes = lanes_rdata(dmr.size, dmr.va[2:0], dc_rdata);
  always_comb begin
    dms = dms_q;
    if (dms_q.ack && bk_sel_q) dms.rdata = {28'd0, bk_q};     // a breakpoint/counter register, read a cycle ago
    if (ds == D_IDLE && dc_fast) begin
      dms.ack = 1'b1;
      dms.rdata = dc_lanes;
    end else if (ds == D_CACHE && dc_done) begin
      dms.ack = 1'b1;
      dms.rdata = dc_lanes;
      dms.fault = (dc_err && !d_masked && !(dmr.write && !dmr.atomic)) ? 2'd2 : 2'd0;
    end
  end

  always_ff @(posedge clk) begin
    dms_q <= '0;
    bk_sel_q <= 1'b0; bk_rdclr <= 1'b0;
    ic_inval <= 1'b0; dc_inval <= 1'b0;
    ic_flash_v <= 1'b0; ic_flash_l <= 1'b0; dc_flash_v <= 1'b0; dc_flash_l <= 1'b0;
    if (rst) begin
      ds <= D_WD;                   // the sweep clears every breakpoint/counter word
      wd_idx <= '0; wd_clr <= 8'hFF;
      d_pa <= '0; d_cacheable <= 1'b0; inval_line <= '0;
    end else if (wd_now) begin
      ds <= D_WD;                   // abandon the access in flight; clear control, status, counter controls, ACTION
      wd_idx <= '0; wd_clr <= 8'b1110_1100;
    end else begin
      case (ds)
        D_IDLE: begin
          if (dmr.valid && !dms_q.ack) begin
            if (d_normal) begin
              if (dut_ok) begin                // translated this cycle (d_hit_now): the cache has it
                d_pa <= d_fast_pa;
                d_cacheable <= cacheable_pa(d_fast_pa);
                if (!dc_fast) ds <= D_CACHE;   // (a read hit with its lines read ahead: answered now)
              end else begin
                ds <= D_XLAT;                  // the MMU's TLB: misses, faults and walks are found there
              end
            end else if (d_bypass) begin
              d_pa <= {dmr.asi[3:0], dmr.va};
              d_cacheable <= 1'b0;
              ds <= D_CACHE;
            end else if (dmr.asi >= 8'h03 && dmr.asi <= 8'h07) begin
              ds <= D_REG;
            end else if (dmr.asi[7:2] == 6'b000011) begin           // 0x0C-0x0F
              // doubleword, or a word (the suite's tag-clearing loops: the
              // other word of the image is written as 0)
              if (dmr.size[1] == 1'b0) begin dms_q.ack <= 1'b1; dms_q.fault <= 2'd1;
`ifndef SYNTHESIS
                $display("%0t cpu_module: data fault (%s) va=%08x asi=%02x write=%0d acc=%0d nf=%0d masked=%0d", $time, "diagnostic size", dmr.va, dmr.asi, dmr.write, xd_r.acc, nf, d_masked); $fflush();
`endif
              end
              else ds <= dmr.asi[1] ? D_DIAG_D : D_DIAG_I;
            end else if (d_flushasi) begin
              if (dmr.write) ds <= D_FLUSH_XLAT;
              else dms_q.ack <= 1'b1;
            end else if (dmr.asi == 8'h36 || dmr.asi == 8'h37) begin
              if (dmr.write) begin
                // the sweep runs; the store completes when it is over
                if (dmr.asi[0]) begin dc_flash_v <= !dmr.va[31]; dc_flash_l <= dmr.va[31]; end
                else            begin ic_flash_v <= !dmr.va[31]; ic_flash_l <= dmr.va[31]; end
                ds <= D_FLASH;
              end else begin
                dms_q.ack <= 1'b1;
              end
            end else if (bk_sel) begin
              // the breakpoint, counter and ACTION registers (bk_m): a
              // doubleword for 0x38; the word read now answers next cycle
              // (bk_wr writes it now), the status word is cleared after a read
              dms_q.ack <= 1'b1;
              if (dmr.asi == 8'h38 && dmr.size != 2'd3) dms_q.fault <= 2'd1;
              else begin
                bk_sel_q <= 1'b1;
                bk_rdclr <= !dmr.write && bk_idx == 3'd3;
              end
            end else begin
              dms_q.ack <= 1'b1;                                   // reserved: 0
            end
          end
        end
        D_WD: begin
          wd_idx <= wd_idx + 3'd1;
          if (wd_idx == 3'd7) ds <= D_IDLE;
        end
        D_XLAT: begin
          if (xd_r.busy) begin
            // the lookup's first cycle, or the port was the other side's
          end else if (xd_r.hit) begin
            d_pa <= xd_r.pa;
            d_cacheable <= cacheable_pa(xd_r.pa);
            ds <= D_CACHE;
          end else if (xd_r.fault) begin
            dms_q.ack <= 1'b1;
            if (!d_masked) begin dms_q.fault <= 2'd1;
`ifndef SYNTHESIS
                $display("%0t cpu_module: data fault (%s) va=%08x asi=%02x write=%0d acc=%0d nf=%0d masked=%0d", $time, "permission", dmr.va, dmr.asi, dmr.write, xd_r.acc, nf, d_masked); $fflush();
`endif
                end
            ds <= D_IDLE;
          end else if (wk_req_d) begin
            ds <= D_WALK;
          end else begin
            ds <= D_WALK_WAIT;
          end
        end
        D_WALK: begin
          if (wk_done && wk_owner == 2'd1) begin
            if (wk_fault) begin
              dms_q.ack <= 1'b1;
              if (!wk_masked) begin dms_q.fault <= 2'd1;
`ifndef SYNTHESIS
                $display("%0t cpu_module: data fault (%s) va=%08x asi=%02x write=%0d acc=%0d nf=%0d masked=%0d", $time, "walk", dmr.va, dmr.asi, dmr.write, xd_r.acc, nf, d_masked); $fflush();
`endif
                end
              ds <= D_IDLE;
            end else ds <= D_XLAT;
          end else if (wk_owner != 2'd1) begin
            ds <= D_WALK_WAIT;
          end
        end
        D_WALK_WAIT: begin
          if (wk_owner == 2'd0) ds <= D_XLAT;
        end
        D_CACHE: begin
          if (dc_done) ds <= D_IDLE;      // the answer is combinational
        end
        D_REG: begin
          if (rg_ack) begin
            dms_q.ack <= 1'b1;
            dms_q.rdata <= {32'd0, rg_rdata};
            if (rg_fault) begin dms_q.fault <= 2'd1;
`ifndef SYNTHESIS
                $display("%0t cpu_module: data fault (%s) va=%08x asi=%02x write=%0d acc=%0d nf=%0d masked=%0d", $time, "mmu register", dmr.va, dmr.asi, dmr.write, xd_r.acc, nf, d_masked); $fflush();
`endif
                end
            ds <= D_IDLE;
          end
        end
        D_DIAG_I: begin
          if (ic_dg_done) begin dms_q.ack <= 1'b1; dms_q.rdata <= diag_rd(ic_dg_rdata); ds <= D_IDLE; end
        end
        D_DIAG_D: begin
          if (dc_dg_done) begin dms_q.ack <= 1'b1; dms_q.rdata <= diag_rd(dc_dg_rdata); ds <= D_IDLE; end
        end
        D_FLUSH_XLAT: begin
          if (xd_r.busy) begin
            // the lookup's first cycle
          end else if (xd_r.hit) begin
            inval_line <= xd_r.pa[35:5];
            dc_inval <= !dmr.asi[3];          // 0x10-0x14 both caches, 0x18-0x1C the I-cache
            ic_inval <= 1'b1;
            dms_q.ack <= 1'b1;
            ds <= D_IDLE;
          end else if (xd_r.fault) begin
            dms_q.ack <= 1'b1;                  // an unmapped page: nothing to flush
            ds <= D_IDLE;
          end else if (wk_req_d) begin
            ds <= D_FLUSH_WALK;
          end else begin
            ds <= D_FLUSH_WAIT;
          end
        end
        D_FLUSH_WALK: begin
          if (wk_done && wk_owner == 2'd1) begin
            if (wk_fault) begin dms_q.ack <= 1'b1; ds <= D_IDLE; end
            else ds <= D_FLUSH_XLAT;
          end else if (wk_owner != 2'd1) ds <= D_FLUSH_WAIT;
        end
        D_FLUSH_WAIT: begin
          if (wk_owner == 2'd0) ds <= D_FLUSH_XLAT;
        end
        D_FLASH: begin
          if (!ic_flash_busy && !dc_flash_busy && !ic_flash_v && !ic_flash_l && !dc_flash_v && !dc_flash_l) begin
            dms_q.ack <= 1'b1;
            ds <= D_IDLE;
          end
        end
        default: ds <= D_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  // synthesis translate_off
  // The IU withdrew its data request while the data side was working on it
  // (a trap flushed M): the answer would land on the next request. A reset
  // or a watchdog reset abandons the access on purpose (D_WD answers
  // nothing).
  logic dmr_valid_q;
  always_ff @(posedge clk) begin
    dmr_valid_q <= dmr.valid;
    if (dmr_valid_q && !dmr.valid && ds != D_IDLE && ds != D_WD && !rst && !wd_now && !dms_q.ack)
      $error("cpu_module: data request withdrawn mid-access (ds=%0d va=%08x): its answer would land on the next request", ds, dmr.va);
  end
  // synthesis translate_on
`endif
  logic unused_ok;
  assign unused_ok = &{1'b0, ic_wb_empty, ic_fast, iu_halt, iu_cwp, be_masked, xd_r.pte_c, xi_r.pte_c, xi_r.m, ifr.supv, dmr.va[7:0]};

  // the hang reporter's words: the IU's pipeline, the data request, the
  // fetch, the states of the data side, instruction side, arbiter, MMU
  // walker and both caches, and the memory port
  assign dbg_w_o[0] = {dbg_pipe, 5'd0, mem_req_o.write, mem_req_o.burst, mem_req_o.lock, mem_req_o.be};
  assign dbg_w_o[1] = dmr.va;
  assign dbg_w_o[2] = {4'd0, dmr.valid, dmr.write, dmr.atomic, dmr.size, 3'd0, dmr.asi,
                       ds, is, 1'b0, owner_q, locked_q, mem_req_o.valid};
  assign dbg_w_o[3] = ifr.va;
  assign dbg_w_o[4] = {dbg_ic, dbg_dc, dbg_mmu, ifr.valid, ifs.valid, dms.ack, mem_rsp_i.ack, wk_owner, mcntl[0], 1'b0};
  assign dbg_w_o[5] = {mem_req_o.pa[35:32], mem_req_o.pa[27:0]};

endmodule
