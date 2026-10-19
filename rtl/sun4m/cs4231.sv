// SPDX-License-Identifier: GPL-2.0-or-later
//
// cs4231: the SS20's audio "card" in SBus slot 3: the SPARCstation 5's
// on-board audio, a Crystal CS4231A codec behind Sun's APC DMA controller,
// with an FCode PROM of our own so a Sun OBP finds it (SUNW,CS4231).
//
// From: Crystal CS4231A data sheet DS139PP2 (the direct registers R0-R3,
//   the indirect registers I0-I31, MODE 2, calibration, power down and
//   initialization, the DMA count registers, interrupts, error
//   conditions, the formats, the sample-frequency table); the APC as its
//   drivers describe it (no Sun specification is known): NetBSD
//   dev/ic/apcdmareg.h and dev/sbus/cs4231_sbus.c, OpenBSD dev/sbus/cs4231.c,
//   Linux sound/sparc/cs4231.c; QEMU hw/audio/cs4231.c (a register stub:
//   the 0x40-byte window, I12 = 0x8A, I25 = 0xA0); OpenBIOS
//   drivers/sbus.c ob_cs4231_init (regs at slot offset 0x0C000000, 0x40
//   bytes, SBus level 5).
//
// The slot (iob addr = offset in slot 3; every access acks, never err):
//   0x0000000-0x00007FF  FCode PROM (cs4231_fcode, tools/fcode_cs4231.py)
//   0xC000000 + 4n, n=0-3 codec R0 IAR, R1 IDR, R2 status, R3 PIO data: a
//          byte register at a word address; reads return it in every byte
//          lane, writes take the lowest enabled lane (a byte store at 4n
//          or a word store with the value in bits 7:0 both work)
//   0xC000010  APC CSR      0xC000020/24/28/2C  capture  VA, count, next VA, next count
//                           0xC000030/34/38/3C  playback VA, count, next VA, next count
//          (APC registers are whole words: the byte enables are ignored)
//   anything else reads 0 and ignores writes.
//
// The codec (MODE 1 at reset, MODE 2 when I12 bit 6 is set; IA4 and the
// indexes 16-31 only in MODE 2, else they alias 0-15):
//  - I12 reads {1, MODE2, 00, 1010} (ID 0xA: Linux insists), I25 0xA0 (a
//    CS4231A: NetBSD's name, Solaris' cs_revA), I11 {COR PUR ACI 0 0000};
//    the rest store what is written (reserved bits too), except the MCE/
//    PMCE/CMCE write protection of I8, I9, I16 and I28 (Table 3).
//  - Reset and power down: CSR PDN (bit 5) holds the codec in power down;
//    after it (and after rst) the codec initializes for 168 sample periods
//    (full calibration at the reset rate, 8 kHz: 21 ms); while down or
//    initializing R0-R3 read 0x80 and ignore writes; then the registers
//    hold their reset values (R0 = 0x40: MCE set).
//  - MCE 1 -> 0 runs the calibration I9 CAL selects: ACI (I11) is 1 for 0,
//    136, 40 or 168 sample periods. The DAC output is muted while MCE or
//    ACI is set.
//  - The sample clock is exact on average (a phase accumulator of the
//    crystal over CLK_HZ): XTAL1 24.576 MHz / XTAL2 16.9344 MHz (C2SL)
//    divided by 3072, 1536, 896, 768, 448, 384, 512, 2560 (CFS).
//  - Playback (PEN, PPIO = 0): every sample period plays the next frame the
//    APC delivered; formats 8-bit unsigned, u-law, A-law (G.711), 16-bit
//    little and big endian, mono or stereo (2 bytes a frame in 8-bit
//    stereo); ADPCM and the reserved formats consume a byte a frame and
//    play silence. A sample period with no frame is an underrun: PU (I24),
//    PUR (I11, R2 SER) and the last sample again (0 with DACZ). Each frame
//    played counts the playback current count down; the period after 0 sets
//    PI and reloads it from I14:I15 (a write to I14 loads it).
//  - Capture (CEN, CPIO = 0): there is no input; each sample period hands
//    the APC a frame of silence in the capture format (0x80, 0xFF u-law,
//    0xD5 A-law, 0 otherwise), so recording returns silence at the right
//    rate; a frame not taken before the next one is an overrun (CO, COR).
//    Counted on I30:I31 (I14:I15 in MODE 1) into CI (PI in MODE 1).
//  - The timer (TE, I20/I21; ~10 us: XTAL1/245, XTAL2/168) sets TI.
//  - R2 INT = PI | CI | TI; a write to R2 clears all three, a 0 written to
//    one in I24 clears it. TRD (R0) stops DMA transfers while INT is set.
//    The interrupt pin (INT & IEN, I10) reaches the APC as EI (below).
//  - R2 PRDY/CRDY and the L/R, U/L bits read 0; R3 (PIO) reads 0 and
//    ignores writes: PIO transfers are not modelled.
//
// The APC (CSR bits per apcdmareg.h):
//   23 IP (R)  = IE & (PI&PIE | CI&CIE | EI&EIE | PMI&PMIE | CMI&CMIE) = irq_o
//   22 PI, 21 CI, 20 EI, 15 PMI, 9 CMI: latched; writing 1 clears
//   19 IE, 18 PIE, 17 CIE, 16 EIE, 12 PMIE, 8 CMIE, 7 PPAUSE, 6 CPAUSE,
//   5 PDN (codec power down), 3 PDMA_GO, 2 CDMA_GO, 0 RESET: read/write
//   14 PM, 13 PD, 11 CM, 10 CD (R): live status
// Each direction has a current (VA, count) and a next (NVA, NC) pair. A
// write of a non-zero count makes the pair valid (NetBSD and Linux write
// NVA, then NC; 0 empties it, as Linux's stop does). While GO is set and
// not paused, the next pair moves into the current one as soon as that is
// empty: at once on an idle channel (no PI: nothing finished), else in
// the cycle the current pair's last byte goes. The codec's requests (one byte at a time; playback reads whole
// doublewords and serves bytes from them) advance VA and count down; the
// byte that empties the current pair raises PI (CI): the drivers' "block
// done, load the next one" (NetBSD: PI with PD; Linux: PI, PD, not PMI);
// if there is no next pair to move in (or the channel is paused) it also
// raises PMI (CMI). PD (CD) = the next pair is empty: the driver may load
// one. PM (CM) = the current pair is empty and none will move in (no next
// pair, paused, or GO clear): NetBSD's halt_output/halt_input pause and
// wait for it. PAUSE lets the current pair finish ("pause after the
// current", NetBSD/Linux); GO clear stops transfers where they are. EI is
// set by a DVMA error (the pair is dropped, no PI) and by a rising edge
// of the codec's interrupt pin (OpenBSD's "general interrupt": it then
// reads the codec status). RESET (while set) empties both directions and
// clears the latched interrupts; CSR's other bits stay as written.
//
// DVMA: one request at a time on dvma_o (sbus_pkg protocol): a playback
// read is one doubleword (be all ones, va[2:0] = 0), a capture write one
// byte. A frame needs at most 4 bytes, so at 48 kHz this is under 200
// thousand requests a second.
//
// Left out: PIO transfers, SDC (single DMA channel: capture uses I30/I31
// in MODE 2 regardless), loopback and the analog mixer (I0-I5, I13,
// I16-I19, I26 are stored only; only I6/I7's DAC attenuation and mute
// shape the output, not I10's XCTL line/headphone mutes or I26's mono
// mute), ADPCM decoding, the serial port, the APC's FIFO depth (the
// codec's next frame is prefetched one sample period ahead).
//
// Interface: audio_l_o/audio_r_o are signed 16-bit samples in the clk
// domain, changing at the sample rate (held between); irq_o is level, for
// SBus level 5 (SI bit 11 in the sun4m interrupt controller).

module cs4231
  import iobus_pkg::*, mem_pkg::*, sbus_pkg::*;
#(
  parameter int CLK_HZ = 55_000_000
)(
  input  logic             clk,
  input  logic             rst,

  input  iob_req_t         bus_i,           // addr = offset in SBus slot 3
  output iob_rsp_t         bus_o,

  output dvma_req_t        dvma_o,          // the APC's DVMA master port
  input  mem_rsp_t         dvma_i,

  output logic             irq_o,           // SBus level 5
  output logic signed [15:0] audio_l_o,
  output logic signed [15:0] audio_r_o
);

  // ---------------------------------------------------------------------
  // Bus decode
  // ---------------------------------------------------------------------
  logic       access, wr, rd;
  logic       sel_rom, sel_reg;
  logic [3:0] word;

  assign access  = bus_i.req & ~bus_o.ack;
  assign wr      = access & bus_i.we;
  assign rd      = access & ~bus_i.we;
  assign sel_rom = (bus_i.addr[27:11] == '0);
  assign sel_reg = (bus_i.addr[27:6] == 22'h30_0000);       // 0x0C000000-3F
  assign word    = bus_i.addr[5:2];

  // the byte a codec register write carries
  logic [7:0] wbyte;
  always_comb
    unique casez (bus_i.be)
      4'b???1: wbyte = bus_i.wdata[7:0];
      4'b??10: wbyte = bus_i.wdata[15:8];
      4'b?100: wbyte = bus_i.wdata[23:16];
      default: wbyte = bus_i.wdata[31:24];
    endcase

  logic w_r0, w_r1, w_r2, r_r2, w_csr;
  logic w_cva, w_cc, w_cnva, w_cnc, w_pva, w_pc, w_pnva, w_pnc;
  logic codec_ok;                               // not down or initializing
  assign w_r0   = wr & sel_reg & (word == 4'h0) & codec_ok;
  assign w_r1   = wr & sel_reg & (word == 4'h1) & codec_ok;
  assign w_r2   = wr & sel_reg & (word == 4'h2) & codec_ok;
  assign r_r2   = rd & sel_reg & (word == 4'h2) & codec_ok;
  assign w_csr  = wr & sel_reg & (word == 4'h4);
  assign w_cva  = wr & sel_reg & (word == 4'h8);
  assign w_cc   = wr & sel_reg & (word == 4'h9);
  assign w_cnva = wr & sel_reg & (word == 4'hA);
  assign w_cnc  = wr & sel_reg & (word == 4'hB);
  assign w_pva  = wr & sel_reg & (word == 4'hC);
  assign w_pc   = wr & sel_reg & (word == 4'hD);
  assign w_pnva = wr & sel_reg & (word == 4'hE);
  assign w_pnc  = wr & sel_reg & (word == 4'hF);

  // ---------------------------------------------------------------------
  // APC CSR
  // ---------------------------------------------------------------------
  logic pi_q, ci_q, ei_q, pmi_q, cmi_q;         // latched interrupts
  logic ie_q, pie_q, cie_q, eie_q, pmie_q, cmie_q;
  logic ppause_q, cpause_q, pdn_q, pgo_q, cgo_q, areset_q;
  logic p_cv, p_nv, c_cv, c_nv;                 // pair valid: current, next
  logic pm, pd, cm, cd, ip;

  assign pd = ~p_nv;
  assign cd = ~c_nv;
  assign pm = ~p_cv & (~p_nv | ppause_q | ~pgo_q);
  assign cm = ~c_cv & (~c_nv | cpause_q | ~cgo_q);
  assign ip = ie_q & ((pi_q & pie_q) | (ci_q & cie_q) | (ei_q & eie_q) |
                      (pmi_q & pmie_q) | (cmi_q & cmie_q));
  assign irq_o = ip;

  logic [31:0] csr;
  assign csr = {8'h00, ip, pi_q, ci_q, ei_q, ie_q, pie_q, cie_q, eie_q,
                pmi_q, pm, pd, pmie_q, cm, cd, cmi_q, cmie_q,
                ppause_q, cpause_q, pdn_q, 1'b0, pgo_q, cgo_q, 1'b0, areset_q};

  // ---------------------------------------------------------------------
  // Codec registers
  // ---------------------------------------------------------------------
  logic        crst;                            // codec in reset / power down
  assign crst = rst | pdn_q;

  logic [7:0]  ir [32];                         // the stored indirect registers
  logic        mce_q, trd_q;
  logic [4:0]  ia_q;
  logic [7:0]  init_cnt;                        // sample periods of initialization left
  logic [7:0]  aci_cnt;                         // sample periods of calibration left
  logic        pur_q, cor_q;                    // I11
  logic        ti_q, cii_q, pii_q, cu_q, co_q, po_q, pu_q;   // I24
  logic [15:0] p_ccnt, c_ccnt, t_cnt;           // current counts

  logic mode2, int_st, aci, pen, cen, dacz, ien, te;
  assign codec_ok = ~crst & (init_cnt == 0);
  assign mode2    = ir[12][6];
  assign int_st   = pii_q | cii_q | ti_q;
  assign aci      = (aci_cnt != 0);
  assign pen      = ir[9][0] & ~ir[9][6] & codec_ok;
  assign cen      = ir[9][1] & ~ir[9][7] & codec_ok;
  assign dacz     = ir[16][0];
  assign te       = ir[16][6];
  assign ien      = ir[10][1];

  logic [4:0] idx;                              // the effective index
  assign idx = mode2 ? ia_q : {1'b0, ia_q[3:0]};

  // ---- reads ----
  logic [7:0] r0_v, r1_v, r2_v, creg_v;
  assign r0_v = {1'b0, mce_q, trd_q, mode2 & ia_q[4], ia_q[3:0]};
  assign r2_v = {3'b000, pur_q | cor_q, 3'b000, int_st};
  always_comb
    unique case (idx)
      5'd11:   r1_v = {cor_q, pur_q, aci, 5'b0};
      5'd12:   r1_v = {1'b1, mode2, 2'b00, 4'hA};
      5'd24:   r1_v = {1'b0, ti_q, cii_q, pii_q, cu_q, co_q, po_q, pu_q};
      5'd25:   r1_v = 8'hA0;
      default: r1_v = ir[idx];
    endcase
  always_comb begin
    creg_v = 8'h80;
    if (codec_ok)
      unique case (word[1:0])
        2'd0:    creg_v = r0_v;
        2'd1:    creg_v = r1_v;
        2'd2:    creg_v = r2_v;
        default: creg_v = 8'h00;
      endcase
  end

  // ---------------------------------------------------------------------
  // Sample clock and timer clock
  // ---------------------------------------------------------------------
  // The rates are exact: each period is CLK_HZ * divide / crystal cycles,
  // counted by adding the crystal's frequency each cycle. Everything is
  // scaled by the common factor of the clock and both crystals (400 at
  // 55 MHz), which keeps the accumulators near 30 bits instead of 40.
  function automatic longint gcd(input longint a, input longint b);
    longint t;
    while (b != 0) begin t = a % b; a = b; b = t; end
    return a;
  endfunction
  localparam longint SG    = gcd(gcd(longint'(CLK_HZ), 64'd16_934_400), 64'd24_576_000);
  localparam longint CLKS  = longint'(CLK_HZ) / SG;
  localparam int     AW    = $clog2(CLKS * 3072 + 24_576_000 / SG) + 1;
  logic [AW-1:0] s_thr, s_acc, s_sum, t_thr, t_acc, t_sum, xtal;
  logic        s_tick, t_tick;

  assign xtal = ir[8][0] ? AW'(16_934_400 / SG) : AW'(24_576_000 / SG);
  always_comb
    unique case (ir[8][3:1])
      3'd0: s_thr = AW'(CLKS * 3072);
      3'd1: s_thr = AW'(CLKS * 1536);
      3'd2: s_thr = AW'(CLKS * 896);
      3'd3: s_thr = AW'(CLKS * 768);
      3'd4: s_thr = AW'(CLKS * 448);
      3'd5: s_thr = AW'(CLKS * 384);
      3'd6: s_thr = AW'(CLKS * 512);
      default: s_thr = AW'(CLKS * 2560);
    endcase
  assign t_thr  = ir[8][0] ? AW'(CLKS * 168) : AW'(CLKS * 245);
  assign s_sum  = s_acc + xtal;
  assign t_sum  = t_acc + xtal;
  assign s_tick = (s_sum >= s_thr);
  assign t_tick = (t_sum >= t_thr);

  // a write that changes the rate restarts the period (the accumulator
  // stays below the threshold)
  logic rate_wr;
  assign rate_wr = w_r1 & (idx == 5'd8) & mce_q & (wbyte[3:0] != ir[8][3:0]);

  always_ff @(posedge clk) begin
    if (crst | rate_wr) s_acc <= '0;
    else                s_acc <= s_tick ? s_sum - s_thr : s_sum;
    if (crst | rate_wr) t_acc <= '0;
    else                t_acc <= t_tick ? t_sum - t_thr : t_sum;
  end

  // ---------------------------------------------------------------------
  // Formats
  // ---------------------------------------------------------------------
  logic [2:0] pfmt, cfmt;
  logic       pst, cst;
  assign pfmt = {ir[8][7] & mode2, ir[8][6:5]};
  assign pst  = ir[8][4];
  assign cfmt = mode2 ? ir[28][7:5] : {1'b0, ir[8][6:5]};
  assign cst  = mode2 ? ir[28][4] : ir[8][4];

  function automatic logic [2:0] frame_bytes(input logic [2:0] f, input logic st);
    logic w16;
    w16 = (f == 3'b010) | (f == 3'b110);
    return st ? (w16 ? 3'd4 : 3'd2) : (w16 ? 3'd2 : 3'd1);
  endfunction

  function automatic logic [7:0] silence(input logic [2:0] f);
    unique case (f)
      3'b000:  return 8'h80;
      3'b001:  return 8'hFF;
      3'b011:  return 8'hD5;
      default: return 8'h00;
    endcase
  endfunction

  // G.711 (the Sun g711.c formulas)
  function automatic logic signed [15:0] ulaw(input logic [7:0] b);
    logic [7:0]  u;
    logic [15:0] t;
    u = ~b;
    t = 16'({u[3:0], 3'b000} + 8'h84) << u[6:4];
    return u[7] ? 16'(16'h84 - t) : 16'(t - 16'h84);
  endfunction

  function automatic logic signed [15:0] alaw(input logic [7:0] b);
    logic [7:0]  a;
    logic [15:0] t;
    a = b ^ 8'h55;
    t = {8'h00, a[3:0], 4'b0000};
    if (a[6:4] == 3'd0) t = t + 16'h8;
    else                t = (t + 16'h108) << (a[6:4] - 3'd1);
    return a[7] ? t : 16'(-t);
  endfunction

  function automatic logic signed [15:0] dec8(input logic [2:0] f, input logic [7:0] b);
    unique case (f)
      3'b000:  return {b ^ 8'h80, 8'h00};
      3'b001:  return ulaw(b);
      3'b011:  return alaw(b);
      default: return 16'sd0;
    endcase
  endfunction

  // ---------------------------------------------------------------------
  // Playback: the prefetched frame, the doubleword cache, the APC pairs
  // ---------------------------------------------------------------------
  logic [31:0] p_va, p_cnt, p_nva, p_ncnt;
  logic [31:0] c_va, c_cnt, c_nva, c_ncnt;
  logic        fb_v;                            // a whole frame is ready
  logic [7:0]  fb [4];
  logic [1:0]  fb_i;                            // bytes of the frame so far
  logic        dc_v;                            // doubleword cache
  logic [28:0] dc_tag;
  logic [63:0] dc_data;
  logic signed [15:0] smp_l, smp_r;             // the sample being played

  logic dma_ok;                                 // TRD holds requests while INT
  assign dma_ok = ~(trd_q & int_st);

  logic p_want, p_hit, p_take;
  logic [7:0] p_byte;
  assign p_want = pen & dma_ok & ~fb_v & p_cv & pgo_q & ~areset_q;
  assign p_hit  = dc_v & (dc_tag == p_va[31:3]);
  assign p_take = p_want & p_hit;
  assign p_byte = dc_data[8 * (7 - int'(p_va[2:0])) +: 8];

  // decode of the frame (the format in force when it is played)
  logic signed [15:0] f_l, f_r;
  always_comb begin
    if (pfmt == 3'b010) begin                   // 16-bit little endian
      f_l = {fb[1], fb[0]};
      f_r = pst ? {fb[3], fb[2]} : f_l;
    end else if (pfmt == 3'b110) begin          // 16-bit big endian
      f_l = {fb[0], fb[1]};
      f_r = pst ? {fb[2], fb[3]} : f_l;
    end else begin
      f_l = dec8(pfmt, fb[0]);
      f_r = pst ? dec8(pfmt, fb[1]) : f_l;
    end
  end

  // ---------------------------------------------------------------------
  // Capture: the pending frame of silence
  // ---------------------------------------------------------------------
  logic       cap_v;                            // a frame waits for the APC
  logic [1:0] cap_i;                            // bytes of it written

  logic c_want;
  assign c_want = cap_v & c_cv & cgo_q & dma_ok & ~areset_q;

  // ---------------------------------------------------------------------
  // The DVMA port
  // ---------------------------------------------------------------------
  typedef enum logic [1:0] {D_IDLE, D_RD, D_WR} dstate_t;
  dstate_t   d_st;
  logic      d_done, d_err;
  assign d_done = (d_st != D_IDLE) & dvma_i.ack;
  assign d_err  = d_done & dvma_i.err;

  logic c_wrote;                                // a capture byte was written
  assign c_wrote = (d_st == D_WR) & dvma_i.ack & ~dvma_i.err;

  always_ff @(posedge clk) begin
    if (rst) begin
      d_st   <= D_IDLE;
      dvma_o <= DVMA_REQ_IDLE;
    end else begin
      unique case (d_st)
        D_IDLE:
          if (p_want & ~p_hit) begin
            d_st   <= D_RD;
            dvma_o <= '{valid: 1'b1, write: 1'b0, burst: 1'b0,
                        va: {p_va[31:3], 3'b000}, be: 8'hFF, wdata: '0};
          end else if (c_want) begin
            d_st   <= D_WR;
            dvma_o <= '{valid: 1'b1, write: 1'b1, burst: 1'b0, va: c_va,
                        be: 8'h80 >> c_va[2:0], wdata: {8{silence(cfmt)}}};
          end
        default:
          if (dvma_i.ack) begin
            d_st   <= D_IDLE;
            dvma_o <= DVMA_REQ_IDLE;
          end
      endcase
    end
  end

  // ---------------------------------------------------------------------
  // The APC pairs and interrupts
  // ---------------------------------------------------------------------
  // A pair moves in when the current one is empty, or in the cycle its
  // last byte goes (so PD never shows the gap).
  logic p_load, c_load, p_last, c_last;
  assign p_last = p_take & (p_cnt == 32'd1);
  assign c_last = c_wrote & (c_cnt == 32'd1);
  assign p_load = (~p_cv | p_last) & p_nv & pgo_q & ~ppause_q & ~areset_q;
  assign c_load = (~c_cv | c_last) & c_nv & cgo_q & ~cpause_q & ~areset_q;

  logic pin_q;                                  // the codec's interrupt pin, delayed
  logic pin;
  assign pin = int_st & ien & codec_ok;

  logic set_pi, set_ci, set_ei, set_pmi, set_cmi;
  assign set_pi  = p_last;
  assign set_ci  = c_last;
  assign set_pmi = p_last & (~p_nv | ppause_q);
  assign set_cmi = c_last & (~c_nv | cpause_q);
  assign set_ei  = d_err | (pin & ~pin_q);

  always_ff @(posedge clk) begin
    if (rst) begin
      {pi_q, ci_q, ei_q, pmi_q, cmi_q} <= '0;
      {ie_q, pie_q, cie_q, eie_q, pmie_q, cmie_q} <= '0;
      {ppause_q, cpause_q, pdn_q, pgo_q, cgo_q, areset_q} <= '0;
      pin_q <= 1'b0;
      p_cv <= 1'b0; p_nv <= 1'b0; c_cv <= 1'b0; c_nv <= 1'b0;
      p_va <= '0; p_cnt <= '0; p_nva <= '0; p_ncnt <= '0;
      c_va <= '0; c_cnt <= '0; c_nva <= '0; c_ncnt <= '0;
      dc_v <= 1'b0; dc_tag <= '0; dc_data <= '0;
    end else begin
      pin_q <= pin;

      // interrupts: a new event wins over a write-1-to-clear
      pi_q  <= (pi_q  & ~(w_csr & bus_i.wdata[22])) | set_pi;
      ci_q  <= (ci_q  & ~(w_csr & bus_i.wdata[21])) | set_ci;
      ei_q  <= (ei_q  & ~(w_csr & bus_i.wdata[20])) | set_ei;
      pmi_q <= (pmi_q & ~(w_csr & bus_i.wdata[15])) | set_pmi;
      cmi_q <= (cmi_q & ~(w_csr & bus_i.wdata[9]))  | set_cmi;
      if (w_csr) begin
        {ie_q, pie_q, cie_q, eie_q} <= bus_i.wdata[19:16];
        pmie_q   <= bus_i.wdata[12];
        cmie_q   <= bus_i.wdata[8];
        ppause_q <= bus_i.wdata[7];
        cpause_q <= bus_i.wdata[6];
        pdn_q    <= bus_i.wdata[5];
        pgo_q    <= bus_i.wdata[3];
        cgo_q    <= bus_i.wdata[2];
        areset_q <= bus_i.wdata[0];
      end

      // playback pair: the engine, then the bus on top
      if (p_take) begin
        p_va  <= p_va + 32'd1;
        p_cnt <= p_cnt - 32'd1;
        if (p_last) p_cv <= 1'b0;
      end
      if (p_load) begin
        p_va <= p_nva; p_cnt <= p_ncnt; p_cv <= 1'b1; p_nv <= 1'b0;
        dc_v <= 1'b0;
      end
      if ((d_st == D_RD) & dvma_i.ack) begin
        if (dvma_i.err) p_cv <= 1'b0;           // the pair is dropped
        else begin
          dc_v    <= 1'b1;
          dc_tag  <= dvma_o.va[31:3];
          dc_data <= dvma_i.rdata;
        end
      end
      if (w_pva)  begin p_va <= bus_i.wdata; dc_v <= 1'b0; end
      if (w_pc)   begin p_cnt <= bus_i.wdata; p_cv <= (bus_i.wdata != 0); end
      if (w_pnva) p_nva <= bus_i.wdata;
      if (w_pnc)  begin p_ncnt <= bus_i.wdata; p_nv <= (bus_i.wdata != 0); end

      // capture pair
      if (c_wrote) begin
        c_va  <= c_va + 32'd1;
        c_cnt <= c_cnt - 32'd1;
        if (c_last) c_cv <= 1'b0;
      end
      if (c_load) begin
        c_va <= c_nva; c_cnt <= c_ncnt; c_cv <= 1'b1; c_nv <= 1'b0;
      end
      if ((d_st == D_WR) & d_err) c_cv <= 1'b0;
      if (w_cva)  c_va <= bus_i.wdata;
      if (w_cc)   begin c_cnt <= bus_i.wdata; c_cv <= (bus_i.wdata != 0); end
      if (w_cnva) c_nva <= bus_i.wdata;
      if (w_cnc)  begin c_ncnt <= bus_i.wdata; c_nv <= (bus_i.wdata != 0); end

      if (areset_q) begin
        {pi_q, ci_q, ei_q, pmi_q, cmi_q} <= '0;
        p_cv <= 1'b0; p_nv <= 1'b0; c_cv <= 1'b0; c_nv <= 1'b0;
        dc_v <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------
  // The codec: registers, counts, the frame path
  // ---------------------------------------------------------------------
  logic [2:0] p_need, c_need;
  assign p_need = frame_bytes(pfmt, pst);
  assign c_need = frame_bytes(cfmt, cst);

  logic pmce, cmce;
  assign pmce = ir[16][4];
  assign cmce = ir[16][5];

  logic play_tick, cap_tick;
  assign play_tick = s_tick & pen;
  assign cap_tick  = s_tick & cen;

  logic cap_done;                               // the frame's last byte was written
  assign cap_done = c_wrote & (3'(cap_i) + 3'd1 == c_need);

  logic set_pii, set_cii, set_ti;
  logic [15:0] c_base;
  assign c_base = mode2 ? {ir[30], ir[31]} : {ir[14], ir[15]};
  assign set_pii = (play_tick & fb_v & (p_ccnt == 0)) | (~mode2 & cap_done & (c_ccnt == 0));
  assign set_cii = mode2 & cap_done & (c_ccnt == 0);
  assign set_ti  = t_tick & te & (t_cnt == 0);

  logic aci_start;
  assign aci_start = w_r0 & mce_q & ~wbyte[6];

  always_ff @(posedge clk) begin
    if (crst) begin
      for (int i = 0; i < 32; i++) ir[i] <= 8'h00;
      ir[2] <= 8'h88; ir[3] <= 8'h88; ir[4] <= 8'h88; ir[5] <= 8'h88;
      ir[6] <= 8'h80; ir[7] <= 8'h80;
      ir[9] <= 8'h08;
      ir[12] <= 8'h8A;
      ir[18] <= 8'h88; ir[19] <= 8'h88;
      ir[26] <= 8'hA0;
      mce_q <= 1'b1; trd_q <= 1'b0; ia_q <= '0;
      init_cnt <= 8'd168;
      aci_cnt  <= '0;
      {pur_q, cor_q} <= '0;
      {ti_q, cii_q, pii_q, cu_q, co_q, po_q, pu_q} <= '0;
      p_ccnt <= '0; c_ccnt <= '0; t_cnt <= '0;
      fb_v <= 1'b0; fb_i <= '0;
      fb[0] <= '0; fb[1] <= '0; fb[2] <= '0; fb[3] <= '0;
      smp_l <= '0; smp_r <= '0;
      cap_v <= 1'b0; cap_i <= '0;
    end else begin
      if (s_tick && init_cnt != 0) init_cnt <= init_cnt - 8'd1;
      if (s_tick && aci_cnt != 0)  aci_cnt  <= aci_cnt - 8'd1;

      // ---- the playback frame ----
      if (p_take) begin
        fb[fb_i] <= p_byte;
        if (3'(fb_i) + 3'd1 >= p_need) begin
          fb_v <= 1'b1;
          fb_i <= '0;
        end else
          fb_i <= fb_i + 2'd1;
      end
      if (play_tick) begin
        if (fb_v) begin
          smp_l <= f_l;
          smp_r <= f_r;
          fb_v  <= 1'b0;
          p_ccnt <= (p_ccnt == 0) ? {ir[14], ir[15]} : p_ccnt - 16'd1;
        end else begin
          pu_q  <= 1'b1;
          pur_q <= 1'b1;
          if (dacz) begin smp_l <= '0; smp_r <= '0; end
        end
      end
      if (!pen | areset_q) begin
        // stopped: silence, and the next start begins on a frame boundary
        fb_v  <= 1'b0;
        fb_i  <= '0;
        smp_l <= '0;
        smp_r <= '0;
      end

      // ---- the capture frame ----
      if (c_wrote) cap_i <= cap_i + 2'd1;
      if (cap_done) begin
        cap_v  <= 1'b0;
        cap_i  <= '0;
        c_ccnt <= (c_ccnt == 0) ? c_base : c_ccnt - 16'd1;
      end
      if (cap_tick) begin
        if (cap_v & ~cap_done) begin
          co_q  <= 1'b1;
          cor_q <= 1'b1;
        end else begin
          cap_v <= 1'b1;
          cap_i <= '0;
        end
      end
      if (!cen | areset_q) begin
        cap_v <= 1'b0;
        cap_i <= '0;
      end

      // ---- the timer ----
      if (t_tick & te) t_cnt <= (t_cnt == 0) ? {ir[21], ir[20]} : t_cnt - 16'd1;

      // ---- reading R2 clears the error bits ----
      if (r_r2) {pur_q, cor_q} <= '0;

      // ---- R0 ----
      if (w_r0) begin
        mce_q <= wbyte[6];
        trd_q <= wbyte[5];
        ia_q  <= wbyte[4:0];
      end
      if (aci_start)
        unique case (ir[9][4:3])
          2'd0: aci_cnt <= 8'd0;
          2'd1: aci_cnt <= 8'd136;
          2'd2: aci_cnt <= 8'd40;
          default: aci_cnt <= 8'd168;
        endcase

      // ---- R1: the indexed register ----
      if (w_r1)
        unique case (idx)
          5'd8: begin
            if (mce_q | pmce) ir[8][7:4] <= {wbyte[7] & mode2, wbyte[6:4]};
            if (mce_q)        ir[8][3:0] <= wbyte[3:0];
          end
          5'd9: begin
            if (mce_q) ir[9][7:2] <= wbyte[7:2];
            ir[9][1:0] <= wbyte[1:0];
          end
          5'd11, 5'd25: ;                       // read-only
          5'd12: ir[12][6] <= wbyte[6];
          5'd14: begin
            ir[14] <= wbyte;
            p_ccnt <= {wbyte, ir[15]};
            if (!mode2) c_ccnt <= {wbyte, ir[15]};
          end
          5'd16: begin
            ir[16][7:4] <= wbyte[7:4];
            ir[16][0]   <= wbyte[0];
            if (mce_q) ir[16][3:1] <= wbyte[3:1];
          end
          5'd20: begin
            ir[20] <= wbyte;
            t_cnt  <= {ir[21], wbyte};
          end
          5'd24: begin
            {ti_q, cii_q, pii_q, cu_q, co_q, po_q, pu_q} <=
              {ti_q, cii_q, pii_q, cu_q, co_q, po_q, pu_q} & wbyte[6:0];
          end
          5'd28: if (mce_q | cmce) ir[28] <= {wbyte[7:4], 4'b0000};
          5'd30: begin
            ir[30] <= wbyte;
            c_ccnt <= {wbyte, ir[31]};
          end
          default: ir[idx] <= wbyte;
        endcase

      // ---- R2: a write clears the interrupt ----
      if (w_r2) {ti_q, cii_q, pii_q} <= 3'b000;

      // count events win over the clears
      if (set_pii) pii_q <= 1'b1;
      if (set_cii) cii_q <= 1'b1;
      if (set_ti)  ti_q  <= 1'b1;
    end
  end

  // ---------------------------------------------------------------------
  // The DAC: I6/I7 attenuation (-1.5 dB a step) and mute
  // ---------------------------------------------------------------------
  function automatic logic [16:0] gain(input logic [5:0] a);
    logic [16:0] g;
    unique case (a)
      6'd0: g = 17'd65536;  6'd1: g = 17'd55142;  6'd2: g = 17'd46396;  6'd3: g = 17'd39037;
      6'd4: g = 17'd32846;  6'd5: g = 17'd27636;  6'd6: g = 17'd23253;  6'd7: g = 17'd19565;
      6'd8: g = 17'd16462;  6'd9: g = 17'd13851;  6'd10: g = 17'd11654; 6'd11: g = 17'd9806;
      6'd12: g = 17'd8250;  6'd13: g = 17'd6942;  6'd14: g = 17'd5841;  6'd15: g = 17'd4915;
      6'd16: g = 17'd4135;  6'd17: g = 17'd3479;  6'd18: g = 17'd2927;  6'd19: g = 17'd2463;
      6'd20: g = 17'd2072;  6'd21: g = 17'd1744;  6'd22: g = 17'd1467;  6'd23: g = 17'd1234;
      6'd24: g = 17'd1039;  6'd25: g = 17'd874;   6'd26: g = 17'd735;   6'd27: g = 17'd619;
      6'd28: g = 17'd521;   6'd29: g = 17'd438;   6'd30: g = 17'd369;   6'd31: g = 17'd310;
      6'd32: g = 17'd261;   6'd33: g = 17'd220;   6'd34: g = 17'd185;   6'd35: g = 17'd155;
      6'd36: g = 17'd131;   6'd37: g = 17'd110;   6'd38: g = 17'd93;    6'd39: g = 17'd78;
      6'd40: g = 17'd66;    6'd41: g = 17'd55;    6'd42: g = 17'd46;    6'd43: g = 17'd39;
      6'd44: g = 17'd33;    6'd45: g = 17'd28;    6'd46: g = 17'd23;    6'd47: g = 17'd20;
      6'd48: g = 17'd16;    6'd49: g = 17'd14;    6'd50: g = 17'd12;    6'd51: g = 17'd10;
      6'd52: g = 17'd8;     6'd53: g = 17'd7;     6'd54: g = 17'd6;     6'd55: g = 17'd5;
      6'd56: g = 17'd4;     6'd57: g = 17'd3;     6'd58: g = 17'd3;     6'd59: g = 17'd2;
      6'd60: g = 17'd2;     6'd61: g = 17'd2;     6'd62: g = 17'd1;     default: g = 17'd1;
    endcase
    return g;
  endfunction

  logic signed [33:0] prod_l, prod_r;
  logic               dac_mute;
  assign prod_l   = smp_l * $signed({1'b0, gain(ir[6][5:0])});
  assign prod_r   = smp_r * $signed({1'b0, gain(ir[7][5:0])});
  assign dac_mute = mce_q | aci | ~codec_ok;

  always_ff @(posedge clk) begin
    if (rst) begin
      audio_l_o <= '0;
      audio_r_o <= '0;
    end else begin
      audio_l_o <= (dac_mute | ir[6][7]) ? 16'sd0 : prod_l[31:16];
      audio_r_o <= (dac_mute | ir[7][7]) ? 16'sd0 : prod_r[31:16];
    end
  end

  // ---------------------------------------------------------------------
  // Read data
  // ---------------------------------------------------------------------
  logic [31:0] reg_v;
  always_comb
    unique case (word)
      4'h0, 4'h1, 4'h2, 4'h3: reg_v = {4{creg_v}};
      4'h4:    reg_v = csr;
      4'h8:    reg_v = c_va;
      4'h9:    reg_v = c_cnt;
      4'hA:    reg_v = c_nva;
      4'hB:    reg_v = c_ncnt;
      4'hC:    reg_v = p_va;
      4'hD:    reg_v = p_cnt;
      4'hE:    reg_v = p_nva;
      4'hF:    reg_v = p_ncnt;
      default: reg_v = '0;
    endcase

  logic [31:0] rom_q;
  cs4231_fcode u_rom (.clk, .addr(bus_i.addr[10:2]), .q(rom_q));

  logic        ack_q, rom_sel_q;
  logic [31:0] reg_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      ack_q     <= 1'b0;
      rom_sel_q <= 1'b0;
      reg_q     <= '0;
    end else begin
      ack_q     <= access;
      rom_sel_q <= sel_rom;
      reg_q     <= sel_reg ? reg_v : 32'h0;
    end
  end
  assign bus_o = '{ack: ack_q, err: 1'b0, rdata: rom_sel_q ? rom_q : reg_q};

  logic unused_ok;
  assign unused_ok = &{1'b0, bus_i.pair, bus_i.addr[1:0], dvma_i.rdata[0], prod_l[33:32],
                       prod_r[33:32], prod_l[15:0], prod_r[15:0], cu_q, po_q};

endmodule
