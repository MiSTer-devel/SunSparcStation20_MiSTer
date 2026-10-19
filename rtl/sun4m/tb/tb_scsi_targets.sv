// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_scsi_targets: the SCSI target engine between a behavioural ESP (the
// initiator side of the record bus, as scsi_targets.sv's header describes
// it) and a model of hps_io's block interface serving known images. The
// cases follow what the whole-machine sim/run-scsi.sh and the CPU
// suite's scsitest.S check, at the level of the target engine:
//   - the probe: INQUIRY (disk, CD, LUN 1, VPD pages), TEST UNIT READY,
//     READ CAPACITY; selection only of present targets (an unmounted disk
//     does not answer, the CD answers without a disc);
//   - OpenBIOS's sequence (mode 0: no ICCS after a command without data,
//     the next selection with ATN finds the target in STATUS), switching
//     targets with bsy held, and the whole sequence (mode 1);
//   - READ/WRITE(6/10) against the images, one block and many, multi-chunk
//     transfers beyond 32 blocks (the sd_blk_cnt requests counted), the
//     last block, past the end, a write restored afterwards, with and
//     without the ESP withholding ack;
//   - sense: UNIT ATTENTION after a mount (28h), a bus reset and BUS DEVICE
//     RESET (29h), ILLEGAL REQUEST with the information field, REQUEST
//     SENSE with 255 bytes allowed (18 sent), read-only (DATA PROTECT, WP);
//   - MODE SENSE(6/10) pages, MODE SELECT of the CD's block size (2048 at
//     power-up, 512, back), the power-up size from the OSD bit;
//   - messages: SDTR answered asynchronous byte by byte, WDTR rejected, a
//     SIMPLE QUEUE TAG taken, an unknown two-byte message rejected, ABORT;
//     an ATN abort in the middle of a long read (and no stray requests);
//   - CD audio: the track table fetched at mount (TOC_BLK), READ TOC from
//     it (LBA, MSF, lead-out, format 1), PLAY AUDIO TRACK/INDEX with every
//     sample checked against the frame windows (AUDIO_BLK + 5f), READ
//     SUB-CHANNEL playing/paused/completed/no status, PAUSE/RESUME, STOP,
//     PLAY AUDIO(10)/MSF, the volume page; a disc without the table (one
//     data track, audio rejected); an eject (NOT READY).
//
// The SD model: hps_io WIDE, each word on its own 4 clocks (address, data,
// strobe), request to ack after sd_lat clocks. Image block n holds 'SCSI',
// the tag, n, then (n << 8 | k) ^ 0xa5a5a5a5 (tests/cpu/mkscsiimg.py);
// the CD's audio windows are the old sim_main.cpp's: tracks of 150 frames
// after the data track, sample k of frame f = (f << 4) + k.

module tb_scsi_targets;
  import tb_pkg::*;

  localparam int SYSFREQ = 8_000_000;

  localparam logic [2:0] PH_DOUT = 3'd0, PH_DIN = 3'd1, PH_CMD = 3'd2, PH_STAT = 3'd3,
                         PH_MOUT = 3'd6, PH_MIN = 3'd7, PH_NONE = 3'd5;
  localparam logic [2:0] ID_HD0 = 3'd3, ID_HD1 = 3'd1, ID_CD = 3'd6;

  localparam int HD0_BLKS = 2048, HD1_BLKS = 1024, CD_BLKS = 4096;   // 512-byte blocks
  localparam int CD_DATA = CD_BLKS / 4;                               // 2048-byte frames
  localparam int WAIT_TO = 3_000_000;

  logic clk;
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // ---------------------------------------------------------------------
  // The DUT
  // ---------------------------------------------------------------------
  logic        reset_n = 1'b0;
  logic [7:0]  esp_d = 8'h5A;
  logic        esp_ack;
  logic        esp_bsy = 1'b0, esp_atn = 1'b0, esp_rst = 1'b0;
  logic [2:0]  esp_did = 3'd7;
  logic [7:0]  tgt_d;
  logic        tgt_req, tgt_sel;
  logic [2:0]  tgt_phase;
  logic [9:0]  tgt_pc;
  logic [2:0]  ena = 3'b111;
  logic        cd2048 = 1'b1;
  logic [2:0]  img_mounted = 3'b000;
  logic [63:0] img_size = '0;
  logic        img_readonly = 1'b0;
  logic [31:0] sd_lba;
  logic [5:0]  sd_blk_cnt;
  logic [2:0]  sd_rd, sd_wr;
  logic [2:0]  sd_ack;
  logic [12:0] sd_buff_addr;
  logic [15:0] sd_buff_dout;
  logic [15:0] sd_buff_din;
  logic        sd_buff_wr;
  logic        busy;
  logic [15:0] cd_l, cd_r;

  scsi_targets #(.SYSFREQ(SYSFREQ), .SIMU(1'b1)) dut (
    .clk, .reset_n,
    .esp_d_i(esp_d), .esp_ack_i(esp_ack), .esp_bsy_i(esp_bsy), .esp_atn_i(esp_atn),
    .esp_did_i(esp_did), .esp_rst_i(esp_rst),
    .tgt_d_o(tgt_d), .tgt_req_o(tgt_req), .tgt_phase_o(tgt_phase), .tgt_sel_o(tgt_sel),
    .tgt_pc_o(tgt_pc),
    .id0_i(ID_HD0), .id1_i(ID_HD1), .id2_i(ID_CD), .ena_i(ena), .cd2048_i(cd2048),
    .img_mounted_i(img_mounted), .img_size_i(img_size), .img_readonly_i(img_readonly),
    .sd_lba_o(sd_lba), .sd_blk_cnt_o(sd_blk_cnt), .sd_rd_o(sd_rd), .sd_wr_o(sd_wr),
    .sd_ack_i(sd_ack), .sd_buff_addr_i(sd_buff_addr), .sd_buff_dout_i(sd_buff_dout),
    .sd_buff_din_o(sd_buff_din), .sd_buff_wr_i({3{sd_buff_wr}} & sd_ack),
    .busy_o(busy), .cd_l_o(cd_l), .cd_r_o(cd_r));

  task automatic cycles(input int n);
    repeat (n) @(posedge clk);
    #1;
  endtask

  // ---------------------------------------------------------------------
  // The images
  // ---------------------------------------------------------------------
  logic [7:0] img0 [HD0_BLKS * 512];
  logic [7:0] img1 [HD1_BLKS * 512];
  logic [7:0] img2 [CD_BLKS * 512];
  int         img_blks [3];                   // as mounted (0: none)
  bit         img_ro [3];
  int         cd_audio = 2;                   // audio tracks Main serves (0: an older Main)
  logic [7:0] toc [1024];

  localparam logic [31:0] TAG_HD0 = 32'h48443000, TAG_HD1 = 32'h48443100, TAG_CD = 32'h43443000;

  function automatic logic [7:0] pat(input logic [31:0] tag, input int n, input int off);
    logic [31:0] w;
    int k;
    k = off / 4;
    if (k == 0)      w = 32'h53435349;          // 'SCSI'
    else if (k == 1) w = tag;
    else if (k == 2) w = 32'(n);
    else             w = ((32'(n) << 8) | 32'(k)) ^ 32'ha5a5a5a5;
    return w[8 * (3 - off % 4) +: 8];
  endfunction

  function automatic logic [7:0] img_rd(input int slot, input int a);
    if (slot == 0)      return img0[a];
    else if (slot == 1) return img1[a];
    else                return img2[a];
  endfunction

  task automatic img_wr(input int slot, input int a, input logic [7:0] d);
    if (slot == 0)      img0[a] <= d;
    else if (slot == 1) img1[a] <= d;
    else                img2[a] <= d;
  endtask

  // the pristine content of byte a of a slot's image
  function automatic logic [7:0] pristine(input int slot, input int a);
    logic [31:0] tag;
    tag = slot == 0 ? TAG_HD0 : slot == 1 ? TAG_HD1 : TAG_CD;
    return pat(tag, a / 512, a % 512);
  endfunction

  task automatic toc_entry(input int at, input logic [7:0] ctl, input logic [7:0] trk, input int lba);
    int a;
    a = lba + 150;
    toc[at]     = ctl;
    toc[at + 1] = trk;
    toc[at + 2] = 8'(a / 4500);
    toc[at + 3] = 8'(a / 75 % 60);
    toc[at + 4] = 8'(a % 75);
    toc[at + 5] = 8'(lba >> 16);
    toc[at + 6] = 8'(lba >> 8);
    toc[at + 7] = 8'(lba);
  endtask

  // Main's track table (support/sun/sun_cdrom.h, as the old sim_main.cpp
  // serves it): the data track, cd_audio tracks of 150 frames, the lead-out
  task automatic make_toc();
    for (int i = 0; i < 1024; i++) toc[i] = 8'h00;
    toc_entry(8, 8'h14, 8'd1, 0);
    for (int i = 0; i < cd_audio; i++)
      toc_entry(16 + 8 * i, 8'h10, 8'(2 + i), CD_DATA + 150 * i);
    toc_entry(16 + 8 * cd_audio, 8'h10, 8'hAA, CD_DATA + 150 * cd_audio);
    toc[0] = 8'd1;
    toc[1] = 8'(1 + cd_audio);
    toc[2] = 8'(2 + cd_audio);
    toc[3] = 8'd1;
  endtask

  // the word Main returns for a read of the CD slot's windows
  function automatic logic [15:0] cd_window(input logic [31:0] lba, input int w);
    longint off;
    longint f, fo;
    int last;
    if (lba == 32'hC000_0000) begin
      if (w < 512) return {toc[2 * w + 1], toc[2 * w]};
      return 16'h0000;
    end
    if (lba >= 32'hC000_0000) return 16'h0000;
    off = (longint'(lba) - longint'(32'h8000_0000)) * 512 + longint'(2 * w);
    f  = off / 2560;
    fo = off % 2560;
    last = CD_DATA + 150 * cd_audio;
    if (fo >= 2352 || f < longint'(CD_DATA) || f >= longint'(last)) return 16'h0000;
    return 16'((f << 4) + fo / 2);
  endfunction

  // ---------------------------------------------------------------------
  // The hps_io model
  // ---------------------------------------------------------------------
  typedef enum {SD_IDLE, SD_DELAY, SD_RD, SD_WR, SD_END} sd_e;
  sd_e         sd_st;
  int          sd_slot, sd_word, sd_sub, sd_wait, sd_nblk;
  bit          sd_isw;
  logic [31:0] sd_rlba;
  int          sd_lat = 40;
  // the request log
  int          lg_slot [$];
  bit          lg_wr [$];
  logic [31:0] lg_lba [$];
  int          lg_n [$];

  initial begin
    sd_st = SD_IDLE;
    sd_ack = 3'b000;
    sd_buff_addr = '0;
    sd_buff_dout = '0;
    sd_buff_wr = 1'b0;
  end

  always @(posedge clk) begin : sd_model
    longint a;
    int     pick, sub_n, word_n;
    sd_buff_wr <= 1'b0;
    case (sd_st)
      SD_IDLE: begin
        pick = -1;
        for (int n = 0; n < 3; n++)
          if (pick < 0 && (sd_rd[n] || sd_wr[n])) pick = n;
        if (pick >= 0) begin
          sd_slot <= pick;
          sd_isw  <= sd_wr[pick];
          sd_rlba <= sd_lba;
          sd_nblk <= int'(sd_blk_cnt) + 1;
          lg_slot.push_back(pick);
          lg_wr.push_back(sd_wr[pick]);
          lg_lba.push_back(sd_lba);
          lg_n.push_back(int'(sd_blk_cnt) + 1);
          sd_wait <= sd_lat;
          sd_st <= SD_DELAY;
        end
      end
      SD_DELAY: begin
        if (sd_wait > 1)
          sd_wait <= sd_wait - 1;
        else begin
          sd_ack[sd_slot] <= 1'b1;
          sd_buff_addr <= '0;
          sd_word <= 0;
          sd_sub  <= 0;
          sd_st <= sd_isw ? SD_WR : SD_RD;
        end
      end
      SD_RD, SD_WR: begin
        a = longint'(sd_rlba) * 512 + longint'(2 * sd_word);
        if (sd_st == SD_RD) begin
          // the address and the word, then the strobe, then the next
          if (sd_sub == 0) begin
            sd_buff_addr <= 13'(sd_word);
            if (sd_slot == 2 && cd_audio != 0 && sd_rlba >= 32'h8000_0000)
              sd_buff_dout <= cd_window(sd_rlba, sd_word);
            else if (a + 1 < longint'(img_blks[sd_slot]) * 512)
              sd_buff_dout <= {img_rd(sd_slot, int'(a) + 1), img_rd(sd_slot, int'(a))};
            else
              sd_buff_dout <= 16'h0000;
          end else if (sd_sub == 1)
            sd_buff_wr <= 1'b1;
        end else begin
          // the address; the data three clocks later (a block RAM read)
          if (sd_sub == 0)
            sd_buff_addr <= 13'(sd_word);
          else if (sd_sub == 3 && !img_ro[sd_slot] && a + 1 < longint'(img_blks[sd_slot]) * 512) begin
            img_wr(sd_slot, int'(a), sd_buff_din[7:0]);
            img_wr(sd_slot, int'(a) + 1, sd_buff_din[15:8]);
          end
        end
        sub_n = sd_sub + 1;
        word_n = sd_word;
        if (sub_n == 4) begin
          sub_n = 0;
          word_n = sd_word + 1;
          if (word_n == 256 * sd_nblk) begin sd_st <= SD_END; sd_wait <= 4; end
        end
        sd_sub  <= sub_n;
        sd_word <= word_n;
      end
      default: begin
        if (sd_wait > 1)
          sd_wait <= sd_wait - 1;
        else begin
          sd_ack <= 3'b000;
          sd_st <= SD_IDLE;
        end
      end
    endcase
  end

  // ---------------------------------------------------------------------
  // The ESP model: ack is combinational from req, for the phase a Transfer
  // Information was started in, gated by the ESP's readiness (rdy: the
  // FIFO/DMA, withheld at random when stall is set). An OUT byte is on
  // esp_d only in the cycle after its req & ack cycle (a registered DMA
  // byte); 5Ah otherwise.
  // ---------------------------------------------------------------------
  logic        ack_en = 1'b0;
  logic [2:0]  ack_ph = PH_NONE;
  logic        rdy = 1'b1;
  bit          stall = 1'b0;
  assign esp_ack = tgt_req && ack_en && tgt_phase == ack_ph && rdy;

  byte unsigned outq [$];                     // OUT bytes of the next TI
  byte unsigned inq [$];                      // IN bytes received
  int           proto_err = 0;                // unexpected phases, time-outs

  task automatic perr(input string what);
    proto_err++;
    check(1'b0, what);
  endtask

  // Wait for req; the phase it asks for (PH_NONE after a time-out)
  task automatic wait_req(output logic [2:0] ph);
    int t;
    t = 0;
    while (!tgt_req) begin
      cycles(1);
      t++;
      if (t > WAIT_TO) begin ph = PH_NONE; perr("wait_req: time-out"); return; end
    end
    ph = tgt_phase;
  endtask

  // Transfer Information: up to n bytes in phase ph; stops early when the
  // target asks for another phase (end_ph). drop_atn: ATN falls with the
  // last byte (MESSAGE OUT).
  task automatic ti(input logic [2:0] ph, input int n, input bit drop_atn,
                    output int moved, output logic [2:0] end_ph);
    int  idle, oi;
    bit  hs;
    moved = 0; oi = 0; idle = 0; end_ph = ph;
    ack_ph = ph;
    ack_en = 1'b1;
    while (moved < n) begin
      rdy = stall ? ($urandom_range(3) != 0) : 1'b1;
      if (tgt_req && tgt_phase != ph) begin end_ph = tgt_phase; break; end
      hs = tgt_req && rdy;                    // req & ack: the byte moves at the edge
      if (hs && ph[0]) inq.push_back(tgt_d);
      @(posedge clk); #1;
      if (hs) begin
        moved++;
        idle = 0;
        if (!ph[0]) begin
          esp_d = (oi < outq.size()) ? outq[oi] : 8'hEE;
          oi++;
        end
        if (drop_atn && moved == n) esp_atn = 1'b0;
      end else begin
        esp_d = 8'h5A;
        idle++;
        if (idle > WAIT_TO) begin perr("ti: time-out"); break; end
      end
    end
    ack_en = 1'b0;
    rdy = 1'b1;
    if (!ph[0] && moved > 0) begin cycles(1); esp_d = 8'h5A; end
    if (moved == n && n > 0) begin
      // the phase the target asks for next is the caller's to wait for
    end
  endtask

  // Selection: did, sel a cycle later, then bsy (left set if it was) and
  // ATN. A target left in STATUS (mode 0) still has req up for its status
  // byte when ATN rises: the ESP must not take that for the target's
  // answer; the engine drops req the next cycle and asks for MESSAGE OUT
  // the one after, so the ESP waits two cycles before looking at req.
  task automatic select(input logic [2:0] id, input bit atn, output bit ok);
    esp_did = id;
    cycles(2);
    ok = tgt_sel;
    if (!ok) return;
    esp_atn = atn;
    esp_bsy = 1'b1;
    cycles(2);
  endtask

  // ICCS: status and message; the ESP then lets bsy go (MESSAGE ACCEPTED:
  // the target disconnects)
  int r_status, r_msg;
  task automatic iccs();
    int moved;
    logic [2:0] eph;
    inq.delete();
    ti(PH_STAT, 1, 1'b0, moved, eph);
    r_status = (moved == 1) ? int'(inq[0]) : -3;
    inq.delete();
    wait_req(eph);
    if (eph != PH_MIN) perr("iccs: no MESSAGE IN");
    ti(PH_MIN, 1, 1'b0, moved, eph);
    r_msg = (moved == 1) ? int'(inq[0]) : -1;
    inq.delete();
    esp_bsy = 1'b0;
    esp_atn = 1'b0;
    cycles(3);
  endtask

  // From COMMAND on: the CDB, a data phase if the target goes to one (up
  // to dlen bytes; out: wdata), then ICCS -- unless mode 0 and there was
  // no data phase (OpenBIOS: the target is left in STATUS, bsy set).
  byte unsigned cdbq [$];
  byte unsigned wdata [$];
  byte unsigned r_data [$];
  bit           r_dphase;
  task automatic from_command(input int dlen, input int mode);
    logic [2:0] ph, eph;
    int moved;
    r_data.delete();
    r_status = -3;
    r_dphase = 1'b0;
    wait_req(ph);
    if (ph != PH_CMD) begin perr($sformatf("expected COMMAND, got phase %0d", ph)); return; end
    outq = cdbq;
    ti(PH_CMD, cdbq.size(), 1'b0, moved, eph);
    wait_req(ph);
    if (ph == PH_DIN) begin
      inq.delete();
      ti(PH_DIN, dlen, 1'b0, moved, eph);
      r_data = inq;
      inq.delete();
      r_dphase = 1'b1;
      wait_req(ph);
    end else if (ph == PH_DOUT) begin
      outq = wdata;
      ti(PH_DOUT, dlen, 1'b0, moved, eph);
      r_dphase = 1'b1;
      wait_req(ph);
    end
    if (ph != PH_STAT) begin perr($sformatf("expected STATUS, got phase %0d", ph)); return; end
    if (mode == 0 && !r_dphase) begin r_status = -2; return; end
    iccs();
  endtask

  // A command: SELATN with IDENTIFY (or SEL without ATN), the rest
  task automatic cmd(input logic [2:0] id, input int dlen, input int mode,
                     input logic [7:0] ident, input bit atn);
    bit ok;
    logic [2:0] ph, eph;
    int moved;
    select(id, atn, ok);
    if (!ok) begin r_status = -1; r_data.delete(); return; end
    if (atn) begin
      wait_req(ph);
      if (ph != PH_MOUT) begin perr("expected MESSAGE OUT"); return; end
      outq = '{ident};
      ti(PH_MOUT, 1, 1'b1, moved, eph);
    end
    from_command(dlen, mode);
  endtask

  // The common case: mode 1, IDENTIFY LUN 0
  task automatic cmd1(input logic [2:0] id, input int dlen);
    cmd(id, dlen, 1, 8'h80, 1'b1);
  endtask

  // CDB builders
  task automatic cdb6(input logic [7:0] op, input logic [7:0] b1, input logic [7:0] b2,
                      input logic [7:0] b3, input logic [7:0] b4, input logic [7:0] b5);
    cdbq = '{op, b1, b2, b3, b4, b5};
  endtask
  task automatic cdb10(input logic [7:0] op, input logic [7:0] b1, input logic [31:0] lba,
                       input logic [7:0] b6, input logic [15:0] n, input logic [7:0] b9);
    cdbq = '{op, b1, lba[31:24], lba[23:16], lba[15:8], lba[7:0], b6, n[15:8], n[7:0], b9};
  endtask

  // REQUEST SENSE (18 bytes): key, ASC
  logic [3:0]  sn_key;
  logic [7:0]  sn_asc;
  logic [31:0] sn_info;
  task automatic sense(input logic [2:0] id);
    cdb6(8'h03, 0, 0, 0, 8'd18, 0);
    cmd1(id, 18);
    check(r_status == 0 && r_data.size() == 18 && r_data[0] == 8'h70 && r_data[7] == 8'h0A,
          "REQUEST SENSE: 18 bytes, fixed format");
    sn_key  = r_data.size() > 2 ? r_data[2][3:0] : 4'hF;
    sn_asc  = r_data.size() > 12 ? r_data[12] : 8'hFF;
    sn_info = r_data.size() > 6 ? {r_data[3], r_data[4], r_data[5], r_data[6]} : 32'hFFFFFFFF;
  endtask

  // A command expected to end CHECK CONDITION with key/ASC
  task automatic expect_check(input logic [2:0] id, input logic [3:0] key, input logic [7:0] asc,
                              input string what);
    cmd1(id, 0);
    check32(32'(r_status), 32'd2, {what, ": CHECK CONDITION"});
    sense(id);
    check32({28'd0, sn_key}, {28'd0, key}, {what, ": sense key"});
    check32({24'd0, sn_asc}, {24'd0, asc}, {what, ": ASC"});
  endtask

  // TEST UNIT READY until GOOD (a pending UNIT ATTENTION goes)
  task automatic tur_clear(input logic [2:0] id);
    for (int i = 0; i < 3; i++) begin
      cdb6(8'h00, 0, 0, 0, 0, 0);
      cmd1(id, 0);
      if (r_status == 0) break;
    end
  endtask

  // READ(10) of count blocks from lba, checked against the slot's image
  // (bs: the block size, 512 or 2048)
  int lg_mark;
  task automatic read_check(input logic [2:0] id, input int slot, input logic [7:0] op,
                            input int lba, input int count, input int bs, input int mode,
                            input string what);
    int bad, nb;
    nb = (op == 8'h08 && count == 0) ? 256 : count;
    if (op == 8'h08) cdb6(8'h08, 8'(lba >> 16), 8'(lba >> 8), 8'(lba), 8'(count), 0);
    else             cdb10(op, 0, 32'(lba), 0, 16'(count), 0);
    cmd(id, nb * bs, mode, 8'h80, 1'b1);
    check(r_status == 0, {what, ": GOOD"});
    check32(32'(r_data.size()), 32'(nb * bs), {what, ": bytes"});
    bad = 0;
    for (int i = 0; i < r_data.size(); i++)
      if (r_data[i] != img_rd(slot, lba * bs + i)) bad++;
    check32(32'(bad), 0, {what, ": data"});
  endtask

  // the hps_io requests since lg_mark, all for the given slot and kind:
  // their count, and that they cover [lba, lba + n) in order, in chunks
  // of at most 32
  task automatic check_chunks(input int slot, input bit wr, input int lba, input int n,
                              input int expect_reqs, input string what);
    int at, reqs, ok;
    at = lba; reqs = 0; ok = 1;
    for (int i = lg_mark; i < lg_slot.size(); i++) begin
      if (lg_slot[i] != slot || lg_wr[i] != wr || lg_lba[i] != 32'(at) || lg_n[i] > 32) ok = 0;
      at += lg_n[i];
      reqs++;
    end
    check(ok == 1 && at == lba + n, {what, ": the requests cover the transfer in chunks of <= 32"});
    check32(32'(reqs), 32'(expect_reqs), {what, ": hps_io requests"});
  endtask

  task automatic mount(input int slot, input int blks, input bit ro);
    img_blks[slot] = blks;
    img_ro[slot] = ro;
    if (slot == 2) make_toc();
    img_size = 64'(blks) * 512;
    img_readonly = ro;
    img_mounted[slot] = 1'b1;
    cycles(2);
    img_mounted[slot] = 1'b0;
    cycles(2);
  endtask

  task automatic wait_idle();
    int t;
    t = 0;
    while ((busy || sd_st != SD_IDLE) && t < WAIT_TO) begin cycles(1); t++; end
    cycles(4);                                // the engine sees the ack fall
    check(t < WAIT_TO, "the engine goes idle");
  endtask

  // ---------------------------------------------------------------------
  // The CD player's samples: each one read from the ring must be frame
  // ap_cur's word ap_ri (left) or ap_ri + 1 (right) of the window; cd_l/r
  // follow at the page's volume
  // ---------------------------------------------------------------------
  // (counters only grow: the cases take differences)
  int aud_ok, aud_bad;
  logic [15:0] vol_exp_l, vol_exp_r;
  int vol_bad, vol_n;
  initial begin aud_ok = 0; aud_bad = 0; vol_bad = 0; vol_n = 0; end
  always @(posedge clk) begin : aud_mon
    logic signed [25:0] pl, pr;
    if (dut.ap_ph == 2'd2 || dut.ap_ph == 2'd3) begin
      if (dut.aud_q == 16'((32'(dut.ap_cur) << 4) + 32'(dut.ap_ri) + (dut.ap_ph == 2'd3 ? 1 : 0)))
        aud_ok <= aud_ok + 1;
      else
        aud_bad <= aud_bad + 1;
    end
    if (cd_l != vol_exp_l || cd_r != vol_exp_r) vol_bad <= vol_bad + 1;
    if (dut.smp_l != 16'd0) vol_n <= vol_n + 1;
    pl = $signed(dut.smp_l) * $signed({2'b00, dut.vol0} + 10'd1);
    pr = $signed(dut.smp_r) * $signed({2'b00, dut.vol1} + 10'd1);
    vol_exp_l <= pl[23:8];
    vol_exp_r <= pr[23:8];
  end

  // READ SUB-CHANNEL, format 1 (current position), LBA form
  logic [7:0]  sc_status, sc_track;
  logic [31:0] sc_abs, sc_rel;
  task automatic subch();
    cdb10(8'h42, 8'h00, 32'h40010000, 0, 16'd16, 0);   // SubQ, format 1
    cmd1(ID_CD, 16);
    sc_status = r_data.size() > 1 ? r_data[1] : 8'hFF;
    sc_track  = r_data.size() > 6 ? r_data[6] : 8'hFF;
    sc_abs    = r_data.size() > 11 ? {r_data[8], r_data[9], r_data[10], r_data[11]} : '1;
    sc_rel    = r_data.size() > 15 ? {r_data[12], r_data[13], r_data[14], r_data[15]} : '1;
  endtask

  // ---------------------------------------------------------------------
  // The cases
  // ---------------------------------------------------------------------
  initial begin : main
    bit ok;
    logic [2:0] ph, eph;
    int moved, bad, n0;
    int a_ok0, a_bad0, v_bad0, v_n0;
    byte unsigned saved [$];

    for (int i = 0; i < HD0_BLKS * 512; i++) img0[i] = pristine(0, i);
    for (int i = 0; i < HD1_BLKS * 512; i++) img1[i] = pristine(1, i);
    for (int i = 0; i < CD_BLKS * 512; i++)  img2[i] = pristine(2, i);
    for (int i = 0; i < 3; i++) begin img_blks[i] = 0; img_ro[i] = 1'b0; end

    // power-up: reset, then the slots mounted (HD1 left empty for now)
    cycles(10);
    reset_n = 1'b1;
    cycles(5);
    lg_mark = lg_slot.size();
    mount(0, HD0_BLKS, 1'b0);
    mount(2, CD_BLKS, 1'b1);
    wait_idle();
    check(lg_slot.size() == lg_mark + 1 && lg_slot[lg_mark] == 2 && lg_lba[lg_mark] == 32'hC000_0000 &&
          lg_n[lg_mark] == 2 && !lg_wr[lg_mark],
          "CD mount: the track table read, 2 blocks at 0xC0000000");
    check(dut.toc_ok == 1'b1, "CD mount: the track table taken");

    // --- selection: present targets only
    for (int id = 0; id < 8; id++) begin
      esp_did = 3'(id);
      cycles(2);
      check(tgt_sel == (id == 3 || id == 6), $sformatf("selection of t%0d", id));
    end
    esp_did = 3'd7;

    // --- the probe, mode 1: INQUIRY, TUR (UA 28 first), READ CAPACITY
    cdb6(8'h12, 0, 0, 0, 8'd36, 0);
    cmd1(ID_HD0, 36);
    check(r_status == 0 && r_msg == 0, "INQUIRY t3: GOOD, COMMAND COMPLETE");
    check(r_data.size() == 36, "INQUIRY t3: 36 bytes");
    if (r_data.size() == 36) begin
      check(r_data[0] == 8'h00 && r_data[1] == 8'h00 && r_data[2] == 8'h02 && r_data[3] == 8'h02 &&
            r_data[4] == 8'h1F, "INQUIRY t3: a SCSI-2 disk, 36 bytes");
      check(r_data[8] == "M" && r_data[9] == "i" && r_data[13] == "r" && r_data[16] == "S" &&
            r_data[21] == "D" && r_data[32] == "1" && r_data[34] == "0", "INQUIRY t3: the strings");
    end
    check(tgt_pc == 10'd0 && !tgt_req, "after MESSAGE ACCEPTED the target is idle");

    cdb6(8'h12, 0, 0, 0, 8'd255, 0);         // 255 allowed: 36 sent, then STATUS
    cmd1(ID_CD, 255);
    check(r_status == 0 && r_data.size() == 36, "INQUIRY t6, 255 allowed: 36 bytes");
    if (r_data.size() == 36)
      check(r_data[0] == 8'h05 && r_data[1] == 8'h80 && r_data[21] == "C" && r_data[24] == "R",
            "INQUIRY t6: a removable CD-ROM");

    cdb6(8'h12, 0, 0, 0, 8'd36, 0);
    cmd(ID_HD0, 36, 1, 8'h81, 1'b1);         // IDENTIFY LUN 1
    check(r_status == 0 && r_data.size() == 36 && r_data[0] == 8'h7F, "INQUIRY t3 LUN 1: qualifier 3, 7Fh");
    cdb6(8'h00, 0, 0, 0, 0, 0);
    cmd(ID_HD0, 0, 1, 8'h81, 1'b1);
    check32(32'(r_status), 2, "TUR t3 LUN 1: CHECK");
    cdb6(8'h03, 0, 0, 0, 8'd18, 0);
    cmd(ID_HD0, 18, 1, 8'h81, 1'b1);
    check(r_data.size() == 18 && r_data[2] == 8'h05 && r_data[12] == 8'h25, "REQUEST SENSE LUN 1: 05/25h");

    cdb6(8'h12, 8'h01, 8'h80, 0, 8'd255, 0); // EVPD: the serial number
    cmd1(ID_HD0, 255);
    check(r_status == 0 && r_data.size() == 12 && r_data[1] == 8'h80 && r_data[3] == 8'h08 &&
          r_data[4] == "M" && r_data[10] == "0" && r_data[11] == "0", "INQUIRY VPD 80h t3: MISTER00");
    cdb6(8'h12, 8'h01, 8'h00, 0, 8'd255, 0);
    cmd1(ID_CD, 255);
    check(r_status == 0 && r_data.size() == 6 && r_data[0] == 8'h05 && r_data[3] == 8'h02 &&
          r_data[5] == 8'h80, "INQUIRY VPD 00h t6: pages 00h, 80h");
    cdb6(8'h12, 8'h01, 8'h83, 0, 8'd255, 0);
    cmd1(ID_HD0, 255);
    check32(32'(r_status), 2, "INQUIRY VPD 83h: CHECK");
    sense(ID_HD0);
    check(sn_key == 4'h6 && sn_asc == 8'h28, "the pending UNIT ATTENTION 28h comes before the CHECK's sense");
    sense(ID_HD0);
    check(sn_key == 4'h0, "sense cleared once reported");

    cdb6(8'h00, 0, 0, 0, 0, 0);
    expect_check(ID_CD, 4'h6, 8'h28, "TUR t6 after the mount: UNIT ATTENTION, medium changed");
    cdb6(8'h00, 0, 0, 0, 0, 0);
    cmd1(ID_CD, 0);
    check32(32'(r_status), 0, "TUR t6: GOOD");

    cdb10(8'h25, 0, 0, 0, 0, 0);
    cmd1(ID_HD0, 8);
    check(r_status == 0 && r_data.size() == 8 &&
          {r_data[0], r_data[1], r_data[2], r_data[3]} == 32'(HD0_BLKS - 1) &&
          {r_data[4], r_data[5], r_data[6], r_data[7]} == 32'd512, "READ CAPACITY t3: 2047, 512");
    cdb10(8'h25, 0, 0, 0, 0, 0);
    cmd1(ID_CD, 8);
    check(r_status == 0 && r_data.size() == 8 &&
          {r_data[0], r_data[1], r_data[2], r_data[3]} == 32'(CD_DATA - 1) &&
          {r_data[4], r_data[5], r_data[6], r_data[7]} == 32'd2048,
          "READ CAPACITY t6: 2048-byte blocks at power-up (OSD 2048)");

    // --- OpenBIOS's sequence (mode 0): TUR leaves the target in STATUS
    cdb6(8'h00, 0, 0, 0, 0, 0);
    cmd(ID_HD0, 0, 0, 8'h80, 1'b1);
    check(r_status == -2 && tgt_req && tgt_phase == PH_STAT && esp_bsy,
          "mode 0: TUR t3 left in STATUS, bsy set");
    cdb6(8'h12, 0, 0, 0, 8'd36, 0);
    cmd(ID_HD0, 36, 0, 8'h80, 1'b1);
    check(r_status == 0 && r_data.size() == 36, "mode 0: the next SELATN (bsy still set) gets INQUIRY t3");
    cdb6(8'h00, 0, 0, 0, 0, 0);
    cmd(ID_CD, 0, 0, 8'h80, 1'b1);
    check(r_status == -2, "mode 0: TUR t6");
    read_check(ID_HD0, 0, 8'h28, 0, 1, 512, 0, "mode 0: t6 left in STATUS, READ(10) t3");
    // OpenBIOS's probe: t0-t7, INQUIRY then TUR
    n0 = 0;
    for (int id = 0; id < 8; id++) begin
      cdb6(8'h12, 0, 0, 0, 8'd36, 0);
      cmd(3'(id), 36, 0, 8'h80, 1'b1);
      if (r_status == 0) n0++;
      cdb6(8'h00, 0, 0, 0, 0, 0);
      cmd(3'(id), 0, 0, 8'h80, 1'b1);
    end
    check32(32'(n0), 2, "mode 0 probe of t0-t7: two targets answer");
    esp_bsy = 1'b0; esp_atn = 1'b0; cycles(3);

    // --- reads (t_scsi_read0: one by one, then by 8, mode 0)
    for (int b = 0; b < 16; b++) read_check(ID_HD0, 0, 8'h28, b, 1, 512, 0, $sformatf("READ(10) t3 block %0d", b));
    for (int b = 16; b < 32; b += 8) read_check(ID_HD0, 0, 8'h28, b, 8, 512, 0, $sformatf("READ(10) t3 blocks %0d+8", b));
    read_check(ID_HD0, 0, 8'h08, 100, 5, 512, 1, "READ(6) t3 100+5");
    lg_mark = lg_slot.size();
    read_check(ID_HD0, 0, 8'h28, 1000, 100, 512, 1, "READ(10) t3 1000+100 (four chunks)");
    check_chunks(0, 1'b0, 1000, 100, 4, "READ(10) 100 blocks");
    lg_mark = lg_slot.size();
    stall = 1'b1;
    read_check(ID_HD0, 0, 8'h08, 1500, 0, 512, 1, "READ(6) t3 count 0 = 256 blocks, ack withheld at random");
    stall = 1'b0;
    check_chunks(0, 1'b0, 1500, 256, 8, "READ(6) 256 blocks");
    sd_lat = 3000;                            // Main slower than the bus
    read_check(ID_HD0, 0, 8'h28, 300, 70, 512, 1, "READ(10) t3 300+70, slow hps_io");
    sd_lat = 40;
    read_check(ID_HD0, 0, 8'h28, HD0_BLKS - 1, 1, 512, 1, "READ(10) t3 the last block");
    cdb10(8'h28, 0, 32'(HD0_BLKS - 1), 0, 16'd2, 0);
    cmd1(ID_HD0, 1024);
    check(r_status == 2 && r_data.size() == 0, "READ(10) past the end: CHECK, no data");
    sense(ID_HD0);
    check(sn_key == 4'h5 && sn_asc == 8'h21 && sn_info == 32'(HD0_BLKS - 1),
          "past the end: 05/21h, information = the LBA");
    cdb10(8'h28, 0, 32'(HD0_BLKS), 0, 16'd0, 0);
    cmd1(ID_HD0, 0);
    check32(32'(r_status), 0, "READ(10) of 0 blocks at the end: GOOD");
    cdb10(8'h2B, 0, 32'd5, 0, 16'd0, 0);
    cmd1(ID_HD0, 0);
    check32(32'(r_status), 0, "SEEK(10): GOOD");
    cdb10(8'h2F, 0, 32'd5, 0, 16'd8, 0);
    cmd1(ID_HD0, 0);
    check32(32'(r_status), 0, "VERIFY(10): GOOD, no data");
    cdb10(8'h2F, 8'h02, 32'd5, 0, 16'd8, 0);
    expect_check(ID_HD0, 4'h5, 8'h24, "VERIFY with BYTCHK");

    // --- writes (t_scsi_write1: written, read back, restored)
    lg_mark = lg_slot.size();
    wdata.delete();
    for (int i = 0; i < 70 * 512; i++) wdata.push_back(8'(i * 7 + (i >> 9)));
    stall = 1'b1;
    cdb10(8'h2A, 0, 32'd200, 0, 16'd70, 0);
    cmd1(ID_HD0, 70 * 512);
    stall = 1'b0;
    check32(32'(r_status), 0, "WRITE(10) t3 200+70: GOOD");
    check_chunks(0, 1'b1, 200, 70, 3, "WRITE(10) 70 blocks");
    bad = 0;
    for (int i = 0; i < 70 * 512; i++) if (img0[200 * 512 + i] != wdata[i]) bad++;
    check32(32'(bad), 0, "WRITE(10): the image holds the data");
    bad = 0;
    for (int i = 0; i < 512; i++)
      if (img0[199 * 512 + i] != pristine(0, 199 * 512 + i) || img0[270 * 512 + i] != pristine(0, 270 * 512 + i))
        bad++;
    check32(32'(bad), 0, "WRITE(10): the blocks around it unchanged");
    read_check(ID_HD0, 0, 8'h28, 200, 70, 512, 1, "the written blocks read back");
    wdata.delete();
    for (int i = 0; i < 70 * 512; i++) wdata.push_back(pristine(0, 200 * 512 + i));
    cdb10(8'h2A, 0, 32'd200, 0, 16'd70, 0);
    cmd1(ID_HD0, 70 * 512);
    check32(32'(r_status), 0, "WRITE(10) restoring");
    wdata.delete();
    for (int i = 0; i < 512; i++) wdata.push_back(8'(255 - i));
    cdb6(8'h0A, 0, 0, 8'd8, 8'd1, 0);         // WRITE(6) block 8
    cmd1(ID_HD0, 512);
    check(r_status == 0 && img0[8 * 512] == 8'd255 && img0[8 * 512 + 511] == 8'd0, "WRITE(6) t3 block 8");
    wdata.delete();
    for (int i = 0; i < 512; i++) wdata.push_back(pristine(0, 8 * 512 + i));
    cmd1(ID_HD0, 512);
    bad = 0;
    for (int i = 0; i < HD0_BLKS * 512; i++) if (img0[i] != pristine(0, i)) bad++;
    check32(32'(bad), 0, "after the writes and restores, HD0's image is as made");

    // --- HD1: absent until mounted, then UA 28; read-only
    esp_did = ID_HD1; cycles(2);
    check(!tgt_sel, "t1 unmounted: no answer");
    mount(1, HD1_BLKS, 1'b1);
    esp_did = ID_HD1; cycles(2);
    check(tgt_sel, "t1 mounted: answers");
    cdb6(8'h00, 0, 0, 0, 0, 0);
    expect_check(ID_HD1, 4'h6, 8'h28, "t1 after its mount: UNIT ATTENTION 28h");
    read_check(ID_HD1, 1, 8'h28, HD1_BLKS - 8, 8, 512, 1, "READ(10) t1 its last 8 blocks");
    wdata.delete();
    for (int i = 0; i < 512; i++) wdata.push_back(8'h00);
    cdb10(8'h2A, 0, 32'd0, 0, 16'd1, 0);
    expect_check(ID_HD1, 4'h7, 8'h27, "WRITE(10) on a read-only image: DATA PROTECT");
    lg_mark = lg_slot.size();
    cdb10(8'h2A, 0, 32'd0, 0, 16'd1, 0);
    cmd1(ID_HD1, 512);
    check(r_status == 2 && !r_dphase && lg_slot.size() == lg_mark, "read-only: no data phase, no request");
    cdb6(8'h1A, 0, 8'h00, 0, 8'd255, 0);
    cmd1(ID_HD1, 255);
    check(r_status == 0 && r_data.size() == 12 && r_data[2] == 8'h80, "MODE SENSE t1: WP set");
    // two disks in turn (t_scsi_two0)
    for (int b = 0; b < 4; b++) begin
      read_check(ID_HD0, 0, 8'h28, 40 + b, 1, 512, 0, "t3 and t1 in turn: t3");
      cdb6(8'h00, 0, 0, 0, 0, 0);
      cmd(ID_HD1, 0, 0, 8'h80, 1'b1);
      read_check(ID_HD1, 1, 8'h28, 40 + b, 1, 512, 0, "t3 and t1 in turn: t1");
    end
    esp_bsy = 1'b0; esp_atn = 1'b0; cycles(3);

    // --- sense (t_scsi_sense1: 255 allowed, 18 sent)
    cdb6(8'hFF, 0, 0, 0, 0, 0);
    cmd1(ID_HD0, 0);
    check32(32'(r_status), 2, "an invalid opcode: CHECK");
    cdb6(8'h03, 0, 0, 0, 8'd255, 0);
    cmd1(ID_HD0, 255);
    check(r_status == 0 && r_data.size() == 18 && r_data[2] == 8'h05 && r_data[12] == 8'h20 &&
          r_data[16] == 8'h00 && r_data[17] == 8'h00, "REQUEST SENSE, 255 allowed: 18 bytes, 05/20h");
    cdb6(8'hFF, 0, 0, 0, 0, 0);
    cmd1(ID_HD0, 0);
    cdb6(8'h03, 0, 0, 0, 8'd0, 0);
    cmd1(ID_HD0, 255);
    check(r_status == 0 && r_data.size() == 4 && r_data[2] == 8'h05, "REQUEST SENSE, allocation 0: 4 bytes");
    cdb6(8'h00, 8'h20, 0, 0, 0, 0);           // LUN 1 in the CDB, no IDENTIFY
    cmd(ID_HD0, 0, 1, 8'h00, 1'b0);
    check32(32'(r_status), 2, "SCSI-1 (no ATN), LUN 1 in the CDB: CHECK");
    cdb6(8'h00, 0, 0, 0, 0, 0);
    cmd(ID_HD0, 0, 1, 8'h00, 1'b0);
    check32(32'(r_status), 0, "SCSI-1 (no ATN), LUN 0: TUR GOOD");

    // --- other disk commands
    cdb6(8'h04, 0, 0, 0, 0, 0);    cmd1(ID_HD0, 0); check32(32'(r_status), 0, "FORMAT UNIT: GOOD");
    cdb6(8'h1B, 0, 0, 0, 8'h01, 0); cmd1(ID_HD0, 0); check32(32'(r_status), 0, "START UNIT: GOOD");
    cdb10(8'h35, 0, 0, 0, 0, 0);   cmd1(ID_HD0, 0); check32(32'(r_status), 0, "SYNCHRONIZE CACHE: GOOD");
    cdb6(8'h1D, 8'h04, 0, 0, 0, 0); cmd1(ID_HD0, 0); check32(32'(r_status), 0, "SEND DIAGNOSTIC: GOOD");
    cdb10(8'h37, 0, 32'h08000000, 0, 16'd4, 0);
    cmd1(ID_HD0, 4);
    check(r_status == 0 && r_data.size() == 4 && r_data[1] == 8'h08, "READ DEFECT DATA: an empty list");

    // --- MODE SENSE
    cdb6(8'h1A, 0, 8'h3F, 0, 8'd255, 0);
    cmd1(ID_HD0, 255);
    check(r_status == 0 && r_data.size() == 68, "MODE SENSE(6) t3 3Fh: 68 bytes");
    if (r_data.size() == 68) begin
      check(r_data[0] == 8'd67 && r_data[2] == 8'h00 && r_data[3] == 8'd8, "MODE SENSE(6): header");
      check({r_data[5], r_data[6], r_data[7]} == 24'(HD0_BLKS) && {r_data[9], r_data[10], r_data[11]} == 24'd512,
            "MODE SENSE(6): block descriptor");
      check(r_data[12] == 8'h01 && r_data[13] == 8'h0A && r_data[14] == 8'h80, "MODE SENSE(6): page 1");
      check(r_data[24] == 8'h04 && r_data[25] == 8'h16 && r_data[28] == 8'd2 && r_data[29] == 8'h10,
            "MODE SENSE(6): page 4, 2 cylinders of 16 heads");
      check(r_data[48] == 8'h08 && r_data[49] == 8'h12, "MODE SENSE(6): page 8");
    end
    cdb10(8'h5A, 8'h08, 32'h04000000, 0, 16'd255, 0);   // DBD, page 4
    cmd1(ID_HD0, 255);
    check(r_status == 0 && r_data.size() == 32 && r_data[1] == 8'd30 && r_data[7] == 8'd0 && r_data[8] == 8'h04,
          "MODE SENSE(10) DBD page 4: 32 bytes");
    cdb6(8'h1A, 0, 8'hC1, 0, 8'd255, 0);
    expect_check(ID_HD0, 4'h5, 8'h39, "MODE SENSE saved values");
    cdb6(8'h1A, 0, 8'h2A, 0, 8'd255, 0);
    expect_check(ID_HD0, 4'h5, 8'h24, "MODE SENSE page 2Ah on a disk");

    // --- the CD: block size by MODE SELECT, writes refused
    read_check(ID_CD, 2, 8'h28, 3, 2, 2048, 1, "READ(10) t6 2048-byte blocks 3+2");
    wdata.delete();
    for (int i = 0; i < 2048; i++) wdata.push_back(8'h00);
    cdb10(8'h2A, 0, 32'd0, 0, 16'd1, 0);
    expect_check(ID_CD, 4'h5, 8'h20, "WRITE(10) on the CD");
    wdata = '{8'h00, 8'h00, 8'h00, 8'h08, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h02, 8'h00};
    cdb6(8'h15, 8'h10, 0, 0, 8'd12, 0);
    cmd1(ID_CD, 12);
    check32(32'(r_status), 0, "MODE SELECT(6) t6: 512-byte blocks");
    cdb10(8'h25, 0, 0, 0, 0, 0);
    cmd1(ID_CD, 8);
    check(r_status == 0 && {r_data[0], r_data[1], r_data[2], r_data[3]} == 32'(CD_BLKS - 1) &&
          {r_data[4], r_data[5], r_data[6], r_data[7]} == 32'd512, "READ CAPACITY t6: 4095, 512");
    read_check(ID_CD, 2, 8'h28, 13, 3, 512, 1, "READ(10) t6 512-byte blocks 13+3");
    cdb6(8'h1A, 0, 8'h00, 0, 8'd255, 0);
    cmd1(ID_CD, 255);
    check(r_status == 0 && r_data.size() == 12 && r_data[2] == 8'h80 && r_data[10] == 8'h02 && r_data[11] == 8'h00,
          "MODE SENSE t6: write-protected, block descriptor 512");
    wdata = '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h08,
              8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h08, 8'h00};
    cdb10(8'h55, 8'h10, 0, 0, 16'd16, 0);
    cmd1(ID_CD, 16);
    check32(32'(r_status), 0, "MODE SELECT(10) t6: 2048-byte blocks");
    cdb10(8'h25, 0, 0, 0, 0, 0);
    cmd1(ID_CD, 8);
    check({r_data[4], r_data[5], r_data[6], r_data[7]} == 32'd2048, "READ CAPACITY t6: 2048 again");
    wdata = '{8'h00, 8'h00, 8'h00, 8'h08, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h02, 8'h00};
    cdb6(8'h15, 8'h10, 0, 0, 8'd12, 0);
    cmd1(ID_HD0, 12);
    cdb10(8'h25, 0, 0, 0, 0, 0);
    cmd1(ID_HD0, 8);
    check({r_data[4], r_data[5], r_data[6], r_data[7]} == 32'd512, "MODE SELECT on a disk: accepted, 512 stays");

    // --- messages: SDTR as Sun's esp driver sends it (t_scsi_sdtr1)
    select(ID_HD0, 1'b1, ok);
    wait_req(ph);
    outq = '{8'hC0};
    ti(PH_MOUT, 1, 1'b0, moved, eph);         // SELATNS: ATN stays
    wait_req(ph);
    check(ph == PH_MOUT, "SDTR: stopped in MESSAGE OUT");
    outq = '{8'h01, 8'h03, 8'h01, 8'h19, 8'h08};
    ti(PH_MOUT, 5, 1'b1, moved, eph);
    saved.delete();
    for (int i = 0; i < 5; i++) begin
      wait_req(ph);
      check(ph == PH_MIN, $sformatf("SDTR: reply byte %0d in MESSAGE IN", i));
      inq.delete();
      ti(PH_MIN, 1, 1'b0, moved, eph);
      if (inq.size() == 1) saved.push_back(inq[0]);
      cycles(20);                              // MESSAGE ACCEPTED: a bus service, not a disconnect
      check(esp_bsy && tgt_pc != 10'd0, "SDTR: still connected after MESSAGE ACCEPTED");
    end
    check(saved.size() == 5 && saved[0] == 8'h01 && saved[1] == 8'h03 && saved[2] == 8'h01 &&
          saved[3] == 8'h19 && saved[4] == 8'h00, "SDTR: answered 01 03 01 19 00 (asynchronous)");
    cdb6(8'h12, 0, 0, 0, 8'd36, 0);
    from_command(36, 1);
    check(r_status == 0 && r_data.size() == 36 && r_data[0] == 8'h00, "SDTR: then the CDB, INQUIRY t3");

    // WDTR: rejected
    select(ID_HD0, 1'b1, ok);
    wait_req(ph);
    outq = '{8'hC0, 8'h01, 8'h02, 8'h03, 8'h01};
    ti(PH_MOUT, 5, 1'b1, moved, eph);
    wait_req(ph);
    inq.delete();
    ti(PH_MIN, 1, 1'b0, moved, eph);
    check(ph == PH_MIN && inq.size() == 1 && inq[0] == 8'h07, "WDTR: MESSAGE REJECT");
    cdb6(8'h00, 0, 0, 0, 0, 0);
    from_command(0, 1);
    check32(32'(r_status), 0, "WDTR: then TUR GOOD");

    // a SIMPLE QUEUE TAG (t_scsi_tag1)
    select(ID_HD0, 1'b1, ok);
    wait_req(ph);
    outq = '{8'hC0};
    ti(PH_MOUT, 1, 1'b0, moved, eph);
    wait_req(ph);
    outq = '{8'h20, 8'h05};
    ti(PH_MOUT, 2, 1'b1, moved, eph);
    wait_req(ph);
    check(ph == PH_CMD, "SIMPLE QUEUE TAG: taken, then COMMAND");
    cdb6(8'h12, 0, 0, 0, 8'd36, 0);
    from_command(36, 1);
    check(r_status == 0 && r_data.size() == 36, "SIMPLE QUEUE TAG: INQUIRY GOOD");
    // HEAD OF QUEUE, ORDERED in one go
    select(ID_HD0, 1'b1, ok);
    wait_req(ph);
    outq = '{8'h80, 8'h21, 8'h09};
    ti(PH_MOUT, 3, 1'b1, moved, eph);
    cdb6(8'h00, 0, 0, 0, 0, 0);
    from_command(0, 1);
    check32(32'(r_status), 0, "HEAD OF QUEUE tag with IDENTIFY: TUR GOOD");
    // an unknown two-byte message: rejected, its second byte not taken for a message
    select(ID_HD0, 1'b1, ok);
    wait_req(ph);
    outq = '{8'h80, 8'h23, 8'h0C};
    ti(PH_MOUT, 3, 1'b1, moved, eph);
    wait_req(ph);
    inq.delete();
    ti(PH_MIN, 1, 1'b0, moved, eph);
    check(ph == PH_MIN && inq.size() == 1 && inq[0] == 8'h07, "two-byte message 23h: MESSAGE REJECT");
    cdb6(8'h00, 0, 0, 0, 0, 0);
    from_command(0, 1);
    check32(32'(r_status), 0, "23h 0Ch: the 0Ch was not BUS DEVICE RESET (no UNIT ATTENTION)");

    // ABORT
    select(ID_HD0, 1'b1, ok);
    wait_req(ph);
    outq = '{8'h80, 8'h06};
    ti(PH_MOUT, 2, 1'b1, moved, eph);
    cycles(10);
    check(!tgt_req && tgt_pc == 10'd14, "ABORT: the target waits for bus free");
    esp_bsy = 1'b0; cycles(3);
    check(tgt_pc == 10'd0, "ABORT: idle");
    // BUS DEVICE RESET
    select(ID_HD0, 1'b1, ok);
    wait_req(ph);
    outq = '{8'h80, 8'h0C};
    ti(PH_MOUT, 2, 1'b1, moved, eph);
    esp_bsy = 1'b0; cycles(3);
    expect_check(ID_HD0, 4'h6, 8'h29, "after BUS DEVICE RESET: UNIT ATTENTION 29h");

    // ATN in the middle of a long read, a block request in flight (a slow
    // hps_io): MESSAGE OUT, ABORT; no stray requests after it (h_left
    // saturates, see the RTL)
    sd_lat = 3000;
    select(ID_HD0, 1'b1, ok);
    wait_req(ph);
    outq = '{8'h80};
    ti(PH_MOUT, 1, 1'b1, moved, eph);
    cdb10(8'h28, 0, 32'd600, 0, 16'd200, 0);
    wait_req(ph);
    outq = cdbq;
    ti(PH_CMD, 10, 1'b0, moved, eph);
    wait_req(ph);
    inq.delete();
    ti(PH_DIN, 40000, 1'b0, moved, eph);      // into the third chunk
    esp_atn = 1'b1;
    wait_req(ph);
    check(ph == PH_MOUT, "ATN during DATA IN: MESSAGE OUT");
    outq = '{8'h06};
    ti(PH_MOUT, 1, 1'b1, moved, eph);
    check(sd_st != SD_IDLE, "the abort comes with a block request in flight");
    esp_bsy = 1'b0;
    sd_lat = 40;
    cycles(20000);
    lg_mark = lg_slot.size();
    cdb6(8'h00, 0, 0, 0, 0, 0);               // a command without blocks frees the halves
    cmd1(ID_HD0, 0);
    cycles(20000);
    check(r_status == 0 && lg_slot.size() == lg_mark && sd_st == SD_IDLE && dut.h_left == 32'd0,
          "after the abort and a TUR: no more block requests");
    read_check(ID_HD0, 0, 8'h28, 610, 40, 512, 1, "after the abort: READ(10) t3 610+40");

    // --- a bus reset: UNIT ATTENTION 29h everywhere
    esp_rst = 1'b1; cycles(2); esp_rst = 1'b0; cycles(2);
    cdb6(8'h00, 0, 0, 0, 0, 0);
    expect_check(ID_HD0, 4'h6, 8'h29, "after a bus reset: t3 UNIT ATTENTION 29h");
    cdb6(8'h00, 0, 0, 0, 0, 0);
    expect_check(ID_CD, 4'h6, 8'h29, "after a bus reset: t6 UNIT ATTENTION 29h");
    cdb10(8'h25, 0, 0, 0, 0, 0);
    cmd1(ID_CD, 8);
    check({r_data[4], r_data[5], r_data[6], r_data[7]} == 32'd2048, "a bus reset keeps the CD's block size");

    // --- CD audio
    cdb10(8'h43, 8'h00, 32'h00000000, 8'd0, 16'd804, 0);  // READ TOC format 0, LBA, from track 0
    cmd1(ID_CD, 804);
    check(r_status == 0 && r_data.size() == 36, "READ TOC: 4 + 4 descriptors");
    if (r_data.size() == 36) begin
      check(r_data[0] == 8'd0 && r_data[1] == 8'd34 && r_data[2] == 8'd1 && r_data[3] == 8'd3,
            "READ TOC: length 34, tracks 1-3");
      check(r_data[5] == 8'h14 && r_data[6] == 8'd1 && {r_data[8], r_data[9], r_data[10], r_data[11]} == 32'd0,
            "READ TOC: track 1, data, LBA 0");
      check(r_data[13] == 8'h10 && r_data[14] == 8'd2 &&
            {r_data[16], r_data[17], r_data[18], r_data[19]} == 32'(CD_DATA), "READ TOC: track 2, audio");
      check(r_data[22] == 8'd3 && {r_data[24], r_data[25], r_data[26], r_data[27]} == 32'(CD_DATA + 150),
            "READ TOC: track 3");
      check(r_data[30] == 8'hAA && {r_data[32], r_data[33], r_data[34], r_data[35]} == 32'(CD_DATA + 300),
            "READ TOC: the lead-out");
    end
    cdb10(8'h43, 8'h02, 32'h00000000, 8'd2, 16'd804, 0);  // MSF, from track 2
    cmd1(ID_CD, 804);
    check(r_status == 0 && r_data.size() == 28 && r_data[6] == 8'd2 && r_data[8] == 8'd0 &&
          r_data[9] == 8'd0 && r_data[10] == 8'd15 && r_data[11] == 8'd49,
          "READ TOC MSF from track 2: 00:15:49 (1174 + 150 frames)");
    cdb10(8'h43, 8'h00, 32'h00000000, 8'hAA, 16'd804, 0);
    cmd1(ID_CD, 804);
    check(r_status == 0 && r_data.size() == 12 && r_data[6] == 8'hAA, "READ TOC track AAh: the lead-out alone");
    cdb10(8'h43, 8'h00, 32'h01000000, 8'd0, 16'd804, 0);
    cmd1(ID_CD, 804);
    check(r_status == 0 && r_data.size() == 12 && r_data[2] == 8'd1 && r_data[3] == 8'd1 && r_data[6] == 8'd1,
          "READ TOC format 1: the first session");
    cdb10(8'h43, 8'h00, 32'h00000000, 8'd4, 16'd804, 0);
    expect_check(ID_CD, 4'h5, 8'h24, "READ TOC from track 4");

    subch();
    check(r_status == 0 && sc_status == 8'h15, "READ SUB-CHANNEL before playing: no status");
    // PLAY AUDIO TRACK/INDEX, track 2
    lg_mark = lg_slot.size();
    a_ok0 = aud_ok; a_bad0 = aud_bad; v_bad0 = vol_bad; v_n0 = vol_n;
    cdb10(8'h48, 0, 32'h00000201, 8'd0, 16'h0201, 0);    // start track 2 index 1, end track 2 index 1
    cmd1(ID_CD, 0);
    check32(32'(r_status), 0, "PLAY AUDIO TRACK/INDEX 2: GOOD");
    cycles(30000);
    subch();
    check(sc_status == 8'h11 && sc_track == 8'd2 && sc_abs >= 32'(CD_DATA) && sc_abs < 32'(CD_DATA + 150) &&
          sc_rel == sc_abs - 32'(CD_DATA), "SUB-CHANNEL: playing track 2, positions");
    n0 = int'(sc_abs);
    cycles(30000);
    subch();
    check(sc_status == 8'h11 && int'(sc_abs) > n0, "SUB-CHANNEL: the position moves");
    cdb10(8'h4B, 0, 0, 0, 16'd0, 0);                      // PAUSE
    cmd1(ID_CD, 0);
    check32(32'(r_status), 0, "PAUSE: GOOD");
    subch();
    n0 = int'(sc_abs);
    check(sc_status == 8'h12, "SUB-CHANNEL: paused");
    cycles(30000);
    subch();
    check(sc_status == 8'h12 && int'(sc_abs) == n0, "SUB-CHANNEL: still while paused");
    cdb10(8'h4B, 0, 0, 0, 16'd1, 0);                      // RESUME
    cmd1(ID_CD, 0);
    check32(32'(r_status), 0, "RESUME: GOOD");
    for (int i = 0; i < 400; i++) begin
      cycles(10000);
      subch();
      if (sc_status != 8'h11) break;
    end
    check(sc_status == 8'h13 && sc_abs == 32'(CD_DATA + 150), "SUB-CHANNEL: completed past track 2's last frame");
    subch();
    check(sc_status == 8'h15, "SUB-CHANNEL: then no status");
    check(aud_bad == a_bad0 && aud_ok - a_ok0 >= 2 * 150 * 588,
          $sformatf("every sample of track 2 played from its frame (%0d ok, %0d bad)", aud_ok - a_ok0, aud_bad - a_bad0));
    bad = 0;
    for (int i = lg_mark; i < lg_slot.size(); i++)
      if (lg_slot[i] == 2 && lg_lba[i] >= 32'h8000_0000 &&
          (lg_n[i] != 5 || (lg_lba[i] - 32'h8000_0000) % 5 != 0 ||
           (lg_lba[i] - 32'h8000_0000) / 5 < 32'(CD_DATA) || (lg_lba[i] - 32'h8000_0000) / 5 >= 32'(CD_DATA + 150)))
        bad++;
    check32(32'(bad), 0, "the frames fetched: 5 blocks at 0x80000000 + 5f, f in track 2");
    check(vol_bad == v_bad0 && vol_n > v_n0, "cd_l/cd_r: the samples at volume FFh");

    cdb6(8'h1A, 0, 8'h0E, 0, 8'd255, 0);
    cmd1(ID_CD, 255);
    check(r_status == 0 && r_data.size() == 28 && r_data[12] == 8'h0E && r_data[21] == 8'hFF && r_data[23] == 8'hFF,
          "MODE SENSE page 0Eh: both volumes FFh");
    wdata = '{8'h00, 8'h00, 8'h00, 8'h00,
              8'h0E, 8'h0E, 8'h04, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h01, 8'h7F, 8'h02, 8'h3F, 8'h00, 8'h00};
    cdb6(8'h15, 8'h10, 0, 0, 8'd18, 0);
    cmd1(ID_CD, 18);
    check(r_status == 0 && dut.vol0 == 8'h7F && dut.vol1 == 8'h3F, "MODE SELECT page 0Eh: volumes 7Fh, 3Fh");
    // PLAY AUDIO(10) at the lower volume, then STOP
    a_bad0 = aud_bad; v_bad0 = vol_bad; v_n0 = vol_n;
    cdb10(8'h45, 0, 32'(CD_DATA + 160), 0, 16'd20, 0);
    cmd1(ID_CD, 0);
    check32(32'(r_status), 0, "PLAY AUDIO(10) 1184+20: GOOD");
    cycles(40000);
    subch();
    check(sc_status == 8'h11 && sc_track == 8'd3, "PLAY AUDIO(10): playing track 3");
    cdb10(8'h4E, 0, 0, 0, 0, 0);
    cmd1(ID_CD, 0);
    subch();
    check(r_status == 0 && sc_status == 8'h15, "STOP PLAY: stopped");
    check(vol_bad == v_bad0 && vol_n > v_n0 && aud_bad == a_bad0, "cd_l/cd_r at volumes 7Fh/3Fh");
    // PLAY AUDIO MSF 00:16:00-00:16:05
    cdb10(8'h47, 0, 32'h00001000, 8'h00, 16'h1005, 0);
    cdbq[3] = 8'h00; cdbq[4] = 8'd16; cdbq[5] = 8'd0;
    cdbq[6] = 8'h00; cdbq[7] = 8'd16; cdbq[8] = 8'd5;
    cmd1(ID_CD, 0);
    check32(32'(r_status), 0, "PLAY AUDIO MSF: GOOD");
    cycles(5000);
    subch();
    check(sc_status == 8'h11 && sc_abs >= 32'(16 * 75 - 150) && sc_abs < 32'(16 * 75 - 145),
          "PLAY AUDIO MSF: from 00:16:00");
    cdb6(8'h1B, 0, 0, 0, 8'h00, 0);           // STOP UNIT stops the audio too
    cmd1(ID_CD, 0);
    subch();
    check(sc_status == 8'h15, "STOP UNIT: the audio stops");
    cdb10(8'h45, 0, 32'(CD_DATA + 290), 0, 16'd20, 0);
    expect_check(ID_CD, 4'h5, 8'h21, "PLAY AUDIO past the lead-out");
    cdb10(8'h4B, 0, 0, 0, 16'd1, 0);
    expect_check(ID_CD, 4'h5, 8'h2C, "RESUME while stopped");
    cdb10(8'h45, 0, 32'd100, 0, 16'd20, 0);
    expect_check(ID_HD0, 4'h5, 8'h20, "PLAY AUDIO on a disk");

    // --- the CD from an older Main (no track table): one data track
    cd_audio = 0;
    mount(2, CD_BLKS, 1'b1);
    wait_idle();
    check(dut.toc_ok == 1'b0, "no track table: none taken");
    tur_clear(ID_CD);
    cdb10(8'h43, 8'h00, 32'h00000000, 8'd0, 16'd804, 0);
    cmd1(ID_CD, 804);
    check(r_status == 0 && r_data.size() == 20 && r_data[1] == 8'h12 && r_data[3] == 8'd1 &&
          r_data[6] == 8'd1 && r_data[14] == 8'hAA && {r_data[16], r_data[17], r_data[18], r_data[19]} == 32'(CD_DATA),
          "READ TOC without the table: track 1 and the lead-out at the image's end");
    cdb10(8'h43, 8'h02, 32'h00000000, 8'd0, 16'd804, 0);
    cmd1(ID_CD, 804);
    check(r_status == 0 && r_data.size() == 20 && r_data[17] == 8'd0 && r_data[18] == 8'd15 && r_data[19] == 8'd49,
          "READ TOC MSF without the table: lead-out 00:15:49");
    cdb10(8'h48, 0, 32'h00000201, 8'd0, 16'h0201, 0);
    expect_check(ID_CD, 4'h5, 8'h20, "PLAY without the table: rejected");
    subch();
    check(r_status == 0 && sc_status == 8'h15 && sc_track == 8'd1, "SUB-CHANNEL without the table: track 1");

    // --- an eject: NOT READY, still selectable
    img_size = '0;
    img_mounted[2] = 1'b1; cycles(2); img_mounted[2] = 1'b0; cycles(2);
    esp_did = ID_CD; cycles(2);
    check(tgt_sel, "no disc: t6 still answers selection");
    cdb6(8'h00, 0, 0, 0, 0, 0);
    expect_check(ID_CD, 4'h6, 8'h28, "eject: UNIT ATTENTION");
    cdb6(8'h00, 0, 0, 0, 0, 0);
    expect_check(ID_CD, 4'h2, 8'h3A, "no disc: TUR NOT READY 3Ah");
    cdb10(8'h25, 0, 0, 0, 0, 0);
    expect_check(ID_CD, 4'h2, 8'h3A, "no disc: READ CAPACITY NOT READY");

    // --- the OSD's 512-byte CD from a machine reset; mounts survive it
    cd_audio = 2;
    mount(2, CD_BLKS, 1'b1);
    wait_idle();
    cd2048 = 1'b0;
    reset_n = 1'b0; cycles(5); reset_n = 1'b1; cycles(5);
    tur_clear(ID_CD);
    cdb10(8'h25, 0, 0, 0, 0, 0);
    cmd1(ID_CD, 8);
    check(r_status == 0 && {r_data[4], r_data[5], r_data[6], r_data[7]} == 32'd512 &&
          {r_data[0], r_data[1], r_data[2], r_data[3]} == 32'(CD_BLKS - 1), "after a reset with the OSD at 512: 512-byte CD blocks");
    cdb6(8'h00, 0, 0, 0, 0, 0);
    expect_check(ID_HD0, 4'h6, 8'h29, "after a machine reset: t3 still mounted, UNIT ATTENTION 29h");
    read_check(ID_HD0, 0, 8'h28, 7, 3, 512, 1, "after a machine reset: READ(10) t3");

    check32(32'(proto_err), 0, "no protocol errors or time-outs");
    tb_done("tb_scsi_targets");
  end

  initial begin
    #2_000_000_000;
    $display("FAIL tb_scsi_targets: global time-out");
    $fatal(1, "time-out");
  end

endmodule
