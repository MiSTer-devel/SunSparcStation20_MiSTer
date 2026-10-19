// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_cs4231: the slot-3 audio (CS4231A codec + APC DMA + FCode PROM)
// against the CS4231A data sheet and the drivers' sequences: the FCode
// header, the codec's initialization and register file (Linux's probe,
// NetBSD's attach), MCE/ACAL, the write protections, APC playback of
// buffers from a behavioural DVMA memory in every format with the samples
// checked at the output, the next-pair handover and its interrupts as
// NetBSD's and Linux's handlers use them, NetBSD's halt (PPAUSE/PM),
// Linux's stop, capture of silence, the codec timer and pin (EI), a DVMA
// error, APC RESET and codec power down.

module tb_cs4231;
  import iobus_pkg::*;
  import mem_pkg::*;
  import sbus_pkg::*;
  import tb_pkg::*;

  localparam int CLK_HZ = 5_000_000;            // a slow clock: short sample periods
  localparam int P48 = CLK_HZ / 48000;          // cycles per sample at 48 kHz
  localparam int P8  = CLK_HZ / 8000;

  logic clk, rst;
  initial begin clk = 0; rst = 1; end
  always #5 clk = ~clk;

  iob_req_t  req = IOB_REQ_IDLE;
  iob_rsp_t  rsp;
  dvma_req_t dq;
  mem_rsp_t  dr;
  logic      irq;
  logic signed [15:0] aud_l, aud_r;

  cs4231 #(.CLK_HZ(CLK_HZ)) dut (
    .clk, .rst, .bus_i(req), .bus_o(rsp), .dvma_o(dq), .dvma_i(dr),
    .irq_o(irq), .audio_l_o(aud_l), .audio_r_o(aud_r));

  // ---- offsets ----------------------------------------------------------
  localparam logic [27:0] CS = 28'hC00_0000;
  localparam logic [27:0] CSR = CS + 28'h10, CVA = CS + 28'h20, CC = CS + 28'h24,
                          CNVA = CS + 28'h28, CNC = CS + 28'h2C, PVA = CS + 28'h30,
                          PC = CS + 28'h34, PNVA = CS + 28'h38, PNC = CS + 28'h3C;
  localparam logic [31:0] IP = 32'h0080_0000, PI = 32'h0040_0000, CI = 32'h0020_0000,
                          EI = 32'h0010_0000, IE = 32'h0008_0000, PIE = 32'h0004_0000,
                          CIE = 32'h0002_0000, EIE = 32'h0001_0000, PMI = 32'h0000_8000,
                          PM = 32'h0000_4000, PD = 32'h0000_2000, PMIE = 32'h0000_1000,
                          CM = 32'h0000_0800, CD = 32'h0000_0400, CMI = 32'h0000_0200,
                          PPAUSE = 32'h80, CPAUSE = 32'h40, PDN = 32'h20, PGO = 32'h8,
                          CGO = 32'h4, ARST = 32'h1;
  localparam logic [31:0] INTR_MASK = IP | PI | CI | EI | PMI | CMI;

  // ---- behavioural DVMA memory -------------------------------------------
  // Bytes by VA; VAs at 0xE000_0000 and up answer err. Random latency.
  logic [7:0] mem [logic [31:0]];
  int  maxlat = 3, wcnt;
  bit  fin;
  int  nrd, nwr, nbad;
  dvma_req_t held;

  function automatic logic [7:0] mb(input logic [31:0] a);
    return mem.exists(a) ? mem[a] : 8'h00;
  endfunction

  /* verilator lint_off BLKSEQ */
  always @(posedge clk) begin
    dr <= '0;
    if (rst) begin
      wcnt = -1; fin = 0; nrd = 0; nwr = 0; nbad = 0;
    end else if (fin) begin
      fin = 0;                                  // the ack cycle: the request still shows
    end else if (dq.valid) begin
      if (wcnt < 0) begin
        wcnt = $urandom_range(0, maxlat);
        held = dq;
        // the APC's requests: a doubleword read or a one-byte write, no bursts
        if (dq.burst) nbad++;
        if (!dq.write && (dq.be != 8'hFF || dq.va[2:0] != 3'd0)) nbad++;
        if (dq.write && dq.be != (8'h80 >> dq.va[2:0])) nbad++;
      end
      if (dq != held) nbad++;                   // fields held until the ack
      if (wcnt == 0) begin
        logic [63:0] d;
        bit e;
        e = (dq.va >= 32'hE000_0000);
        d = '0;
        for (int b = 0; b < 8; b++) begin
          logic [31:0] a;
          a = {dq.va[31:3], 3'b000} + 32'(b);
          if (dq.write && dq.be[7 - b] && !e) mem[a] = dq.wdata[8*(7-b) +: 8];
          d[8*(7-b) +: 8] = mb(a);
        end
        if (dq.write) nwr++; else nrd++;
        dr <= '{ack: 1'b1, err: e, rdata: (dq.write || e) ? 64'h0 : d};
        fin = 1;
        wcnt = -1;
      end else wcnt--;
    end
  end
  /* verilator lint_on BLKSEQ */

  // ---- the output, one entry per played sample period ---------------------
  typedef struct packed { logic signed [15:0] l; logic signed [15:0] r; } smp_t;
  smp_t outq [$];
  logic [1:0] tick_d;
  longint cyc;
  always @(posedge clk) cyc <= rst ? 0 : cyc + 1;
  always @(posedge clk) begin
    tick_d <= {tick_d[0], dut.play_tick};
    if (tick_d[1]) outq.push_back('{aud_l, aud_r});
  end

  // ---- bus functional models -------------------------------------------
  task automatic cycles(input int n);
    repeat (n) @(posedge clk);
    #1;
  endtask

  task automatic bus(input bit we, input logic [27:0] a, input logic [3:0] be,
                     input logic [31:0] wd, output logic [31:0] rd);
    req = '{req: 1'b1, we: we, addr: a, be: be, wdata: wd, pair: 1'b0};
    do cycles(1); while (!rsp.ack);
    if (rsp.err) check(0, $sformatf("bus %08x: err", a));
    rd = rsp.rdata;
    req = IOB_REQ_IDLE;
  endtask

  logic [31:0] dummy;
  task automatic wr32(input logic [27:0] a, input logic [31:0] v);
    bus(1, a, 4'hF, v, dummy);
  endtask
  task automatic rd32(input logic [27:0] a, output logic [31:0] v);
    bus(0, a, 4'hF, 32'h0, v);
  endtask

  // codec: byte accesses at CS + 4n (lane 0 = bits 31:24), as sbus_readb
  logic [7:0] mce_bit = 8'h00;
  task automatic cw(input int n, input logic [7:0] v);
    bus(1, CS + 28'(4*n), 4'b1000, {v, 24'h0}, dummy);
  endtask
  task automatic cr(input int n, output logic [7:0] v);
    logic [31:0] w;
    bus(0, CS + 28'(4*n), 4'b1000, 32'h0, w);
    v = w[31:24];
  endtask
  task automatic iw(input int i, input logic [7:0] v);
    cw(0, mce_bit | 8'(i));
    cw(1, v);
  endtask
  task automatic ird(input int i, output logic [7:0] v);
    cw(0, mce_bit | 8'(i));
    cr(1, v);
  endtask
  task automatic expect_i(input int i, input logic [7:0] e, input string what);
    logic [7:0] v;
    ird(i, v);
    check32({24'h0, v}, {24'h0, e}, what);
  endtask
  task automatic mce_up();
    mce_bit = 8'h40;
    cw(0, 8'h40);
  endtask
  task automatic mce_down();
    logic [7:0] v;
    mce_bit = 8'h00;
    cw(0, 8'h00);
    // Linux's mce_down: wait for ACI (I11) to clear
    for (int t = 0; t < 2000; t++) begin
      ird(11, v);
      if (!v[5]) break;
      cycles(100);
    end
  endtask

  task automatic wait_irq(input int bound, input string what);
    int t = 0;
    while (!irq && t < bound) begin cycles(1); t++; end
    check(irq, what);
  endtask

  task automatic wait_csr(input logic [31:0] bit_, input int bound, input string what);
    logic [31:0] v;
    int t = 0;
    do begin rd32(CSR, v); t++; end while ((v & bit_) == 0 && t < bound);
    check((v & bit_) != 0, what);
  endtask

  // the samples played since the queue was cleared, without the silence
  // before the first frame
  task automatic played(output smp_t s [$]);
    s = outq;
    while (s.size() > 0 && s[0] == '0) void'(s.pop_front());
  endtask

  task automatic put16(input logic [31:0] a, input logic [15:0] v);  // big endian
    mem[a] = v[15:8];
    mem[a + 1] = v[7:0];
  endtask

  // ---- reference values ---------------------------------------------------
  function automatic logic signed [15:0] lsmp(input int i); return 16'(16'h1000 + 16'(i * 16'h0111)); endfunction
  function automatic logic signed [15:0] rsmp(input int i); return 16'(-(16'sh0800 + 16'(i * 16'h0023))); endfunction

  // one buffer of nb bytes (by: first byte in bits 63:56) in format fmt
  // at 48 kHz; the first nf samples played must be ex[3], ex[2], ...
  task automatic fmt_case(input logic [7:0] fmt, input int nb, input logic [63:0] by,
                          input int nf, input string name, input smp_t [3:0] ex);
    logic [31:0] cv;
    smp_t q [$];
    bit ok;
    mce_up(); iw(8, fmt); mce_down();
    for (int i = 0; i < nb; i++) mem[32'h0004_0000 + 32'(i)] = by[8*(7-i) +: 8];
    wr32(PNVA, 32'h0004_0000); wr32(PNC, 32'(nb));
    outq.delete();
    iw(9, 8'h01);
    wait_irq(10 * P48, {name, ": buffer done"});
    rd32(CSR, cv); wr32(CSR, cv);
    cycles(2 * P48);
    iw(9, 8'h00);
    played(q);
    ok = (q.size() >= nf);
    for (int i = 0; i < nf && ok; i++) ok &= (q[i] == ex[3 - i]);
    check(ok, {name, ": decoded samples"});
    if (!ok) foreach (q[i]) $display("  %0d: %0d %0d", i, q[i].l, q[i].r);
  endtask

  localparam logic [31:0] BA = 32'h0001_0000, BB = 32'h0002_0002, BC = 32'h0003_0004;

  logic [31:0] v, c;
  logic [7:0]  b;
  smp_t s [$];
  int   t0;

  initial begin
    cycles(3);
    rst = 0;
    cycles(2);

    // ===== FCode PROM =========================================================
    rd32(28'h0, v);   check32(v, 32'hF108_0D7C, "FCode: start1, format, checksum");
    rd32(28'h4, v);   check32(v, 32'h0000_0060, "FCode: length 96");
    rd32(28'h8, v);   check32(v, 32'h120B_5355, "FCode: b-quote, length 11, S U");
    rd32(28'hC, v);   check32(v, 32'h4E57_2C43, "FCode: NW,C");
    rd32(28'h5C, v);  check32(v, 32'h7201_1000, "FCode: the last word (property, end0)");
    rd32(28'h60, v);  check32(v, 32'h0, "FCode: 0 past the image");
    rd32(28'h7FC, v); check32(v, 32'h0, "FCode window end reads 0");
    rd32(28'h800, v); check32(v, 32'h0, "past the FCode window reads 0");
    rd32(28'h100_0000, v); check32(v, 32'h0, "empty slot space reads 0");
    rd32(CS + 28'h40, v);  check32(v, 32'h0, "past the 0x40-byte register window reads 0");
    rd32(CS + 28'h14, v);  check32(v, 32'h0, "APC pad word reads 0");

    // ===== initialization ======================================================
    cr(0, b); check32({24'h0, b}, 32'h80, "initializing: R0 reads 0x80");
    cr(1, b); check32({24'h0, b}, 32'h80, "initializing: R1 reads 0x80");
    cr(2, b); check32({24'h0, b}, 32'h80, "initializing: R2 reads 0x80");
    t0 = int'(cyc);
    do begin cr(0, b); cycles(10); end while (b == 8'h80 && cyc < 400000);
    t0 = int'(cyc) - t0;
    check32({24'h0, b}, 32'h40, "after initialization R0 = 010x0000 (MCE set)");
    check(t0 > 160 * P8 && t0 < 176 * P8, $sformatf("initialization ~168 periods at 8 kHz (%0d cycles)", t0));
    rd32(CSR, v); check32(v, PM | PD | CM | CD, "APC CSR after reset: pipes empty");
    check(!irq, "no interrupt after reset");

    // ===== registers: MODE 1, Linux's probe, NetBSD's attach ===================
    mce_bit = 8'h40;
    expect_i(12, 8'h8A, "I12 MODE 1: 10xx1010");
    expect_i(9, 8'h08, "I9 reset 00x01000");
    expect_i(6, 8'h80, "I6 reset: DAC muted");
    expect_i(2, 8'h88, "I2 reset 1xx01000");
    iw(0, 8'h5A);
    cw(0, 8'h50);                               // IA4 in MODE 1
    cr(0, b); check32({24'h0, b}, 32'h40, "MODE 1: IA4 reads 0");
    cr(1, b); check32({24'h0, b}, 32'h5A, "MODE 1: index 16 aliases I0");
    // Linux snd_cs4231_probe: MODE2, I12 & 0x0f == 0x0a, version
    iw(12, 8'h40);
    expect_i(12, 8'hCA, "MODE 2 set: I12 = 0xCA (ID 0xA for Linux)");
    expect_i(25, 8'hA0, "I25: CS4231A (version 101, chip 000)");
    iw(25, 8'h00); expect_i(25, 8'hA0, "I25 read-only");
    iw(11, 8'hFF); expect_i(11, 8'h00, "I11 read-only");
    iw(12, 8'hFF); expect_i(12, 8'hCA, "I12: only MODE2 writable");
    cw(0, 8'h50);
    cr(0, b); check32({24'h0, b}, 32'h50, "MODE 2: IA4 reads back");
    iw(16, 8'h00); expect_i(16, 8'h00, "MODE 2: I16 distinct from I0");
    expect_i(0, 8'h5A, "I0 kept");
    // NetBSD's attach writes and reads back the mixer and pin registers
    begin
      bit ok = 1;
      int regs[10] = '{0, 1, 2, 3, 4, 5, 13, 18, 19, 26};
      foreach (regs[k]) begin
        iw(regs[k], 8'hA5 ^ 8'(k)); ird(regs[k], b); ok &= (b == (8'hA5 ^ 8'(k)));
        iw(regs[k], 8'h5A ^ 8'(k)); ird(regs[k], b); ok &= (b == (8'h5A ^ 8'(k)));
      end
      check(ok, "mixer registers read back what was written");
    end
    iw(10, 8'h00);
    expect_i(10, 8'h00, "I10 pin control RW");
    // byte lanes: a word read returns the register in every lane; a word
    // write takes bits 7:0
    cw(0, 8'h40 | 8'd25);
    rd32(CS + 28'h4, v); check32(v, 32'hA0A0_A0A0, "codec word read: every lane");
    wr32(CS, 32'h0000_0040 | 32'd13);
    wr32(CS + 28'h4, 32'h0000_0033);
    expect_i(13, 8'h33, "codec word write: bits 7:0");
    iw(13, 8'h00);

    // ===== MCE / calibration ====================================================
    iw(9, 8'h08);                               // CAL = 01 (converter, 136 periods)
    expect_i(9, 8'h08, "I9 CAL written under MCE");
    mce_bit = 8'h00;
    cw(0, 8'h00);
    ird(11, b); check(b[5], "MCE 1 -> 0: ACI set");
    t0 = int'(cyc);
    do begin ird(11, b); cycles(10); end while (b[5] && int'(cyc) - t0 < 400000);
    t0 = int'(cyc) - t0;
    check(!b[5], "ACI clears");
    check(t0 > 130 * P8 && t0 < 145 * P8, $sformatf("converter calibration ~136 periods (%0d cycles)", t0));
    cw(0, 8'h00);
    ird(11, b); check(!b[5], "MCE already 0: no calibration");
    // write protection without MCE
    iw(8, 8'hFF); expect_i(8, 8'h00, "I8 needs MCE or PMCE");
    iw(9, 8'hF8); expect_i(9, 8'h08, "I9 upper bits need MCE");
    iw(9, 8'h0B); expect_i(9, 8'h0B, "I9 PEN/CEN change any time");
    iw(9, 8'h08);
    iw(16, 8'h10);                              // PMCE
    iw(8, 8'h5F); expect_i(8, 8'h50, "PMCE: only the I8 format bits change");
    iw(28, 8'hF0); expect_i(28, 8'h00, "I28 needs MCE or CMCE");
    iw(16, 8'h20);                              // CMCE
    iw(28, 8'h3F); expect_i(28, 8'h30, "CMCE: I28 format bits");
    iw(16, 8'h00);
    mce_up();
    iw(9, 8'h00);                               // no calibration from here on
    iw(8, 8'hDC);                               // 16-bit BE stereo, 48 kHz
    iw(28, 8'h00);
    mce_down();
    expect_i(8, 8'hDC, "I8 written under MCE");
    cr(0, b); check(!b[6], "MCE clear");
    ird(11, b); check(!b[5], "CAL = 0: no calibration");

    // ===== playback: the double-buffered handover (NetBSD) ======================
    for (int i = 0; i < 8; i++) begin put16(BA + 32'(4*i), lsmp(i));     put16(BA + 32'(4*i + 2), rsmp(i)); end
    for (int i = 0; i < 4; i++) begin put16(BB + 32'(4*i), lsmp(8 + i)); put16(BB + 32'(4*i + 2), rsmp(8 + i)); end
    for (int i = 0; i < 2; i++) begin put16(BC + 32'(4*i), lsmp(12 + i)); put16(BC + 32'(4*i + 2), rsmp(12 + i)); end
    iw(6, 8'h00); iw(7, 8'h00);                 // 0 dB, unmuted
    iw(15, 8'd3); iw(14, 8'd0);                 // codec PI every 4 frames
    iw(10, 8'h00);
    // trigger_output: next pair, then GO
    wr32(PNVA, BA); wr32(PNC, 32);
    rd32(CSR, v);
    check((v & PD) == 0, "next pair loaded: PD = 0");
    check((v & PM) != 0, "GO clear: PM");
    v = v & ~(PPAUSE | PMIE | INTR_MASK);
    wr32(CSR, v);
    rd32(CSR, v);
    v = (v & ~INTR_MASK) | EI | IE | EIE | PIE | PMIE | PGO;
    wr32(CSR, v);
    rd32(CSR, v);
    check((v & (PD | PM | PI)) == PD, "GO: the next pair moves in at once (PD, no PI, not PM)");
    rd32(PVA, c); check32(c, BA, "PVA = the first buffer");
    rd32(PC, c);  check32(c, 32, "PC = its count");
    wr32(PNVA, BB); wr32(PNC, 16);
    rd32(CSR, v); check((v & PD) == 0, "second pair loaded behind it");
    check(!irq, "no interrupt yet");
    outq.delete();
    nrd = 0;
    iw(9, 8'h01);                               // PEN
    // interrupt 1: buffer A done, B moved in
    wait_irq(20 * P48, "PI after the first buffer");
    t0 = int'(cyc);
    rd32(CSR, v);
    check((v & (IP | PI | PD)) == (IP | PI | PD) && (v & PMI) == 0, $sformatf("first buffer done: IP PI PD, no PMI (%08x)", v));
    rd32(PVA, c); check(c >= BB && c <= BB + 16, "PVA in the second buffer");
    cr(2, b); check(b[0], "codec R2 INT (PI after 4 frames)");
    ird(24, b); check(b[4], "I24 PI");
    cw(2, 8'h00);
    cr(2, b); check(!b[0], "a write to R2 clears INT");
    wr32(CSR, v);                               // the handler: write back to clear
    check(!irq, "written back: interrupt cleared");
    wr32(PNVA, BC); wr32(PNC, 8);
    // interrupt 2: buffer B done, C moved in
    wait_irq(10 * P48, "PI after the second buffer");
    t0 = int'(cyc) - t0;
    // the pace: buffer B is 4 frames, one a sample period at 48 kHz
    check(t0 > 3 * P48 && t0 < 5 * P48, $sformatf("buffer B (4 frames) played in ~4 periods at 48 kHz (%0d cycles, P48 %0d)", t0, P48));
    rd32(CSR, v);
    check((v & (PI | PD | PMI)) == (PI | PD), $sformatf("second buffer done: PI PD, no PMI (%08x)", v));
    wr32(CSR, v);
    // interrupt 3: C done, nothing next: PI and PMI, the pipe empty
    wait_irq(6 * P48, "PI after the last buffer");
    rd32(CSR, v);
    check((v & (PI | PD | PMI | PM)) == (PI | PD | PMI | PM), "last buffer done: PI PMI PM");
    wr32(CSR, v);
    check(!irq, "cleared");
    cycles(4 * P48);
    played(s);
    begin
      bit ok = (s.size() >= 16);
      for (int i = 0; i < 14 && ok; i++) ok &= (s[i].l == lsmp(i) && s[i].r == rsmp(i));
      for (int i = 14; i < s.size() && ok; i++) ok &= (s[i] == s[13]);
      check(ok, "16-bit BE stereo: 14 frames from 3 buffers in order, then the last held (DACZ = 0)");
      if (!ok) foreach (s[i]) $display("  %0d: %04x %04x", i, s[i].l, s[i].r);
    end
    check(nrd >= 7 && nrd <= 9, $sformatf("doubleword reads: %0d for 56 bytes over 3 buffers", nrd));
    ird(11, b); check(b[6], "underrun: I11 PUR");
    ird(24, b); check(b[0], "underrun: I24 PU");
    cr(2, b);   check(b[4], "underrun: R2 SER");
    cr(2, b);   check(!b[4], "reading R2 cleared PUR");
    iw(16, 8'h01);                              // DACZ
    outq.delete();
    cycles(3 * P48);
    check(outq.size() >= 2 && outq[outq.size() - 1] == '0, "DACZ: an underrun plays 0");
    iw(16, 8'h00);
    iw(24, 8'h00);

    // ===== NetBSD halt_output: PPAUSE lets the current pair finish ===============
    outq.delete();
    wr32(PNVA, BA); wr32(PNC, 32);              // GO set, pipe empty: moves in
    rd32(CSR, v); check((v & (PD | PI)) == PD, "a pair written to an idle GO channel moves in, no PI");
    wr32(PNVA, BB); wr32(PNC, 16);
    rd32(CSR, v);
    wr32(CSR, (v & ~INTR_MASK) | PPAUSE);
    wait_csr(PM, 2000, "PPAUSE: PM once the current pair is done");
    rd32(CSR, v);
    check((v & PD) == 0, "paused: the next pair stays loaded");
    rd32(PC, c); check32(c, 0, "the current pair ran out");
    check(irq && (v & PMI) != 0 && (v & PI) != 0, "the paused end raises PI and PMI");
    cycles(3 * P48);
    played(s);
    check(s.size() >= 8 && s[7].l == lsmp(7) && s[s.size() - 1].l == lsmp(7),
          "paused: buffer A played to its end, B not started");
    iw(9, 8'h00);                               // PEN off
    wr32(CSR, v);
    // Linux's stop: zero the pairs, pause, GO off
    wr32(PNC, 0); wr32(PNVA, 0); wr32(PC, 0); wr32(PVA, 0);
    rd32(CSR, v);
    check((v & (PD | PM)) == (PD | PM), "Linux stop: both pairs empty");
    wr32(CSR, v & ~(PGO | INTR_MASK));
    wr32(CSR, (v & ~(PPAUSE | INTR_MASK)) | PGO);
    check(!irq, "no interrupt from the stop");

    // ===== the formats ============================================================
    fmt_case(8'h2C, 4, 64'h8000_8F2A_0000_0000, 4, "u-law mono",
             {smp_t'({16'sd32124, 16'sd32124}), smp_t'({-16'sd32124, -16'sd32124}),
              smp_t'({16'sd16764, 16'sd16764}), smp_t'({-16'sd5372, -16'sd5372})});
    fmt_case(8'h7C, 4, 64'hD555_AA2A_0000_0000, 2, "A-law stereo",
             {smp_t'({16'sd8, -16'sd8}), smp_t'({16'sd32256, -16'sd32256}), smp_t'(0), smp_t'(0)});
    fmt_case(8'h1C, 4, 64'h00FF_C040_0000_0000, 2, "8-bit unsigned stereo",
             {smp_t'({-16'sd32768, 16'sd32512}), smp_t'({16'sd16384, -16'sd16384}), smp_t'(0), smp_t'(0)});
    fmt_case(8'h4C, 6, 64'h3412_CDAB_0180_0000, 3, "16-bit LE mono",
             {smp_t'({16'sh1234, 16'sh1234}), smp_t'({-16'sh5433, -16'sh5433}),
              smp_t'({-16'sh7FFF, -16'sh7FFF}), smp_t'(0)});

    // ===== the DAC attenuation and mute =========================================
    mce_up(); iw(8, 8'hDC); mce_down();
    put16(32'h0004_0000, 16'h4000); put16(32'h0004_0002, 16'h4000);
    iw(6, 8'h08);                               // -12 dB
    iw(7, 8'h80);                               // right muted
    wr32(PNVA, 32'h0004_0000); wr32(PNC, 4);
    outq.delete();
    iw(9, 8'h01);
    wait_irq(10 * P48, "attenuation: buffer done");
    rd32(CSR, v); wr32(CSR, v);
    cycles(2 * P48);
    played(s);
    check(s.size() > 0 && s[0].l == 16'sd4115 && s[0].r == 16'sd0,
          $sformatf("I6 -12 dB: 0x4000 -> 4115; I7 mute -> 0 (got %0d %0d)", s[0].l, s[0].r));
    iw(9, 8'h00);
    iw(6, 8'h00); iw(7, 8'h00);
    iw(14, 8'h00); iw(15, 8'h00);

    // ===== capture: silence at the sample rate =====================================
    for (int i = 0; i < 6; i++) mem[32'h0005_0000 + 32'(i)] = 8'h11;
    for (int i = 0; i < 3; i++) mem[32'h0005_0100 + 32'(i)] = 8'h11;
    mce_up(); iw(28, 8'h20); mce_down();        // u-law mono capture
    iw(31, 8'd1); iw(30, 8'd0);                 // codec CI every 2 frames
    wr32(CNVA, 32'h0005_0000); wr32(CNC, 6);
    rd32(CSR, v);
    wr32(CSR, (v & ~(CPAUSE | INTR_MASK)) | IE | EIE | CIE | CGO);
    rd32(CSR, v); check((v & (CD | CM)) == CD, "capture GO: the pair moves in");
    wr32(CNVA, 32'h0005_0100); wr32(CNC, 3);
    nwr = 0;
    iw(9, 8'h02);                               // CEN
    wait_irq(12 * P48, "CI after the first capture buffer");
    rd32(CSR, v);
    check((v & (CI | CD | CMI)) == (CI | CD), $sformatf("capture buffer done: CI CD (%08x)", v));
    wr32(CSR, v);
    begin
      bit ok = 1;
      for (int i = 0; i < 6; i++) ok &= (mb(32'h0005_0000 + 32'(i)) == 8'hFF);
      check(ok, "capture: u-law silence (0xFF) written");
    end
    ird(24, b); check(b[5], "codec I24 CI");
    cr(2, b); check(b[0], "codec INT from CI");
    cw(2, 8'h00);
    // NetBSD halt_input: CPAUSE, wait for CM
    rd32(CSR, v);
    wr32(CSR, (v & ~INTR_MASK) | CPAUSE);
    wait_csr(CM, 2000, "CPAUSE: CM once the current capture pair is done");
    check(mb(32'h0005_0102) == 8'hFF && mb(32'h0005_0103) == 8'h00, "the second buffer filled, no more");
    check(nwr == 9, $sformatf("9 one-byte writes (%0d)", nwr));
    rd32(CSR, v);
    check((v & CMI) != 0, "paused end: CMI");
    cycles(3 * P48);                            // CEN on, no buffer: overruns
    iw(9, 8'h00);
    wr32(CSR, (v & ~(CPAUSE | CGO | CIE)) | (v & INTR_MASK));
    ird(11, b); check(b[7], "capture overrun while no buffer: COR");
    cr(2, b); cr(2, b);

    // ===== the codec timer and interrupt pin -> EI ==================================
    rd32(CSR, v); wr32(CSR, v);
    check(!irq, "quiet before the timer");
    iw(21, 8'h00); iw(20, 8'h02);
    cw(2, 8'h00);
    iw(10, 8'h02);                              // IEN
    iw(16, 8'h40);                              // TE
    wait_irq(8 * CLK_HZ / 100000, "timer: TI through the pin sets EI");
    rd32(CSR, v); check((v & (EI | IP)) == (EI | IP), "CSR EI, IP");
    ird(24, b); check(b[6], "I24 TI");
    iw(16, 8'h00);
    cw(2, 8'h00);
    wr32(CSR, v);
    check(!irq, "EI cleared, codec INT cleared");
    cycles(8 * CLK_HZ / 100000);
    check(!irq, "no new EI with the timer off");
    iw(10, 8'h00);

    // ===== a DVMA error ================================================================
    wr32(PNVA, 32'hE000_0000); wr32(PNC, 64);
    iw(9, 8'h01);
    wait_irq(4 * P48, "DVMA error: an interrupt");
    rd32(CSR, v);
    check((v & (EI | PM)) == (EI | PM) && (v & PI) == 0, "DVMA error: EI, the pair dropped (PM), no PI");
    iw(9, 8'h00);
    wr32(CSR, v);

    // ===== APC RESET ====================================================================
    wr32(PNVA, BA); wr32(PNC, 32); wr32(PNVA, BB); wr32(PNC, 16);
    rd32(CSR, v); check((v & (PD | PM)) == 0, "two pairs loaded");
    wr32(CSR, v | ARST);
    wr32(CSR, v & ~(ARST | INTR_MASK));
    rd32(CSR, v); check((v & (PD | PM | INTR_MASK)) == (PD | PM), "RESET empties the pairs");

    // ===== codec power down (CSR PDN) =====================================================
    wr32(CSR, PDN);
    cr(0, b); check32({24'h0, b}, 32'h80, "PDN: R0 reads 0x80");
    cw(0, 8'h0C); cw(1, 8'h00);
    wr32(CSR, 32'h0);
    t0 = 0;
    do begin cr(0, b); cycles(50); t0 += 60; end while (b == 8'h80 && t0 < 400000);
    check32({24'h0, b}, 32'h40, "after PDN: R0 = 0x40");
    mce_bit = 8'h40;
    expect_i(12, 8'h8A, "after PDN: registers at reset (MODE 1)");
    expect_i(8, 8'h00, "after PDN: I8 reset");

    check(nbad == 0, $sformatf("DVMA protocol: %0d violations", nbad));
    tb_done("tb_cs4231");
  end

  initial begin
    #100ms;
    $display("FAIL: timeout");
    $fatal(1, "timeout");
  end

endmodule
