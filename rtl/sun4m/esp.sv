// SPDX-License-Identifier: GPL-2.0-or-later
//
// esp: the SCSI controller in the MACIO as Sun's software sees it, an
// NCR 53C90A / Emulex ESP100A (the 53C9x initiator), on the target engine
// scsi_targets (two disks and a CD from the MiSTer's SD slots). Slot F
// offset 0x0080_0000: byte registers at 4-byte strides.
//
// From: NCR 53C90A/53C90B data manual (1991: the registers, the command
//   set, Tables 7-10 for the sequence steps, the Transfer Information and
//   Message Accepted rules); QEMU hw/scsi/esp.c (the interrupt merge, the
//   DMA count reload, the CFG2/CFG3 probe); NetBSD dev/sbus/esp_sbus.c
//   (how the variant is told apart) and dev/ic/ncr53c9x.c (DMA select);
//   OpenBIOS drivers/esp.c do_command (tests/cpu/src/scsitest.S mode 2);
//   docs/VERILOG-PLAN.md §6 ESP-7, ESP-8, ESP-9; rtl/sun4m/scsi_targets.sv's header (the bus contract).
//   The register file, FIFO and interrupt merge follow our Quadra core's
//   ncr53c96.sv (GPL-2, ours); its built-in target is replaced by the bus
//   engine below, which drives scsi_targets.
//
// Variant: an ESP100A. CFG2 (reg B) reads back what is written, CFG3
// (reg C) does not exist and reads 0, so NetBSD's and Linux's probes
// settle on ESP100A (64 KB transfers, 16-bit counter, no FE/TCHI); reg E
// (the FAS family's TCHI/UID) is absent and reads 0. Unused and
// write-only registers read 0 (DEC-3).
//
// Registers (byte n at 4n; a byte access in any lane of the word works,
// reads return the byte in all four lanes):
//   0/1 R: the transfer counter (live), W: its load value (clears STAT.TC)
//   2   FIFO (16 bytes): read pops (an empty FIFO returns the bottom byte)
//   3   command (R: the last one)
//   4   R: STATUS {INT, GE, PE, TC, VGC, phase[2:0]}; W: destination ID
//   5   R: INTR (clears it, the sequence step and GE)
//   6   R: sequence step [2:0]      7  R: {step, FIFO count[4:0]}
//   8   CFG1 (RW)                   B  CFG2 (RW)
//
// Commands: 00 NOP, 01 FLUSH, 02 RESET chip, 03 RESET SCSI bus (they run at
// once), 10 TI, 11 ICCS, 12 MESSAGE ACCEPTED, 18 TRANSFER PAD, 1A/1B
// SET/RESET ATN (initiator: Illegal Command when not connected), 41 SEL,
// 42 SELATN, 43 SELATNS, 46 SELATN3, 44 ENSEL (nothing: no reselection),
// 45 DISSEL (Function Complete); anything else (target mode, reselect)
// raises Illegal Command. The DMA bit (80) reloads the counter from the
// load value (0 = 65536). A command written while one runs is held (one
// deep, as the chip's two-deep command register) and runs after it; the
// interrupts merge (OR) instead of stacking.
//
// Deliberate differences from the chip, for the software we run:
//  - a select is accepted while connected (OpenBIOS ends a command without
//    data without ICCS and selects again: scsitest mode 0); every select
//    first takes the bus away from whatever target is still on it (a cycle
//    of bsy low with another destination ID: scsi_targets idles);
//  - ESP-7: from a select command, the interrupt (irq_o, STATUS.INT, the
//    INTR register) stays hidden for HOLD_CYCLES (1 ms, about a real
//    drive's command time; NeXTSTEP deadlocks without it), while the bus
//    side runs at once. Interrupts raised meanwhile, or still pending from
//    before (OpenBIOS leaves the bus reset's into its first select), show
//    together when the hold ends;
//  - ESP-8: MESSAGE ACCEPTED disconnects only after a message that ends
//    the nexus (COMMAND COMPLETE, DISCONNECT, as the first byte of a
//    message); otherwise it waits for the target's next REQ and gives
//    Bus Service (the esp driver's SDTR reply, a byte at a time). ICCS
//    drops bsy after a COMMAND COMPLETE, so scsi_targets is free even when
//    no MESSAGE ACCEPTED follows (modes 0 and 2). After any MESSAGE IN
//    byte the phase reads MESSAGE IN until MESSAGE ACCEPTED, as the
//    chip's with ACK held (OBP 2.25 and Solaris rely on it);
//  - ESP-9: a TI without DMA in an OUT phase moves at least one byte: with
//    the FIFO empty it waits for the CPU to write one (NeXTSTEP's sc driver
//    issues TI, then writes the CDB byte; ending at once gave it a Bus
//    Service in COMMAND phase with nothing sent, and it retried forever);
//  - scsi_targets has no BSY of its own: the ESP knows the target leaves
//    the bus after COMMAND COMPLETE/DISCONNECT in (above) and after an
//    ABORT or BUS DEVICE RESET it sent (Disconnected, bsy dropped);
//  - no target mode, reselection, parity, synchronous transfers (period
//    and offset are written and ignored), selection time-out register
//    (an absent target times out at once, then the ESP-7 hold).
//
// The DMA side (dma2, the espdma channel): a byte handshake. dreq_o asks
// for one byte; dtomem_o is its direction (1: SCSI data in, the byte on
// ddata_o goes to memory; 0: dma2 supplies ddata_i). A byte moves in a
// cycle where dreq_o and dack_i are both high (neither depends on the
// other in the same cycle). Each byte moved counts the transfer counter
// down. All DMA goes through the FIFO, as on the chip: a DMA Transfer
// Information in an IN phase ends (Bus Service) only once the FIFO is
// empty, i.e. every byte has been handed to dma2; dma2 drains its own
// buffer on this interrupt. Out of memory, the bytes of the counter are
// prefetched into the FIFO (a select's IDENTIFY and CDB: the counter reads
// 0 when the selection completes, as OpenBIOS checks).
//
// The bus (scsi_targets' record bus): bsy, atn, did, ack out; req, phase,
// data in; ack is combinational from req, gated by the FIFO's readiness;
// an OUT byte is registered (valid the cycle after its req & ack).
// Every interrupt comes only once the target asks for the next phase
// (req), as on the chip: the end of a DATA OUT comes with STATUS, after
// the target has written the blocks (NetBSD reads the phase there).

module esp
  import iobus_pkg::*;
#(
  parameter int CLK_HZ      = 55_000_000,
  parameter int HOLD_CYCLES = CLK_HZ / 1000,   // ESP-7: 1 ms
  parameter int BRST_CYCLES = 64,              // the SCSI bus reset pulse
  parameter bit SIMU        = 1'b0             // scsi_targets: CD audio 16x faster
)(
  input  logic        clk,
  input  logic        rst,               // machine reset
  input  logic        chip_rst_i,        // dma2's D_RESET (the chip's RESET pin)

  input  iob_req_t    bus_i,             // addr[5:0] used
  output iob_rsp_t    bus_o,
  output logic        irq_o,             // level, to dma2

  // The DMA handshake with dma2 (see the header)
  output logic        dreq_o,
  output logic        dtomem_o,
  output logic [7:0]  ddata_o,
  input  logic        dack_i,
  input  logic [7:0]  ddata_i,

  // The targets (scsi_targets): slot 0 HD0, 1 HD1, 2 CD
  input  logic [2:0]  id0_i,
  input  logic [2:0]  id1_i,
  input  logic [2:0]  id2_i,
  input  logic [2:0]  ena_i,
  input  logic        cd2048_i,

  // hps_io's block interface (scsi_targets' ports, unchanged)
  input  logic [2:0]  img_mounted_i,
  input  logic [63:0] img_size_i,
  input  logic        img_readonly_i,
  output logic [31:0] sd_lba_o,
  output logic [5:0]  sd_blk_cnt_o,
  output logic [2:0]  sd_rd_o,
  output logic [2:0]  sd_wr_o,
  input  logic [2:0]  sd_ack_i,
  input  logic [12:0] sd_buff_addr_i,
  input  logic [15:0] sd_buff_dout_i,
  output logic [15:0] sd_buff_din_o,
  input  logic [2:0]  sd_buff_wr_i,

  output logic        busy_o,            // a nexus or a block request (an activity LED)
  output logic [15:0] cd_l_o,            // CD audio, signed, 44.1 kHz
  output logic [15:0] cd_r_o
);

  localparam logic [2:0] PH_DOUT = 3'd0, PH_DIN = 3'd1, PH_CMD = 3'd2, PH_STAT = 3'd3,
                         PH_MOUT = 3'd6, PH_MIN = 3'd7;
  localparam logic [7:0] I_FC = 8'h08, I_BS = 8'h10, I_DC = 8'h20, I_ILL = 8'h40,
                         I_RST = 8'h80;
  localparam int HW = $clog2(HOLD_CYCLES + 2);
  localparam int BW = $clog2(BRST_CYCLES + 2);

  // ---------------------------------------------------------------------
  // The target engine
  // ---------------------------------------------------------------------
  logic [7:0] bus_dout;                  // OUT byte, registered
  logic       esp_ack;
  logic       bsy, atn, srst;
  logic [2:0] did;
  logic [7:0] tgt_d;
  logic       tgt_req, tgt_sel;
  logic [2:0] tgt_phase;
  logic [9:0] tgt_pc;

  scsi_targets #(.SYSFREQ(CLK_HZ), .SIMU(SIMU)) u_tgt (
    .clk, .reset_n(~rst),
    .esp_d_i(bus_dout), .esp_ack_i(esp_ack), .esp_bsy_i(bsy), .esp_atn_i(atn),
    .esp_did_i(did), .esp_rst_i(srst),
    .tgt_d_o(tgt_d), .tgt_req_o(tgt_req), .tgt_phase_o(tgt_phase), .tgt_sel_o(tgt_sel),
    .tgt_pc_o(tgt_pc),
    .id0_i, .id1_i, .id2_i, .ena_i, .cd2048_i,
    .img_mounted_i, .img_size_i, .img_readonly_i,
    .sd_lba_o, .sd_blk_cnt_o, .sd_rd_o, .sd_wr_o, .sd_ack_i, .sd_buff_addr_i,
    .sd_buff_dout_i, .sd_buff_din_o, .sd_buff_wr_i,
    .busy_o, .cd_l_o, .cd_r_o);

  // ---------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------
  typedef enum logic [3:0] {
    E_IDLE, E_SELW, E_SMSG, E_SCMD, E_SSTOP, E_XFER, E_ICCS, E_MACC, E_PAD, E_BRST
  } est_e;

  est_e        st;
  logic [15:0] tc_lat;                   // the counter's load value
  logic [16:0] tc;                       // the counter, 0..65536
  logic        stat_tc, stat_ge;
  logic [7:0]  cmd_r;
  logic [7:0]  cmd_q;                    // a command held behind the running one
  logic        cmd_qv;
  logic [2:0]  busid;
  logic [7:0]  cfg1, cfg2;
  logic [7:0]  istat;
  logic [2:0]  seq;
  logic [HW-1:0] hold_cnt;               // ESP-7
  logic [BW-1:0] brst_cnt;

  // the FIFO's bytes in MLAB (asynchronous read at the tail; in flops with
  // their write decode and 16:1 mux they cost ~170 ALUTs)
  (* ramstyle = "MLAB, no_rw_check" *) logic [7:0] fifo [16];
  logic [3:0]  f_rp, f_wp;
  logic [4:0]  f_cnt;

  logic        conn;                     // the ESP's initiator state
  logic        dma;                      // the running command has the DMA bit
  logic [2:0]  selop;                    // 1 SEL, 2 SELATN, 3 SELATNS, 6 SELATN3
  logic [1:0]  scnt;                     // selection: the bus settles
  logic [1:0]  msg_left;                 // selection: message bytes to send
  logic        msg_sent, cmd_sent;
  logic [2:0]  xph;                      // TI/PAD: the phase it moves bytes in
  logic        xph_v;                    //   known (the first req seen)
  logic        got1;                     // TI: a byte moved (non-DMA in: its one byte)
  logic [16:0] bus_left;                 // DMA TI in: bytes the bus may still bring
  logic        got_st;                   // ICCS took the status byte
  // MESSAGE IN parsing (ESP-8): where the next byte falls in a message
  logic        min_len;                  // the next byte is an extended message's length
  logic [7:0]  min_rem;                  // bytes left of this message
  logic        nexus_end;                // the last message ends the nexus
  // MESSAGE OUT likewise: ABORT and BUS DEVICE RESET make the target leave
  // the bus, which scsi_targets does not show (no BSY of its own)
  logic        mo_len;
  logic [7:0]  mo_rem;
  logic        mo_abort;

  wire [7:0] f_head = fifo[f_rp];
  wire       hold   = hold_cnt != '0;
  wire       int_vis = istat != 8'h00 && !hold;

  assign irq_o = int_vis;

  // ---------------------------------------------------------------------
  // Register access
  // ---------------------------------------------------------------------
  wire       access = bus_i.req & ~bus_o.ack;
  wire [3:0] ra     = bus_i.addr[5:2];
  wire       facc   = access && ra == 4'h2;           // the CPU at the FIFO this cycle
  logic [7:0] wbyte;
  always_comb begin
    if (bus_i.be[3])      wbyte = bus_i.wdata[31:24];
    else if (bus_i.be[2]) wbyte = bus_i.wdata[23:16];
    else if (bus_i.be[1]) wbyte = bus_i.wdata[15:8];
    else                  wbyte = bus_i.wdata[7:0];
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, bus_i.addr[IOB_AW-1:6], bus_i.addr[1:0], bus_i.pair, tgt_pc};

  // The phase lines: the target's while it holds the bus. After a MESSAGE
  // IN byte (a TI's or ICCS's) the chip holds ACK, so the target cannot
  // change phase: the lines read MESSAGE IN until MESSAGE ACCEPTED, even
  // though scsi_targets has already moved on (to the next phase, or off
  // the bus after COMMAND COMPLETE) (ESP-8). OBP 2.25's esp driver reads
  // the phase after ICCS and answers MESSAGE IN with MESSAGE ACCEPTED
  // (with 0 it started a data transfer and waited forever); Solaris's
  // takes an SDTR reply a byte at a time and, seeing COMMAND after the
  // last byte instead, never accepted it ("Connected command timeout").
  logic       min_held;
  logic [2:0] st_phase;
  assign st_phase = min_held ? PH_MIN : bsy ? tgt_phase : 3'b000;

  logic [7:0] rbyte;
  always_comb begin
    case (ra)
      4'h0:    rbyte = tc[7:0];
      4'h1:    rbyte = tc[15:8];
      4'h2:    rbyte = f_head;
      4'h3:    rbyte = cmd_r;
      4'h4:    rbyte = {int_vis, stat_ge, 1'b0, stat_tc, 1'b0, st_phase};
      4'h5:    rbyte = hold ? 8'h00 : istat;
      4'h6:    rbyte = {5'd0, seq};
      4'h7:    rbyte = {seq, f_cnt};
      4'h8:    rbyte = cfg1;
      4'hB:    rbyte = cfg2;
      default: rbyte = 8'h00;
    endcase
  end

  // ---------------------------------------------------------------------
  // The bus handshake: ack for the byte the running command wants, when
  // the FIFO can give or take it
  // ---------------------------------------------------------------------
  wire [2:0] eff_ph = xph_v ? xph : tgt_phase;
  wire       more   = f_cnt != 5'd0 || (dma && tc != 17'd0);   // bytes still to send
  logic ack_ok;
  always_comb begin
    ack_ok = 1'b0;
    case (st)
      E_SMSG: ack_ok = tgt_phase == PH_MOUT && f_cnt != 5'd0 && msg_left != 2'd0;
      E_SCMD: ack_ok = tgt_phase == PH_CMD && f_cnt != 5'd0;
      E_XFER:
        if (tgt_phase == eff_ph) begin
          if (!eff_ph[0])                     ack_ok = f_cnt != 5'd0;
          else if (dma && eff_ph != PH_MIN)   ack_ok = f_cnt != 5'd16 && bus_left != 17'd0;
          else                                ack_ok = f_cnt != 5'd16 && !got1;
        end
      E_ICCS: ack_ok = f_cnt <= 5'd14 &&
                       ((tgt_phase == PH_STAT && !got_st) || tgt_phase == PH_MIN);
      E_PAD:  ack_ok = tgt_phase == eff_ph && tc != 17'd0;
      default: ;
    endcase
  end
  assign esp_ack = tgt_req && ack_ok && !facc;

  // ---------------------------------------------------------------------
  // The DMA handshake
  // ---------------------------------------------------------------------
  logic dgo, dtomem;
  always_comb begin
    dgo    = 1'b0;
    dtomem = 1'b0;
    if (dma) begin
      case (st)
        E_SMSG, E_SCMD: dgo = 1'b1;
        E_XFER: begin dgo = xph_v; dtomem = xph[0]; end
        default: ;
      endcase
    end
  end
  assign dreq_o   = dgo && tc != 17'd0 && !facc &&
                    (dtomem ? f_cnt != 5'd0 : f_cnt != 5'd16);
  assign dtomem_o = dtomem;
  assign ddata_o  = f_head;
  wire   dx       = dreq_o && dack_i;

  // ---------------------------------------------------------------------
  // The controller
  // ---------------------------------------------------------------------
  always_ff @(posedge clk) begin : p_main
    logic [7:0] rz;                      // interrupt bits raised this cycle
    logic       fin;                     // the running command ends
    logic       fin_sq;                  //   and sets the sequence step
    logic [2:0] fin_seq;
    logic       ex_v;                    // a command to run now
    logic [7:0] ex_c;
    logic       push, pop, push_ok;
    logic [7:0] pushd;
    logic       tcdec;
    logic       ends;                    // this MESSAGE IN byte ends the nexus
    logic       intr_rd;
    logic       soft_rst;                // RESET chip: wins over the merge below

    soft_rst = 1'b0;
    rz = 8'h00; fin = 1'b0; fin_sq = 1'b0; fin_seq = 3'd0;
    ex_v = 1'b0; ex_c = 8'h00;
    push = 1'b0; pop = 1'b0; pushd = 8'h00; tcdec = 1'b0;
    ends = !min_len && min_rem == 8'd0 && (tgt_d == 8'h00 || tgt_d == 8'h04);

    if (rst || chip_rst_i) begin
      // in D_RESET the chip is held, but its accesses still complete
      // (no data: dma2.txt D_RESET)
      bus_o    <= '{ack: access && !rst, err: 1'b0, rdata: 32'h0};
      st       <= E_IDLE;
      stat_tc  <= 1'b0;
      stat_ge  <= 1'b0;
      cmd_r    <= 8'h00;
      cmd_qv   <= 1'b0;
      cfg1     <= 8'h00;
      cfg2     <= 8'h00;
      istat    <= 8'h00;
      seq      <= 3'd0;
      hold_cnt <= '0;
      brst_cnt <= '0;
      f_rp     <= 4'd0;
      f_wp     <= 4'd0;
      f_cnt    <= 5'd0;
      conn     <= 1'b0;
      dma      <= 1'b0;
      bsy      <= 1'b0;
      atn      <= 1'b0;
      srst     <= 1'b0;
      did      <= 3'd7;
      bus_dout <= 8'h00;
      xph_v    <= 1'b0;
      got1     <= 1'b0;
      got_st   <= 1'b0;
      min_len  <= 1'b0;
      min_rem  <= 8'd0;
      nexus_end <= 1'b0;
      min_held <= 1'b0;
      mo_len   <= 1'b0;
      mo_rem   <= 8'd0;
      mo_abort <= 1'b0;
      if (rst) begin                     // the counter and ID survive a chip reset
        tc_lat <= 16'd0;
        tc     <= 17'd0;
        busid  <= 3'd0;
      end
    end else begin
      bus_o.ack   <= access;
      bus_o.err   <= 1'b0;
      bus_o.rdata <= {4{rbyte}};

      if (hold) hold_cnt <= hold_cnt - 1'b1;

      // -----------------------------------------------------------------
      // The FIFO: the CPU, the bus and the DMA (the CPU's access cycle
      // holds the other two off, so one push and one pop at most)
      if (facc) begin
        if (bus_i.we)          begin push = 1'b1; pushd = wbyte; end
        else if (f_cnt != 5'd0) pop = 1'b1;
      end
      if (esp_ack && st != E_PAD) begin
        if (tgt_phase[0]) begin push = 1'b1; pushd = tgt_d; end
        else begin pop = 1'b1; bus_dout <= f_head; end
      end
      if (esp_ack && st == E_PAD) begin
        bus_dout <= 8'h00;               // pad bytes out, bytes in discarded
        tcdec = 1'b1;
      end
      if (dx) begin
        tcdec = 1'b1;
        if (dtomem) pop = 1'b1;
        else begin push = 1'b1; pushd = ddata_i; end
      end
      push_ok = push && (f_cnt != 5'd16 || pop);
      if (push && !push_ok) stat_ge <= 1'b1;          // the top of the FIFO overwritten
      if (push_ok) begin
        fifo[f_wp] <= pushd;
        f_wp <= f_wp + 4'd1;
      end
      if (pop) f_rp <= f_rp + 4'd1;
      f_cnt <= f_cnt + {4'd0, push_ok} - {4'd0, pop};

      if (tcdec) begin
        tc <= tc - 17'd1;
        if (tc == 17'd1) stat_tc <= 1'b1;
      end

      // MESSAGE IN bytes: where the next one falls
      if (esp_ack && tgt_phase == PH_MIN && st != E_PAD) begin
        if (min_len) begin
          min_len <= 1'b0;
          min_rem <= tgt_d;
        end else if (min_rem != 8'd0)
          min_rem <= min_rem - 8'd1;
        else begin
          nexus_end <= ends;
          if (tgt_d == 8'h01)            min_len <= 1'b1;      // extended
          else if (tgt_d[7:4] == 4'h2)   min_rem <= 8'd1;      // two-byte
        end
      end

      if (esp_ack && tgt_phase == PH_MOUT && st != E_PAD) begin
        if (mo_len) begin
          mo_len <= 1'b0;
          mo_rem <= f_head;
        end else if (mo_rem != 8'd0)
          mo_rem <= mo_rem - 8'd1;
        else begin
          mo_abort <= f_head == 8'h06 || f_head == 8'h0C;
          if (f_head == 8'h01)          mo_len <= 1'b1;
          else if (f_head[7:4] == 4'h2) mo_rem <= 8'd1;
        end
      end

      // -----------------------------------------------------------------
      // The running command
      case (st)
        E_SELW: begin
          // a cycle of bsy low with another ID (set by the command) idled
          // any target left on the bus; now the destination, and its sel
          did <= busid;
          if (scnt != 2'd0)
            scnt <= scnt - 2'd1;
          else if (tgt_sel) begin
            bsy       <= 1'b1;
            atn       <= selop != 3'd1;
            conn      <= 1'b1;
            min_len   <= 1'b0;
            min_rem   <= 8'd0;
            nexus_end <= 1'b0;
            mo_len    <= 1'b0;
            mo_rem    <= 8'd0;
            mo_abort  <= 1'b0;
            msg_sent  <= 1'b0;
            cmd_sent  <= 1'b0;
            msg_left  <= selop == 3'd6 ? 2'd3 : 2'd1;
            st <= selop == 3'd1 ? E_SCMD : E_SMSG;
          end else begin
            conn <= 1'b0;                // selection time-out
            rz |= I_DC;
            fin = 1'b1; fin_sq = 1'b1; fin_seq = 3'd0;
          end
        end

        E_SMSG: begin
          if (esp_ack) begin
            msg_sent <= 1'b1;
            msg_left <= msg_left - 2'd1;
            if (msg_left == 2'd1) begin
              if (selop == 3'd3)
                st <= E_SSTOP;           // ATN stays
              else begin
                atn <= 1'b0;             // with the last message byte
                st <= E_SCMD;
              end
            end
          end else if (tgt_req) begin
            if (tgt_phase != PH_MOUT) begin
              rz |= I_FC | I_BS;
              fin = 1'b1; fin_sq = 1'b1; fin_seq = msg_sent ? 3'd2 : 3'd0;
            end else if (!more) begin
              rz |= I_FC | I_BS;         // nothing to send
              fin = 1'b1; fin_sq = 1'b1; fin_seq = 3'd0;
            end
          end
        end

        E_SCMD: begin
          if (esp_ack)
            cmd_sent <= 1'b1;
          else if (mo_abort) begin
            bsy  <= 1'b0;
            conn <= 1'b0;
            rz |= I_DC;
            fin = 1'b1; fin_sq = 1'b1; fin_seq = 3'd2;
          end else if (tgt_req) begin
            if (tgt_phase != PH_CMD) begin
              rz |= I_FC | I_BS;
              fin = 1'b1; fin_sq = 1'b1;
              fin_seq = !cmd_sent ? 3'd2 : more ? 3'd3 : 3'd4;
            end else if (!more) begin
              rz |= I_FC | I_BS;         // the target wants more CDB than given
              fin = 1'b1; fin_sq = 1'b1; fin_seq = 3'd3;
            end
          end
        end

        E_SSTOP:
          if (mo_abort) begin
            bsy  <= 1'b0;                // the message was ABORT
            conn <= 1'b0;
            rz |= I_DC;
            fin = 1'b1; fin_sq = 1'b1; fin_seq = 3'd1;
          end else if (tgt_req) begin
            rz |= I_FC | I_BS;
            fin = 1'b1; fin_sq = 1'b1; fin_seq = 3'd1;
          end

        E_XFER: begin
          if (tgt_req && !xph_v) begin
            xph   <= tgt_phase;
            xph_v <= 1'b1;
          end
          if (esp_ack) begin
            got1 <= 1'b1;
            if (eff_ph[0]) begin
              if (dma) bus_left <= bus_left - 17'd1;
            end else if (eff_ph == PH_MOUT && f_cnt == 5'd1 && !(dma && tc != 17'd0))
              atn <= 1'b0;               // before the last message byte's ack
          end else if (eff_ph == PH_MIN && got1) begin
            // a message byte: ACK stays (MESSAGE ACCEPTED releases it)
            if (!dma || f_cnt == 5'd0) begin
              rz |= I_FC;
              fin = 1'b1;
              min_held <= 1'b1;
            end
          end else if (xph == PH_MOUT && xph_v && mo_abort && !more) begin
            // ABORT / BUS DEVICE RESET sent: the target has left
            bsy  <= 1'b0;
            conn <= 1'b0;
            rz |= I_DC;
            fin = 1'b1;
          end else if (tgt_req && xph_v) begin
            if (tgt_phase != xph) begin
              // the target moved on; a DMA in drains the FIFO first
              if (!(dma && xph[0] && f_cnt != 5'd0)) begin
                rz |= I_BS;
                fin = 1'b1;
              end
            end else if (xph[0]) begin
              if (dma ? (bus_left == 17'd0 && f_cnt == 5'd0) : got1) begin
                rz |= I_BS;
                fin = 1'b1;
              end
            end else if (!more && (dma || got1)) begin
              // ESP-9: a non-DMA TI out sends at least one byte, which
              // may be written to the FIFO after the command
              rz |= I_BS;
              fin = 1'b1;
            end
          end
        end

        E_ICCS: begin
          if (esp_ack) begin
            if (tgt_phase == PH_STAT)
              got_st <= 1'b1;
            else begin
              if (ends) bsy <= 1'b0;     // the target leaves the bus
              rz |= I_FC;
              fin = 1'b1;
              min_held <= 1'b1;
            end
          end else if (tgt_req && !(tgt_phase == PH_STAT && !got_st) && tgt_phase != PH_MIN) begin
            rz |= I_BS;                  // not the status/message the command expects
            fin = 1'b1;
          end
        end

        E_MACC: begin
          if (nexus_end) begin
            bsy  <= 1'b0;
            conn <= 1'b0;
            rz |= I_DC;
            fin = 1'b1; fin_sq = 1'b1; fin_seq = 3'd0;
          end else if (tgt_req) begin
            rz |= I_BS;                  // ESP-8: the target wants more
            fin = 1'b1;
          end
        end

        E_PAD: begin
          if (tgt_req && !xph_v) begin
            xph   <= tgt_phase;
            xph_v <= 1'b1;
          end
          if (!esp_ack && tgt_req && xph_v && (tgt_phase != xph || tc == 17'd0)) begin
            rz |= I_BS;
            fin = 1'b1;
          end
        end

        E_BRST: begin
          if (brst_cnt != '0)
            brst_cnt <= brst_cnt - 1'b1;
          else begin
            srst <= 1'b0;
            if (!cfg1[6]) rz |= I_RST;   // CFG1 bit 6 disables the report
            st <= E_IDLE;
          end
        end

        default: ;
      endcase

      if (fin) begin
        st  <= E_IDLE;
        dma <= 1'b0;
      end

      // -----------------------------------------------------------------
      // Register writes; a command runs now or waits behind the running one
      if (access && bus_i.we) begin
        case (ra)
          4'h0: begin tc_lat[7:0]  <= wbyte; stat_tc <= 1'b0; end
          4'h1: begin tc_lat[15:8] <= wbyte; stat_tc <= 1'b0; end
          4'h3: begin
            cmd_r <= wbyte;
            if (wbyte[6:2] == 5'd0) begin                // 00-03 run at once
              ex_v = 1'b1; ex_c = wbyte;
            end else if (st == E_IDLE && !cmd_qv) begin
              ex_v = 1'b1; ex_c = wbyte;
            end else if (st == E_IDLE) begin
              ex_v = 1'b1; ex_c = cmd_q;                 // the held one first
              cmd_q <= wbyte;
            end else begin
              if (cmd_qv) stat_ge <= 1'b1;               // the command register overwritten
              cmd_q  <= wbyte;
              cmd_qv <= 1'b1;
            end
          end
          4'h4: busid <= wbyte[2:0];
          4'h8: cfg1  <= wbyte;
          4'hB: cfg2  <= wbyte;
          default: ;
        endcase
      end else if (cmd_qv && st == E_IDLE) begin
        ex_v = 1'b1; ex_c = cmd_q;
        cmd_qv <= 1'b0;
      end

      if (ex_v) begin
        // ACK released (MESSAGE ACCEPTED, a select, a reset, ...); NOP,
        // FLUSH and SET/RESET ATN (a message about to be rejected) keep it
        if (ex_c[6:0] != 7'h00 && ex_c[6:0] != 7'h01 && ex_c[6:0] != 7'h1A && ex_c[6:0] != 7'h1B)
          min_held <= 1'b0;
        if (ex_c[7]) begin
          tc <= tc_lat == 16'd0 ? 17'h10000 : {1'b0, tc_lat};
          stat_tc <= 1'b0;
        end
        case (ex_c[6:0])
          7'h00: ;
          7'h01: begin                                   // FLUSH FIFO
            f_rp <= 4'd0; f_wp <= 4'd0; f_cnt <= 5'd0;
          end
          7'h02: begin                                   // RESET chip
            st       <= E_IDLE;
            stat_tc  <= 1'b0;
            stat_ge  <= 1'b0;
            cmd_r    <= 8'h00;
            cmd_qv   <= 1'b0;
            cfg1     <= cfg1 & 8'h07;                    // the bus ID stays
            cfg2     <= 8'h00;
            hold_cnt <= '0;
            f_rp <= 4'd0; f_wp <= 4'd0; f_cnt <= 5'd0;
            conn <= 1'b0; dma <= 1'b0; bsy <= 1'b0; atn <= 1'b0;
            soft_rst = 1'b1;
          end
          7'h03: begin                                   // RESET SCSI bus
            st       <= E_BRST;
            srst     <= 1'b1;
            brst_cnt <= BW'(BRST_CYCLES);
            hold_cnt <= '0;
            conn <= 1'b0; dma <= 1'b0; bsy <= 1'b0; atn <= 1'b0;
          end
          7'h10, 7'h18: begin                            // TRANSFER INFORMATION, PAD
            if (!conn) rz |= I_ILL;
            else begin
              st       <= ex_c[3] ? E_PAD : E_XFER;
              dma      <= ex_c[7];
              xph_v    <= 1'b0;
              got1     <= 1'b0;
              bus_left <= tc_lat == 16'd0 ? 17'h10000 : {1'b0, tc_lat};
            end
          end
          7'h11: begin                                   // ICCS
            if (!conn) rz |= I_ILL;
            else begin st <= E_ICCS; got_st <= 1'b0; end
          end
          7'h12: begin                                   // MESSAGE ACCEPTED
            if (!conn) rz |= I_ILL;
            else st <= E_MACC;
          end
          7'h1A, 7'h1B: begin                            // SET/RESET ATN
            if (!conn) rz |= I_ILL;
            else atn <= !ex_c[0];
          end
          7'h41, 7'h42, 7'h43, 7'h46: begin              // the selects
            selop    <= ex_c[2:0];
            dma      <= ex_c[7];
            hold_cnt <= HW'(HOLD_CYCLES);
            bsy      <= 1'b0;
            atn      <= 1'b0;
            did      <= busid ^ 3'd1;
            scnt     <= 2'd3;
            xph_v    <= 1'b0;
            st <= E_SELW;
          end
          7'h44: ;                                       // ENSEL: no reselection
          7'h45: rz |= I_FC;                             // DISSEL
          default: begin
            rz |= I_ILL;
            cmd_r <= 8'h00;
          end
        endcase
      end

      // -----------------------------------------------------------------
      // The interrupt register: reading it (while the interrupt shows)
      // clears it, the sequence step and GE; bits raised in the same
      // cycle survive
      intr_rd = access && !bus_i.we && ra == 4'h5 && int_vis;
      if (intr_rd) begin
        istat   <= rz;
        seq     <= 3'd0;
        stat_ge <= 1'b0;
      end else
        istat <= istat | rz;
      if (fin_sq) seq <= fin_seq;
      if (soft_rst) begin
        istat   <= 8'h00;
        seq     <= 3'd0;
        stat_ge <= 1'b0;
      end
    end
  end

`ifndef SYNTHESIS
  // +esplog: register accesses, the bytes of the non-data phases, the
  // interrupt line (simulation)
  logic esplog, irq_q;
  initial esplog = $test$plusargs("esplog");
  always_ff @(posedge clk) begin
    irq_q <= irq_o;
    if (esplog) begin
      if (access)
        $display("esp %0t: %s r%x=%02x st=%0d ph=%0d bsy=%0d f=%0d tc=%0x", $time,
                 bus_i.we ? "W" : "R", ra, bus_i.we ? wbyte : rbyte, st, tgt_phase, bsy,
                 f_cnt, tc);
      if (esp_ack && tgt_phase[2:1] != 2'b00)
        $display("esp %0t: bus ph=%0d %s %02x", $time, tgt_phase,
                 tgt_phase[0] ? "in" : "out", tgt_phase[0] ? tgt_d : f_head);
      if (irq_o != irq_q)
        $display("esp %0t: irq %0d istat=%02x seq=%0d", $time, irq_o, istat, seq);
    end
  end
`endif

endmodule
