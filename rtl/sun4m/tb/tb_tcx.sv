// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_tcx: the TCX against QEMU hw/display/tcx.c's behaviour. A behavioural
// DDR3 (two Avalon ports, random waitrequest and read latency, the hold
// rule checked) holds the VRAM window; the bench keeps its own copy of
// VRAM and of the palette and checks the DDR contents after CPU accesses,
// blits and stipples, and every pixel of whole frames at the video output.
// clk is 55.6 MHz, clk_vid 65.4 MHz, unrelated.

/* verilator lint_off PROCASSINIT */   // a bench: its variables start at their declared values
/* verilator lint_off WIDTHEXPAND */   // and does its pixel arithmetic in ints
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off BLKSEQ */        // its DDR model is behavioural

module tb_tcx;
  import iobus_pkg::*;
  import ss20_ddr_pkg::*;
  import tb_pkg::*;

  localparam logic [27:0] DAC = 28'h0200000, THC = 28'h0300000, VRAM = 28'h0800000;
  localparam logic [27:0] STIP = 28'h4000000, BLIT = 28'h6000000;
  localparam logic [27:0] RSTIP = 28'hC000000, RBLIT = 28'hE000000;

  logic clk = 0, clk_vid = 0, rst = 1;
  always #9    clk = ~clk;
  always #7.65 clk_vid = ~clk_vid;

  iob_req_t req = IOB_REQ_IDLE;
  iob_rsp_t rsp;
  logic irq;

  logic [28:0] v_addr, s_addr;
  logic [7:0]  v_bc, s_bc, v_be;
  logic        v_rd, v_wr, v_wait, v_rdv, s_rd, s_wait, s_rdv;
  logic [63:0] v_wd, v_rdata, s_rdata;
  logic        vid_ce, vid_hs, vid_vs, vid_de;
  logic [7:0]  vid_r, vid_g, vid_b;

  tcx #(.BURST(32)) dut (
    .clk, .rst, .bus_i(req), .bus_o(rsp), .irq_o(irq),
    .vram_address(v_addr), .vram_burstcount(v_bc), .vram_read(v_rd), .vram_write(v_wr),
    .vram_writedata(v_wd), .vram_byteenable(v_be), .vram_waitrequest(v_wait),
    .vram_readdata(v_rdata), .vram_readdatavalid(v_rdv),
    .scan_address(s_addr), .scan_burstcount(s_bc), .scan_read(s_rd),
    .scan_waitrequest(s_wait), .scan_readdata(s_rdata), .scan_readdatavalid(s_rdv),
    .clk_vid, .vid_ce_o(vid_ce), .vid_r_o(vid_r), .vid_g_o(vid_g), .vid_b_o(vid_b),
    .vid_hs_o(vid_hs), .vid_vs_o(vid_vs), .vid_de_o(vid_de));

  // ================================================== the DDR3 model
  localparam logic [28:0] VBASE = ddr_word(VRAM_BASE);
  logic [63:0] mem [131072];
  longint unsigned cyc = 0;
  int ddr_errors = 0;
  int wait_pct = 30;

  typedef struct { logic [63:0] d; longint unsigned t; } rbeat_t;
  rbeat_t vq[$], sq[$];
  longint unsigned v_last_t = 0, s_last_t = 0;

  // held-command check
  logic        v_held = 0, s_held = 0;
  logic [28:0] v_h_addr, s_h_addr;
  logic [63:0] v_h_wd;
  logic [7:0]  v_h_be;
  logic        v_h_rd, v_h_wr;

  function automatic int widx(input logic [28:0] a);
    if (a < VBASE || a >= VBASE + 29'd131072) return -1;
    return int'(a - VBASE);
  endfunction

  always @(posedge clk) begin
    cyc <= cyc + 1;
    // ---- VRAM port
    if (v_held && (v_addr != v_h_addr || v_rd != v_h_rd || v_wr != v_h_wr ||
                   (v_wr && (v_wd != v_h_wd || v_be != v_h_be)))) begin
      ddr_errors++; $display("FAIL: vram command changed under waitrequest");
    end
    v_held <= (v_rd || v_wr) && v_wait;
    v_h_addr <= v_addr; v_h_rd <= v_rd; v_h_wr <= v_wr; v_h_wd <= v_wd; v_h_be <= v_be;
    if ((v_rd || v_wr) && !v_wait) begin
      if (v_bc != 8'd1) begin ddr_errors++; $display("FAIL: vram burstcount %0d", v_bc); end
      if (widx(v_addr) < 0) begin ddr_errors++; $display("FAIL: vram address %h outside VRAM", v_addr); end
      else if (v_wr) begin
        for (int b = 0; b < 8; b++) if (v_be[b]) mem[widx(v_addr)][8*b +: 8] = v_wd[8*b +: 8];
      end else begin
        longint unsigned t;
        t = cyc + 2 + ($urandom % 20);
        if (t < v_last_t) t = v_last_t;
        v_last_t = t;
        vq.push_back('{d: mem[widx(v_addr)], t: t});
      end
    end
    v_rdv <= 1'b0;
    if (vq.size() > 0 && vq[0].t <= cyc && ($urandom % 4) != 0) begin
      v_rdv <= 1'b1; v_rdata <= vq[0].d; void'(vq.pop_front());
    end else v_rdata <= 64'hx;
    v_wait <= ($urandom % 100) < wait_pct;

    // ---- scan port (read bursts only)
    if (s_held && (s_addr != s_h_addr || !s_rd)) begin
      ddr_errors++; $display("FAIL: scan command changed under waitrequest");
    end
    s_held <= s_rd && s_wait;
    s_h_addr <= s_addr;
    if (s_rd && !s_wait) begin
      longint unsigned t;
      t = cyc + 4 + ($urandom % 30);
      if (t < s_last_t) t = s_last_t;
      for (int i = 0; i < int'(s_bc); i++) begin
        if (widx(s_addr + 29'(i)) < 0) begin ddr_errors++; $display("FAIL: scan address outside VRAM"); end
        else sq.push_back('{d: mem[widx(s_addr + 29'(i))], t: t});
      end
      s_last_t = t;
    end
    s_rdv <= 1'b0;
    if (sq.size() > 0 && sq[0].t <= cyc && ($urandom % 8) != 0) begin
      s_rdv <= 1'b1; s_rdata <= sq[0].d; void'(sq.pop_front());
    end else s_rdata <= 64'hx;
    s_wait <= ($urandom % 100) < wait_pct;
  end

  // ================================================== reference model
  logic [7:0]  ref_vram [1 << 20];
  logic [23:0] ref_pal [260];
  logic [7:0]  ref_tmp;

  function automatic logic [7:0] ddr_byte(input int p);
    return mem[p >> 3][8 * (7 - (p & 7)) +: 8];
  endfunction

  task automatic check_vram(input int lo, input int hi, input string what);
    int bad = 0;
    for (int p = lo; p < hi; p++)
      if (ddr_byte(p & 20'hFFFFF) !== ref_vram[p & 20'hFFFFF]) begin
        if (bad < 5) $display("  pixel %h: ddr %h, expected %h", p, ddr_byte(p & 20'hFFFFF), ref_vram[p & 20'hFFFFF]);
        bad++;
      end
    check(bad == 0, what);
  endtask

  // ================================================== the I/O bus
  task automatic cycles(input int n);
    repeat (n) @(posedge clk);
    #1;
  endtask

  task automatic bus_write(input logic [27:0] a, input logic [31:0] d,
                           input logic [3:0] be = 4'hF, input bit pair = 0);
    int n = 0;
    req.req = 1; req.we = 1; req.addr = a; req.be = be; req.wdata = d; req.pair = pair;
    do begin cycles(1); n++; end while (!rsp.ack && !rsp.err && n < 10000);
    check(rsp.ack && !rsp.err, $sformatf("write %h acked", a));
    req.req = 0; req.we = 0; req.pair = 0;
  endtask

  task automatic bus_read(input logic [27:0] a, output logic [31:0] d,
                          input logic [3:0] be = 4'hF, input bit pair = 0);
    int n = 0;
    req.req = 1; req.we = 0; req.addr = a; req.be = be; req.pair = pair;
    do begin cycles(1); n++; end while (!rsp.ack && !rsp.err && n < 10000);
    check(rsp.ack && !rsp.err, $sformatf("read %h acked", a));
    d = rsp.rdata;
    req.req = 0; req.pair = 0;
  endtask

  // a 64-bit store: two beats, the high word first
  task automatic bus_write64(input logic [27:0] a, input logic [63:0] d);
    bus_write(a, d[63:32], 4'hF, 1);
    bus_write(a + 28'd4, d[31:0], 4'hF, 1);
  endtask

  // CPU stores into the 8-bit frame buffer, mirrored in the model
  task automatic vram_wb(input int p, input logic [7:0] v);
    bus_write(VRAM + 28'(p), {4{v}}, 4'b1000 >> (p & 3));
    ref_vram[p] = v;
  endtask
  task automatic vram_wh(input int p, input logic [15:0] v);   // p even
    bus_write(VRAM + 28'(p), {2{v}}, (p & 2) != 0 ? 4'b0011 : 4'b1100);
    ref_vram[p] = v[15:8]; ref_vram[p + 1] = v[7:0];
  endtask
  task automatic vram_ww(input int p, input logic [31:0] v);   // p a multiple of 4
    bus_write(VRAM + 28'(p), v);
    for (int i = 0; i < 4; i++) ref_vram[p + i] = v[31 - 8 * i -: 8];
  endtask

  // the engine, and the model of tcx.c
  task automatic set_colour(input logic [7:0] c);
    bus_write(BLIT, {24'h0, c});
    ref_tmp = c;
  endtask

  task automatic do_fill(input int p, input int n, input bit raw = 0);   // n 1..32
    bus_write((raw ? RBLIT : BLIT) + 28'(p << 3) + 28'd4, {3'd0, 5'(n - 1), 24'hFFFFFF});
    for (int i = 0; i < n; i++) ref_vram[(p + i) & 20'hFFFFF] = ref_tmp;
  endtask

  task automatic do_copy(input int dst, input int src, input int n, input bit raw = 0);
    logic [7:0] t [32];
    bus_write((raw ? RBLIT : BLIT) + 28'(dst << 3) + 28'd4, {3'd0, 5'(n - 1), 4'd0, 20'(src)});
    for (int i = 0; i < n; i++) t[i] = ref_vram[(src + i) & 20'hFFFFF];
    for (int i = 0; i < n; i++) ref_vram[(dst + i) & 20'hFFFFF] = t[i];
  endtask

  task automatic do_stip(input int p, input logic [31:0] m, input bit raw = 0);
    bus_write((raw ? RSTIP : STIP) + 28'(p << 3) + 28'd4, m);
    for (int i = 0; i < 32; i++) if (m[31 - i]) ref_vram[(p + i) & 20'hFFFFF] = ref_tmp;
  endtask

  // a 64-bit store to the stippler: colour and mask in one access
  task automatic do_stip64(input int p, input logic [7:0] c, input logic [31:0] m);
    bus_write64(STIP + 28'(p << 3), {24'h0, c, m});
    ref_tmp = c;
    for (int i = 0; i < 32; i++) if (m[31 - i]) ref_vram[(p + i) & 20'hFFFFF] = ref_tmp;
  endtask

  // wait until the engine has finished (a VRAM read waits for it)
  task automatic sync_engine;
    logic [31:0] d;
    bus_read(VRAM, d);
  endtask

  // DAC
  task automatic dac_colour(input logic [7:0] i, input logic [23:0] rgb);
    bus_write(DAC, {i, 24'h0});
    bus_write(DAC + 28'h4, {rgb[23:16], 24'h0});
    bus_write(DAC + 28'h4, {rgb[15:8], 24'h0});
    bus_write(DAC + 28'h4, {rgb[7:0], 24'h0});
    ref_pal[i] = rgb;
  endtask

  // ================================================== the video monitor
  int  mon_x = 0, mon_y = 0;
  bit  mon_on = 0, mon_blank = 0;
  int  mon_bad = 0, mon_pix = 0;
  logic mon_de_d = 0, mon_vs_d = 0;
  int  frames = 0;
  logic [15:0] m_cx, m_cy;
  logic [7:0]  m_rm;
  logic [31:0] m_mask [32], m_bits [32];

  function automatic logic [23:0] expect_pix(input int x, input int y);
    logic [7:0] v;
    if (mon_blank) return 24'h0;
    if (y >= int'(m_cy) && y < int'(m_cy) + 32 && x >= int'(m_cx) && x < int'(m_cx) + 32 &&
        m_mask[y - int'(m_cy)][31 - (x - int'(m_cx))])
      return m_bits[y - int'(m_cy)][31 - (x - int'(m_cx))] ? ref_pal[259] : ref_pal[258];
    v = ref_vram[y * 1024 + x] & m_rm;
    return ref_pal[v];
  endfunction

  always @(posedge clk_vid) begin
    mon_vs_d <= vid_vs;
    mon_de_d <= vid_de;
    if (vid_vs && !mon_vs_d) begin frames++; mon_y = 0; end
    if (!vid_de && mon_de_d) begin mon_x = 0; mon_y++; end
    if (vid_de && mon_on) begin
      logic [23:0] e;
      e = expect_pix(mon_x, mon_y);
      if ({vid_r, vid_g, vid_b} !== e) begin
        if (mon_bad < 8) $display("  pixel (%0d,%0d): %h, expected %h", mon_x, mon_y, {vid_r, vid_g, vid_b}, e);
        mon_bad++;
      end
      mon_pix++;
    end
    if (vid_de) mon_x++;
  end

  task automatic wait_frames(input int n);
    int f = frames;
    while (frames < f + n) @(posedge clk_vid);
  endtask

  // check one whole frame: from the next vertical sync to the one after
  task automatic check_frame(input string what);
    wait_frames(1);
    mon_bad = 0; mon_pix = 0; mon_on = 1;
    wait_frames(1);
    mon_on = 0;
    check(mon_bad == 0 && mon_pix == 1024 * 768, $sformatf("%s (%0d of %0d pixels wrong)", what, mon_bad, mon_pix));
  endtask

  // ================================================== the tests
  logic [31:0] d;
  int hs_n;

  initial begin
    for (int i = 0; i < 131072; i++) mem[i] = 64'h0;
    for (int i = 0; i < (1 << 20); i++) ref_vram[i] = 8'h0;
    for (int i = 0; i < 260; i++) ref_pal[i] = 24'h0;
    ref_pal[255] = 24'hFFFFFF; ref_pal[256] = 24'hFFFFFF; ref_pal[258] = 24'hFFFFFF;
    ref_tmp = 8'h0;

    cycles(5);
    rst = 0;
    cycles(2);

    // ---- the FCode PROM (held during the palette load, then QEMU,tcx.bin)
    bus_read(28'h0, d);           check32(d, 32'hF1081C02, "PROM word 0 (FCode header, F1 = version 3)");
    bus_read(28'h4, d);           check32(d, 32'h0000057A, "PROM word 1 (length 1402)");
    bus_read(28'h1, d, 4'b0100);  check32(d[23:16], 32'h08, "PROM byte 1");
    bus_read(28'h578, d);         check32(d[15:0], 32'h0000, "PROM: 0 past the end of the image");
    bus_read(28'h800, d);         check32(d, 32'h0, "PROM past 2 KB reads 0");
    bus_read(28'hFFFC, d);        check32(d, 32'h0, "PROM window top reads 0");

    // ---- dummy regions read 0
    bus_read(28'h0240000, d); check32(d, 0, "DHC reads 0");
    bus_read(28'h0280000, d); check32(d, 0, "ALT reads 0");
    bus_read(28'h0700000, d); check32(d, 0, "TEC reads 0");
    bus_read(28'h0301818, d); check32(d, 0, "THC24 reads 0");
    bus_read(28'h2000000, d); check32(d, 0, "24-bit plane reads 0");
    bus_read(28'hA000000, d); check32(d, 0, "control plane reads 0");
    bus_read(STIP, d);        check32(d, 0, "stippler reads 0");
    bus_read(BLIT + 28'h4, d); check32(d, 0, "blitter reads 0");

    // ---- THC
    bus_read(THC + 28'h818, d); check32(d, 32'h0200_0400, "THC_MISC after reset (VIDEN, QEMU's bit 25)");
    bus_read(THC + 28'h8FC, d); check32(d, 0, "THC cursor position reads 0 (QEMU)");

    // ---- DAC: palette read-back, overlay, control
    bus_write(DAC, {8'd255, 24'h0});
    bus_read(DAC + 28'h4, d); check32(d, 32'hFF00_0000, "palette 255 R after reset");
    bus_read(DAC + 28'h4, d); check32(d, 32'hFF00_0000, "palette 255 G after reset");
    bus_read(DAC + 28'h4, d); check32(d, 32'hFF00_0000, "palette 255 B after reset");
    bus_read(DAC, d);         check32(d, 32'h0000_0000, "DAC address autoincrement wraps to 0");
    dac_colour(8'd5, 24'h123456);
    dac_colour(8'd6, 24'hABCDEF);
    bus_write(DAC, {8'd5, 24'h0});
    bus_read(DAC + 28'h4, d); check32(d, 32'h1200_0000, "palette 5 R");
    bus_read(DAC + 28'h4, d); check32(d, 32'h3400_0000, "palette 5 G");
    bus_read(DAC + 28'h4, d); check32(d, 32'h5600_0000, "palette 5 B");
    bus_read(DAC + 28'h4, d); check32(d, 32'hAB00_0000, "palette 6 R (autoincrement)");
    bus_read(DAC, d);         check32(d, 32'h0600_0000, "DAC address mid-entry");
    bus_write(DAC, {8'd2, 24'h0});                         // overlay 2, 3: the cursor colours
    bus_write(DAC + 28'hC, 32'h1100_0000); bus_write(DAC + 28'hC, 32'h2200_0000); bus_write(DAC + 28'hC, 32'h3300_0000);
    bus_write(DAC + 28'hC, 32'hEE00_0000); bus_write(DAC + 28'hC, 32'hDD00_0000); bus_write(DAC + 28'hC, 32'hCC00_0000);
    ref_pal[258] = 24'h112233; ref_pal[259] = 24'hEEDDCC;
    bus_write(DAC, {8'd3, 24'h0});
    bus_read(DAC + 28'hC, d); check32(d, 32'hEE00_0000, "overlay 3 R");
    bus_write(DAC, {8'd4, 24'h0});
    bus_read(DAC + 28'h8, d); check32(d, 32'hFF00_0000, "Bt458 read mask resets to FF");
    bus_write(DAC + 28'h8, 32'hFF00_0000);                 // what Linux writes
    bus_write(DAC, {8'd6, 24'h0}); bus_write(DAC + 28'h8, 32'h7300_0000);
    bus_read(DAC + 28'h8, d); check32(d, 32'h7300_0000, "Bt458 command register held");

    // ---- CPU access to the frame buffer
    vram_ww(0, 32'hDEADBEEF);
    vram_ww(4, 32'h01234567);
    bus_read(VRAM, d);        check32(d, 32'hDEADBEEF, "VRAM word 0");
    bus_read(VRAM + 4, d);    check32(d, 32'h01234567, "VRAM word 1");
    check(mem[0] == 64'hDEADBEEF_01234567, "VRAM doubleword big-endian in DDR");
    vram_wb(1, 8'h5A);
    vram_wb(7, 8'hA5);
    vram_wh(10, 16'hCAFE);
    vram_wh(12, 16'hF00D);
    bus_read(VRAM + 28'h1, d, 4'b0100); check32(d, 32'hDE5ABEEF, "VRAM byte write lane 1");
    bus_read(VRAM + 28'h4, d);          check32(d, 32'h012345A5, "VRAM byte write lane 3");
    bus_read(VRAM + 28'h8, d);          check32(d, 32'h0000CAFE, "VRAM half write, low half");
    bus_read(VRAM + 28'hC, d);          check32(d, 32'hF00D0000, "VRAM half write, high half");
    bus_write64(VRAM + 28'h10, 64'h0011223344556677);
    for (int i = 0; i < 8; i++) ref_vram[16 + i] = 8'(i * 8'h11);
    bus_read(VRAM + 28'h14, d);         check32(d, 32'h44556677, "VRAM doubleword store, low word");
    vram_ww(20'hFFFFC, 32'h89ABCDEF);
    bus_read(VRAM + 28'hFFFFC, d);      check32(d, 32'h89ABCDEF, "VRAM top word");
    bus_read(28'h0900000, d);           check32(d, 0, "past VRAM reads 0");
    check_vram(0, 64, "VRAM model after CPU writes");

    // ---- blitter and stippler, fixed cases (console scroll and clears)
    for (int i = 0; i < 4096; i++) vram_wb(20'h10000 + i, 8'($urandom));
    set_colour(8'h3C);
    do_fill(20'h20000, 32);
    do_fill(20'h20103, 1);
    do_fill(20'h20205, 13, 1);
    do_copy(20'h30000, 20'h10000, 32);                     // aligned
    do_copy(20'h30101, 20'h10007, 32);                     // src ahead of dst in the word
    do_copy(20'h30207, 20'h10001, 32);                     // dst ahead
    do_copy(20'h30300, 20'h10003, 5);
    do_copy(20'h10400, 20'h10410, 32);                     // overlap, dst below (scroll up)
    do_copy(20'h10510, 20'h10500, 32);                     // overlap, dst above
    do_copy(20'h10603, 20'h10604, 32, 1);
    do_stip(20'h40000, 32'h8000_0001);
    do_stip(20'h40105, 32'hF0F0_A5A5, 1);
    do_stip64(20'h40207, 8'h77, 32'hFFFF_FFFF);
    bus_write64(BLIT + 28'(20'h40300 << 3), {32'h0000_0099, 3'd0, 5'd6, 24'hFFFFFF});   // colour and fill in one store
    ref_tmp = 8'h99;
    for (int i = 0; i < 7; i++) ref_vram[20'h40300 + i] = 8'h99;
    sync_engine();
    check_vram(20'h10000, 20'h11000, "blit sources and overlapping copies");
    check_vram(20'h20000, 20'h20300, "fills");
    check_vram(20'h30000, 20'h30400, "copies at every alignment");
    check_vram(20'h40000, 20'h40400, "stipples");

    // ---- random operations against the model, scan-out running
    for (int n = 0; n < 400; n++) begin
      int p = 20'h50000 + ($urandom % 8192);
      int q = 20'h50000 + ($urandom % 8192);
      case ($urandom % 6)
        0: set_colour(8'($urandom));
        1: do_fill(p, 1 + $urandom % 32, $urandom % 2);
        2, 3: do_copy(p, q, 1 + $urandom % 32, $urandom % 2);
        4: do_stip(p, $urandom, $urandom % 2);
        default: vram_wb(p, 8'($urandom));
      endcase
    end
    sync_engine();
    check_vram(20'h50000, 20'h52020, "400 random blits, stipples and stores");

    // ---- scan-out: a pattern, a palette, the cursor
    wait_pct = 20;
    for (int y = 0; y < 768; y++)
      for (int x = 0; x < 1024; x++) ref_vram[y * 1024 + x] = 8'((x >> 2) ^ (y * 3));
    for (int w = 0; w < 98304; w++)
      for (int b = 0; b < 8; b++) mem[w][8 * (7 - b) +: 8] = ref_vram[w * 8 + b];
    for (int i = 0; i < 256; i++) dac_colour(8'(i), {8'(i), 8'(~i), 8'(i * 7)});
    for (int r = 0; r < 32; r++) begin
      m_mask[r] = r < 16 ? 32'hFFFF_0000 >> r : 32'h0F0F_F0F0;
      m_bits[r] = 32'hAAAA_5555 ^ 32'(r);
      bus_write(THC + 28'h900 + 28'(4 * r), m_mask[r]);
      bus_write(THC + 28'h980 + 28'(4 * r), m_bits[r]);
    end
    m_cx = 16'd100; m_cy = 16'd50; m_rm = 8'hFF;
    bus_write(THC + 28'h8FC, {m_cx, m_cy});
    check_frame("frame 1: pattern through the palette, cursor at (100,50)");

    // cursor at the bottom right corner, half off; read mask 0x0F
    m_cx = 16'd1010; m_cy = 16'd750; m_rm = 8'h0F;
    bus_write(THC + 28'h8FC, {m_cx, m_cy});
    bus_write(DAC, {8'd4, 24'h0}); bus_write(DAC + 28'h8, 32'h0F00_0000);
    check_frame("frame 2: cursor clipped at (1010,750), read mask 0F");

    // retrace interrupt
    bus_write(THC + 28'h818, 32'h0000_0420);               // VIDEN, INTEN
    wait_frames(1);
    cycles(20);
    check(irq, "vertical retrace interrupt");
    bus_read(THC + 28'h818, d); check32(d, 32'h0200_0430, "THC_MISC INTR set");
    bus_write(THC + 28'h818, 32'h0000_0410);               // ack, INTEN off
    check(!irq, "interrupt cleared");
    bus_read(THC + 28'h818, d); check32(d, 32'h0200_0400, "THC_MISC INTR cleared by writing 1");

    // video disabled: black
    bus_write(THC + 28'h818, 32'h0000_0000);
    mon_blank = 1;
    check_frame("frame 3: VIDEN off, blank");

    // sync pulses keep running: count hsyncs in one frame
    hs_n = 0;
    wait_frames(1);
    fork
      begin wait_frames(1); end
      forever begin @(posedge vid_hs); hs_n++; end
    join_any
    disable fork;
    check(hs_n == 806, $sformatf("806 lines a frame (%0d)", hs_n));

    check(ddr_errors == 0, "DDR model: Avalon rules held, addresses in VRAM");
    tb_done("tb_tcx");
  end

  initial begin
    #400ms;
    $display("FAIL: timeout");
    $fatal(1, "timeout");
  end

endmodule
