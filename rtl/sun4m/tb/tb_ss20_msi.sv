// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_ss20_msi: the MSI registers and the IOMMU's DVMA path against Sun-4M
// §5.1.2, §5.2, §5.4.3, §5.8, §5.9, §7.2, the OBP 2.25 POST's MSI/IOMMU
// tests (post-tests.md §8) and t_msi. A behavioural memory with a random
// ack latency holds the IOPTE table and the data; it logs every request so
// the bench can count table walks and see the order of the grants.

module tb_ss20_msi;
  import iobus_pkg::*;
  import mem_pkg::*;
  import sbus_pkg::*;
  import tb_pkg::*;

  logic clk, rst;
  initial begin clk = 0; rst = 1; end
  always #5 clk = ~clk;

  iob_req_t        req = IOB_REQ_IDLE;
  iob_rsp_t        rsp;
  logic [3:0]      bus_mid = 4'd8;
  dvma_req_t [2:0] dreq;                 // NDVMA = 3 (the default): ESP, LANCE, APC
  mem_rsp_t  [2:0] drsp;
  mem_req_t        mreq;
  mem_rsp_t        mrsp;
  logic            mts_err = 0, mts_to = 0, mts_s = 0;
  logic [35:0]     mts_pa = '0;
  logic [2:0]      mts_siz = '0;
  logic [3:0]      mts_mid = '0;
  logic            irq;
  logic [31:0]     arb;

  initial dreq = '0;

  ss20_msi dut (
    .clk, .rst, .bus_i(req), .bus_o(rsp), .bus_mid_i(bus_mid),
    .dvma_req_i(dreq), .dvma_rsp_o(drsp), .mem_req_o(mreq), .mem_rsp_i(mrsp),
    .mts_err_i(mts_err), .mts_err_to_i(mts_to), .mts_err_pa_i(mts_pa),
    .mts_err_siz_i(mts_siz), .mts_err_s_i(mts_s), .mts_err_mid_i(mts_mid),
    .irq_err_o(irq), .arb_en_o(arb));

  // ---- register offsets ------------------------------------------------
  localparam logic [27:0] CTRL = 28'h0, BASE = 28'h4, FLALL = 28'h14, FLPG = 28'h18,
                          TAG = 28'h100, DVA = 28'h140, CMP = 28'h150, TDATA = 28'h200,
                          AFSR = 28'h1000, AFAR = 28'h1004, AER = 28'h1008, SBCFG = 28'h1010,
                          MID = 28'h2000;

  // ---- behavioural memory ----------------------------------------------
  // Doublewords by PA[35:3], big-endian. PA[35:32] = 7 answers err.
  logic [63:0] mem [logic [32:0]];
  int  maxlat = 4;
  int  wcnt, mbeat;
  bit  fin;
  typedef struct { bit we; bit burst; logic [35:0] pa; } rec_t;
  rec_t mlog [$];
  bit  mem_watch_quiet = 0;   // checks that no request reaches memory
  bit  mem_saw;

  function automatic logic [63:0] mrd(input logic [32:0] a);
    return mem.exists(a) ? mem[a] : 64'h0;
  endfunction

  // (blocking updates of the model's own counters: a testbench process)
  /* verilator lint_off BLKSEQ */
  always @(posedge clk) begin
    mrsp <= '0;
    if (mreq.valid) mem_saw = 1;
    if (rst) begin
      wcnt = -1; mbeat = 0; fin = 0;
    end else if (fin) begin
      fin = 0;                              // the master drops the finished request
    end else if (mreq.valid) begin
      if (wcnt < 0) wcnt = $urandom_range(0, maxlat);
      if (wcnt == 0) begin
        logic [32:0] a;
        logic [63:0] d;
        bit e;
        a = mreq.pa[35:3] + (mreq.burst ? 33'(mbeat) : 33'd0);
        e = (mreq.pa[35:32] == 4'h7);
        if (mbeat == 0) mlog.push_back('{mreq.write, mreq.burst, mreq.pa});
        d = mrd(a);
        if (mreq.write && !e) begin
          for (int b = 0; b < 8; b++)
            if (mreq.be[b]) d[b*8 +: 8] = mreq.wdata[b*8 +: 8];
          mem[a] = d;
        end
        mrsp <= '{ack: 1'b1, err: e, rdata: (mreq.write || e) ? 64'h0 : d};
        if (e || !mreq.burst || mbeat == 3) begin mbeat = 0; fin = 1; end
        else mbeat++;
        wcnt = -1;
      end else wcnt--;
    end
  end
  /* verilator lint_on BLKSEQ */

  task automatic mem_wr32(input logic [35:0] pa, input logic [31:0] v);
    logic [63:0] d;
    d = mrd(pa[35:3]);
    if (pa[2]) d[31:0] = v; else d[63:32] = v;
    mem[pa[35:3]] = d;
  endtask

  // ---- bus functional models -------------------------------------------
  task automatic cycles(input int n);
    repeat (n) @(posedge clk);
    #1;
  endtask

  task automatic bus_write(input logic [27:0] a, input logic [31:0] d);
    req.req = 1; req.we = 1; req.addr = a; req.be = '1; req.wdata = d; req.pair = 0;
    do cycles(1); while (!rsp.ack);
    check(!rsp.err, "write: no error");
    req.req = 0; req.we = 0;
  endtask

  task automatic bus_read(input logic [27:0] a, output logic [31:0] d);
    req.req = 1; req.we = 0; req.addr = a; req.be = '1; req.pair = 0;
    do cycles(1); while (!rsp.ack);
    check(!rsp.err, "read: no error");
    d = rsp.rdata;
    req.req = 0;
  endtask

  task automatic expect_reg(input logic [27:0] a, input logic [31:0] e, input string what);
    logic [31:0] v;
    bus_read(a, v);
    check32(v, e, what);
  endtask

  // One DVMA request on port p: a single beat (wd[0]) or a 4-beat burst
  // (wd[k] presented after the k-th ack). Returns the read data and err.
  typedef logic [63:0] dw4_t [4];
  task automatic dvma(input int p, input bit we, input bit burst, input logic [31:0] va,
                      input logic [7:0] be, input dw4_t wd, output dw4_t rd, output bit err,
                      input int bound = 400);
    int n = 0, t = 0;
    err = 0;
    for (int k = 0; k < 4; k++) rd[k] = 'x;
    dreq[p] = '{valid: 1'b1, write: we, burst: burst, va: va, be: burst ? 8'hFF : be, wdata: wd[0]};
    forever begin
      cycles(1);
      t++;
      if (drsp[p].ack) begin
        rd[n] = drsp[p].rdata;
        n++;
        if (drsp[p].err) begin err = 1; break; end
        if (!burst || n == 4) break;
        dreq[p].wdata = wd[n];
      end
      if (t > bound) begin
        check(0, $sformatf("dvma port %0d va %08x: no answer", p, va));
        break;
      end
    end
    cycles(1);                               // the cycle after the last ack
    dreq[p] = DVMA_REQ_IDLE;
  endtask

  // Single-beat word helpers
  task automatic dvma_rd32(input int p, input logic [31:0] va, output logic [31:0] v, output bit err);
    dw4_t wd, rd;
    wd = '{default: 64'h0};
    dvma(p, 0, 0, va, va[2] ? 8'h0F : 8'hF0, wd, rd, err);
    v = va[2] ? rd[0][31:0] : rd[0][63:32];
  endtask
  task automatic dvma_wr32(input int p, input logic [31:0] va, input logic [31:0] v, output bit err);
    dw4_t wd, rd;
    wd = '{default: 64'h0};
    wd[0] = {v, v};
    dvma(p, 1, 0, va, va[2] ? 8'h0F : 8'hF0, wd, rd, err);
  endtask

  // Requests the memory saw (since the last call) at PAs in [lo, hi)
  function automatic int count_reqs(input logic [35:0] lo, input logic [35:0] hi);
    int c = 0;
    foreach (mlog[i]) if (mlog[i].pa >= lo && mlog[i].pa < hi) c++;
    return c;
  endfunction

  // ---- the IOPTE table ---------------------------------------------------
  localparam logic [35:0] TBL = 36'h0_0010_0000;   // 16 MB range: 16 KB table
  localparam logic [31:0] DV  = 32'hFF00_0000;     // DVMA base for RANGE 0
  function automatic logic [31:0] iopte(input logic [35:0] pa, input bit c, input bit w, input bit v);
    return {pa[35:12], c, 4'b0, w, v, 1'b0};
  endfunction
  function automatic logic [35:0] page_pa(input int n);   // page n's normal mapping
    return 36'h0_0400_0000 + 36'(n) * 36'h3000;
  endfunction

  logic [31:0] v, v2;
  bit e;
  dw4_t wd, rd;
  logic [63:0] dq;

  initial begin
    cycles(3);
    rst = 0;
    cycles(2);

    // ===== reset values ===================================================
    expect_reg(CTRL, 32'h1300_0000, "control after reset: IMPL/VER 0x13, ME/DE/RANGE 0");
    expect_reg(BASE, 32'h0, "base after reset");
    expect_reg(AFSR, 32'h0, "AFSR after reset");
    expect_reg(AFAR, 32'h0, "AFAR after reset");
    expect_reg(AER, 32'h0010_0003, "arbiter enable after reset: 8, 9, on-board");
    check32(arb, 32'h0010_0003, "arb_en_o after reset");
    for (int n = 0; n < 4; n++) expect_reg(SBCFG + 28'(4*n), 32'h0, "slot configuration after reset");
    expect_reg(MID, 32'h8, "MID register: the requester's MID 8");
    bus_mid = 4'd9;
    expect_reg(MID, 32'h9, "MID register: the requester's MID 9");
    bus_mid = 4'd8;
    expect_reg(TDATA, 32'h0, "TLB diagnostic reads 0 with DE = 0");
    expect_reg(TAG, 32'h0, "tag diagnostic reads 0 with DE = 0");
    check(!irq, "no error interrupt after reset");

    // ===== register read/write ============================================
    bus_write(CTRL, 32'hFFFF_FFFF);
    expect_reg(CTRL, 32'h1300_001F, "control: IMPL/VER read-only, RANGE/DE/ME RW");
    bus_write(CTRL, 32'h0);
    bus_write(BASE, 32'hFFFF_FFFF);
    expect_reg(BASE, 32'hFFFF_FC00, "base: IBA 31:10");
    bus_write(BASE, 32'h0);
    // t_msi
    bus_write(AER, 32'h801F_000E);
    expect_reg(AER, 32'h801F_000F, "arbiter enable: bit 0 reads 1 (t_msi 3)");
    bus_write(AER, 32'h0000_000F);
    expect_reg(AER, 32'h0000_000F, "arbiter enable 0xf (t_msi 4)");
    bus_write(AER, 32'hFFFF_FFFF);
    expect_reg(AER, 32'h801F_000F, "arbiter enable: reserved bits 0");
    bus_write(AER, 32'h0010_0003);
    // the POST's walk over the slot configuration registers (mask 0x3800f)
    begin
      logic [31:0] p;
      bit ok = 1;
      for (int s = 3; s >= 0; s--) begin
        int o;
        o = (s == 0) ? 2 : s - 1;
        p = 32'h5a5a_5a5a;
        while (p != 0) begin
          bus_write(SBCFG + 28'(4*s), p);  bus_write(SBCFG + 28'(4*o), ~p);
          bus_read(SBCFG + 28'(4*s), v);   ok &= (v == (p & 32'h0003_800F));
          bus_write(SBCFG + 28'(4*s), ~p); bus_write(SBCFG + 28'(4*o), p);
          bus_read(SBCFG + 28'(4*s), v);   ok &= (v == (~p & 32'h0003_800F));
          p = p << 1;
        end
      end
      check(ok, "slot configuration walk: RW bits 0x3800f, no aliasing (POST)");
    end
    // the POST's walks over base (mask 0xfffffc00) and control (0x1f)
    bus_write(BASE, 32'h5a5a_5a5a); bus_write(CTRL, 32'ha5a5_a5a5);
    expect_reg(BASE, 32'h5a5a_5800, "base walk value");
    expect_reg(CTRL, 32'h1300_0005, "control walk value");
    bus_write(CTRL, 32'h0); bus_write(BASE, 32'h0);
    expect_reg(28'h8, 32'h0, "reserved 0x8 reads 0");
    expect_reg(28'h100C, 32'h0, "reserved 0x100c reads 0");
    expect_reg(28'h2004, 32'h0, "reserved 0x2004 reads 0");
    expect_reg(28'h4000, 32'h0, "outside the window reads 0");

    // ===== diagnostic access (POST IOMMU tests) ===========================
    bus_write(CTRL, 32'h2);                         // DE
    begin
      bit ok = 1;
      for (int i = 0; i < 16; i++) begin
        bus_write(TAG + 28'(4*i), 32'hFFFF_FFFF);
        bus_write(TDATA + 28'(4*i), 32'hFFFF_FFFF);
      end
      for (int i = 0; i < 16; i++) begin
        bus_read(TAG + 28'(4*i), v);   ok &= ((v & 32'h7FFF_F000) == 32'h7FFF_F000) && v[31];
        bus_read(TDATA + 28'(4*i), v); ok &= (v == 32'hFFFF_FF86);
      end
      for (int i = 0; i < 16; i++) begin
        bus_write(TAG + 28'(4*i), 32'h5555_5555 ^ 32'(i << 12));
        bus_write(TDATA + 28'(4*i), 32'hAAAA_AAAA);
      end
      for (int i = 0; i < 16; i++) begin
        bus_read(TAG + 28'(4*i), v);   ok &= ((v & 32'h7FFF_F000) == ((32'h5555_5555 ^ 32'(i << 12)) & 32'h7FFF_F000));
        bus_read(TDATA + 28'(4*i), v); ok &= (v == (32'hAAAA_AAAA & 32'hFFFF_FF86));
      end
      check(ok, "CAM/TLB diagnostic patterns: tags 30:12, data PPN/C/W/V RW (POST NTA)");
    end
    // comparator (POST CAM TLB comparator test)
    begin
      bit ok = 1;
      for (int i = 0; i < 16; i++) bus_write(TAG + 28'(4*i), 32'h4000_0000 >> i);
      for (int k = 0; k < 16; k++) begin
        bus_write(DVA, 32'h8000 << k);
        bus_read(CMP, v);
        ok &= (v == (32'h8000 >> k));
      end
      check(ok, "diagnostic comparator: one bit per matching tag");
    end
    // TLB flush tests, as the POST runs them
    begin
      bit ok = 1;
      for (int k = 0; k < 16; k++) begin
        bus_write(TDATA + 28'(4*k), 32'((16 - k) << 12) | 32'h2);
        bus_write(TAG + 28'(4*k), 32'((16 - k) << 12) | 32'h2);
      end
      bus_write(CTRL, 32'h1);
      for (int k = 0; k < 16; k++) begin
        bus_write(FLPG, 32'h8000_0000 | 32'((16 - k) << 12));
        bus_write(CTRL, 32'h2);
        for (int i = 0; i < 16; i++) begin
          bus_read(TDATA + 28'(4*i), v);
          ok &= (v[1] == (i != k));
        end
        bus_write(CTRL, 32'h1);
        bus_write(CTRL, 32'h2);
        bus_read(TDATA + 28'(4*k), v);
        bus_write(TDATA + 28'(4*k), v | 32'h2);
        bus_write(CTRL, 32'h1);
      end
      check(ok, "address flush invalidates only the matching entry (POST)");
      bus_write(FLALL, 32'h0);
      for (int i = 0; i < 16; i++) begin
        bus_read(TDATA + 28'(4*i), v);
        ok &= (v == 0);
      end
      check(ok, "flush all: every V 0, diagnostic reads 0 with DE = 0 (POST)");
      bus_write(CTRL, 32'h2);
      ok = 1;
      for (int i = 0; i < 16; i++) begin
        bus_read(TDATA + 28'(4*i), v);
        ok &= !v[1];
      end
      check(ok, "flush all: V 0 in every entry");
      bus_read(TAG, v);
      check32(v & 32'hF, 32'h0, "LRUQ of tag 0 is the next victim (0 after reset)");
      bus_read(TAG + 28'h4, v);
      check32(v & 32'hF, 32'h1, "LRUQ of tag 1");
      bus_write(CTRL, 32'h0);
    end

    // ===== translation ====================================================
    // table at 1 MB, RANGE 0 (16 MB, 0xff00_0000 up); pages 0-63 mapped to
    // page_pa(n); page 40 read-only; page 41 invalid; page 42 at PA 7_xxxx
    // (the memory answers err); page 43 at a high PA (1_2345_6000).
    for (int n = 0; n < 64; n++)
      mem_wr32(TBL + 36'(4*n), iopte(page_pa(n), 1, 1, 1));
    mem_wr32(TBL + 36'(4*40), iopte(page_pa(40), 0, 0, 1));
    mem_wr32(TBL + 36'(4*41), iopte(page_pa(41), 0, 1, 0));
    mem_wr32(TBL + 36'(4*42), iopte(36'h7_0000_0000, 0, 1, 1));
    mem_wr32(TBL + 36'(4*43), iopte(36'h1_2345_6000, 0, 1, 1));
    for (int n = 0; n < 64; n++)
      for (int w = 0; w < 4; w++)
        mem_wr32(page_pa(n) + 36'(w*4), 32'hD000_0000 | 32'(n << 8) | 32'(w));
    mem_wr32(36'h1_2345_6010, 32'hCAFE_F00D);

    bus_write(BASE, 32'(TBL >> 4));
    bus_write(CTRL, 32'h1);                         // ME, RANGE 0
    bus_write(FLALL, 32'h0);

    mlog.delete();
    dvma_rd32(0, DV + 32'h0000_0004, v, e);
    check(!e, "port 0 read page 0: no error");
    check32(v, 32'hD000_0001, "port 0 read page 0 word 1: translated");
    check(count_reqs(TBL, TBL + 36'h4000) == 1, "first access walks once");
    check(mlog.size() == 2 && mlog[0].pa == TBL && mlog[1].pa == page_pa(0) + 36'h4,
          "walk read at the IOPTE, then the data at the translated PA");
    mlog.delete();
    dvma_rd32(1, DV + 32'h0000_0008, v, e);
    check32(v, 32'hD000_0002, "port 1 read page 0 word 2");
    check(count_reqs(TBL, TBL + 36'h4000) == 0, "second access to the page: TLB hit, no walk");

    // pages 1..3: a walk each, then hits
    mlog.delete();
    for (int n = 1; n < 4; n++) begin
      dvma_rd32(n & 1, DV + 32'(n << 12), v, e);
      check32(v, 32'hD000_0000 | 32'(n << 8), "read pages 1-3");
    end
    for (int n = 0; n < 4; n++) dvma_rd32(n & 1, DV + 32'(n << 12) + 32'hC, v, e);
    check(count_reqs(TBL, TBL + 36'h4000) == 3, "pages 1-3 walk once each, then hit");

    // a high PA
    dvma_rd32(0, DV + 32'(43 << 12) + 32'h10, v, e);
    check(!e, "page 43: no error");
    check32(v, 32'hCAFE_F00D, "page 43: PA[35:32] from the IOPTE");

    // writes: single word with partial enables, burst write, burst read
    dvma_wr32(1, DV + 32'(5 << 12) + 32'h4, 32'h1234_5678, e);
    check(!e, "port 1 word write: no error");
    dq = mrd(33'(page_pa(5) >> 3));
    check32(dq[31:0], 32'h1234_5678, "word write landed (low word)");
    check32(dq[63:32], 32'hD000_0500, "the other word untouched");
    for (int k = 0; k < 4; k++) wd[k] = {32'hB0B0_0000 | 32'(k), 32'hC0C0_0000 | 32'(k)};
    dvma(0, 1, 1, DV + 32'(6 << 12) + 32'h20, 8'hFF, wd, rd, e);
    check(!e, "port 0 burst write: no error");
    begin
      bit ok = 1;
      for (int k = 0; k < 4; k++) ok &= (mrd(33'((page_pa(6) + 36'h20) >> 3) + 33'(k)) == wd[k]);
      check(ok, "burst write: four doublewords in order at the translated line");
    end
    mlog.delete();
    dvma(1, 0, 1, DV + 32'(6 << 12) + 32'h20, 8'hFF, wd, rd, e);
    check(!e, "port 1 burst read: no error");
    check(rd[0] == wd[0] && rd[1] == wd[1] && rd[2] == wd[2] && rd[3] == wd[3],
          "burst read: four doublewords back");
    check(mlog.size() == 1 && mlog[0].burst && !mlog[0].we && mlog[0].pa == page_pa(6) + 36'h20,
          "burst passed to memory as one burst (TLB hit)");

    // faults: read-only page written, invalid page, out of range, memory err
    mlog.delete();
    dvma_rd32(0, DV + 32'(40 << 12), v, e);
    check(!e, "read-only page: a read is fine");
    dvma_wr32(0, DV + 32'(40 << 12), 32'hDEAD_BEEF, e);
    check(e, "read-only page: a write gets err");
    dq = mrd(33'(page_pa(40) >> 3));
    check32(dq[63:32], 32'hD000_2800, "read-only page: memory not written");
    check(count_reqs(page_pa(40), page_pa(40) + 36'h1000) == 1, "read-only write never reaches memory");
    dvma_wr32(1, DV + 32'(40 << 12) + 32'h8, 32'hDEAD_BEEF, e);
    check(e, "read-only page (TLB hit): a write gets err");
    mlog.delete();
    for (int k = 0; k < 4; k++) wd[k] = 64'h0;
    dvma(1, 0, 1, DV + 32'(41 << 12), 8'hFF, wd, rd, e);
    check(e, "invalid IOPTE: burst read gets err");
    dvma_rd32(0, DV + 32'(41 << 12), v, e);
    check(e, "invalid IOPTE: read gets err");
    check(count_reqs(TBL, TBL + 36'h4000) == 2, "an invalid IOPTE is not cached: walked each time");
    check(count_reqs(page_pa(41), page_pa(41) + 36'h1000) == 0, "invalid page: no data access");
    mlog.delete();
    dvma_rd32(1, 32'h1000_0000, v, e);
    check(e, "VA outside the 16 MB range: err");
    check(mlog.size() == 0, "out of range: no memory access at all");
    dvma_rd32(0, DV + 32'(42 << 12), v, e);
    check(e, "memory err on the data access reaches the master");
    for (int k = 0; k < 4; k++) wd[k] = 64'h0;
    dvma(0, 0, 1, DV + 32'(42 << 12), 8'hFF, wd, rd, e);
    check(e, "memory err ends a burst");
    expect_reg(AFSR, 32'h0, "DVMA faults leave the M-to-S AFSR alone (§7.2.1)");
    check(!irq, "DVMA faults raise no level-15");

    // a PTE change: the TLB keeps the old one until flushed
    mem_wr32(TBL + 36'(4*2), iopte(page_pa(50), 1, 1, 1));
    dvma_rd32(0, DV + 32'(2 << 12), v, e);
    check32(v, 32'hD000_0200, "PTE changed in memory: TLB still maps the old page");
    bus_write(FLPG, DV + 32'(3 << 12));             // another page: no effect on page 2
    dvma_rd32(0, DV + 32'(2 << 12), v, e);
    check32(v, 32'hD000_0200, "flush of another page: still the old mapping");
    mlog.delete();
    bus_write(FLPG, DV + 32'(2 << 12) + 32'h123);
    dvma_rd32(1, DV + 32'(2 << 12), v, e);
    check32(v, 32'hD000_3200, "address flush: re-walked, the new mapping");
    check(count_reqs(TBL, TBL + 36'h4000) == 1, "address flush: one walk");
    mem_wr32(TBL + 36'(4*2), iopte(page_pa(2), 1, 1, 1));
    mlog.delete();
    dvma_rd32(1, DV + 32'(1 << 12), v, e);
    check(count_reqs(TBL, TBL + 36'h4000) == 0, "page 1 still cached");
    bus_write(FLALL, 32'h0);
    dvma_rd32(1, DV + 32'(1 << 12), v, e);
    dvma_rd32(0, DV + 32'(2 << 12), v, e);
    check32(v, 32'hD000_0200, "flush all: page 2 back to its restored mapping");
    check(count_reqs(TBL, TBL + 36'h4000) == 2, "flush all: every page walks again");

    // capacity: 16 entries round robin; 17 pages evict the first
    bus_write(FLALL, 32'h0);
    for (int n = 0; n < 16; n++) dvma_rd32(0, DV + 32'((n + 10) << 12), v, e);
    mlog.delete();
    for (int n = 0; n < 16; n++) dvma_rd32(1, DV + 32'((n + 10) << 12), v, e);
    check(count_reqs(TBL, TBL + 36'h4000) == 0, "16 pages fit the TLB");
    dvma_rd32(0, DV + 32'(26 << 12), v, e);         // the 17th replaces the oldest (page 10)
    mlog.delete();
    dvma_rd32(0, DV + 32'(11 << 12), v, e);
    check(count_reqs(TBL, TBL + 36'h4000) == 0, "page 11 still cached");
    dvma_rd32(0, DV + 32'(10 << 12), v, e);
    check(count_reqs(TBL, TBL + 36'h4000) == 1, "page 10 evicted by the 17th page");
    check32(v, 32'hD000_0A00, "page 10 re-walked");
    // the TLB as the diagnostic window shows it
    // (page 10's walk evicted page 11, the next oldest; the comparator finds
    // page 12's entry)
    bus_write(CTRL, 32'h3);
    bus_write(DVA, DV + 32'(12 << 12));
    bus_read(CMP, v2);
    // (the comparator ignores V: stale tags of flushed entries match too)
    begin
      int i = -1, nv = 0;
      for (int j = 0; j < 16; j++)
        if (v2[j]) begin
          bus_read(TDATA + 28'(4*j), v);
          if (v[1]) begin i = j; nv++; end
        end
      check(nv == 1, "comparator: exactly one valid entry holds page 12");
      if (i < 0) i = 0;
      bus_read(TDATA + 28'(4*i), v);
      check32(v, iopte(page_pa(12), 1, 1, 1), "TLB diagnostic read of a walked entry");
      bus_read(TAG + 28'(4*i), v);
      check32(v & 32'hFFFF_F000, 32'h8000_0000 | ((DV + 32'(12 << 12)) & 32'h7FFF_F000), "its tag");
    end
    bus_write(CTRL, 32'h1);

    // a flush-all while a walk is in flight: the walk's IOPTE is used for
    // its own access but not cached
    maxlat = 0;
    bus_write(FLALL, 32'h0);
    maxlat = 30;
    fork
      dvma_rd32(0, DV + 32'(30 << 12), v, e);
      begin
        while (!(mreq.valid && mreq.pa == TBL + 36'(4*30))) cycles(1);
        bus_write(FLALL, 32'h0);
      end
    join
    check(!e && v == 32'hD000_1E00, "flush during a walk: the access completes");
    maxlat = 4;
    mlog.delete();
    dvma_rd32(1, DV + 32'(30 << 12), v, e);
    check(count_reqs(TBL, TBL + 36'h4000) == 1, "flush during a walk: the IOPTE was not cached");

    // RANGE 2 (64 MB, 0xfc00_0000 up), table 64 KB aligned at 0x20_0000
    begin
      logic [35:0] t2;
      t2 = 36'h0_0020_0000;
      mem_wr32(t2 + 36'(4 * 32'h2ABC), iopte(36'h0_0567_8000, 0, 1, 1));
      mem_wr32(36'h0_0567_8ABC, 32'h5EED_1234);
      bus_write(BASE, 32'(t2 >> 4));
      bus_write(CTRL, 32'h9);                       // RANGE 2, ME
      bus_write(FLALL, 32'h0);
      mlog.delete();
      dvma_rd32(1, 32'hFEAB_CABC, v, e);
      check(!e, "RANGE 2: no error");
      check32(v, 32'h5EED_1234, "RANGE 2: translated through IOPTE 0x2abcd");
      check(mlog.size() == 2 && mlog[0].pa == t2 + 36'(4 * 32'h2ABC), "RANGE 2: IOPTE address");
      dvma_rd32(1, 32'hFBFF_F000, v, e);
      check(e, "RANGE 2: 0xfbff_f000 is out of range");
    end

    // a walk the memory refuses
    bus_write(BASE, 32'(36'h7_0000_0000 >> 4));
    bus_write(CTRL, 32'h1);
    bus_write(FLALL, 32'h0);
    dvma_rd32(0, DV, v, e);
    check(e, "IOPTE read answered err: err to the master");
    bus_write(BASE, 32'(TBL >> 4));
    bus_write(FLALL, 32'h0);

    // ===== IOMMU disabled: pass-through ===================================
    bus_write(CTRL, 32'h0);
    mem_wr32(36'h0_0012_3458, 32'h0BAD_CAFE);
    mlog.delete();
    dvma_rd32(0, 32'h0012_3458, v, e);
    check(!e, "ME = 0: no error");
    check32(v, 32'h0BAD_CAFE, "ME = 0: PA = VA");
    check(mlog.size() == 1 && mlog[0].pa == 36'h0_0012_3458, "ME = 0: no walk, PA[35:32] = 0");
    dvma_wr32(1, DV + 32'h10, 32'h7777_8888, e);
    dq = mrd(33'(36'h0_FF00_0010 >> 3));
    check(!e && dq[63:32] == 32'h7777_8888, "ME = 0: a DVMA-range VA is a PA too");
    bus_write(CTRL, 32'h1);

    // ===== arbitration =====================================================
    // warm the TLB with pages 20 (port 0) and 21 (port 1)
    dvma_rd32(0, DV + 32'(20 << 12), v, e);
    dvma_rd32(1, DV + 32'(21 << 12), v, e);
    mlog.delete();
    maxlat = 2;
    fork
      for (int i = 0; i < 8; i++) begin logic [31:0] x; bit ee; dvma_rd32(0, DV + 32'(20 << 12) + 32'(8*i), x, ee); end
      for (int i = 0; i < 8; i++) begin logic [31:0] x; bit ee; dvma_rd32(1, DV + 32'(21 << 12) + 32'(8*i), x, ee); end
    join
    begin
      int n0 = 0, n1 = 0, same = 0;
      foreach (mlog[i]) begin
        if (mlog[i].pa[35:12] == 24'(page_pa(20) >> 12)) n0++;
        if (mlog[i].pa[35:12] == 24'(page_pa(21) >> 12)) n1++;
        if (i > 0 && i < 15 && mlog[i].pa[35:12] == mlog[i-1].pa[35:12]) same++;
      end
      check(n0 == 8 && n1 == 8, "both ports served 8 times");
      check(same == 0, "round robin: the grants alternate while both ask");
    end
    // three ports asking: each grant goes to the next port in turn
    dvma_rd32(2, DV + 32'(22 << 12), v, e);
    mlog.delete();
    fork
      for (int i = 0; i < 6; i++) begin logic [31:0] x; bit ee; dvma_rd32(0, DV + 32'(20 << 12) + 32'(8*i), x, ee); end
      for (int i = 0; i < 6; i++) begin logic [31:0] x; bit ee; dvma_rd32(1, DV + 32'(21 << 12) + 32'(8*i), x, ee); end
      for (int i = 0; i < 6; i++) begin logic [31:0] x; bit ee; dvma_rd32(2, DV + 32'(22 << 12) + 32'(8*i), x, ee); end
    join
    begin
      int n2 = 0, bad = 0;
      foreach (mlog[i]) begin
        if (mlog[i].pa[35:12] == 24'(page_pa(22) >> 12)) n2++;
        // while all three ask, no port is served twice within three grants
        if (i >= 2 && i < 16 && (mlog[i].pa[35:12] == mlog[i-1].pa[35:12] ||
                                 mlog[i].pa[35:12] == mlog[i-2].pa[35:12])) bad++;
      end
      check(mlog.size() == 18 && n2 == 6, "three ports: all 18 requests served, 6 for port 2");
      check(bad == 0, "round robin over three ports: 0, 1, 2 in turn");
    end
    check(!e && v == 32'hD000_1600, "port 2 reads through the IOMMU");
    maxlat = 4;

    // parking: EN<F> = 0 holds both ports un-granted; a granted burst completes
    bus_write(AER, 32'h0000_000F);
    check32(arb, 32'h0000_000F, "arb_en_o follows the register");
    mem_saw = 0;
    fork
      begin dvma_rd32(0, DV + 32'(20 << 12), v, e); end
      begin
        cycles(60);
        check(!mem_saw, "parked: no request reaches memory");
        check(!drsp[0].ack, "parked: no answer");
        bus_write(AER, 32'h0010_000F);
      end
    join
    check(!e && v == 32'hD000_1400, "released: the parked request completes");
    maxlat = 12;
    for (int k = 0; k < 4; k++) wd[k] = 64'h0;
    fork
      dvma(1, 0, 1, DV + 32'(21 << 12), 8'hFF, wd, rd, e);
      begin cycles(4); bus_write(AER, 32'h0000_000F); end
    join
    check(!e, "a granted burst completes after parking");
    check(rd[0] == {32'hD000_1500, 32'hD000_1501} && rd[1] == {32'hD000_1502, 32'hD000_1503},
          "the granted burst's data");
    mem_saw = 0;
    fork
      begin dvma_rd32(1, DV + 32'(21 << 12), v, e); end
      begin cycles(80); check(!mem_saw, "the next request parks"); bus_write(AER, 32'h0010_0003); end
    join
    check(!e, "released again");
    maxlat = 4;

    // ===== M-to-S AFSR/AFAR =================================================
    // the POST's SBus case: a byte write to an empty slot times out
    @(posedge clk); #1;
    mts_err = 1; mts_to = 1; mts_pa = 36'hE_0000_0E00; mts_siz = 3'd0; mts_s = 1; mts_mid = 4'd8;
    cycles(1);
    mts_err = 0;
    cycles(1);
    check(irq, "M-to-S error: level-15 source raised");
    expect_reg(AFSR, 32'hA100_020E | (32'd8 << 20), "AFSR: ERR TO SIZ=byte S MID SSIZ=byte PA=e (POST)");
    expect_reg(AFAR, 32'h0000_0E00, "AFAR: PA[31:0]");
    // a second error: ME, the first one kept
    mts_err = 1; mts_to = 0; mts_pa = 36'hF_F110_0060; mts_siz = 3'd2; mts_mid = 4'd9;
    cycles(1);
    mts_err = 0;
    expect_reg(AFSR, 32'hA108_020E | (32'd8 << 20), "a second error sets ME only");
    expect_reg(AFAR, 32'h0000_0E00, "AFAR keeps the first error");
    bus_write(AFSR, 32'h0);
    check(!irq, "an AFSR write clears the interrupt");
    bus_read(AFSR, v);
    check(!v[31] && !v[19], "an AFSR write clears ERR and ME");
    // the POST's EBus case: a word write answered with an error ack
    mts_err = 1; mts_to = 0; mts_pa = 36'hF_F110_0060; mts_siz = 3'd2; mts_s = 1; mts_mid = 4'd8;
    cycles(1);
    mts_err = 0;
    expect_reg(AFSR, 32'h9500_000F | (32'd8 << 20), "AFSR: ERR BERR SIZ=word S MID PA=f (POST)");
    expect_reg(AFAR, 32'hF110_0060, "AFAR 0xf1100060 (POST)");
    bus_write(AFSR, 32'h0);
    check(!irq, "cleared");

    tb_done("tb_ss20_msi");
  end

  initial begin
    #5ms;
    $display("FAIL: timeout");
    $fatal(1, "timeout");
  end

endmodule
