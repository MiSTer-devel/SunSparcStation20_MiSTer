// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_lance: the on-board Ethernet (rtl/sun4m/lance.sv: Wish7990's LANCE
// with eth_hps behind it) against
//  - a CPU on the iobus (RDP at +0, RAP at +2, halfword accesses as
//    tests/cpu/src/ethtest.S makes them);
//  - a behavioural DVMA memory (64 KB of the LANCE's 24-bit space, big-
//    endian, random latency, an error window) holding the init block, the
//    rings and the buffers, written and read the way a sun4m driver does
//    (sth/ldub: descriptors are big-endian halfwords);
//  - a behavioural DDR holding the SSETH002 mailbox (random waitrequest and
//    read latency) and Main's side of it (take TX frames, post RX frames
//    with the FCS and the LADRF hash), as rtl/mister/tb/tb_eth_hps.sv.
// Covers ethtest's nine cases and the plan's phase 8 list:
//  - init: IDON, INTR/INEA and irq_o, CSR1-3 only while stopped, RXON/TXON
//    after STRT, a 32-bit read of {RDP, RAP}, STOP, the RESET pin;
//  - transmit: single frames at odd buffer addresses, chains of 2 and 3
//    descriptors with odd lengths and addresses handed over later-first, a
//    1-byte fragment, a 1514-byte frame, DTCR (driver's FCS not sent),
//    several frames queued at once, OWN cleared and TINT;
//  - receive: frames in order with MCNT = length + FCS and the FCS bytes,
//    STP/ENP, a frame chained over small buffers, the ring wrapping, MISS
//    with no buffer and recovery, BUFF when a chain runs out;
//  - filtering: another station dropped, broadcast in, multicast by the
//    LADRF hash (set and clear), promiscuous;
//  - oversize: a 1600-byte received frame dropped (no RINT, no MISS) and
//    the next one in;
//  - loopback: MODE LOOP|INTL (70 bytes, the FCS computed, nothing on the
//    wire) and MODE LOOP (through eth_hps, nothing in the mailbox);
//  - CSR3.BSWP = 0: frame bytes swapped within each halfword, both ways;
//  - BABL over 1518 bytes; a DVMA error: MERR, the engine stops;
//  - 32-bit accesses to RDP/RAP; the RESET pin.

/* verilator lint_off PROCASSINIT */
/* verilator lint_off BLKSEQ */
module tb_lance;
  import tb_pkg::*;
  import iobus_pkg::*;

  localparam int CLK_HZ = 55_000_000;
  localparam logic [28:0] BASE = 29'h03FE_0000;
  localparam int MB_WORDS = 'h10000 / 8;
  localparam int W_TXW = 2, W_TXR = 3, W_RXW = 4, W_RXR = 5;
  localparam int W_TX = 'h1000 / 8, W_RX = 'h5000 / 8;

  // LANCE memory layout (offsets in its 24-bit space)
  localparam int IB = 'h100, RDR = 'h200, TDR = 'h300;
  localparam int TXBUF = 'h1000, RXBUF = 'h4000;

  // CSR0 bits
  localparam logic [15:0] C0_INIT = 16'h0001, C0_STRT = 16'h0002, C0_STOP = 16'h0004,
                          C0_TDMD = 16'h0008, C0_TXON = 16'h0010, C0_RXON = 16'h0020,
                          C0_INEA = 16'h0040, C0_INTR = 16'h0080, C0_IDON = 16'h0100,
                          C0_TINT = 16'h0200, C0_RINT = 16'h0400, C0_MERR = 16'h0800,
                          C0_MISS = 16'h1000, C0_BABL = 16'h4000, C0_ERR  = 16'h8000;
  localparam logic [15:0] D_OWN = 16'h8000, D_ERR = 16'h4000, D_STP = 16'h0200,
                          D_ENP = 16'h0100, R_BUFF = 16'h0400;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  // ------------------------------------------------------------------ DUT --
  logic                rst = 1'b1, le_reset = 1'b0, ena = 1'b1;
  iob_req_t            bus_i = IOB_REQ_IDLE;
  iob_rsp_t            bus_o;
  logic                irq;
  sbus_pkg::dvma_req_t mem_o;
  mem_pkg::mem_rsp_t   mem_i = '0;
  logic        avl_waitrequest = 1'b0;
  logic [28:0] avl_address;
  logic        avl_read, avl_write;
  logic [63:0] avl_writedata, avl_readdata = '0;
  logic [7:0]  avl_byteenable, avl_burstcount;
  logic        avl_readdatavalid = 1'b0;

  lance #(.CLK_HZ(CLK_HZ), .SIMU(1'b1), .POLL_TICKS(3000)) dut (
    .clk, .rst, .bus_i, .bus_o, .le_reset, .irq_o(irq), .mem_o, .mem_i, .ena,
    .avl_waitrequest, .avl_address, .avl_read, .avl_write, .avl_writedata,
    .avl_byteenable, .avl_burstcount, .avl_readdata, .avl_readdatavalid);

  int unsigned lfsr = 32'h2468_ace1;
  function automatic int unsigned rnd();
    lfsr = lfsr * 32'd1664525 + 32'd1013904223;
    return lfsr >> 8;
  endfunction

  // --------------------------------------------------------- DVMA memory --
  logic [7:0]  m [65536];
  int          err_lo = -1, err_hi = -1;   // a beat in [lo, hi] answers err
  bit          serving = 1'b0;
  int          lat = 0;
  sbus_pkg::dvma_req_t held;
  int unsigned n_dvma_bad = 0, n_dvma = 0;

  always @(posedge clk) begin
    int a;
    mem_i.ack <= 1'b0;
    mem_i.err <= 1'b0;
    if (serving) begin
      if (mem_o != held) begin
        n_dvma_bad++;
        $display("tb_lance: DVMA request changed before its ack");
      end
      lat = lat - 1;
      if (lat == 0) begin
        a = int'(held.va[15:3]) * 8;
        if (err_lo >= 0 && int'(held.va) >= err_lo && int'(held.va) <= err_hi) begin
          mem_i.err <= 1'b1;
        end else if (held.write) begin
          for (int j = 0; j < 8; j++)
            if (held.be[7 - j]) m[a + j] = held.wdata[63 - 8 * j -: 8];
        end else begin
          for (int j = 0; j < 8; j++) mem_i.rdata[63 - 8 * j -: 8] <= m[a + j];
        end
        mem_i.ack <= 1'b1;
        serving = 1'b0;
      end
    end else if (mem_o.valid && !mem_i.ack) begin
      n_dvma++;
      if (mem_o.va[31:16] != 16'h0 || mem_o.burst || mem_o.be == 8'h0) begin
        n_dvma_bad++;
        $display("tb_lance: bad DVMA request va %08x be %02x burst %0d", mem_o.va, mem_o.be, mem_o.burst);
      end
      held    = mem_o;
      serving = 1'b1;
      lat     = 1 + int'(rnd() % 6);
    end
  end

  // The host's view: big-endian halfwords and bytes
  task automatic mh(input int a, input logic [15:0] v);
    m[a] = v[15:8]; m[a + 1] = v[7:0];
  endtask
  function automatic logic [15:0] mrh(input int a);
    return {m[a], m[a + 1]};
  endfunction
  function automatic logic mbit(input int a, input int b);
    logic [15:0] w = {m[a], m[a + 1]};
    return w[b];
  endfunction
  function automatic logic [31:0] mcnt(input int a);
    logic [15:0] w = {m[a], m[a + 1]};
    return {20'h0, w[11:0]};
  endfunction

  // -------------------------------------------------- DDR and the mailbox --
  logic [63:0] mb [MB_WORDS];
  int unsigned n_avl_bad = 0;
  bit          rd_pend = 1'b0;
  int          rd_cnt = 0, rd_idx = 0;

  always @(posedge clk) begin
    int idx;
    avl_readdatavalid <= 1'b0;
    if (rd_pend) rd_cnt = rd_cnt - 1;
    if (rd_pend && rd_cnt == 0) begin
      avl_readdatavalid <= 1'b1;
      avl_readdata      <= mb[rd_idx];
      rd_pend = 1'b0;
    end
    if ((avl_read || avl_write) && !avl_waitrequest) begin
      idx = int'(avl_address) - int'(BASE);
      if (idx < 0 || idx >= 'hD000 / 8 || avl_byteenable != 8'hFF || avl_burstcount != 8'd1) begin
        n_avl_bad++;
      end else if (avl_write) begin
        mb[idx] = avl_writedata;
      end else begin
        rd_pend = 1'b1;
        rd_idx  = idx;
        rd_cnt  = 1 + int'(rnd() % 7);
      end
    end
    avl_waitrequest <= (rnd() % 4 == 0);
  end

  logic [31:0] main_txr = '0;

  task automatic main_take(output bit got, output logic [7:0] f [$]);
    logic [63:0] h;
    int s, len;
    got = 1'b0;
    f = {};
    if (mb[W_TXW][31:0] == main_txr) return;
    s = W_TX + 256 * int'(main_txr % 8);
    h = mb[s];
    len = int'(h[10:0]);
    for (int i = 0; i < len; i++) f.push_back(mb[s + 1 + i / 8][8 * (i % 8) +: 8]);
    main_txr = main_txr + 1;
    mb[W_TXR] = {32'd0, main_txr};
    got = 1'b1;
  endtask

  // Wait for Main to see a frame; got = 0 after `limit` cycles
  task automatic main_wait(output bit got, output logic [7:0] f [$], input int limit);
    for (int n = 0; n < limit; n += 16) begin
      main_take(got, f);
      if (got) return;
      repeat (16) @(posedge clk);
    end
    got = 1'b0;
  endtask

  // ------------------------------------------------------------- frames --
  logic [7:0] mac [6] = '{8'h08, 8'h00, 8'h20, 8'h12, 8'h34, 8'h56};

  function automatic logic [31:0] crc32(input logic [7:0] f [$], input int n);
    logic [31:0] c = 32'hFFFF_FFFF;
    for (int i = 0; i < n; i++) begin
      c = c ^ {24'h0, f[i]};
      for (int b = 0; b < 8; b++) c = c[0] ? ((c >> 1) ^ 32'hEDB8_8320) : (c >> 1);
    end
    return c;                                     // the residue; the FCS is ~c
  endfunction

  // A frame of len bytes to dst, from us, type 0x88b5, payload 7k + seed
  function automatic void mkframe(output logic [7:0] f [$], input logic [7:0] dst [6],
                                  input int len, input int seed);
    f = {};
    for (int i = 0; i < 6; i++) f.push_back(dst[i]);
    for (int i = 0; i < 6; i++) f.push_back(mac[i]);
    f.push_back(8'h88); f.push_back(8'hb5);
    for (int i = 14; i < len; i++) f.push_back(8'(7 * (i - 14) + seed));
  endfunction

  // Main posts a received frame: its bytes, the FCS appended, the hash
  task automatic main_post(input logic [7:0] f [$]);
    logic [7:0] g [$];
    logic [31:0] w, fcs;
    logic [5:0] hash;
    int s, len;
    g = f;
    fcs = ~crc32(f, f.size());
    for (int i = 0; i < 4; i++) g.push_back(fcs[8 * i +: 8]);
    hash = 6'(crc32(f, 6) >> 26);
    len = g.size();
    w = mb[W_RXW][31:0];
    s = W_RX + 256 * int'(w % 16);
    mb[s] = {42'd0, hash, 5'd0, 11'(len)};
    for (int i = 0; i < (len + 7) / 8; i++) mb[s + 1 + i] = '0;
    for (int i = 0; i < len; i++) mb[s + 1 + i / 8][8 * (i % 8) +: 8] = g[i];
    mb[W_RXW] = {32'd0, w + 32'd1};
  endtask

  // ------------------------------------------------------------- iobus --
  task automatic iob(input bit we, input logic [27:0] addr, input logic [3:0] be,
                     input logic [31:0] wd, output logic [31:0] rd);
    @(posedge clk); #1;
    bus_i = '{req: 1'b1, we: we, addr: addr, be: be, wdata: wd, pair: 1'b0};
    do @(posedge clk); while (!bus_o.ack);
    rd = bus_o.rdata;
    #1 bus_i = IOB_REQ_IDLE;
  endtask

  task automatic le_w(input int csr, input logic [15:0] v);
    logic [31:0] d;
    iob(1'b1, 28'h2, 4'b0011, {16'h0, 16'(csr)}, d);
    iob(1'b1, 28'h0, 4'b1100, {v, 16'h0}, d);
  endtask

  task automatic le_r(input int csr, output logic [15:0] v);
    logic [31:0] d;
    iob(1'b1, 28'h2, 4'b0011, {16'h0, 16'(csr)}, d);
    iob(1'b0, 28'h0, 4'b1100, 32'h0, d);
    v = d[31:16];
  endtask

  // Poll CSR0 until (csr0 & mask) != 0; v = the last CSR0
  task automatic wait_csr0(input logic [15:0] mask, input int limit, output logic [15:0] v);
    for (int n = 0; n < limit; n++) begin
      le_r(0, v);
      if ((v & mask) != 16'h0) return;
      repeat (20) @(posedge clk);
    end
  endtask

  task automatic wait_own(input int d, input int limit, output bit cleared);
    cleared = 1'b0;
    for (int n = 0; n < limit; n++) begin
      if (!mbit(d + 2, 15)) begin cleared = 1'b1; return; end
      @(posedge clk);
    end
  endtask

  // ------------------------------------------------------------ set-up --
  int rx_n = 8;                 // RX ring: rlen_f descriptors
  int rx_bcnt = 1600;
  int rx_i, tx_i;               // the next descriptor the LANCE uses

  task automatic give_rx(input int i);
    mh(RDR + 8 * i, 16'(RXBUF + 'h800 * i));
    mh(RDR + 8 * i + 4, 16'(-rx_bcnt));
    mh(RDR + 8 * i + 6, 16'h0);
    mh(RDR + 8 * i + 2, D_OWN);
  endtask

  // STOP, CSR3, the init block (rings: rlog2 RX, 4 TX), INIT, IDON, STRT
  task automatic setup(input logic [15:0] mode, input logic [15:0] csr3,
                       input int rlog2, input int bcnt, input logic [63:0] ladrf,
                       output logic [15:0] c0);
    logic [15:0] v;
    rx_n = 1 << rlog2;
    rx_bcnt = bcnt;
    le_w(0, C0_STOP);
    le_w(3, csr3);
    mh(IB, mode);
    for (int k = 0; k < 3; k++) mh(IB + 2 + 2 * k, {mac[2 * k + 1], mac[2 * k]});
    for (int k = 0; k < 4; k++) mh(IB + 8 + 2 * k, ladrf[16 * k +: 16]);
    mh(IB + 16, 16'(RDR));
    mh(IB + 18, 16'(rlog2 << 13));
    mh(IB + 20, 16'(TDR));
    mh(IB + 22, 16'(2 << 13));
    for (int i = 0; i < rx_n; i++) give_rx(i);
    for (int i = 0; i < 4; i++) mh(TDR + 8 * i + 2, 16'h0);
    le_w(1, 16'(IB));
    le_w(2, 16'h0);
    le_w(0, C0_INIT);
    wait_csr0(C0_IDON, 2000, v);
    le_w(0, C0_IDON | C0_STRT | C0_INEA);
    le_r(0, c0);
    rx_i = 0;
    tx_i = 0;
  endtask

  // Transmit f over fragments of the given sizes, the k-th at TXBUF +
  // 0x800 k + odd[k]; descriptors handed over last first, then TDMD.
  task automatic tx_send(input logic [7:0] f [$], input int sizes [$], input int odd [$],
                         input logic [15:0] extra1, output int last);
    int pos, d, a, n;
    n = sizes.size();
    pos = 0;
    for (int k = 0; k < n; k++) begin
      a = TXBUF + 'h800 * ((tx_i + k) % 4) + odd[k];
      for (int i = 0; i < sizes[k]; i++) m[a + i] = f[pos + i];
      pos += sizes[k];
    end
    for (int k = n - 1; k >= 0; k--) begin
      d = TDR + 8 * ((tx_i + k) % 4);
      a = TXBUF + 'h800 * ((tx_i + k) % 4) + odd[k];
      mh(d, 16'(a));
      mh(d + 4, 16'(-sizes[k]));
      mh(d + 6, 16'h0);
      mh(d + 2, D_OWN | (k == 0 ? D_STP | extra1 : 16'h0) | (k == n - 1 ? D_ENP : 16'h0));
    end
    last = TDR + 8 * ((tx_i + n - 1) % 4);
    tx_i = (tx_i + n) % 4;
    le_w(0, C0_TDMD | C0_INEA);
  endtask

  function automatic bit same(input logic [7:0] a [$], input logic [7:0] b [$]);
    if (a.size() != b.size()) return 1'b0;
    for (int i = 0; i < a.size(); i++) if (a[i] !== b[i]) return 1'b0;
    return 1'b1;
  endfunction

  // Check RX descriptor i holds f + its FCS (one buffer)
  task automatic check_rx(input int i, input logic [7:0] f [$], input string what);
    logic [7:0] got [$];
    logic [31:0] fcs;
    int d, n;
    d = RDR + 8 * i;
    n = f.size() + 4;
    check32({16'h0, mrh(d + 2) & 16'hFF00}, {16'h0, D_STP | D_ENP}, {what, ": RMD1"});
    check32(mcnt(d + 6), 32'(n), {what, ": MCNT"});
    got = {};
    for (int k = 0; k < f.size(); k++) got.push_back(m[RXBUF + 'h800 * i + k]);
    check(same(got, f), {what, ": the frame's bytes"});
    fcs = ~crc32(f, f.size());
    check32({m[RXBUF + 'h800 * i + n - 1], m[RXBUF + 'h800 * i + n - 2],
             m[RXBUF + 'h800 * i + n - 3], m[RXBUF + 'h800 * i + n - 4]}, fcs, {what, ": the FCS"});
  endtask

  // ---------------------------------------------------------------- run --
  initial begin
    logic [15:0] v, c0;
    logic [31:0] d32;
    logic [7:0] f [$], g [$], h [$], mcq [$], bc [6], other [6], mc [6];
    bit got, ok;
    int last, txw0;

    bc = '{8'hff, 8'hff, 8'hff, 8'hff, 8'hff, 8'hff};
    other = '{8'h08, 8'h00, 8'h20, 8'h99, 8'h99, 8'h99};
    mc = '{8'h01, 8'h00, 8'h5e, 8'h00, 8'h00, 8'h01};
    for (int i = 0; i < 6; i++) mcq.push_back(mc[i]);
    for (int i = 0; i < 65536; i++) m[i] = 8'(i * 13);
    for (int i = 0; i < MB_WORDS; i++) mb[i] = '0;
    repeat (5) @(posedge clk);
    #1 rst = 1'b0;
    repeat (300) @(posedge clk);       // eth_hps initialises the mailbox

    // ---- reset state and register access
    le_r(0, v);
    check32({16'h0, v}, {16'h0, C0_STOP}, "CSR0 after reset: STOP");
    check(!irq, "no interrupt after reset");
    le_w(1, 16'h1235);
    le_w(2, 16'h00ab);
    le_w(3, 16'h0007);
    le_r(1, v); check32({16'h0, v}, 32'h1234, "CSR1 (bit 0 forced 0)");
    le_r(2, v); check32({16'h0, v}, 32'h00ab, "CSR2");
    le_r(3, v); check32({16'h0, v}, 32'h0007, "CSR3 BSWP|ACON|BCON");
    iob(1'b0, 28'h0, 4'b1111, 32'h0, d32);
    check32(d32, {16'h0007, 16'h0003}, "32-bit read: {RDP, RAP}");
    iob(1'b0, 28'h2, 4'b0011, 32'h0, d32);
    check32(d32 & 32'hFFFF, 32'h3, "RAP reads back");

    // ---- t_eth_init
    setup(16'h0, 16'h7, 3, 1600, 64'h0, c0);
    check32({16'h0, c0}, {16'h0, C0_RXON | C0_TXON | C0_STRT | C0_INIT | C0_INEA},
            "after INIT/IDON/STRT: RXON TXON STRT INIT (until STOP) INEA, IDON acked");
    check(!irq, "no interrupt once IDON is acked");
    le_r(3, v); check32({16'h0, v}, 32'h0, "CSR3 reads 0 while running");
    le_w(1, 16'h5555);
    le_w(0, C0_STOP);
    le_r(1, v); check32({16'h0, v}, 32'(IB), "CSR1 not written while running");
    le_r(3, v); check32({16'h0, v}, 32'h0, "STOP clears CSR3");
    // IDON with INEA raises the interrupt; acking it drops it
    le_w(3, 16'h7);
    le_w(0, C0_INIT | C0_INEA);
    wait_csr0(C0_IDON, 2000, v);
    check32({16'h0, v & (C0_IDON | C0_INTR | C0_INIT)}, {16'h0, C0_IDON | C0_INTR | C0_INIT},
            "IDON sets INTR");
    check(irq, "irq_o with INTR and INEA");
    le_w(0, C0_INEA | C0_IDON | C0_STRT);
    check(!irq, "irq_o drops when IDON is acked");

    // ---- t_eth_loop: a frame to our own address, sent; Main loops it back
    setup(16'h0, 16'h7, 3, 1600, 64'h0, c0);
    mkframe(f, mac, 114, 3);
    tx_send(f, '{114}, '{1}, 16'h0, last);
    wait_own(last, 20000, ok);
    check(ok, "tx: OWN cleared");
    check32({16'h0, mrh(last + 2)}, {16'h0, D_STP | D_ENP}, "tx: TMD1 STP|ENP, no ERR");
    repeat (4) @(posedge clk);
    check(irq, "tx: TINT interrupts");
    main_wait(got, g, 20000);
    check(got && same(g, f), "tx: Main has the 114-byte frame (odd buffer address)");
    main_post(g);
    wait_own(RDR, 40000, ok);
    check(ok, "rx: descriptor 0 handed back");
    check_rx(0, f, "rx 114");
    le_r(0, v);
    check32({16'h0, v & (C0_TINT | C0_RINT | C0_MISS | C0_ERR)}, {16'h0, C0_TINT | C0_RINT},
            "CSR0 TINT RINT, no MISS/ERR");
    le_w(0, C0_TINT | C0_RINT | C0_INEA);
    check(!irq, "irq_o drops after acking TINT RINT");
    rx_i = 1;

    // ---- t_eth_filter: another station's frame dropped, broadcast in
    mkframe(f, other, 200, 4);
    main_post(f);
    mkframe(f, bc, 60, 5);
    main_post(f);
    wait_own(RDR + 8, 40000, ok);
    check(ok, "rx: the broadcast arrives");
    check_rx(1, f, "rx broadcast (the other station's frame dropped)");
    check(mbit(RDR + 16 + 2, 15), "rx: descriptor 2 still the LANCE's");
    le_w(0, C0_RINT | C0_INEA);

    // ---- t_eth_long: 1514 bytes both ways
    mkframe(f, mac, 1514, 6);
    tx_send(f, '{1514}, '{0}, 16'h0, last);
    main_wait(got, g, 60000);
    check(got && same(g, f), "tx: a 1514-byte frame");
    main_post(f);
    wait_own(RDR + 16, 150000, ok);
    check(ok, "rx: the 1514-byte frame");
    check_rx(2, f, "rx 1514");
    le_r(0, v);
    check(!v[14], "no BABL for 1514 bytes");
    le_w(0, C0_TINT | C0_RINT | C0_INEA);

    // ---- t_eth_miss: no buffer: MISS, then the ring goes on
    for (int i = 0; i < 8; i++) mh(RDR + 8 * i + 2, 16'h0);   // the host takes them all
    mkframe(f, mac, 80, 7);
    main_post(f);
    wait_csr0(C0_MISS, 5000, v);
    check(v[12], "MISS with no receive buffer");
    check(irq, "MISS interrupts");
    check(!v[10], "no RINT for a missed frame");
    le_w(0, C0_MISS | C0_INEA);
    give_rx(3);
    mkframe(f, mac, 90, 8);
    main_post(f);
    wait_own(RDR + 24, 40000, ok);
    check(ok, "after MISS the next frame lands in descriptor 3");
    check_rx(3, f, "rx after MISS");
    le_w(0, C0_RINT | C0_INEA);

    // ---- t_eth_oversize: 1600 bytes dropped before the LANCE
    for (int i = 0; i < 8; i++) give_rx(i);
    setup(16'h0, 16'h7, 3, 1600, 64'h0, c0);
    mkframe(f, mac, 1596, 9);                       // 1600 with the FCS
    main_post(f);
    repeat (90000) @(posedge clk);
    le_r(0, v);
    check32({16'h0, v & (C0_RINT | C0_MISS)}, 32'h0, "oversize: no RINT, no MISS");
    check(mbit(RDR + 2, 15), "oversize: descriptor 0 untouched");
    mkframe(f, mac, 100, 10);
    main_post(f);
    wait_own(RDR, 40000, ok);
    check(ok, "the frame after the oversize one arrives");
    check_rx(0, f, "rx after oversize");
    le_w(0, C0_RINT | C0_INEA);

    // ---- t_eth_chain2 / chain3: TX descriptors, later ones handed over first
    setup(16'h0, 16'h7, 3, 1600, 64'h0, c0);
    mkframe(f, mac, 100, 11);
    tx_send(f, '{14, 86}, '{0, 0}, 16'h0, last);
    wait_own(last, 20000, ok);
    check(ok && mrh(TDR + 2) == D_STP && mrh(TDR + 8 + 2) == D_ENP,
          "chain2: both descriptors back, STP / ENP");
    main_wait(got, g, 20000);
    check(got && same(g, f), "chain2: 14 + 86");
    mkframe(f, mac, 100, 12);
    tx_send(f, '{14, 33, 53}, '{1, 3, 1}, 16'h0, last);
    wait_own(last, 20000, ok);
    check(ok && mrh(TDR + 16 + 2) == D_STP && mrh(TDR + 24 + 2) == 16'h0 && mrh(TDR + 2) == D_ENP,
          "chain3: descriptors 2, 3, 0 back (the ring wraps)");
    main_wait(got, g, 20000);
    check(got && same(g, f), "chain3: 14 + 33 + 53 at odd addresses");
    mkframe(f, mac, 61, 13);
    tx_send(f, '{1, 31, 1, 28}, '{3, 0, 1, 2}, 16'h0, last);
    main_wait(got, g, 20000);
    check(got && same(g, f), "chain4: 1 + 31 + 1 + 28, odd and even addresses");
    // a chain whose next buffer is not handed over: BUFF|UFLO, TXON off
    mh(TDR + 8 * tx_i, 16'(TXBUF));
    mh(TDR + 8 * tx_i + 4, 16'(-20));
    mh(TDR + 8 * tx_i + 6, 16'h0);
    mh(TDR + 8 * ((tx_i + 1) % 4) + 2, 16'h0);
    mh(TDR + 8 * tx_i + 2, D_OWN | D_STP);
    le_w(0, C0_TDMD | C0_INEA);
    wait_own(TDR + 8 * tx_i, 20000, ok);
    check(ok && mbit(TDR + 8 * tx_i + 2, 14) && (mrh(TDR + 8 * tx_i + 6) & 16'hC000) == 16'hC000,
          "chain without the next buffer: ERR, TMD3 BUFF|UFLO");
    le_r(0, v);
    check(!v[4] && v[5], "BUFF turns TXON off, RXON stays");
    le_w(0, C0_TINT | C0_INEA);

    // ---- several frames queued at once; DTCR (the driver's FCS)
    setup(16'h0, 16'h7, 3, 1600, 64'h0, c0);
    mkframe(f, mac, 64, 14);
    mkframe(g, bc, 70, 15);
    begin
      int l1;
      tx_send(f, '{64}, '{0}, 16'h0, l1);
      tx_send(g, '{35, 35}, '{1, 0}, 16'h0, last);
    end
    main_wait(got, h, 20000);
    check(got && same(h, f), "queued: the first frame");
    main_wait(got, h, 20000);
    check(got && same(h, g), "queued: the second frame");
    setup(16'h0008, 16'h7, 3, 1600, 64'h0, c0);        // DTCR
    mkframe(f, mac, 64, 16);
    tx_send(f, '{64}, '{0}, 16'h0, last);
    main_wait(got, g, 20000);
    f = f[0:59];
    check(got && same(g, f), "DTCR: the last 4 bytes (the driver's FCS) not sent");

    // ---- multicast and promiscuous
    setup(16'h0, 16'h7, 3, 1600, 64'h1 << 6'(crc32(mcq, 6) >> 26), c0);
    mkframe(f, mc, 64, 17);
    main_post(f);
    wait_own(RDR, 40000, ok);
    check(ok, "multicast: hash bit set, received");
    check_rx(0, f, "rx multicast");
    setup(16'h0, 16'h7, 3, 1600, ~(64'h1 << 6'(crc32(mcq, 6) >> 26)), c0);
    main_post(f);
    mkframe(g, mac, 64, 18);
    main_post(g);
    wait_own(RDR, 60000, ok);
    check_rx(0, g, "multicast with its hash bit clear dropped, the next one in");
    setup(16'h8000, 16'h7, 3, 1600, 64'h0, c0);        // PROM
    mkframe(f, other, 64, 19);
    main_post(f);
    wait_own(RDR, 40000, ok);
    check(ok, "promiscuous: another station's frame received");
    check_rx(0, f, "rx promiscuous");

    // ---- receive chaining: 100-byte buffers, a 250-byte frame
    setup(16'h0, 16'h7, 2, 100, 64'h0, c0);           // 4 descriptors
    mkframe(f, mac, 250, 20);
    main_post(f);
    wait_own(RDR + 16, 40000, ok);
    check(ok, "rx chain: three buffers used");
    check32({16'h0, mrh(RDR + 2)}, {16'h0, D_STP}, "rx chain: first RMD1 STP");
    check32({16'h0, mrh(RDR + 8 + 2)}, 32'h0, "rx chain: middle RMD1 no flags");
    check32({16'h0, mrh(RDR + 16 + 2)}, {16'h0, D_ENP}, "rx chain: last RMD1 ENP");
    check32(mcnt(RDR + 16 + 6), 32'd254, "rx chain: MCNT in the last, the whole frame");
    begin
      logic [7:0] q [$];
      for (int k = 0; k < 254; k++) q.push_back(m[RXBUF + 'h800 * (k / 100) + k % 100]);
      g = f;
      begin
        logic [31:0] fcs = ~crc32(f, f.size());
        for (int i = 0; i < 4; i++) g.push_back(fcs[8 * i +: 8]);
      end
      check(same(q, g), "rx chain: bytes and FCS across the buffers");
    end
    check(mbit(RDR + 24 + 2, 15), "rx chain: descriptor 3 still the LANCE's");
    // the ring runs out mid-frame: BUFF in the last buffer
    give_rx(0);
    mkframe(f, mac, 250, 21);
    main_post(f);
    wait_own(RDR, 40000, ok);
    check(ok && mbit(RDR + 2, 14) && (mrh(RDR + 2) & R_BUFF) != 0,
          "rx chain without a buffer: ERR|BUFF in the last one held");
    le_w(0, C0_RINT | C0_INEA);

    // ---- internal loopback (MODE LOOP|INTL): nothing on the wire
    setup(16'h0044, 16'h7, 3, 1600, 64'h0, c0);
    check32({16'h0, c0 & 16'h0037}, {16'h0, C0_RXON | C0_TXON | C0_STRT | C0_INIT}, "loopback: running");
    txw0 = int'(mb[W_TXW][31:0]);
    mkframe(f, mac, 70, 22);
    tx_send(f, '{70}, '{0}, 16'h0, last);
    wait_own(last, 20000, ok);
    check(ok, "internal loopback: sent");
    wait_own(RDR, 40000, ok);
    check(ok, "internal loopback: received in descriptor 0");
    check_rx(0, f, "internal loopback (70 bytes, the FCS computed)");
    repeat (2000) @(posedge clk);
    check(int'(mb[W_TXW][31:0]) == txw0, "internal loopback: nothing in the mailbox");

    // ---- external loopback (MODE LOOP): through eth_hps
    setup(16'h0004, 16'h7, 3, 1600, 64'h0, c0);
    mkframe(f, mac, 90, 23);
    tx_send(f, '{45, 45}, '{1, 0}, 16'h0, last);
    wait_own(RDR, 60000, ok);
    check(ok, "external loopback: received");
    begin
      logic [7:0] q [$];
      for (int k = 0; k < 90; k++) q.push_back(m[RXBUF + k]);
      check(same(q, f) && mrh(RDR + 6) == 16'd94 && mrh(RDR + 2) == (D_STP | D_ENP),
            "external loopback: the frame, MCNT + 4");
    end
    check(int'(mb[W_TXW][31:0]) == txw0, "external loopback: nothing in the mailbox");

    // ---- BSWP = 0 (the OBP's POST): frame bytes swapped in halfwords
    setup(16'h0, 16'h3, 3, 1600, 64'h0, c0);
    mkframe(f, mac, 64, 24);
    g = {};
    for (int i = 0; i < 64; i++) g.push_back(f[i ^ 1]);
    tx_send(g, '{64}, '{0}, 16'h0, last);
    main_wait(got, h, 20000);
    check(got && same(h, f), "BSWP 0: memory bytes 2k+1, 2k go out as 2k, 2k+1");
    main_post(f);
    wait_own(RDR, 40000, ok);
    begin
      logic [7:0] q [$];
      for (int k = 0; k < 64; k++) q.push_back(m[RXBUF + k]);
      check(ok && same(q, g), "BSWP 0: received bytes swapped in halfwords");
    end

    // ---- babble: a 1530-byte frame sets BABL, and still goes
    setup(16'h0, 16'h7, 3, 1600, 64'h0, c0);
    mkframe(f, mac, 1530, 26);
    tx_send(f, '{1000, 530}, '{1, 1}, 16'h0, last);
    main_wait(got, g, 60000);
    if (!(got && same(g, f))) $display("babble: got %0d size %0d tmd1 %04x tmd3 %04x", got, g.size(), mrh(last + 2), mrh(last + 6));
    check(got && same(g, f), "babble: the 1530-byte frame sent");
    le_r(0, v);
    check(v[14] && v[15] && v[7], "babble: BABL, ERR, INTR");
    le_w(0, C0_BABL | C0_TINT | C0_INEA);

    // ---- DVMA error: MERR, the transmitter stops
    setup(16'h0, 16'h7, 3, 1600, 64'h0, c0);
    mkframe(f, mac, 64, 25);
    err_lo = TXBUF; err_hi = TXBUF + 'h7ff;
    tx_send(f, '{64}, '{0}, 16'h0, last);
    wait_csr0(C0_MERR, 2000, v);
    check(v[11] && v[15] && !v[4] && v[5], "DVMA error: MERR, ERR, TXON off, RXON on");
    check(irq, "MERR interrupts");
    err_lo = -1; err_hi = -1;

    // ---- a 32-bit write: RDP (with the old RAP), then RAP
    le_w(0, C0_STOP);                                // RAP = 0
    iob(1'b1, 28'h0, 4'b1111, {C0_STOP, 16'h0002}, d32);
    iob(1'b0, 28'h0, 4'b1111, 32'h0, d32);
    check32(d32, {16'h0000, 16'h0002}, "32-bit write: CSR0 then RAP = 2; CSR2 (0) reads back");

    // ---- the RESET pin
    @(posedge clk); #1 le_reset = 1'b1;
    repeat (3) @(posedge clk); #1 le_reset = 1'b0;
    le_r(0, v);
    check32({16'h0, v}, {16'h0, C0_STOP}, "RESET pin: STOP, status and INEA clear");
    check(!irq, "RESET pin: no interrupt");
    iob(1'b0, 28'h2, 4'b0011, 32'h0, d32);
    check32(d32 & 32'hFFFF, 32'h0, "RESET pin: RAP 0");

    check(n_dvma_bad == 0, "DVMA requests well-formed and held until ack");
    check(n_avl_bad == 0, "Avalon accesses in the mailbox, single beats");
    check(n_dvma > 0, "DVMA used");
    tb_done("tb_lance");
  end

  initial begin
    #200ms;
    $display("FAIL tb_lance: time-out");
    $fatal(1, "time-out");
  end

endmodule
