// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_eth_hps: the Ethernet mailbox to Main (rtl/mister/eth_hps.sv) against
// a behavioural DDR (an Avalon slave with random waitrequest and read
// latency, holding the 64 KB mailbox window), Main's side of the mailbox as
// sim/sim_main.cpp's EthHost plays it (Main: support/sun/sun_enet.cpp), and
// a simple LANCE on the MAC side. The checks are those of the old
// repository's whole-machine sim/run-eth.sh with ethtest.S, made unit-sized,
// plus the protocol details behind them:
//  - start-up: the header words zeroed, GEN written, MAGIC "SSETH002" last;
//    a new GEN after a reset; the PADR published in the MAC word (bit 63,
//    first byte in 47:40), again when it changes, invalid when 0;
//  - transmit: frames byte for byte in the TX ring with their length, the
//    driver's FCS left out without crcgen, chains of buffers with odd
//    lengths and an odd start, a 1514-byte frame; TX_WPTR; the slot index
//    wrapping; a full ring holds the LANCE (busy) until Main takes a
//    frame, and the frame is dropped when Main takes nothing for TXWAIT;
//    nothing is posted with the network off;
//  - receive: frames from the RX ring byte for byte with the FCS, rx_len,
//    rx_deof on the last word, RX_RPTR; the filter (PADR, broadcast, a
//    LADRF multicast hash, promiscuous; others dropped but consumed); an
//    oversize (1600-byte) and a runt frame skipped; 10 Mb/s pacing between
//    frames posted together; the 16-slot ring wrapping; a frame the LANCE
//    never takes dropped after STALE; rx_clr withdrawing an offer; no
//    polling with the network off;
//  - loopback: the frame comes back with the 4 FCS bytes counted, through
//    the filter, and nothing goes to or is read from the mailbox's rings.
// rx_d is checked in the first cycle of an offer (the LANCE pops at once).

/* verilator lint_off PROCASSINIT */   // a bench: its variables start at their declared values
/* verilator lint_off BLKSEQ */        // its DDR and LANCE models are behavioural
module tb_eth_hps;
  import tb_pkg::*;

  localparam int CLK_HZ  = 50_000_000;
  localparam int BYTECYC = CLK_HZ / 1_250_000;          // 40
  localparam int POLL = 200, STALE = 20_000, TXWAIT = 20_000;   // eth_hps's SIMU timers
  localparam logic [28:0] BASE = 29'h03FE_0000;
  localparam int MB_WORDS = 'h10000 / 8;
  localparam int W_MAGIC = 0, W_GEN = 1, W_TXW = 2, W_TXR = 3, W_RXW = 4, W_RXR = 5, W_MAC = 6;
  localparam int W_TX = 'h1000 / 8, W_RX = 'h5000 / 8;
  localparam logic [63:0] MAGIC = 64'h5353_4554_4830_3032;

  logic clk = 1'b0;
  always #5 clk = ~clk;
  int unsigned cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ------------------------------------------------------------------ DUT --
  logic        rst = 1'b1, ena = 1'b1;
  logic        tx_push = 0, tx_stp = 0, tx_enp = 0, tx_crcgen = 1, tx_clr = 0;
  logic [1:0]  tx_be = 0;
  logic [15:0] tx_d = 0;
  logic [11:0] tx_len = 0;
  logic        tx_fifordy, tx_busy;
  logic        rx_pop = 0, rx_clr = 0;
  logic [15:0] rx_d;
  logic        rx_deof, rx_fifordy, rx_crcok, rx_eof;
  logic [11:0] rx_len;
  logic        rx_lpbk = 0, rx_prom = 0;
  logic [47:0] rx_padr = 48'h56_34_12_20_00_08;          // 08:00:20:12:34:56, first byte low
  logic [63:0] rx_ladrf = '0;
  logic        avl_waitrequest = 1'b0;
  logic [28:0] avl_address;
  logic        avl_read, avl_write;
  logic [63:0] avl_writedata, avl_readdata = '0;
  logic [7:0]  avl_byteenable, avl_burstcount;
  logic        avl_readdatavalid = 1'b0;

  eth_hps #(.CLK_HZ(CLK_HZ), .SIMU(1'b1)) dut (
    .clk, .rst, .ena,
    .tx_push, .tx_stp, .tx_be, .tx_d, .tx_enp, .tx_len, .tx_crcgen, .tx_clr, .tx_fifordy, .tx_busy,
    .rx_pop, .rx_clr, .rx_d, .rx_deof, .rx_fifordy, .rx_len, .rx_crcok, .rx_eof,
    .rx_lpbk, .rx_prom, .rx_padr, .rx_ladrf,
    .avl_waitrequest, .avl_address, .avl_read, .avl_write, .avl_writedata, .avl_byteenable,
    .avl_burstcount, .avl_readdata, .avl_readdatavalid);

  // ------------------------------------------- the DDR and its mailbox --
  logic [63:0] mb [MB_WORDS];
  bit          stress = 1'b1;           // random waitrequest and read latency
  int unsigned n_bad = 0, n_rd = 0, n_wr = 0, n_rxw_reads = 0, n_ring_acc = 0;
  int          wlog [$];                // the words written, in order
  bit          rd_pend = 1'b0;
  int          rd_cnt = 0, rd_idx = 0;
  int unsigned lfsr = 32'h1234_5678;

  function automatic int unsigned rnd();
    lfsr = lfsr * 32'd1664525 + 32'd1013904223;
    return lfsr >> 8;
  endfunction

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
      if (idx < 0 || idx >= 'hD000 / 8 || avl_byteenable != 8'hFF || avl_burstcount != 8'd1 ||
          (avl_read && avl_write) || (avl_read && rd_pend)) begin
        n_bad++;
        $display("tb_eth_hps: bad access %s at %08x be %02x bc %0d", avl_write ? "write" : "read",
                 avl_address, avl_byteenable, avl_burstcount);
      end else if (avl_write) begin
        mb[idx] = avl_writedata;
        wlog.push_back(idx);
        n_wr++;
        if (idx >= W_TX) n_ring_acc++;
      end else begin
        n_rd++;
        if (idx == W_RXW) n_rxw_reads++;
        if (idx >= W_TX) n_ring_acc++;
        rd_pend = 1'b1;
        rd_idx  = idx;
        rd_cnt  = stress ? 1 + int'(rnd() % 7) : 2;
      end
    end
    avl_waitrequest <= stress && (rnd() % 4 == 0);
  end

  // --------------------------------------------- Main's side (EthHost) --
  logic [31:0] main_txr = '0;           // TX frames Main has taken

  // Take the next TX frame if there is one
  task automatic main_take(output bit got, output int len, output logic [7:0] f [2048]);
    logic [63:0] h;
    int s;
    got = 1'b0; len = 0;
    for (int i = 0; i < 2048; i++) f[i] = 8'h00;
    if (mb[W_TXW][31:0] == main_txr) return;
    s = W_TX + 256 * int'(main_txr % 8);
    h = mb[s];
    len = int'(h[10:0]);
    for (int i = 0; i < len; i++) f[i] = mb[s + 1 + i / 8][8 * (i % 8) +: 8];
    main_txr = main_txr + 1;
    mb[W_TXR] = {32'd0, main_txr};
    got = 1'b1;
  endtask

  // Post a received frame (FCS included in len) with its LADRF hash
  task automatic main_post(input logic [7:0] f [2048], input int len, input logic [5:0] hash);
    int s;
    logic [31:0] w;
    w = mb[W_RXW][31:0];
    s = W_RX + 256 * int'(w % 16);
    mb[s] = {42'd0, hash, 5'd0, 11'(len)};
    for (int i = 0; i < (len + 7) / 8; i++) mb[s + 1 + i] = '0;
    for (int i = 0; i < len; i++) mb[s + 1 + i / 8][8 * (i % 8) +: 8] = f[i];
    mb[W_RXW] = {32'd0, w + 32'd1};
  endtask

  // ---------------------------------------------------------- the LANCE --
  // Receive: pops whenever rx_take (always at once with rx_greedy), and
  // collects each frame.
  bit          rx_take = 1'b1, rx_greedy = 1'b1;
  logic [7:0]  rxf [32][2048];
  int          rxf_len [32];
  int          rxf_words [32];
  int unsigned rxf_offer [32];
  int unsigned rx_n = 0, rx_bad = 0;
  int          rx_cur_words = 0;
  int unsigned rx_cur_offer = 0;
  logic        fifordy_d = 1'b0;

  always @(posedge clk) begin
    fifordy_d <= rx_fifordy;
    if (rx_fifordy && !fifordy_d) begin
      rx_cur_offer = cyc;
      rx_cur_words = 0;
    end
    if (rx_pop && rx_fifordy) begin
      rxf[rx_n % 32][2 * rx_cur_words]     = rx_d[15:8];
      rxf[rx_n % 32][2 * rx_cur_words + 1] = rx_d[7:0];
      rx_cur_words++;
      if (!rx_crcok || rx_eof) rx_bad++;
      if (rx_deof) begin
        rxf_len[rx_n % 32]   = int'(rx_len);
        rxf_words[rx_n % 32] = rx_cur_words;
        rxf_offer[rx_n % 32] = rx_cur_offer;
        rx_n++;
      end
    end
    rx_pop <= rx_take && (rx_greedy || rnd() % 3 != 0);
  end

  // ---------------------------------------------------------------- tasks --
  task automatic cycles(input int n);
    repeat (n) @(posedge clk);
    #1;
  endtask

  // Wait for tx_busy (which = 0) or rx_fifordy (1) to become val
  task automatic wait_for(input string what, input int limit, input int which, input logic val);
    int n;
    logic v;
    n = 0;
    v = which == 0 ? tx_busy : rx_fifordy;
    while (v !== val && n < limit) begin
      cycles(1);
      n++;
      v = which == 0 ? tx_busy : rx_fifordy;
    end
    check(v === val, $sformatf("%s (waited %0d cycles)", what, n));
  endtask

  // A frame: dst, our source 08:00:20:aa:bb:cc, type 0x0800, payload i + seq
  task automatic make_frame(input logic [47:0] dst, input int len, input int seq, output logic [7:0] f [2048]);
    for (int i = 0; i < 2048; i++) f[i] = 8'h00;
    for (int i = 0; i < 6; i++) f[i] = dst[47 - 8 * i -: 8];       // written as on the wire
    f[6] = 8'h08; f[7] = 8'h00; f[8] = 8'h20; f[9] = 8'hAA; f[10] = 8'hBB; f[11] = 8'hCC;
    f[12] = 8'h08; f[13] = 8'h00;
    f[14] = 8'(seq);
    for (int i = 15; i < len; i++) f[i] = 8'(i * 7 + seq);
  endtask

  // Push one buffer's bytes [from, to) of f; `odd`: it starts on an odd
  // address (one byte in d[7:0] first)
  task automatic push_buf(input logic [7:0] f [2048], input int from, input int to, input bit odd,
                          input bit first);
    int i;
    bit stp;
    i = from; stp = first;
    while (i < to) begin
      if (rnd() % 3 == 0) cycles(1);                    // gaps between the LANCE's words
      tx_push = 1'b1; tx_stp = stp; stp = 1'b0;
      if (odd && i == from) begin
        tx_be = 2'b01; tx_d = {8'h00, f[i]}; i += 1;
      end else if (i + 1 == to) begin
        tx_be = 2'b10; tx_d = {f[i], 8'h00}; i += 1;
      end else begin
        tx_be = 2'b11; tx_d = {f[i], f[i + 1]}; i += 2;
      end
      cycles(1);
      tx_push = 1'b0; tx_stp = 1'b0;
    end
  endtask

  // Send a frame over buffers of the given sizes (the LANCE: waits for
  // !busy, holds len/enp, then waits until the frame left)
  task automatic lance_send(input logic [7:0] f [2048], input int sizes [$], input bit odd, input bit crcgen,
                            input int wait_limit);
    int pos;
    while (tx_busy) cycles(1);
    tx_crcgen = crcgen;
    pos = 0;
    foreach (sizes[b]) begin
      tx_len = 12'(pos + sizes[b]);
      tx_enp = (b == sizes.size() - 1);
      push_buf(f, pos, pos + sizes[b], odd && b == 0, b == 0);
      pos += sizes[b];
    end
    cycles(2);
    wait_for("the LANCE's frame left (busy fell)", wait_limit, 0, 1'b0);
    tx_enp = 1'b0;
    tx_len = '0;
  endtask

  // Main: wait for one TX frame and compare it with f[0:len)
  task automatic expect_tx(input logic [7:0] f [2048], input int len, input string what);
    bit got;
    int glen, n, bad;
    logic [7:0] g [2048];
    n = 0;
    do begin main_take(got, glen, g); if (!got) cycles(1); n++; end while (!got && n < 20_000);
    check(got, {what, ": Main got a TX frame"});
    bad = 0;
    for (int i = 0; i < len; i++) if (g[i] !== f[i]) bad++;
    check(glen == len && bad == 0, $sformatf("%s: TX frame %0d bytes (expected %0d), %0d differ", what, glen, len, bad));
  endtask

  // The LANCE: wait for the frame number `n` and compare it
  task automatic expect_rx(input int unsigned n, input logic [7:0] f [2048], input int len, input string what,
                           input int rlen = -1);
    int k, bad;
    k = 0;
    while (rx_n <= n && k < 400_000) begin cycles(1); k++; end
    check(rx_n > n, $sformatf("%s: frame %0d received", what, n));
    if (rx_n > n) begin
      bad = 0;
      for (int i = 0; i < len; i++) if (rxf[n % 32][i] !== f[i]) bad++;
      if (rlen < 0) rlen = len;
      check(rxf_len[n % 32] == rlen && rxf_words[n % 32] == (rlen + 1) / 2 && bad == 0,
            $sformatf("%s: RX frame len %0d words %0d (expected %0d), %0d bytes differ",
                      what, rxf_len[n % 32], rxf_words[n % 32], len, bad));
    end
  endtask

  task automatic reset_dut();
    rst = 1'b1;
    cycles(3);
    rst = 1'b0;
  endtask

  // ----------------------------------------------------------------- test --
  logic [7:0]  f [2048];
  logic [7:0]  f2 [2048];
  logic [7:0]  ffcs [2048];
  logic [63:0] gen1;
  int unsigned n0, t0, w0;
  int          sz [$];
  bit          got;
  int          glen;
  logic [7:0]  g [2048];
  localparam logic [47:0] OURS  = 48'h08_00_20_12_34_56;     // as written on the wire
  localparam logic [47:0] OTHER = 48'h08_00_20_99_88_77;
  localparam logic [47:0] BCAST = 48'hFF_FF_FF_FF_FF_FF;
  localparam logic [47:0] MCAST = 48'h01_00_5E_00_00_01;

  initial begin
    for (int i = 0; i < MB_WORDS; i++) mb[i] = 64'hA5A5_A5A5_A5A5_A5A5;

    // ================= start-up
    cycles(5);
    rst = 1'b0;
    cycles(200);
    check(mb[W_MAGIC] == MAGIC, "init: MAGIC is SSETH002");
    check(wlog.size() >= 8 && wlog[7] == W_MAGIC && wlog[0] == W_MAGIC, "init: MAGIC cleared first, written last");
    begin : init_words
      bit order_ok;
      order_ok = 1'b1;
      for (int i = 0; i < 7; i++) if (wlog[i] != i) order_ok = 1'b0;
      check(order_ok, "init: the header words 0-6 written in order");
    end
    check(mb[W_TXW] == 0 && mb[W_TXR] == 0 && mb[W_RXW] == 0 && mb[W_RXR] == 0, "init: the pointers zeroed");
    check(mb[W_MAC] == 64'h8000_0800_2012_3456, $sformatf("init: the MAC published (%016x)", mb[W_MAC]));
    gen1 = mb[W_GEN];
    check(gen1[63:32] == 0, "init: GEN in the low word");
    cycles(37);
    reset_dut();
    cycles(200);
    check(mb[W_GEN] != gen1 && mb[W_MAGIC] == MAGIC, "init: a reset writes a new GEN");
    main_txr = '0;

    rx_padr = 48'h66_55_44_33_22_11;
    cycles(100);
    check(mb[W_MAC] == 64'h8000_1122_3344_5566, "MAC: republished when the PADR changes");
    rx_padr = '0;
    cycles(100);
    check(mb[W_MAC] == 64'h0, "MAC: invalid with a zero PADR");
    rx_padr = 48'h56_34_12_20_00_08;
    cycles(100);
    check(mb[W_MAC] == 64'h8000_0800_2012_3456, "MAC: back");
    check(tx_fifordy && !tx_busy && !rx_fifordy, "idle: tx_fifordy, not busy, nothing offered");

    // ================= transmit
    make_frame(OURS, 114, 1, f);
    sz = '{114};
    lance_send(f, sz, 0, 1, 20_000);
    check(mb[W_TXW] == 1, "tx: TX_WPTR 1");
    expect_tx(f, 114, "tx 114");

    make_frame(OTHER, 64, 2, f);                      // the driver's FCS: 60 + 4
    sz = '{64};
    lance_send(f, sz, 0, 0, 20_000);
    expect_tx(f, 60, "tx without crcgen");

    make_frame(BCAST, 101, 3, f);
    sz = '{7, 33, 61};
    lance_send(f, sz, 1, 1, 20_000);
    expect_tx(f, 101, "tx chain of 3, odd lengths, odd start");

    make_frame(OURS, 1514, 4, f);
    sz = '{1514};
    lance_send(f, sz, 0, 1, 20_000);
    expect_tx(f, 1514, "tx 1514");

    // a full ring holds the LANCE until Main takes one; slots wrap
    for (int i = 0; i < 8; i++) begin
      make_frame(OURS, 60 + i, 10 + i, f);
      sz = '{60 + i};
      lance_send(f, sz, 0, 1, 20_000);
    end
    check(mb[W_TXW] == 12, "tx: 8 frames posted, Main has taken none");
    make_frame(OURS, 70, 20, f2);
    fork
      begin
        sz = '{70};
        lance_send(f2, sz, 0, 1, 40_000);
      end
      begin
        cycles(5_000);
        check(tx_busy && mb[W_TXW] == 12, "tx: ring full, the LANCE held (busy), nothing posted");
        for (int i = 0; i < 8; i++) begin
          make_frame(OURS, 60 + i, 10 + i, f);
          expect_tx(f, 60 + i, $sformatf("tx ring slot %0d", (4 + i) % 8));
        end
      end
    join
    expect_tx(f2, 70, "tx after the ring drained");
    check(mb[W_TXW] == 13, "tx: TX_WPTR 13");

    // Main stops: the frame after a full ring is dropped after TXWAIT
    for (int i = 0; i < 8; i++) begin
      make_frame(OURS, 60, 30 + i, f);
      sz = '{60};
      lance_send(f, sz, 0, 1, 20_000);
    end
    t0 = cyc;
    sz = '{60};
    lance_send(f, sz, 0, 1, TXWAIT + 5_000);
    check(cyc - t0 >= TXWAIT && mb[W_TXW] == 21,
          $sformatf("tx: dropped after %0d cycles with Main stopped (TXWAIT %0d)", cyc - t0, TXWAIT));
    for (int i = 0; i < 8; i++) main_take(got, glen, g);
    check(mb[W_TXW][31:0] == main_txr, "tx: Main caught up");

    // network off: dropped at once, RX not polled
    ena = 1'b0;
    cycles(50);
    w0 = mb[W_TXW][31:0];
    t0 = cyc;
    make_frame(OURS, 80, 40, f);
    sz = '{80};
    lance_send(f, sz, 0, 1, 2_000);
    check(mb[W_TXW] == 64'(w0) && cyc - t0 < 2_000, "off: the TX frame dropped, nothing posted");
    n0 = n_rxw_reads;
    make_frame(OURS, 64, 41, f);
    main_post(f, 64, 6'd0);
    cycles(10 * POLL);
    check(n_rxw_reads == n0 && rx_n == 0, "off: RX_WPTR not polled");
    ena = 1'b1;
    expect_rx(0, f, 64, "rx after the network came on");
    check(mb[W_RXR] == 1, "rx: RX_RPTR 1");

    // ================= receive and the filter
    make_frame(OURS, 114, 50, f);
    main_post(f, 118, 6'd0);
    expect_rx(1, f, 118, "rx to our address");
    make_frame(OTHER, 64, 51, f2);
    main_post(f2, 64, 6'd0);
    make_frame(BCAST, 64, 52, f);
    main_post(f, 64, 6'd0);
    expect_rx(2, f, 64, "rx broadcast after another station's (filtered)");
    check(mb[W_RXR] == 4, "rx: the filtered frame consumed");
    rx_ladrf = 64'h1 << 37;
    make_frame(MCAST, 70, 53, f2);
    main_post(f2, 70, 6'd36);                         // hash bit clear: dropped
    make_frame(MCAST, 72, 54, f);
    main_post(f, 72, 6'd37);                          // set: kept
    expect_rx(3, f, 72, "rx multicast in the LADRF");
    rx_prom = 1'b1;
    make_frame(OTHER, 66, 55, f);
    main_post(f, 66, 6'd0);
    expect_rx(4, f, 66, "rx promiscuous");
    rx_prom = 1'b0;
    cycles(5_000);
    check(rx_n == 5 && mb[W_RXR] == 7, "rx: 5 kept of 7 posted");

    // oversize and runt frames skipped
    make_frame(OURS, 1600, 56, f2);
    main_post(f2, 1600, 6'd0);
    make_frame(OURS, 10, 57, f2);
    main_post(f2, 10, 6'd0);
    make_frame(OURS, 1522, 58, f);
    main_post(f, 1522, 6'd0);
    expect_rx(5, f, 1522, "rx 1522 after a 1600-byte and a 10-byte frame (skipped)");
    check(mb[W_RXR] == 10, "rx: the skipped frames consumed");

    // pacing: three 1000-byte frames posted together
    for (int i = 0; i < 3; i++) begin
      make_frame(OURS, 1000, 60 + i, f);
      main_post(f, 1000, 6'd0);
    end
    expect_rx(8, f, 1000, "rx paced, the third");
    for (int i = 6; i < 8; i++) begin
      int d;
      d = int'(rxf_offer[(i + 1) % 32]) - int'(rxf_offer[i % 32]);
      check(d >= 1020 * BYTECYC && d < 1020 * BYTECYC + 5_000,
            $sformatf("rx pacing: %0d cycles between offers (wire time %0d)", d, 1020 * BYTECYC));
    end

    // the 16-slot ring wraps: 20 frames, Main posting while there is room
    n0 = rx_n;
    for (int i = 0; i < 20; i++) begin
      while (mb[W_RXW][31:0] - mb[W_RXR][31:0] >= 16) cycles(1);
      make_frame(OURS, 60, 100 + i, f);
      main_post(f, 64, 6'd0);
    end
    for (int i = 0; i < 20; i++) begin
      make_frame(OURS, 60, 100 + i, f);
      expect_rx(n0 + i, f, 64, $sformatf("rx ring wrap %0d", i));
    end

    // a frame the LANCE never takes is dropped after STALE
    rx_take = 1'b0;
    n0 = rx_n;
    make_frame(OURS, 60, 130, f2);
    main_post(f2, 64, 6'd0);
    wait_for("stale: offered", 5_000, 1, 1'b1);
    t0 = cyc;
    wait_for("stale: withdrawn", STALE + 1_000, 1, 1'b0);
    check(cyc - t0 >= STALE - 2, $sformatf("stale: after %0d cycles (STALE %0d)", cyc - t0, STALE));
    rx_take = 1'b1;
    make_frame(OURS, 60, 131, f);
    main_post(f, 64, 6'd0);
    expect_rx(n0, f, 64, "stale: the next frame comes in");

    // rx_clr withdraws an offer
    rx_take = 1'b0;
    make_frame(OURS, 60, 132, f2);
    main_post(f2, 64, 6'd0);
    wait_for("clr: offered", 5_000, 1, 1'b1);
    rx_clr = 1'b1;
    cycles(1);
    rx_clr = 1'b0;
    check(!rx_fifordy, "clr: withdrawn");
    rx_take = 1'b1;
    make_frame(OURS, 60, 133, f);
    main_post(f, 64, 6'd0);
    expect_rx(n0 + 1, f, 64, "clr: the next frame comes in");

    // ================= loopback
    cycles(2_000);                                    // the wire time of the last frame
    rx_lpbk = 1'b1;
    rx_greedy = 1'b0;                                 // pops with gaps
    n0 = rx_n;
    w0 = mb[W_TXW][31:0];
    begin : lb
      int unsigned ring0, rxw0;
      ring0 = n_ring_acc;
      rxw0  = n_rxw_reads;
      make_frame(OURS, 100, 140, f);
      sz = '{40, 60};
      lance_send(f, sz, 0, 1, 20_000);
      expect_rx(n0, f, 100, "loopback: the frame back, its FCS counted (104)", 104);
      make_frame(OTHER, 60, 141, f);
      sz = '{60};
      lance_send(f, sz, 0, 1, 20_000);
      make_frame(MCAST, 60, 142, f);                  // any multicast, LADRF or not
      rx_ladrf = '0;
      lance_send(f, sz, 0, 1, 20_000);
      expect_rx(n0 + 1, f, 60, "loopback: multicast back, another station's filtered", 64);
      cycles(10 * POLL);
      check(rx_n == n0 + 2, "loopback: another station's frame not back");
      check(n_ring_acc == ring0 && n_rxw_reads == rxw0 && mb[W_TXW] == 64'(w0),
            "loopback: the mailbox's rings untouched, RX_WPTR not polled");
    end
    rx_lpbk = 1'b0;
    rx_greedy = 1'b1;

    check(n_bad == 0, "every DDR access in the mailbox window, single 64-bit beats");
    check(rx_bad == 0, "rx_crcok 1, rx_eof 0");
    tb_done("tb_eth_hps");
  end

  initial begin
    #200ms;
    $display("FAIL: tb_eth_hps timed out");
    $fatal(1, "timeout");
  end

endmodule
