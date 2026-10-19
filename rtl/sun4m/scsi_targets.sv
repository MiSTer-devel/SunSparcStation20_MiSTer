// SPDX-License-Identifier: GPL-2.0-or-later
//
// scsi_targets: the SCSI target engine behind the ESP -- two disks and a
// CD-ROM served from the MiSTer's SD image slots through hps_io's block
// interface.
//
// One engine serves every target: the ESP has one nexus at a time. Blocks
// move to and from hps_io in chunks of up to 32 (16 KB, hps_io's
// sd_blk_cnt): Main writes an image O_SYNC, a few ms per call, so an 8 KB
// write is one call instead of sixteen. The buffer has two 16 KB halves:
// the next chunk is fetched (reads) or received (writes) while the other
// one moves on the SCSI side.
//
// Slots: 0 HD0, 1 HD1, 2 CD, at the IDs on the ports (3, 1, 6 on a Sun).
// A disk answers selection while its image is mounted; the CD answers
// whenever it is enabled, NOT READY without a disc.
//
// Behaviour follows SCSI-2 and QEMU's scsi-disk (where the test images were
// installed): UNIT ATTENTION after a reset (29h) or a mount (28h),
// fixed-format sense, bounds and write-protect checks, LUN 0 only, mode
// pages 1, 4, 8 (disk) and 1, 8, 2Ah, 0Eh (CD), READ TOC formats 0 and 1,
// the CD's block size 2048 or 512 (the OSD's choice after a reset, then a
// MODE SELECT block descriptor: Sun CD drives run at 512, the plan's
// CD-512). Messages: IDENTIFY (LUN), SDTR answered asynchronous (offset 0),
// other extended messages rejected, the two-byte queue tags (20h-22h: a
// queue of one, no disconnection), ABORT, BUS DEVICE RESET, NOP, REJECT.
//
// CD audio: Main serves two windows above the data on the CD slot (Main
// support/sun/sun_cdrom.h; plan §1.2):
//   - the track table, 2 blocks at TOC_BLK = 0xC000_0000, read at each
//     mount: byte 0 first track, 1 last track, 2 entries (the lead-out's
//     included), 3 valid (1); from byte 8 one 8-byte entry per track then
//     the lead-out: ADR/control, track, M, S, F (absolute, +150), LBA
//     (3 bytes, big-endian);
//   - the disc's frames: frame f at AUDIO_BLK = 0x8000_0000 + 5f, 2352
//     bytes of 16-bit little-endian samples (L, R, ...) then 208 of padding.
// PLAY AUDIO (10, 12, MSF, TRACK/INDEX), PAUSE/RESUME, STOP PLAY, READ
// SUB-CHANNEL and the audio control page (volume) work as on a SCSI-2
// drive; frames are fetched between the SCSI requests into a ring of four
// and played at 44.1 kHz on cd_l_o/cd_r_o. Without the table (an older
// Main) the disc is one data track and the audio commands are rejected.
//
// ---------------------------------------------------------------------------
// The ESP side: a flat request/response bus (rtl/sun4m/esp.sv is written
// against this). It is not the
// SCSI cable: there is no arbitration, no reselection and no parity; one
// clock (clk) for both sides.
//
//   esp_did_i[2:0]  the destination ID the ESP selects. The target engine
//                   compares it with the three IDs every cycle.
//   tgt_sel_o       "a present target has ID esp_did_i", registered: the
//                   ESP drives did and samples sel one cycle later; sel low
//                   is a selection time-out (Disconnected interrupt).
//   esp_bsy_i       the ESP's: set at selection (and by ICCS), cleared once
//                   ICCS has taken status and message. The engine starts a
//                   nexus when bsy is high and did matches, and returns to
//                   idle from its last state when bsy falls. A change of did
//                   while connected ends the nexus at once.
//   esp_atn_i       ATN: asks for MESSAGE OUT. After selection the engine
//                   waits 5 cycles (ATN may come a cycle or two after bsy)
//                   then goes to MESSAGE OUT with ATN, COMMAND without. The
//                   ESP drops ATN with the last message byte (at the latest
//                   the cycle after its req & ack); while ATN stays up the
//                   engine asks for more message bytes. ATN in any phase but
//                   MESSAGE OUT (the engine waiting for a byte with no
//                   transfer under way) starts a new MESSAGE OUT: OpenBIOS
//                   ends a command without data (TEST UNIT READY) without
//                   ICCS, so the target is still in STATUS with bsy set when
//                   the ESP selects it again with ATN. Its req for the
//                   status byte is then still up: the ESP must not ack it or
//                   take it for the reply. The engine drops req the cycle
//                   after it sees ATN and asks for MESSAGE OUT the cycle
//                   after that.
//   tgt_phase_o     the bus phase, as the 53C9x STATUS register's bits 2:0
//                   {MSG, C/D, I/O}: 0 DATA OUT, 1 DATA IN, 2 COMMAND,
//                   3 STATUS, 6 MESSAGE OUT, 7 MESSAGE IN. Bit 0 (I/O) high
//                   is towards the initiator. Valid whenever tgt_req_o is.
//   tgt_req_o       REQ, registered. A byte moves in a cycle where tgt_req_o
//   esp_ack_i       and esp_ack_i are both high; the ESP drives ack
//                   combinationally from req (gated by its own FIFO/DMA
//                   readiness: flow control is the ESP's to apply). req
//                   drops the next cycle.
//   tgt_d_o         IN phases: the byte, valid with req; the ESP takes it in
//                   the req & ack cycle.
//   esp_d_i         OUT phases: the ESP's byte, valid the cycle AFTER the
//                   req & ack cycle (a registered DMA byte); the engine
//                   takes it then, and raises req again only after that.
//   esp_rst_i       SCSI bus reset: every target back to idle, UNIT
//                   ATTENTION 29h pending, the CD player stopped.
//   tgt_pc_o[9:0]   debug: the engine's state number, for a bus tracer.
//
// The hps_io side (hps_io WIDE = 1: 16-bit words, byte 2w low, 2w+1 high;
// 512-byte blocks). One request at a time, for one slot:
//   sd_lba_o        the first block (shared by the slots: the top level
//                   fans it out to hps_io's per-slot sd_lba);
//   sd_blk_cnt_o    blocks - 1 (0-31), shared as sd_lba_o;
//   sd_rd_o/sd_wr_o one bit per slot, held until that slot's sd_ack_i
//                   rises;
//   sd_ack_i        hps_io's per-slot ack: the words move while it is high,
//                   sd_buff_addr_i counting through the whole chunk
//                   (13 bits: up to 32 blocks of 256 words);
//   sd_buff_dout_i  a word from Main (reads), written on sd_buff_wr_i;
//   sd_buff_wr_i    per slot: hps_io's sd_buff_wr AND sd_ack[n];
//   sd_buff_din_o   the word at sd_buff_addr_i for Main (writes): the data
//                   follows the address one clock later (a block RAM read);
//                   shared by the slots.
//   img_mounted_i   hps_io's per-slot mount strobe (edge-detected here; it
//                   may be held), with img_size_i (bytes; 0 = eject) and
//                   img_readonly_i. Mounts are not reset: they outlive the
//                   machine's resets, as the slots do. The CD is read-only.
//
// The RAMs are block-RAM templates (rtl/lib/ram_tdp8 for the 32 KB
// buffer's two byte lanes; simple dual-port arrays for the track table, its
// entries and the audio ring). When a block request completes, the blocks
// still to fetch or store (h_left) count down saturating at 0, so an abort
// (ATN, a change of did, a bus reset) that clears the count while a request
// is in flight ends the transfer.
// ---------------------------------------------------------------------------

module scsi_targets #(
  parameter int SYSFREQ = 50_000_000,   // clk, Hz (the 44.1 kHz player)
  parameter bit SIMU    = 1'b0          // 1: CD audio played 16 times faster
)(
  input  logic        clk,
  input  logic        reset_n,          // machine reset

  // The ESP side (see the header)
  input  logic [7:0]  esp_d_i,
  input  logic        esp_ack_i,
  input  logic        esp_bsy_i,
  input  logic        esp_atn_i,
  input  logic [2:0]  esp_did_i,
  input  logic        esp_rst_i,
  output logic [7:0]  tgt_d_o,
  output logic        tgt_req_o,
  output logic [2:0]  tgt_phase_o,
  output logic        tgt_sel_o,
  output logic [9:0]  tgt_pc_o,

  // The targets: slot 0 HD0, 1 HD1, 2 CD
  input  logic [2:0]  id0_i,
  input  logic [2:0]  id1_i,
  input  logic [2:0]  id2_i,
  input  logic [2:0]  ena_i,            // slot in use (OSD)
  input  logic        cd2048_i,         // CD block size after a reset: 1 2048, 0 512

  // The images (hps_io)
  input  logic [2:0]  img_mounted_i,
  input  logic [63:0] img_size_i,
  input  logic        img_readonly_i,

  // Block requests (hps_io)
  output logic [31:0] sd_lba_o,
  output logic [5:0]  sd_blk_cnt_o,
  output logic [2:0]  sd_rd_o,
  output logic [2:0]  sd_wr_o,
  input  logic [2:0]  sd_ack_i,
  input  logic [12:0] sd_buff_addr_i,
  input  logic [15:0] sd_buff_dout_i,
  output logic [15:0] sd_buff_din_o,
  input  logic [2:0]  sd_buff_wr_i,

  output logic        busy_o,           // a nexus or a block request under way
  // CD audio, signed 16-bit samples at 44.1 kHz
  output logic [15:0] cd_l_o,
  output logic [15:0] cd_r_o
);

  // ---------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------
  localparam logic [2:0] PH_DATA_OUT = 3'd0, PH_DATA_IN = 3'd1, PH_COMMAND = 3'd2,
                         PH_STATUS = 3'd3, PH_MSG_OUT = 3'd6, PH_MSG_IN = 3'd7;

  // Status bytes, sense keys
  localparam logic [7:0] ST_GOOD = 8'h00, ST_CHECK = 8'h02;
  localparam logic [3:0] SK_NONE = 4'h0, SK_NREADY = 4'h2, SK_ILLEG = 4'h5,
                         SK_UATT = 4'h6, SK_PROT = 4'h7;

  localparam int CHUNK = 32;                  // blocks per hps_io request

  localparam logic [31:0] AUDIO_BLK = 32'h8000_0000;
  localparam logic [31:0] TOC_BLK   = 32'hC000_0000;
  localparam int FRAME_W = 1176;              // 16-bit samples in a frame

  // 44.1 kHz from the core clock: a 24-bit phase accumulator's step,
  // rounded (16 times faster in simulation)
  localparam logic [63:0] AP_NUM  = 64'd44100 * 64'd16777216;
  localparam logic [63:0] AP_STEP = (AP_NUM + 64'(SYSFREQ / 2)) / 64'(SYSFREQ);
  localparam logic [24:0] AP_RATE = 25'(AP_STEP * (SIMU ? 64'd16 : 64'd1));

  // INQUIRY strings
  localparam logic [8*8-1:0]  VENDOR  = "MiSTer  ";
  localparam logic [16*8-1:0] PROD_HD = "SCSI Disk       ";
  localparam logic [16*8-1:0] PROD_CD = "SCSI CD-ROM     ";
  localparam logic [4*8-1:0]  REV     = "1.0 ";
  localparam logic [7*8-1:0]  SERIAL  = "MISTER0";

  // The engine's states (numbered: tgt_pc_o)
  typedef enum logic [4:0] {
    S_IDLE, S_SETTLE, S_MSGOUT, S_MSGIN_REPLY, S_CMD, S_EXEC,
    S_TOCDIV, S_FILL, S_DIN, S_DOUT, S_DOUT_END, S_RD_WAIT,
    S_STATUS, S_MSGIN, S_DONE,
    S_TOCGEN, S_PLAYTI, S_SUBCH, S_SUBDIV
  } st_e;

  // Generated replies
  typedef enum logic [3:0] {
    G_INQ, G_INQ0, G_INQ80, G_SENSE, G_CAP, G_MSENSE, G_DEFECT,
    G_TOC0, G_TOC1, G_TOCAA, G_SUBCH
  } gen_e;

  typedef enum logic [1:0] {H_IDLE, H_REQ, H_XFER} hs_e;

  // ---------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------
  // byte k (0: the low one) of a word, k taken modulo 4
  function automatic logic [7:0] b8(input logic [31:0] v, input int k);
    case (k & 3)
      0:       return v[7:0];
      1:       return v[15:8];
      2:       return v[23:16];
      default: return v[31:24];
    endcase
  endfunction

  // character i (0: the first) of an ASCII string constant of n characters
  function automatic logic [7:0] chr8(input logic [8*8-1:0] s, input int i);
    return s[8*(7 - i) +: 8];
  endfunction
  function automatic logic [7:0] chr16(input logic [16*8-1:0] s, input int i);
    return s[8*(15 - i) +: 8];
  endfunction
  function automatic logic [7:0] chr4(input logic [4*8-1:0] s, input int i);
    return s[8*(3 - i) +: 8];
  endfunction
  function automatic logic [7:0] chr7(input logic [7*8-1:0] s, input int i);
    return s[8*(6 - i) +: 8];
  endfunction

  // Mode pages: their total length (header included), by page code
  function automatic int page_len(input logic [5:0] p);
    case (p)
      6'h01:   return 12;
      6'h04:   return 24;
      6'h08:   return 20;
      6'h2A:   return 22;
      6'h0E:   return 16;
      default: return 0;
    endcase
  endfunction

  // Byte j of mode page p; pc: the page control (1: changeable, all 0)
  function automatic logic [7:0] page_byte(input logic [5:0] p, input int j,
                                           input logic [1:0] pc, input logic cd,
                                           input logic [23:0] cyl,
                                           input logic [7:0] v0, input logic [7:0] v1);
    logic [7:0] r;
    r = 8'h00;
    if (j == 0)
      r = {2'b00, p};
    else if (j == 1)
      r = 8'(page_len(p) - 2);
    else if (pc != 2'b01) begin
      case (p)
        6'h01: begin                          // read/write error recovery
          if (j == 2) r = 8'h80;              // AWRE
          if (j == 3 && cd) r = 8'h20;        // read retry count
        end
        6'h04: begin                          // rigid disk geometry
          case (j)
            2, 6, 9:    r = cyl[23:16];
            3, 7, 10:   r = cyl[15:8];
            4, 8, 11:   r = cyl[7:0];
            5:          r = 8'h10;            // 16 heads
            13:         r = 8'hC8;            // step rate 200 ns
            14, 15, 16: r = 8'hFF;            // landing zone
            20:         r = 8'h15;            // 5400 rpm
            21:         r = 8'h18;
            default:    ;
          endcase
        end
        6'h0E: begin                          // CD audio control: IMMED, the
          case (j)                            // ports' channels and volumes
            2:       r = 8'h04;
            8:       r = 8'h01;
            9:       r = v0;
            10:      r = 8'h02;
            11:      r = v1;
            default: ;
          endcase
        end
        6'h2A: begin                          // CD capabilities
          case (j)
            2:       r = 8'h3B;
            4:       r = 8'h7F;
            5:       r = 8'hFF;
            6:       r = 8'h2D;
            8:       r = 8'h22;               // 50x (8800 KB/s)
            9:       r = 8'h60;
            11:      r = 8'h02;               // two volume levels
            12:      r = 8'h08;               // 2 MB buffer
            default: ;
          endcase
        end
        default: ;
      endcase
    end
    return r;
  endfunction

  // (M*60 + S)*75 + F - 150, 0 below 150
  function automatic logic [23:0] msf2lba(input logic [7:0] m, input logic [7:0] s,
                                          input logic [7:0] f);
    logic [23:0] v;
    v = 24'(m) * 24'd4500 + 24'(s) * 24'd75 + 24'(f);
    return (v < 24'd150) ? 24'd0 : v - 24'd150;
  endfunction

  // ---------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------
  // The images
  logic [2:0]  mnt_d;
  logic [31:0] blk512 [3];                    // 512-byte blocks
  logic [2:0]  ro;

  // Per target
  logic [2:0]  ua;                            // UNIT ATTENTION pending
  logic [7:0]  ua_asc [3];
  logic [3:0]  s_key [3];
  logic [7:0]  s_asc [3];
  logic [7:0]  s_ascq [3];
  logic [31:0] s_info [3];
  logic        cd_bs2k;                       // CD: 2048-byte blocks

  // The bus side
  st_e         st;
  logic [1:0]  tgt;
  logic [2:0]  lun;
  logic        ident;                         // IDENTIFY received
  logic        req_r;
  logic [2:0]  phase_r;
  logic [7:0]  d_r;
  logic        sel_r;
  logic [2:0]  settle;
  logic [1:0]  dstep;                         // DATA IN: a byte's steps
  logic        got_msg;                       // MESSAGE OUT: a byte came
  logic        rx_d;                          // an OUT byte moved last cycle

  logic [7:0]  cdb [12];
  logic [3:0]  cdb_i;
  logic [3:0]  cdb_n;

  // Messages: an extended (or two-byte) message, the reply
  logic [7:0]  ext_n, ext_i;
  logic [7:0]  ext_code;
  logic [7:0]  ext_period;
  logic        in_ext;
  logic [1:0]  rep_kind;                      // 0 none, 1 SDTR, 2 reject
  logic [2:0]  rep_i;

  logic [7:0]  status;

  // Generated data (INQUIRY, sense, capacity, mode pages, TOC)
  gen_e        gen;
  logic [9:0]  gen_n;                         // bytes to send
  logic [7:0]  gen_i;
  logic [7:0]  resp_len;                      // the whole reply
  logic        ms10;
  logic        ms_dbd;
  logic [5:0]  ms_page;
  logic [1:0]  ms_pc;
  logic        msf;
  logic [7:0]  toc_m, toc_s, toc_f;           // lead-out, MSF
  logic [23:0] toc_rem;

  // Block transfers
  logic        xfer_disc;                     // data out, kept here (MODE SELECT)
  logic [13:0] nbytes;                        // byte in the half
  logic [13:0] cur_last;                      // its last byte
  logic [5:0]  cur_n;                         // its blocks
  logic [5:0]  ch_n [2];                      // blocks in each half
  logic        tx_half;                       // the half on the bus side
  logic [31:0] tx_left;                       // blocks still to move on the bus
  logic [7:0]  dout_n;                        // MODE SELECT bytes
  logic [7:0]  dout_i;
  logic [23:0] msel_bl;
  logic [7:0]  msel_bdl;

  // The hps side
  hs_e         hst;
  logic [31:0] h_lba;
  logic [31:0] h_left;                        // blocks to fetch/store
  logic        h_half;
  logic [5:0]  h_cnt;                         // blocks in this request
  logic        h_rd, h_wr;
  logic        h_wmode;
  logic [1:0]  full;

  // What the hps side is fetching: 0 SCSI blocks, 1 an audio frame, 2 the
  // track table; for which slot
  logic [1:0]  h_kind;
  logic [1:0]  h_slot;
  logic [31:0] h_alba;
  logic        h_agen;

  // The track table: Main's bytes (READ TOC), and per entry its ADR/control
  // and address (PLAY TRACK, READ SUB-CHANNEL)
  logic [9:0]  toc_ra;
  logic [7:0]  toc_qe, toc_qo;
  logic        toc_rodd;
  logic        ent_we;
  logic [6:0]  ent_wa, ent_ra;
  logic [31:0] ent_wd, ent_q;
  logic [7:0]  ent_ctl, ent_hi;
  logic        toc_want;
  logic        toc_ok;
  logic [7:0]  toc_first, toc_last, toc_vld;
  logic [6:0]  toc_n;                         // entries, the lead-out's included
  logic [23:0] toc_lead;

  // READ TOC from the table
  logic [9:0]  tg_i;
  logic [9:0]  tg_len;
  logic [6:0]  tg_si;
  logic        tg_fmt1;
  logic [1:0]  tg_ph;

  // The player: the ring of 4 frames (a frame per 2048 words)
  logic [12:0] aud_ra;
  logic [15:0] aud_q;
  logic        ap_play;
  logic        ap_pause;
  logic        ap_gen;                        // flips at each PLAY
  logic [23:0] ap_cur, ap_end, ap_fetch;
  logic [2:0]  ap_full;
  logic [1:0]  ap_ws, ap_rs;
  logic [10:0] ap_ri;
  logic [7:0]  ap_stat;                       // READ SUB-CHANNEL's audio status
  logic [1:0]  ap_ph;
  logic [24:0] ap_acc;                        // 44.1 kHz
  logic [15:0] smp_l, smp_r;
  logic [7:0]  vol0, vol1;                    // the audio control page
  /* verilator lint_off UNUSEDSIGNAL */
  logic [7:0]  msel_pg;                       // the page code: bits 7:6 are PS/SPF
  /* verilator lint_on UNUSEDSIGNAL */
  // PLAY AUDIO TRACK/INDEX, READ SUB-CHANNEL: table lookups
  logic [6:0]  pt_s, pt_e;                    // entries
  logic [2:0]  pt_ph;
  logic [23:0] sc_abs, sc_rel, sc_v;
  logic [6:0]  sc_i;
  logic [7:0]  sc_ctl, sc_trk;
  logic [7:0]  sc_am, sc_as, sc_af, sc_rm, sc_rs, sc_rf;
  logic [2:0]  sc_ph;
  logic        sc_msf;
  logic [7:0]  sc_fmt;
  logic [7:0]  sc_stat;

  // The buffer's ports. A: the bus side, bytes. B: hps_io, words.
  logic [14:0] a_adr;                         // byte: half & 14 bits
  logic        a_we;
  logic [7:0]  a_dw;
  logic [7:0]  a_dre, a_dro;
  logic        a_odd;
  logic [13:0] b_adr;                         // word: half & 13 bits
  logic        b_we;
  logic [7:0]  b_dre, b_dro;

  // Power-up values: the mounts and
  // the player, which no reset touches before their first use.
  initial begin
    mnt_d     = 3'b000;
    blk512[0] = 32'd0;
    blk512[1] = 32'd0;
    blk512[2] = 32'd0;
    ro        = 3'b000;
    toc_want  = 1'b0;
    toc_ok    = 1'b0;
    h_kind    = 2'd0;
    h_slot    = 2'd0;
    ap_play   = 1'b0;
    ap_pause  = 1'b0;
    ap_gen    = 1'b0;
    ap_stat   = 8'h15;
    ap_acc    = '0;
    smp_l     = 16'h0000;
    smp_r     = 16'h0000;
    vol0      = 8'hFF;
    vol1      = 8'hFF;
  end

  // ---------------------------------------------------------------------
  // The buffer: two halves of 16 KB, even and odd bytes in separate RAMs so
  // that hps_io's 16-bit words (byte 2w low, 2w+1 high) write both at once
  // ---------------------------------------------------------------------
  assign b_adr = {h_half, sd_buff_addr_i};
  assign b_we  = (|sd_buff_wr_i) && !h_wmode && h_kind == 2'd0;

  ram_tdp8 #(.AW(14)) u_mem_e (
    .clk,
    .a_addr(a_adr[14:1]), .a_we(a_we && !a_adr[0]), .a_wdata(a_dw), .a_rdata(a_dre),
    .b_addr(b_adr), .b_we, .b_wdata(sd_buff_dout_i[7:0]), .b_rdata(b_dre));

  ram_tdp8 #(.AW(14)) u_mem_o (
    .clk,
    .a_addr(a_adr[14:1]), .a_we(a_we && a_adr[0]), .a_wdata(a_dw), .a_rdata(a_dro),
    .b_addr(b_adr), .b_we, .b_wdata(sd_buff_dout_i[15:8]), .b_rdata(b_dro));

  always_ff @(posedge clk) a_odd <= a_adr[0];

  assign sd_buff_din_o = {b_dro, b_dre};

  // ---------------------------------------------------------------------
  // CD audio: the ring (a frame's 1176 samples per 2048 words; the padding
  // is not kept), the track table's bytes, its entries. Simple dual-port
  // RAMs, written by hps_io, read by the engine a cycle after the address.
  // ---------------------------------------------------------------------
  (* ramstyle = "no_rw_check" *) logic [15:0] aud [8192];
  (* ramstyle = "no_rw_check" *) logic [7:0]  toc_e [512];
  (* ramstyle = "no_rw_check" *) logic [7:0]  toc_o [512];
  (* ramstyle = "no_rw_check" *) logic [31:0] ent [128];

  logic aud_we, toc_we;
  assign aud_we = sd_buff_wr_i[2] && h_kind == 2'd1 && sd_buff_addr_i < 13'(FRAME_W);
  assign toc_we = sd_buff_wr_i[2] && h_kind == 2'd2 && sd_buff_addr_i[12:9] == 4'd0;

  always_ff @(posedge clk) begin
    if (aud_we) aud[{ap_ws, sd_buff_addr_i[10:0]}] <= sd_buff_dout_i;
    aud_q <= aud[aud_ra];
  end

  always_ff @(posedge clk) begin
    if (toc_we) toc_e[sd_buff_addr_i[8:0]] <= sd_buff_dout_i[7:0];
    toc_qe <= toc_e[toc_ra[9:1]];
  end

  always_ff @(posedge clk) begin
    if (toc_we) toc_o[sd_buff_addr_i[8:0]] <= sd_buff_dout_i[15:8];
    toc_qo <= toc_o[toc_ra[9:1]];
    toc_rodd <= toc_ra[0];
  end

  always_ff @(posedge clk) begin
    if (ent_we) ent[ent_wa] <= ent_wd;
    ent_q <= ent[ent_ra];
  end

  // ---------------------------------------------------------------------
  // Selection: which slot answers esp_did_i
  // ---------------------------------------------------------------------
  logic [2:0] match;
  logic [2:0] tgt_id;                         // the connected target's ID
  always_comb begin
    match[0] = ena_i[0] && esp_did_i == id0_i && blk512[0] != 32'd0;
    match[1] = ena_i[1] && esp_did_i == id1_i && blk512[1] != 32'd0;
    match[2] = ena_i[2] && esp_did_i == id2_i;
    case (tgt)
      2'd0:    tgt_id = id0_i;
      2'd1:    tgt_id = id1_i;
      default: tgt_id = id2_i;
    endcase
  end

  // ---------------------------------------------------------------------
  // The engine
  // ---------------------------------------------------------------------
`define SCSI_CHECK(k, a) begin stat_v = ST_CHECK; key_v = (k); asc_v = (a); end

  always_ff @(posedge clk) begin : p_sync
    logic        xfer_v, rx_v;
    logic [1:0]  set_v, clr_v;
    logic [7:0]  op_v;
    logic [31:0] lba_v, n_v, last_v, cnt_v, blocks_v;
    logic        iscd_v, nomed_v;
    int          alloc_v;
    int          len_v;
    logic [7:0]  stat_v;
    logic [3:0]  key_v;
    logic [7:0]  asc_v;
    logic        gen_v;
    logic [7:0]  b_v;
    int          j_v, k_v;
    int          hdr_v, bd_v;
    int          p1_v, p2_v, p3_v;
    logic [5:0]  pg_v;
    logic [23:0] cyl_v, bs_v, bd_blk_v;
    logic [7:0]  trk_v;
    // CD audio
    logic [23:0] st_v, en_v;
    int          tl_v;
    int          si_v;
    int          w_v;
    int          f_v, fld_v, d_v;
    logic        tick_v, inc_v, dec_v;
    logic        pstart_v, pstop_v, tocgen_v, playti_v, subch_v;
    logic        fmt1_v;
    int          pgo_v;

    pstart_v = 1'b0;
    pstop_v  = 1'b0;
    inc_v    = 1'b0;
    dec_v    = 1'b0;
    st_v     = '0;
    en_v     = '0;
    f_v      = 0;

    // -------------------------------------------------------------------
    // Mounts (no reset: they outlive the machine's resets, as the slots)
    mnt_d <= img_mounted_i;
    for (int n = 0; n < 3; n++) begin
      if (img_mounted_i[n] && !mnt_d[n]) begin
        blk512[n] <= img_size_i[40:9];
        ro[n]     <= img_readonly_i || n == 2;
        ua[n]     <= 1'b1;
        ua_asc[n] <= 8'h28;                       // medium changed
      end
    end
    if (img_mounted_i[2] && !mnt_d[2]) begin
      // a new disc: its track table (Main's), the player stops
      toc_ok   <= 1'b0;
      toc_want <= img_size_i != 64'd0;
      pstop_v  = 1'b1;
    end

    sel_r <= |match;

    xfer_v = req_r && esp_ack_i;
    if (xfer_v) req_r <= 1'b0;
    // an OUT phase's byte (I/O = 0), valid now on esp_d_i
    rx_v = rx_d;
    rx_d <= xfer_v && !phase_r[0];
    a_we  <= 1'b0;
    set_v = 2'b00;
    clr_v = 2'b00;
    gen_v = 1'b0;

    // -------------------------------------------------------------------
    // The bus side
    case (st)
      S_IDLE: begin
        req_r <= 1'b0;
        ident <= 1'b0;
        lun   <= 3'd0;
        if (esp_bsy_i && |match) begin
          if (match[0])      tgt <= 2'd0;
          else if (match[1]) tgt <= 2'd1;
          else               tgt <= 2'd2;
          settle <= 3'd4;
          st <= S_SETTLE;
        end
      end

      S_SETTLE: begin
        // ATN comes a cycle or two after bsy when bsy was left set
        if (settle != 3'd0)
          settle <= settle - 3'd1;
        else if (esp_atn_i) begin
          phase_r <= PH_MSG_OUT;
          in_ext  <= 1'b0;
          got_msg <= 1'b0;
          st <= S_MSGOUT;
        end else begin
          phase_r <= PH_COMMAND;
          cdb_i <= 4'd0;
          cdb_n <= 4'd6;
          st <= S_CMD;
        end
      end

      S_MSGOUT: begin
        if (rx_v) begin
          got_msg <= 1'b1;
          b_v = esp_d_i;
          if (in_ext) begin
            if (ext_n == 8'd0) begin                // the length byte
              ext_n <= b_v;
              ext_i <= 8'd0;
              if (b_v == 8'd0) begin in_ext <= 1'b0; rep_kind <= 2'd2; end
            end else if (ext_code[7:4] == 4'h2) begin
              in_ext <= 1'b0;                       // a two-byte message's 2nd
            end else begin
              if (ext_i == 8'd0) ext_code <= b_v;
              if (ext_i == 8'd1) ext_period <= b_v;
              if ({1'b0, ext_i} + 9'd1 == {1'b0, ext_n}) begin
                in_ext <= 1'b0;
                // SDTR: answered asynchronous (offset 0); the rest rejected
                if (ext_code == 8'h01 || (ext_i == 8'd0 && b_v == 8'h01))
                  rep_kind <= 2'd1;
                else
                  rep_kind <= 2'd2;
              end
              ext_i <= ext_i + 8'd1;
            end
          end else if (b_v[7]) begin                // IDENTIFY
            lun   <= b_v[2:0];
            ident <= 1'b1;
          end else if (b_v == 8'h01) begin          // extended message
            in_ext   <= 1'b1;
            ext_n    <= 8'd0;
            ext_code <= 8'h00;
          end else if (b_v[7:4] == 4'h2) begin
            // a two-byte message: its second byte follows. The queue tags
            // (SIMPLE, HEAD OF QUEUE, ORDERED) are taken (one command at a
            // time, no disconnection: a queue of one); the rest rejected
            in_ext   <= 1'b1;
            ext_n    <= 8'd1;
            ext_i    <= 8'd0;
            ext_code <= b_v;
            if (b_v > 8'h22) rep_kind <= 2'd2;
          end else if (b_v == 8'h06 || b_v == 8'h0C) begin   // ABORT, BUS DEVICE RESET
            if (b_v == 8'h0C) begin
              ua[tgt] <= 1'b1;
              ua_asc[tgt] <= 8'h29;
            end
            st <= S_DONE;
          end else if (b_v != 8'h07 && b_v != 8'h08) begin   // not REJECT, NOP
            rep_kind <= 2'd2;
          end
        end else if (xfer_v) begin
          // the byte comes next
        end else if (!req_r) begin
          // Decided before req goes up again, so that no byte of the next
          // phase is taken here: the message is complete and ATN is off
          // (the ESP drops ATN with the last message byte)
          if (got_msg && !in_ext && !esp_atn_i) begin
            if (rep_kind != 2'd0) begin
              phase_r <= PH_MSG_IN;
              rep_i <= 3'd0;
              st <= S_MSGIN_REPLY;
            end else begin
              phase_r <= PH_COMMAND;
              cdb_i <= 4'd0;
              cdb_n <= 4'd6;
              st <= S_CMD;
            end
          end else
            req_r <= 1'b1;
        end
      end

      S_MSGIN_REPLY: begin
        // SDTR: 01 03 01 period 00 (asynchronous); else MESSAGE REJECT
        if (rep_kind == 2'd1) begin
          case (rep_i)
            3'd0:    d_r <= 8'h01;
            3'd1:    d_r <= 8'h03;
            3'd2:    d_r <= 8'h01;
            3'd3:    d_r <= ext_period;
            default: d_r <= 8'h00;
          endcase
        end else
          d_r <= 8'h07;
        if (!req_r && !xfer_v) req_r <= 1'b1;
        if (xfer_v) begin
          if ((rep_kind == 2'd1 && rep_i == 3'd4) || rep_kind == 2'd2) begin
            rep_kind <= 2'd0;
            if (esp_atn_i) begin
              phase_r <= PH_MSG_OUT;
              in_ext  <= 1'b0;
              got_msg <= 1'b0;
              st <= S_MSGOUT;
            end else begin
              phase_r <= PH_COMMAND;
              cdb_i <= 4'd0;
              cdb_n <= 4'd6;
              st <= S_CMD;
            end
          end else
            rep_i <= rep_i + 3'd1;
        end
      end

      S_CMD: begin
        if (!req_r && !xfer_v && !rx_v && cdb_i < cdb_n) req_r <= 1'b1;
        if (rx_v) begin
          cdb[cdb_i] <= esp_d_i;
          if (cdb_i == 4'd0) begin
            case (esp_d_i[7:5])
              3'b001, 3'b010: cdb_n <= 4'd10;
              3'b101:         cdb_n <= 4'd12;
              default:        cdb_n <= 4'd6;
            endcase
          end
          cdb_i <= cdb_i + 4'd1;
        end else if (cdb_i == cdb_n && !req_r && !xfer_v)
          st <= S_EXEC;
      end

      // -----------------------------------------------------------------
      S_EXEC: begin
        if (hst == H_IDLE) begin
          op_v   = cdb[0];
          iscd_v = tgt == 2'd2;
          if (iscd_v && cd_bs2k) blocks_v = {2'b00, blk512[tgt][31:2]};
          else                   blocks_v = blk512[tgt];
          nomed_v = blk512[tgt] == 32'd0;
          stat_v  = ST_GOOD;
          key_v   = SK_NONE;
          asc_v   = 8'h00;
          if (!ident) lun <= cdb[1][7:5];         // SCSI-1: LUN in the CDB
          xfer_disc <= 1'b0;
          tx_left   <= 32'd0;
          ms10      <= 1'b0;
          tocgen_v  = 1'b0;
          playti_v  = 1'b0;
          subch_v   = 1'b0;
          tl_v      = 0;

          // The data a command moves: gen_v (generated, gen/len_v), or
          // blocks (lba_v, n_v) in or out
          gen_v   = 1'b0;
          len_v   = 0;
          n_v     = 32'd0;
          lba_v   = 32'd0;
          alloc_v = 0;

          if ((ident && lun != 3'd0) || (!ident && cdb[1][7:5] != 3'd0)) begin
            // LUN 0 only
            if (op_v == 8'h12) begin                // INQUIRY: qualifier 3
              gen <= G_INQ; gen_v = 1'b1; len_v = 36;
              alloc_v = int'(cdb[4]);
            end else if (op_v == 8'h03) begin       // REQUEST SENSE
              s_key[tgt]  <= SK_ILLEG;
              s_asc[tgt]  <= 8'h25;
              s_ascq[tgt] <= 8'h00;
              gen <= G_SENSE; gen_v = 1'b1; len_v = 18;
              alloc_v = int'(cdb[4]);
              if (alloc_v == 0) alloc_v = 4;
            end else
              `SCSI_CHECK(SK_ILLEG, 8'h25)

          end else if (ua[tgt] && op_v != 8'h12 && op_v != 8'h03) begin
            // UNIT ATTENTION, reported once
            ua[tgt] <= 1'b0;
            `SCSI_CHECK(SK_UATT, ua_asc[tgt])

          end else begin
            case (op_v)
              8'h00, 8'h01, 8'h1B, 8'h1E, 8'h16, 8'h17, 8'h35: begin
                // TEST UNIT READY, REZERO, START STOP, PREVENT ALLOW,
                // RESERVE, RELEASE, SYNCHRONIZE CACHE
                if (nomed_v && (op_v == 8'h00 || op_v == 8'h01))
                  `SCSI_CHECK(SK_NREADY, 8'h3A)
                if (iscd_v && op_v == 8'h1B && !cdb[4][0])
                  pstop_v = 1'b1;                   // STOP: the audio too
              end

              8'h03: begin                          // REQUEST SENSE
                gen <= G_SENSE; gen_v = 1'b1; len_v = 18;
                alloc_v = int'(cdb[4]);
                if (alloc_v == 0) alloc_v = 4;
                if (ua[tgt]) begin
                  ua[tgt] <= 1'b0;
                  s_key[tgt]  <= SK_UATT;
                  s_asc[tgt]  <= ua_asc[tgt];
                  s_ascq[tgt] <= 8'h00;
                end
              end

              8'h04: begin                          // FORMAT UNIT
                if (iscd_v)
                  `SCSI_CHECK(SK_ILLEG, 8'h20)
                else if (cdb[1][4])                 // with a parameter list
                  `SCSI_CHECK(SK_ILLEG, 8'h24)
              end

              8'h12: begin                          // INQUIRY
                alloc_v = int'(cdb[4]);
                if (cdb[1][0]) begin                // EVPD
                  if (cdb[2] == 8'h00) begin
                    gen <= G_INQ0; gen_v = 1'b1; len_v = 6;
                  end else if (cdb[2] == 8'h80) begin
                    gen <= G_INQ80; gen_v = 1'b1; len_v = 12;
                  end else
                    `SCSI_CHECK(SK_ILLEG, 8'h24)
                end else if (cdb[2] != 8'h00)
                  `SCSI_CHECK(SK_ILLEG, 8'h24)
                else begin
                  gen <= G_INQ; gen_v = 1'b1; len_v = 36;
                end
              end

              8'h08, 8'h0A, 8'h0B, 8'h28, 8'h2A, 8'h2B, 8'h2F, 8'hA8, 8'hAA: begin
                // READ, WRITE, SEEK, VERIFY (6, 10, 12)
                if (op_v[7:5] == 3'b000) begin
                  lba_v = {11'd0, cdb[1][4:0], cdb[2], cdb[3]};
                  n_v   = {24'd0, cdb[4]};
                  if (cdb[4] == 8'd0 && op_v != 8'h0B) n_v = 32'h100;
                end else if (op_v[7:5] == 3'b001) begin
                  lba_v = {cdb[2], cdb[3], cdb[4], cdb[5]};
                  n_v   = {16'd0, cdb[7], cdb[8]};
                end else begin
                  lba_v = {cdb[2], cdb[3], cdb[4], cdb[5]};
                  n_v   = {cdb[6], cdb[7], cdb[8], cdb[9]};
                end
                if (op_v == 8'h0B || op_v == 8'h2B)
                  n_v = 32'd0;                      // SEEK: no data
                last_v = lba_v + n_v;
                if (nomed_v)
                  `SCSI_CHECK(SK_NREADY, 8'h3A)
                else if ((op_v == 8'h0A || op_v == 8'h2A || op_v == 8'hAA) && iscd_v)
                  `SCSI_CHECK(SK_ILLEG, 8'h20)
                else if ((op_v == 8'h0A || op_v == 8'h2A || op_v == 8'hAA) && ro[tgt])
                  `SCSI_CHECK(SK_PROT, 8'h27)
                else if (op_v == 8'h2F && cdb[1][1])
                  `SCSI_CHECK(SK_ILLEG, 8'h24)      // VERIFY with BYTCHK
                else if (lba_v >= blocks_v || last_v > blocks_v || last_v < lba_v) begin
                  if (!(n_v == 32'd0 && lba_v <= blocks_v))
                    `SCSI_CHECK(SK_ILLEG, 8'h21)
                end else if (op_v == 8'h2F) begin
                  // VERIFY: nothing to do
                end else if (n_v != 32'd0) begin
                  // in 512-byte blocks for hps_io
                  if (iscd_v && cd_bs2k) begin
                    lba_v = {lba_v[29:0], 2'b00};
                    n_v   = {n_v[29:0], 2'b00};
                  end
                  tx_left <= n_v;
                  h_lba   <= lba_v;
                  h_left  <= n_v;
                  // the first chunk to receive (writes)
                  if (n_v > 32'(CHUNK)) begin
                    cur_n    <= 6'(CHUNK);
                    cur_last <= 14'(CHUNK * 512 - 1);
                    ch_n[0]  <= 6'(CHUNK);
                  end else begin
                    cur_n    <= n_v[5:0];
                    cur_last <= {n_v[4:0], 9'd0} - 14'd1;
                    ch_n[0]  <= n_v[5:0];
                  end
                  if (op_v == 8'h0A || op_v == 8'h2A || op_v == 8'hAA) begin
                    h_wmode <= 1'b1;
                  end else
                    h_wmode <= 1'b0;
                end
                s_info[tgt] <= lba_v;
              end

              8'h25: begin                          // READ CAPACITY
                if (nomed_v)
                  `SCSI_CHECK(SK_NREADY, 8'h3A)
                else begin
                  gen <= G_CAP; gen_v = 1'b1; len_v = 8; alloc_v = 8;
                end
              end

              8'h1A, 8'h5A: begin                   // MODE SENSE (6, 10)
                ms_dbd  <= cdb[1][3];
                ms_page <= cdb[2][5:0];
                ms_pc   <= cdb[2][7:6];
                pg_v    = cdb[2][5:0];
                if (op_v == 8'h1A) begin
                  ms10 <= 1'b0; hdr_v = 4;
                  alloc_v = int'(cdb[4]);
                end else begin
                  ms10 <= 1'b1; hdr_v = 8;
                  alloc_v = int'({cdb[7], cdb[8]});
                end
                bd_v = cdb[1][3] ? 0 : 8;
                if (iscd_v) begin
                  p1_v = 12; p2_v = 20; p3_v = 22;  // pages 1, 8, 2A
                end else begin
                  p1_v = 12; p2_v = 24; p3_v = 20;  // pages 1, 4, 8
                end
                if (cdb[2][7:6] == 2'b11)
                  `SCSI_CHECK(SK_ILLEG, 8'h39)      // saved values
                else if (pg_v == 6'h3F)
                  len_v = hdr_v + bd_v + p1_v + p2_v + p3_v;
                else if (pg_v == 6'h00)
                  len_v = hdr_v + bd_v;
                else if (pg_v == 6'h01 || pg_v == 6'h08 ||
                         (pg_v == 6'h04 && !iscd_v) ||
                         (pg_v == 6'h2A && iscd_v) ||
                         (pg_v == 6'h0E && iscd_v))
                  len_v = hdr_v + bd_v + page_len(pg_v);
                else
                  `SCSI_CHECK(SK_ILLEG, 8'h24)
                if (stat_v == ST_GOOD) begin
                  gen <= G_MSENSE; gen_v = 1'b1;
                end
              end

              8'h15, 8'h55: begin                   // MODE SELECT (6, 10)
                if (op_v == 8'h15) alloc_v = int'(cdb[4]);
                else               alloc_v = int'({cdb[7], cdb[8]});
                ms10 <= op_v[6];
                if (alloc_v > 255)
                  `SCSI_CHECK(SK_ILLEG, 8'h24)
                else if (alloc_v > 0) begin
                  dout_n    <= 8'(alloc_v);
                  dout_i    <= 8'd0;
                  xfer_disc <= 1'b1;
                  msel_bl   <= '0;
                  msel_bdl  <= 8'h00;
                  msel_pg   <= 8'h00;
                end
              end

              8'h37: begin                          // READ DEFECT DATA
                if (iscd_v)
                  `SCSI_CHECK(SK_ILLEG, 8'h20)
                else begin
                  gen <= G_DEFECT; gen_v = 1'b1; len_v = 4;
                  alloc_v = int'({cdb[7], cdb[8]});
                end
              end

              8'h1D: begin                          // SEND DIAGNOSTIC
                if (cdb[3] != 8'd0 || cdb[4] != 8'd0)
                  `SCSI_CHECK(SK_ILLEG, 8'h24)
              end

              8'h43: begin                          // READ TOC
                msf     <= cdb[1][1];
                alloc_v = int'({cdb[7], cdb[8]});
                trk_v   = cdb[6];
                fmt1_v  = cdb[2][3:0] == 4'h1 || cdb[9][7:6] == 2'b01;
                if (!iscd_v)
                  `SCSI_CHECK(SK_ILLEG, 8'h20)
                else if (nomed_v)
                  `SCSI_CHECK(SK_NREADY, 8'h3A)
                else if (toc_ok) begin
                  // from Main's track table
                  tg_fmt1 <= 1'b0;
                  if (fmt1_v) begin
                    tg_fmt1 <= 1'b1; tg_si <= 7'd0; tl_v = 12; tocgen_v = 1'b1;
                  end else if (cdb[2][3:0] != 4'h0)
                    `SCSI_CHECK(SK_ILLEG, 8'h24)
                  else if (trk_v == 8'hAA) begin
                    tg_si <= toc_n - 7'd1; tl_v = 12; tocgen_v = 1'b1;
                  end else if (trk_v > toc_last)
                    `SCSI_CHECK(SK_ILLEG, 8'h24)
                  else begin
                    if (trk_v <= toc_first) si_v = 0;
                    else                    si_v = int'(trk_v) - int'(toc_first);
                    tg_si <= 7'(si_v);
                    tl_v = 4 + 8 * (int'(toc_n) - si_v);
                    tocgen_v = 1'b1;
                  end
                  tg_len <= 10'(tl_v);
                end else if (cdb[2][3:0] == 4'h1 || cdb[9][7:6] == 2'b01) begin
                  gen <= G_TOC1; gen_v = 1'b1; len_v = 12;
                end else if (cdb[2][3:0] != 4'h0 || (trk_v > 8'd1 && trk_v != 8'hAA))
                  `SCSI_CHECK(SK_ILLEG, 8'h24)
                else if (trk_v == 8'hAA) begin
                  gen <= G_TOCAA; gen_v = 1'b1; len_v = 12;
                end else begin
                  gen <= G_TOC0; gen_v = 1'b1; len_v = 20;
                end
                // lead-out = the disc's blocks of 2048 bytes, plus 150
                // frames for MSF
                toc_rem <= blk512[2][25:2] + 24'd150;
                toc_m <= 8'h00;
                toc_s <= 8'h00;
              end

              8'h45, 8'hA5, 8'h47: begin            // PLAY AUDIO (10, 12, MSF)
                if (op_v == 8'h47) begin
                  st_v = msf2lba(cdb[3], cdb[4], cdb[5]);
                  en_v = msf2lba(cdb[6], cdb[7], cdb[8]);
                end else if (op_v == 8'h45) begin
                  st_v = {cdb[3], cdb[4], cdb[5]};
                  en_v = st_v + {8'd0, cdb[7], cdb[8]};
                end else begin
                  st_v = {cdb[3], cdb[4], cdb[5]};
                  en_v = st_v + {cdb[7], cdb[8], cdb[9]};
                end
                if (!iscd_v || !toc_ok)
                  `SCSI_CHECK(SK_ILLEG, 8'h20)
                else if (nomed_v)
                  `SCSI_CHECK(SK_NREADY, 8'h3A)
                else if (en_v == st_v) begin
                  // nothing to play
                end else if (st_v >= toc_lead || en_v > toc_lead || en_v < st_v ||
                             (op_v != 8'h47 && cdb[2] != 8'd0))
                  `SCSI_CHECK(SK_ILLEG, 8'h21)
                else
                  pstart_v = 1'b1;
              end

              8'h48: begin                          // PLAY AUDIO TRACK/INDEX
                if (!iscd_v || !toc_ok)
                  `SCSI_CHECK(SK_ILLEG, 8'h20)
                else if (nomed_v)
                  `SCSI_CHECK(SK_NREADY, 8'h3A)
                else if (cdb[4] < toc_first || cdb[4] > toc_last || cdb[7] < cdb[4])
                  `SCSI_CHECK(SK_ILLEG, 8'h24)
                else begin
                  pt_s <= 7'(cdb[4] - toc_first);
                  if (cdb[7] > toc_last) pt_e <= 7'(toc_last - toc_first) + 7'd1;
                  else                   pt_e <= 7'(cdb[7] - toc_first) + 7'd1;
                  pt_ph <= 3'd0;
                  playti_v = 1'b1;
                end
              end

              8'h4B: begin                          // PAUSE/RESUME
                if (!iscd_v)
                  `SCSI_CHECK(SK_ILLEG, 8'h20)
                else if (!ap_play)
                  `SCSI_CHECK(SK_ILLEG, 8'h2C)      // command sequence error
                else if (cdb[8][0]) begin
                  ap_pause <= 1'b0;
                  ap_stat  <= 8'h11;
                end else begin
                  ap_pause <= 1'b1;
                  ap_stat  <= 8'h12;
                end
              end

              8'h4E: begin                          // STOP PLAY/SCAN
                if (!iscd_v)
                  `SCSI_CHECK(SK_ILLEG, 8'h20)
                else
                  pstop_v = 1'b1;
              end

              8'h42: begin                          // READ SUB-CHANNEL
                alloc_v = int'({cdb[7], cdb[8]});
                if (!iscd_v)
                  `SCSI_CHECK(SK_ILLEG, 8'h20)
                else if (nomed_v)
                  `SCSI_CHECK(SK_NREADY, 8'h3A)
                else if (cdb[2][6] && (cdb[3] == 8'd0 || cdb[3] > 8'd3))
                  `SCSI_CHECK(SK_ILLEG, 8'h24)
                else begin
                  if (!cdb[2][6])            len_v = 4;
                  else if (cdb[3] == 8'h01)  len_v = 16;
                  else                       len_v = 24;
                  sc_msf  <= cdb[1][1];
                  sc_fmt  <= cdb[3];
                  sc_abs  <= ap_cur;
                  sc_stat <= ap_stat;
                  // "completed" and "stopped by an error" are reported once
                  if (ap_stat == 8'h13 || ap_stat == 8'h14) ap_stat <= 8'h15;
                  sc_i  <= 7'd0;
                  sc_ph <= 3'd0;
                  gen <= G_SUBCH; gen_v = 1'b1;
                  subch_v = 1'b1;
                end
              end

              default:
                `SCSI_CHECK(SK_ILLEG, 8'h20)        // invalid command
            endcase
          end

          // Sense: kept from the last CHECK until the next command
          if (op_v != 8'h03) begin
            s_key[tgt]  <= key_v;
            s_asc[tgt]  <= asc_v;
            s_ascq[tgt] <= 8'h00;
          end
          status   <= stat_v;
          resp_len <= 8'(len_v);
          gen_n    <= (alloc_v < len_v) ? 10'(alloc_v) : 10'(len_v);
          if (tocgen_v)
            gen_n <= (alloc_v < tl_v) ? 10'(alloc_v) : 10'(tl_v);
          gen_i   <= 8'd0;
          tg_i    <= 10'd0;
          tg_ph   <= 2'd0;
          nbytes  <= '0;
          tx_half <= 1'b0;
          h_half  <= 1'b0;
          full    <= 2'b00;

          if (stat_v != ST_GOOD) begin
            phase_r <= PH_STATUS;
            st <= S_STATUS;
          end else if (tocgen_v) begin
            if (alloc_v != 0)
              st <= S_TOCGEN;
            else begin
              phase_r <= PH_STATUS;
              st <= S_STATUS;
            end
          end else if (playti_v)
            st <= S_PLAYTI;
          else if (gen_v && alloc_v != 0 && len_v != 0) begin
            if (op_v == 8'h43)  st <= S_TOCDIV;
            else if (subch_v)   st <= S_SUBCH;
            else                st <= S_FILL;
          end else if ((op_v == 8'h15 || op_v == 8'h55) && alloc_v > 0) begin
            phase_r <= PH_DATA_OUT;
            st <= S_DOUT;
          end else if (n_v != 32'd0 && (op_v == 8'h0A || op_v == 8'h2A || op_v == 8'hAA)) begin
            phase_r <= PH_DATA_OUT;
            st <= S_DOUT;
          end else if (n_v != 32'd0 && op_v != 8'h2F) begin
            phase_r <= PH_DATA_IN;
            st <= S_RD_WAIT;
          end else begin
            phase_r <= PH_STATUS;
            st <= S_STATUS;
          end
        end
      end

      // -----------------------------------------------------------------
      S_TOCDIV: begin
        // lead-out MSF: minutes, seconds, frames from frames
        if (toc_rem >= 24'd4500) begin
          toc_rem <= toc_rem - 24'd4500;
          toc_m <= toc_m + 8'd1;
        end else if (toc_rem >= 24'd75) begin
          toc_rem <= toc_rem - 24'd75;
          toc_s <= toc_s + 8'd1;
        end else begin
          toc_f <= toc_rem[7:0];
          st <= S_FILL;
        end
      end

      S_FILL: begin
        // the generated reply into half 0, one byte a cycle
        b_v = 8'h00;
        j_v = int'(gen_i);
        bs_v = (tgt == 2'd2 && cd_bs2k) ? 24'd2048 : 24'd512;
        blocks_v = (tgt == 2'd2 && cd_bs2k) ? {2'b00, blk512[tgt][31:2]} : blk512[tgt];
        case (gen)
          G_INQ: begin
            if (j_v == 0) begin
              if (lun != 3'd0)       b_v = 8'h7F;
              else if (tgt == 2'd2)  b_v = 8'h05;
            end else if (j_v == 1) begin
              if (tgt == 2'd2) b_v = 8'h80;         // RMB
            end else if (j_v == 2) b_v = 8'h02;     // SCSI-2
            else if (j_v == 3) b_v = 8'h02;
            else if (j_v == 4) b_v = 8'h1F;         // 36 bytes
            else if (j_v >= 8 && j_v <= 15) b_v = chr8(VENDOR, j_v - 8);
            else if (j_v >= 16 && j_v <= 31)
              b_v = (tgt == 2'd2) ? chr16(PROD_CD, j_v - 16) : chr16(PROD_HD, j_v - 16);
            else if (j_v >= 32 && j_v <= 35) b_v = chr4(REV, j_v - 32);
          end
          G_INQ0: begin                             // supported VPD pages
            if (j_v == 0 && tgt == 2'd2) b_v = 8'h05;
            if (j_v == 3) b_v = 8'h02;
            if (j_v == 5) b_v = 8'h80;
          end
          G_INQ80: begin                            // unit serial number
            if (j_v == 0 && tgt == 2'd2) b_v = 8'h05;
            if (j_v == 1) b_v = 8'h80;
            if (j_v == 3) b_v = 8'h08;
            if (j_v >= 4 && j_v <= 10) b_v = chr7(SERIAL, j_v - 4);
            if (j_v == 11) b_v = 8'h30 + {6'd0, tgt};
          end
          G_SENSE: begin
            if (j_v == 0) b_v = 8'h70;
            if (j_v == 2) b_v = {4'h0, s_key[tgt]};
            if (j_v >= 3 && j_v <= 6) b_v = b8(s_info[tgt], 6 - j_v);
            if (j_v == 7) b_v = 8'h0A;
            if (j_v == 12) b_v = s_asc[tgt];
            if (j_v == 13) b_v = s_ascq[tgt];
          end
          G_CAP: begin
            last_v = blocks_v - 32'd1;
            if (j_v < 4) b_v = b8(last_v, 3 - j_v);
            else         b_v = b8({8'h00, bs_v}, 7 - j_v);
          end
          G_DEFECT: begin
            if (j_v == 1) b_v = {3'b000, cdb[2][4:0]};
          end
          G_MSENSE: begin
            hdr_v = ms10 ? 8 : 4;
            bd_v  = ms_dbd ? 0 : 8;
            bd_blk_v = (blocks_v[31:24] != 8'd0) ? 24'hFFFFFF : blocks_v[23:0];
            cyl_v = {10'd0, blk512[tgt][23:10]};
            if (blk512[tgt][31:24] != 8'd0) cyl_v = 24'hFFFFFF;
            if (j_v < hdr_v) begin                  // header
              if (!ms10) begin
                if (j_v == 0) b_v = resp_len - 8'd1;
                if (j_v == 2 && ro[tgt]) b_v = 8'h80;
                if (j_v == 3) b_v = 8'(bd_v);
              end else begin
                if (j_v == 1) b_v = resp_len - 8'd2;
                if (j_v == 3 && ro[tgt]) b_v = 8'h80;
                if (j_v == 7) b_v = 8'(bd_v);
              end
            end else if (j_v < hdr_v + bd_v) begin  // block descriptor
              k_v = j_v - hdr_v;
              case (k_v)
                1:       b_v = bd_blk_v[23:16];
                2:       b_v = bd_blk_v[15:8];
                3:       b_v = bd_blk_v[7:0];
                5:       b_v = bs_v[23:16];
                6:       b_v = bs_v[15:8];
                7:       b_v = bs_v[7:0];
                default: ;
              endcase
            end else begin                          // pages
              // the page and the byte in it first, then one page_byte
              // (one copy of its decode rather than six)
              k_v = j_v - hdr_v - bd_v;
              pg_v = ms_page;
              if (ms_page == 6'h3F) begin
                if (tgt == 2'd2) begin
                  if (k_v < 12)      pg_v = 6'h01;
                  else if (k_v < 32) begin pg_v = 6'h08; k_v = k_v - 12; end
                  else               begin pg_v = 6'h2A; k_v = k_v - 32; end
                end else begin
                  if (k_v < 12)      pg_v = 6'h01;
                  else if (k_v < 36) begin pg_v = 6'h04; k_v = k_v - 12; end
                  else               begin pg_v = 6'h08; k_v = k_v - 36; end
                end
              end
              b_v = page_byte(pg_v, k_v, ms_pc, tgt == 2'd2, cyl_v, vol0, vol1);
            end
          end
          G_SUBCH: begin
            // header: audio status, data length; then the format's data
            // (1: the current position; 2, 3: no catalogue number, ISRC)
            case (j_v)
              1: b_v = sc_stat;
              3: if (resp_len > 8'd4) b_v = resp_len - 8'd4;
              4: b_v = sc_fmt;
              5: if (sc_fmt == 8'h01 || sc_fmt == 8'h03) b_v = sc_ctl;
              6: if (sc_fmt == 8'h01 || sc_fmt == 8'h03) b_v = sc_trk;
              7: if (sc_fmt == 8'h01) b_v = 8'h01;   // index
              8, 9, 10, 11: begin
                if (sc_fmt == 8'h01) begin
                  if (sc_msf) begin
                    if (j_v == 9)  b_v = sc_am;
                    if (j_v == 10) b_v = sc_as;
                    if (j_v == 11) b_v = sc_af;
                  end else
                    b_v = b8({8'h00, sc_abs}, 11 - j_v);
                end
              end
              12, 13, 14, 15: begin
                if (sc_fmt == 8'h01) begin
                  if (sc_msf) begin
                    if (j_v == 13) b_v = sc_rm;
                    if (j_v == 14) b_v = sc_rs;
                    if (j_v == 15) b_v = sc_rf;
                  end else
                    b_v = b8({8'h00, sc_rel}, 15 - j_v);
                end
              end
              default: ;
            endcase
          end
          default: begin                            // G_TOC0, G_TOCAA, G_TOC1
            // header: data length, first, last; then 8-byte descriptors
            if (j_v == 1)
              b_v = (gen == G_TOC0) ? 8'h12 : 8'h0A;
            else if (j_v == 2 || j_v == 3)
              b_v = 8'h01;
            else if (j_v >= 4) begin
              k_v = (j_v - 4) % 8;
              if (gen == G_TOCAA || (gen == G_TOC0 && j_v >= 12)) begin
                // the lead-out
                case (k_v)
                  1: b_v = 8'h14;
                  2: b_v = 8'hAA;
                  4, 5, 6, 7: begin
                    if (msf) begin
                      if (k_v == 5) b_v = toc_m;
                      if (k_v == 6) b_v = toc_s;
                      if (k_v == 7) b_v = toc_f;
                    end else
                      b_v = b8({2'b00, blk512[2][31:2]}, 7 - k_v);
                  end
                  default: ;
                endcase
              end else begin
                // track 1 (format 0) or the first session's (format 1)
                case (k_v)
                  1: b_v = 8'h14;
                  2: b_v = 8'h01;
                  6: if (msf) b_v = 8'h02;
                  default: ;
                endcase
              end
            end
          end
        endcase
        a_adr <= 15'(gen_i);
        a_dw  <= b_v;
        a_we  <= 1'b1;
        if ({2'b00, gen_i} + 10'd1 >= gen_n) begin
          gen_i <= 8'd0;
          if (gen == G_SENSE) begin                 // reported: cleared
            s_key[tgt]  <= SK_NONE;
            s_asc[tgt]  <= 8'h00;
            s_ascq[tgt] <= 8'h00;
          end
          nbytes  <= '0;
          phase_r <= PH_DATA_IN;
          dstep   <= 2'd0;
          st <= S_DIN;
        end else
          gen_i <= gen_i + 8'd1;
      end

      // -----------------------------------------------------------------
      S_TOCGEN: begin
        // READ TOC from Main's table: the header, then a descriptor per
        // entry from tg_si (fmt 1: the first track's); a byte from the
        // table takes its address (0), the RAM's cycle (1), the byte (2)
        b_v = 8'h00;
        fld_v = 0;
        case (tg_ph)
          2'd0: begin
            if (tg_i < 10'd4) begin
              case (tg_i[1:0])
                2'd0:    b_v = 8'((tg_len - 10'd2) >> 8);
                2'd1:    b_v = 8'(tg_len - 10'd2);
                2'd2:    b_v = tg_fmt1 ? 8'h01 : toc_first;
                default: b_v = tg_fmt1 ? 8'h01 : toc_last;
              endcase
            end else begin
              f_v = (int'(tg_i) - 4) % 8;
              d_v = (int'(tg_i) - 4) / 8;
              case (f_v)
                1:       fld_v = 0;                 // ADR/control
                2:       fld_v = 1;                 // track
                5:       fld_v = msf ? 2 : 5;
                6:       fld_v = msf ? 3 : 6;
                7:       fld_v = msf ? 4 : 7;
                default: fld_v = 0;
              endcase
              if (f_v == 1 || f_v == 2 || f_v >= 5) begin
                toc_ra <= 10'((int'(tg_si) + d_v + 1) * 8 + fld_v);
                tg_ph <= 2'd1;
              end
            end
          end
          2'd1:
            tg_ph <= 2'd2;
          default: begin
            b_v = toc_rodd ? toc_qo : toc_qe;
            tg_ph <= 2'd0;
          end
        endcase
        if ((tg_ph == 2'd0 && (tg_i < 10'd4 || !(f_v == 1 || f_v == 2 || f_v >= 5))) ||
            tg_ph == 2'd2) begin
          a_adr <= 15'(tg_i);
          a_dw  <= b_v;
          a_we  <= 1'b1;
          if (tg_i + 10'd1 >= gen_n) begin
            nbytes  <= '0;
            phase_r <= PH_DATA_IN;
            dstep   <= 2'd0;
            st <= S_DIN;
          end else
            tg_i <= tg_i + 10'd1;
        end
      end

      S_PLAYTI: begin
        // PLAY AUDIO TRACK/INDEX: the first track's address, then the one
        // after the last (the next track's or the lead-out)
        case (pt_ph)
          3'd0: begin ent_ra <= pt_s; pt_ph <= 3'd1; end
          3'd1: pt_ph <= 3'd2;
          3'd2: begin
            sc_v   <= ent_q[23:0];
            ent_ra <= pt_e;
            pt_ph  <= 3'd3;
          end
          3'd3: pt_ph <= 3'd4;
          default: begin
            st_v = sc_v;
            en_v = ent_q[23:0];
            if (en_v > st_v) pstart_v = 1'b1;
            phase_r <= PH_STATUS;
            st <= S_STATUS;
          end
        endcase
      end

      S_SUBCH: begin
        // READ SUB-CHANNEL: the track the position is in (the last entry
        // whose address is not past it), its ADR/control, the position in it
        case (sc_ph)
          3'd0: begin
            if (!toc_ok) begin
              sc_ctl <= 8'h14;
              sc_trk <= 8'h01;
              sc_rel <= sc_abs;
              sc_ph  <= 3'd0;
              st <= S_SUBDIV;
            end else begin
              ent_ra <= 7'd1;
              sc_ph <= 3'd1;
            end
          end
          3'd1: sc_ph <= 3'd2;
          3'd2: begin
            if ({1'b0, sc_i} + 8'd2 >= {1'b0, toc_n} || ent_q[23:0] > sc_abs) begin
              ent_ra <= sc_i;
              sc_ph <= 3'd3;
            end else begin
              sc_i <= sc_i + 7'd1;
              ent_ra <= sc_i + 7'd2;
              sc_ph <= 3'd1;
            end
          end
          3'd3: sc_ph <= 3'd4;
          default: begin
            sc_ctl <= ent_q[31:24];
            sc_trk <= toc_first + {1'b0, sc_i};
            if (sc_abs >= ent_q[23:0]) sc_rel <= sc_abs - ent_q[23:0];
            else                       sc_rel <= '0;
            sc_ph <= 3'd0;
            st <= S_SUBDIV;
          end
        endcase
      end

      S_SUBDIV: begin
        // the absolute (+ 150 frames) and relative positions in MSF
        case (sc_ph)
          3'd0: begin
            sc_v  <= sc_abs + 24'd150;
            sc_am <= 8'h00; sc_as <= 8'h00;
            sc_rm <= 8'h00; sc_rs <= 8'h00;
            sc_ph <= 3'd1;
          end
          3'd1: begin
            if (sc_v >= 24'd4500) begin
              sc_v <= sc_v - 24'd4500; sc_am <= sc_am + 8'd1;
            end else if (sc_v >= 24'd75) begin
              sc_v <= sc_v - 24'd75; sc_as <= sc_as + 8'd1;
            end else begin
              sc_af <= sc_v[7:0];
              sc_v  <= sc_rel;
              sc_ph <= 3'd2;
            end
          end
          default: begin
            if (sc_v >= 24'd4500) begin
              sc_v <= sc_v - 24'd4500; sc_rm <= sc_rm + 8'd1;
            end else if (sc_v >= 24'd75) begin
              sc_v <= sc_v - 24'd75; sc_rs <= sc_rs + 8'd1;
            end else begin
              sc_rf <= sc_v[7:0];
              st <= S_FILL;
            end
          end
        endcase
      end

      // -----------------------------------------------------------------
      S_RD_WAIT: begin
        // a block from the image: wait until its half is full
        if (full[tx_half]) begin
          nbytes   <= '0;
          cur_n    <= ch_n[tx_half];
          cur_last <= {ch_n[tx_half][4:0], 9'd0} - 14'd1;
          dstep    <= 2'd0;
          st <= S_DIN;
        end
      end

      S_DIN: begin
        // bytes out of the buffer: the address (step 0), the RAM's cycle
        // (1), data and req (2), the handshake (3)
        case (dstep)
          2'd0: begin
            if (tx_left == 32'd0) a_adr <= {1'b0, nbytes};      // generated data
            else                  a_adr <= {tx_half, nbytes};
            dstep <= 2'd1;
          end
          2'd1: dstep <= 2'd2;
          2'd2: begin
            d_r <= a_odd ? a_dro : a_dre;
            req_r <= 1'b1;
            dstep <= 2'd3;
          end
          default: ;
        endcase
        if (xfer_v) begin
          dstep <= 2'd0;
          if (tx_left == 32'd0) begin
            // generated data
            if (nbytes + 14'd1 >= {4'd0, gen_n}) begin
              phase_r <= PH_STATUS;
              st <= S_STATUS;
            end else
              nbytes <= nbytes + 14'd1;
          end else if (nbytes == cur_last) begin
            // a chunk is out: free its half
            clr_v[tx_half] = 1'b1;
            tx_half <= !tx_half;
            nbytes  <= '0;
            if (tx_left == {26'd0, cur_n}) begin
              tx_left <= 32'd0;
              phase_r <= PH_STATUS;
              st <= S_STATUS;
            end else begin
              tx_left <= tx_left - {26'd0, cur_n};
              st <= S_RD_WAIT;
            end
          end else
            nbytes <= nbytes + 14'd1;
        end
      end

      S_DOUT: begin
        // bytes into the buffer: to the image (WRITE) or for MODE SELECT
        if (!xfer_disc && full[tx_half]) begin
          // the half is still busy
        end else if (!req_r && !xfer_v && !rx_v)
          req_r <= 1'b1;
        if (rx_v) begin
          if (xfer_disc) begin
            // MODE SELECT: the block descriptor's block length
            if (!ms10) begin
              if (dout_i == 8'd3)  msel_bdl <= esp_d_i;
              if (dout_i == 8'd9)  msel_bl[23:16] <= esp_d_i;
              if (dout_i == 8'd10) msel_bl[15:8]  <= esp_d_i;
              if (dout_i == 8'd11) msel_bl[7:0]   <= esp_d_i;
            end else begin
              if (dout_i == 8'd7)  msel_bdl <= esp_d_i;
              if (dout_i == 8'd13) msel_bl[23:16] <= esp_d_i;
              if (dout_i == 8'd14) msel_bl[15:8]  <= esp_d_i;
              if (dout_i == 8'd15) msel_bl[7:0]   <= esp_d_i;
            end
            // the audio control page (CD): the two ports' volumes
            pgo_v = (ms10 ? 8 : 4) + int'(msel_bdl);
            if (tgt == 2'd2 && int'(dout_i) >= pgo_v && dout_i > 8'd3) begin
              if (int'(dout_i) == pgo_v)
                msel_pg <= esp_d_i;
              else if (msel_pg[5:0] == 6'h0E) begin
                if (int'(dout_i) == pgo_v + 9)  vol0 <= esp_d_i;
                if (int'(dout_i) == pgo_v + 11) vol1 <= esp_d_i;
              end
            end
            if ({1'b0, dout_i} + 9'd1 >= {1'b0, dout_n})
              st <= S_DOUT_END;
            else
              dout_i <= dout_i + 8'd1;
          end else begin
            a_adr <= {tx_half, nbytes};
            a_dw  <= esp_d_i;
            a_we  <= 1'b1;
            if (nbytes == cur_last) begin
              set_v[tx_half] = 1'b1;
              tx_half <= !tx_half;
              nbytes  <= '0;
              cnt_v = tx_left - {26'd0, cur_n};
              tx_left <= cnt_v;
              if (cnt_v == 32'd0)
                st <= S_DOUT_END;
              else if (cnt_v > 32'(CHUNK)) begin
                cur_n    <= 6'(CHUNK);
                cur_last <= 14'(CHUNK * 512 - 1);
                ch_n[!tx_half] <= 6'(CHUNK);
              end else begin
                cur_n    <= cnt_v[5:0];
                cur_last <= {cnt_v[4:0], 9'd0} - 14'd1;
                ch_n[!tx_half] <= cnt_v[5:0];
              end
            end else
              nbytes <= nbytes + 14'd1;
          end
        end
      end

      S_DOUT_END: begin
        // MODE SELECT: a CD block size; WRITE: every block on the image
        if (xfer_disc) begin
          if (tgt == 2'd2 && msel_bdl >= 8'd8) begin
            if (msel_bl == 24'd2048) cd_bs2k <= 1'b1;
            if (msel_bl == 24'd512)  cd_bs2k <= 1'b0;
          end
          xfer_disc <= 1'b0;
          phase_r <= PH_STATUS;
          st <= S_STATUS;
        end else if (full == 2'b00 && h_left == 32'd0 && hst == H_IDLE) begin
          phase_r <= PH_STATUS;
          st <= S_STATUS;
        end
      end

      // -----------------------------------------------------------------
      S_STATUS: begin
        d_r <= status;
        if (!req_r && !xfer_v) req_r <= 1'b1;
        if (xfer_v) begin
          phase_r <= PH_MSG_IN;
          st <= S_MSGIN;
        end
      end

      S_MSGIN: begin
        d_r <= 8'h00;                               // COMMAND COMPLETE
        if (!req_r && !xfer_v) req_r <= 1'b1;
        if (xfer_v) st <= S_DONE;
      end

      S_DONE: begin
        req_r <= 1'b0;
        if (!esp_bsy_i) st <= S_IDLE;
      end

      default: st <= S_IDLE;
    endcase

    // -------------------------------------------------------------------
    // A new nexus, an abort: ATN outside MESSAGE OUT, did elsewhere
    if (st != S_IDLE && st != S_SETTLE && st != S_MSGOUT && st != S_EXEC &&
        st != S_FILL && st != S_TOCDIV && st != S_DOUT_END &&
        esp_atn_i && !xfer_v && !rx_v) begin
      req_r    <= 1'b0;
      phase_r  <= PH_MSG_OUT;
      in_ext   <= 1'b0;
      got_msg  <= 1'b0;
      rep_kind <= 2'd0;
      h_left   <= 32'd0;                            // no more blocks
      st <= S_MSGOUT;
    end
    if (st != S_IDLE && esp_did_i != tgt_id) begin
      req_r  <= 1'b0;
      h_left <= 32'd0;
      st <= S_IDLE;
    end

    // -------------------------------------------------------------------
    // The hps side: fetch blocks into empty halves (reads), store full
    // halves (writes). Between them, the CD's track table (after a mount)
    // and its audio frames (while playing, into the ring's free frames)
    case (hst)
      H_IDLE: begin
        if (h_left != 32'd0 && ((!h_wmode && !full[h_half]) || (h_wmode && full[h_half]))) begin
          h_kind <= 2'd0;
          h_slot <= tgt;
          if (h_wmode) begin
            h_wr  <= 1'b1;
            h_cnt <= ch_n[h_half];
          end else begin
            h_rd <= 1'b1;
            if (h_left > 32'(CHUNK)) begin
              h_cnt <= 6'(CHUNK);
              ch_n[h_half] <= 6'(CHUNK);
            end else begin
              h_cnt <= h_left[5:0];
              ch_n[h_half] <= h_left[5:0];
            end
          end
          hst <= H_REQ;
        end else if (toc_want && reset_n) begin
          h_kind <= 2'd2;
          h_slot <= 2'd2;
          h_alba <= TOC_BLK;
          h_cnt  <= 6'd2;
          h_rd   <= 1'b1;
          hst <= H_REQ;
        end else if (ap_play && ap_fetch < ap_end && ap_full < 3'd4 && reset_n) begin
          h_kind <= 2'd1;
          h_slot <= 2'd2;
          h_alba <= AUDIO_BLK + 32'(ap_fetch) * 32'd5;
          h_agen <= ap_gen;
          h_cnt  <= 6'd5;
          h_rd   <= 1'b1;
          hst <= H_REQ;
        end
      end
      H_REQ: begin
        if (sd_ack_i[h_slot]) begin
          h_rd <= 1'b0;
          h_wr <= 1'b0;
          hst <= H_XFER;
        end
      end
      default: begin                                // H_XFER
        if (!sd_ack_i[h_slot]) begin
          if (h_kind == 2'd1) begin
            // a frame in the ring, unless a new PLAY came meanwhile
            if (h_agen == ap_gen && ap_play) begin
              inc_v = 1'b1;
              ap_ws <= ap_ws + 2'd1;
              ap_fetch <= ap_fetch + 24'd1;
            end
          end else if (h_kind == 2'd2) begin
            toc_want <= 1'b0;
            if (toc_vld == 8'h01 && toc_n >= 7'd2) toc_ok <= 1'b1;
          end else begin
            if (h_wmode) clr_v[h_half] = 1'b1;
            else         set_v[h_half] = 1'b1;
            h_half <= !h_half;
            h_lba  <= h_lba + {26'd0, h_cnt};
            // Saturating: an abort (ATN, a change of did, a bus reset) clears
            // h_left while a request is in flight; a plain subtraction
            // would wrap and the hps side would keep fetching.
            h_left <= (h_left > {26'd0, h_cnt}) ? h_left - {26'd0, h_cnt} : 32'd0;
          end
          hst <= H_IDLE;
        end
      end
    endcase

    // The track table as it comes: its header and, per entry, ADR/control
    // and address (the lead-out's kept apart)
    ent_we <= 1'b0;
    if (sd_buff_wr_i[2] && h_kind == 2'd2) begin
      w_v = int'(sd_buff_addr_i);
      if (w_v == 0) begin
        toc_first <= sd_buff_dout_i[7:0];
        toc_last  <= sd_buff_dout_i[15:8];
      end
      if (w_v == 1) begin
        toc_n   <= (sd_buff_dout_i[7:0] > 8'd100) ? 7'd100 : sd_buff_dout_i[6:0];
        toc_vld <= sd_buff_dout_i[15:8];
      end
      if (w_v >= 4 && w_v < 4 + 4 * 100) begin
        case (sd_buff_addr_i[1:0])                  // (w - 4) mod 4
          2'd0: ent_ctl <= sd_buff_dout_i[7:0];
          2'd2: ent_hi  <= sd_buff_dout_i[15:8];
          2'd3: begin
            ent_we <= 1'b1;
            ent_wa <= 7'((w_v - 4) / 4);
            ent_wd <= {ent_ctl, ent_hi, sd_buff_dout_i[7:0], sd_buff_dout_i[15:8]};
            if ((w_v - 4) / 4 + 1 == int'(toc_n))
              toc_lead <= {ent_hi, sd_buff_dout_i[7:0], sd_buff_dout_i[15:8]};
          end
          default: ;
        endcase
      end
    end

    // -------------------------------------------------------------------
    // The player: a stereo sample from the ring every 44.1 kHz tick (the
    // address of the left one, of the right one, then each in turn)
    tick_v = ap_acc[24];
    ap_acc <= {1'b0, ap_acc[23:0]} + AP_RATE;
    case (ap_ph)
      2'd0: begin
        if (tick_v) begin
          if (ap_play && !ap_pause && ap_full != 3'd0) begin
            aud_ra <= {ap_rs, ap_ri};
            ap_ph <= 2'd1;
          end else begin
            smp_l <= 16'h0000;                      // stopped, paused, late
            smp_r <= 16'h0000;
          end
        end
      end
      2'd1: begin
        aud_ra <= {ap_rs, ap_ri + 11'd1};
        ap_ph <= 2'd2;
      end
      2'd2: begin
        smp_l <= aud_q;
        ap_ph <= 2'd3;
      end
      default: begin
        smp_r <= aud_q;
        ap_ph <= 2'd0;
        if (ap_ri + 11'd2 >= 11'(FRAME_W)) begin
          ap_ri <= 11'd0;
          ap_rs <= ap_rs + 2'd1;
          dec_v = 1'b1;
          ap_cur <= ap_cur + 24'd1;
          if (ap_cur + 24'd1 >= ap_end) begin
            ap_play <= 1'b0;                        // the end: completed
            ap_stat <= 8'h13;
          end
        end else
          ap_ri <= ap_ri + 11'd2;
      end
    endcase
    if (inc_v && !dec_v)      ap_full <= ap_full + 3'd1;
    else if (dec_v && !inc_v) ap_full <= ap_full - 3'd1;
    if (pstop_v) begin
      ap_play  <= 1'b0;
      ap_pause <= 1'b0;
      ap_stat  <= 8'h15;
    end
    if (pstart_v) begin
      ap_play  <= 1'b1;
      ap_pause <= 1'b0;
      ap_gen   <= !ap_gen;
      ap_cur   <= st_v;
      ap_fetch <= st_v;
      ap_end   <= en_v;
      ap_full  <= 3'd0;
      ap_ws    <= 2'd0;
      ap_rs    <= 2'd0;
      ap_ri    <= 11'd0;
      ap_ph    <= 2'd0;
      ap_stat  <= 8'h11;
    end

    if (st != S_EXEC)                               // S_EXEC sets full itself
      full <= (full | set_v) & ~clr_v;

    // -------------------------------------------------------------------
    if (esp_rst_i || !reset_n) begin
      st        <= S_IDLE;
      req_r     <= 1'b0;
      ua        <= 3'b111;
      ua_asc[0] <= 8'h29;
      ua_asc[1] <= 8'h29;
      ua_asc[2] <= 8'h29;
      rep_kind  <= 2'd0;
      xfer_disc <= 1'b0;
      h_left    <= 32'd0;
      dstep     <= 2'd0;
      ap_play   <= 1'b0;                            // a bus reset stops it
      ap_stat   <= 8'h15;
    end
    if (!reset_n) begin
      cd_bs2k  <= cd2048_i;
      ap_pause <= 1'b0;
      ap_ph    <= 2'd0;
      ap_full  <= 3'd0;
      vol0     <= 8'hFF;
      vol1     <= 8'hFF;
      h_kind   <= 2'd0;
      s_key[0] <= SK_NONE;
      s_key[1] <= SK_NONE;
      s_key[2] <= SK_NONE;
      hst      <= H_IDLE;
      h_rd     <= 1'b0;
      h_wr     <= 1'b0;
      full     <= 2'b00;
    end
  end

`undef SCSI_CHECK

  // ---------------------------------------------------------------------
  // Outputs
  // ---------------------------------------------------------------------
  assign sd_lba_o     = (h_kind == 2'd0) ? h_lba : h_alba;
  assign sd_blk_cnt_o = (h_cnt != 6'd0) ? h_cnt - 6'd1 : 6'd0;
  assign sd_rd_o      = {h_rd && h_slot == 2'd2, h_rd && h_slot == 2'd1, h_rd && h_slot == 2'd0};
  assign sd_wr_o      = {h_wr && h_slot == 2'd2, h_wr && h_slot == 2'd1, h_wr && h_slot == 2'd0};

  // The CD's samples at the audio control page's volumes
  always_ff @(posedge clk) begin : p_vol
    /* verilator lint_off UNUSEDSIGNAL */
    logic signed [25:0] pl, pr;                     // the 16 bits that matter: 23:8
    /* verilator lint_on UNUSEDSIGNAL */
    pl = $signed(smp_l) * $signed({1'b0, {1'b0, vol0} + 9'd1});
    pr = $signed(smp_r) * $signed({1'b0, {1'b0, vol1} + 9'd1});
    cd_l_o <= pl[23:8];
    cd_r_o <= pr[23:8];
  end

  assign tgt_d_o     = d_r;
  assign tgt_req_o   = req_r;
  assign tgt_phase_o = phase_r;
  assign tgt_sel_o   = sel_r;
  assign tgt_pc_o    = {5'd0, st};
  assign busy_o      = st != S_IDLE || h_rd || h_wr;

endmodule
