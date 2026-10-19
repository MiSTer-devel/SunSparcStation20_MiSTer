// SPDX-License-Identifier: MIT
//
// Vendored from Wish7990 (MIT, rtl/sun4m/LICENSE.wish7990; MelkhiorVintageComputing,
// https://github.com/MelkhiorVintageComputing/Wish7990, commit 8610ef5,
// src/le_rx.sv, as pinned by Sun-3_FPGA). Local changes: the module and
// the modules it instantiates take a wish7990_ prefix; after a BUFF
// error the rest of the frame is thrown away (S_END1 to S_DRAINQ) instead
// of being taken for a new frame; an accepted frame always polls its
// descriptor again (S_FILTER to S_POLL) rather than trusting the one
// fetched while idle. See
// rtl/sun4m/lance.sv for how the SS20 uses it.
//
// The receive ring engine.
//
// Frames arrive from mii_rx through an asynchronous FIFO as a stream of
// {end, err[2:0], data[7:0]} words: data words carry a byte, and one end word
// closes the frame and says whether the FCS was wrong, whether it ended part
// way through a byte, and whether the FIFO overflowed on the way.
//
// **Address recognition happens before memory is touched.**  p. 31: "When a
// packet arrives from the physical medium, after the Address Recognition Logic
// accepts the packet, the C-LANCE will immediately poll the Receiver Ring once
// for a buffer."  So the first six bytes are held back here while le_filt
// decides, and only then does anything go to the host - which also means a
// frame for somebody else costs no bus cycles at all.  The held bytes are
// replayed into the buffer ahead of the rest of the frame.
//
// The chip keeps a buffer ready by polling the ring while it is idle, so that
// the poll is rarely on the critical path.  If a frame is for us and there is
// still no buffer, it is lost and MISS is set in CSR0 - a CSR0 bit rather than
// a descriptor bit for the obvious reason: there is no descriptor to write it
// into.  A frame that was not for us sets nothing.
//
// The FCS is written into the buffer and counted in MCNT.  NetBSD's am7990.c
// reads `lance_read(sc, ..., (int)rmd.rmd3 - 4)`, subtracting the four bytes
// itself, so a chip that stripped them would hand every driver a frame four
// bytes short.  mii_rx's KEEP_FCS is what says so.
//
// Write-back order is the rule doc/drivers/SunOS414/if_le.c lines 1434-1444
// relies on: RMD3 carrying MCNT first, then RMD1 carrying OWN on its own as a
// 16-bit write, then RINT.

module wish7990_le_rx #(
    // 1.6 ms at 50 MHz, as on the transmit side.
    parameter int POLL_TICKS = 80000
) (
    input  logic        clk,
    input  logic        rst,

    // ---- from the register file and le_init --------------------------------
    input  logic        stop_i,
    input  logic        rxon_i,
    input  logic [23:0] rdra_i,
    input  logic [2:0]  rlen_i,
    input  logic        bswp_i,
    input  logic [47:0] padr_i,
    input  logic [63:0] ladrf_i,
    input  logic        prom_i,

    // ---- to the register file ----------------------------------------------
    output logic        rint_o,       // one-cycle set strobe
    output logic        miss_o,
    output logic        merr_o,
    output logic        fault_o,      // level: pull RXON down

    // ---- the receive FIFO ---------------------------------------------------
    input  logic        fifo_empty_i,
    input  logic [11:0] fifo_data_i,
    output logic        fifo_rd_o,

    // ---- memory port, into wb_arb ------------------------------------------
    output logic        bus_req_o,
    output logic        bus_we_o,
    output logic [1:0]  bus_size_o,
    output logic [3:0]  bus_sel_o,
    output logic [23:0] bus_addr_o,
    output logic [31:0] bus_wdata_o,
    input  logic        bus_ack_i,
    input  logic [31:0] bus_rdata_i,
    input  logic        bus_err_i
);

  localparam logic [1:0] SZ_HALF = wish7990_pkg::BUS_SZ_HALF;
  localparam logic [1:0] SZ_WORD = wish7990_pkg::BUS_SZ_WORD;

  typedef enum logic [3:0] {
    S_IDLE,      // nothing in progress
    S_POLL,      // read RMD1, looking for a buffer
    S_FETCH0,    // read RMD0
    S_FETCH2,    // read RMD2 for the count
    S_FILTER,    // hold the first six bytes back while le_filt decides
    S_WRITE,     // gather bytes into a word, the held six first
    S_POST,      // drain the posted write and any partial tail
    S_LOOK,      // the buffer filled mid-frame: look at the next descriptor
    S_MID1,      // hand an intermediate buffer back
    S_END3,      // write MCNT into RMD3
    S_END1,      // write RMD1: OWN cleared, flags, error bits
    S_DRAIN,     // throw the frame away, MISS already reported
    S_DRAINQ     // throw it away because it was not ours; report nothing
  } state_e;

  state_e state;

  logic [6:0]  idx;
  wire  [6:0]  ring_mask = (7'b1 << rlen_i) - 7'b1;
  wire  [6:0]  idx_next  = (idx + 7'd1) & ring_mask;
  wire  [23:0] md_addr   = rdra_i + {13'h0, idx, 3'b000};

  logic [15:0] rmd0_q, rmd1_q;
  logic [15:0] next_rmd1_q;
  logic [23:0] buf_addr;
  logic [11:0] buf_left;
  logic [11:0] mcnt;            // bytes of this frame so far, the FCS included
  logic        first_buf;       // this descriptor carries STP
  logic        have_buf;        // a buffer is in hand, fetched and ready
  logic        want_replay;     // where the buffer hunt should return to
  logic        err_crc, err_fram, err_oflo, err_buff;

  // Eight deep rather than six so that the counter, which parks at six,
  // never indexes off the end.
  logic [7:0]  hdr [8];         // the held-back destination address
  logic [2:0]  fill;            // how many of them have been collected
  logic [2:0]  replay;          // which of them is still to be written

  // Frame data moves a word at a time: bytes land in their own lane of an
  // accumulator and the word is posted as soon as the last lane fills, so the
  // bus transaction overlaps the next four bytes coming out of the FIFO.  A
  // partial word - an unaligned buffer start, or the tail of a frame - goes out
  // with the lanes that were actually filled, so it is always one transaction
  // per word of buffer touched.  At gigabit a byte arrives every eight
  // nanoseconds and there is no headroom for anything else; doc/interface.md
  // works the arithmetic through.
  logic [31:0] acc;
  logic [3:0]  acc_sel;
  logic [23:0] acc_addr;       // word aligned
  state_e      after_flush;

  // The completed word waits here while the next one is gathered, so a bus
  // transaction never stops bytes coming out of the FIFO.  At gigabit that is
  // the difference between keeping up and overflowing: a byte arrives every
  // eight nanoseconds, and a write that stalled the gather would cost three
  // clocks in every four bytes.
  logic        out_req;
  logic [31:0] out_data;
  logic [3:0]  out_sel;
  logic [23:0] out_addr;

  logic [31:0] poll_cnt;

  // One FIFO word is held while it is being dealt with.
  logic        fw_valid;
  logic [11:0] fw;
  wire         fw_end  = fw[11];
  wire  [7:0]  fw_byte = fw[7:0];

  wire [15:0] rd16 = bus_rdata_i[15:0];

  // ---- the address filter ----------------------------------------------------
  logic filt_byte_valid, filt_done, filt_accept;
  wire  filt_start;

  wish7990_le_filt u_filt (
      .clk          (clk),
      .rst          (rst),
      .padr_i       (padr_i),
      .ladrf_i      (ladrf_i),
      .prom_i       (prom_i),
      .start_i      (filt_start),
      .byte_valid_i (filt_byte_valid),
      .byte_i       (fw_byte),
      .done_o       (filt_done),
      .accept_o     (filt_accept)
  );

  // start_i has to arrive the cycle *before* the first byte: le_filt resets its
  // counter on it and would otherwise drop that byte, which shifts the whole
  // address by one and rejects every frame.
  assign filt_start      = (state == S_IDLE) && fw_valid && !fw_end;
  assign filt_byte_valid = (state == S_FILTER) && fw_valid && !fw_end;

  // Refill in the same cycle the held word is finished with, so the stream
  // runs at one byte per clock rather than one every two.
  logic fw_consume;
  assign fifo_rd_o = !fifo_empty_i && (!fw_valid || fw_consume);

  // BSWP swaps the two bytes of every word of frame data and nothing else
  // (p. 23, p. 32): address bit 0 inverted.  Inverting bit 0 never leaves the
  // word, so only the lane changes and the word address does not - which is
  // why the swap lives here rather than in front of wb_arb, where descriptor
  // accesses would need a bypass tag.
  wire [1:0]  lane      = bswp_i ? (buf_addr[1:0] ^ 2'b01) : buf_addr[1:0];
  wire [23:0] word_addr = {buf_addr[23:2], 2'b00};
  // The byte just gathered was the last of its word, so the word can go.
  wire        word_full = (buf_addr[1:0] == 2'b11);

  // The byte going into the buffer: the held-back address first, then the
  // stream.  Doing it this way rather than with a state of its own keeps the
  // buffer-full and end-of-frame handling in one place.
  wire        replaying = (replay < 3'd6);
  wire [7:0]  wr_byte   = replaying ? hdr[replay] : fw_byte;
  wire        wr_valid  = replaying ? 1'b1 : (fw_valid && !fw_end);

  // This byte finishes a word, either because it is the last of one or because
  // it is the last of the buffer.  If the previous word has not gone yet the
  // gather stalls for a cycle rather than losing it - which is the only time
  // the bus is allowed to hold the wire up.
  wire        finishes   = word_full || (buf_left == 12'd1);
  wire        post_ready = !out_req || bus_ack_i;
  wire        take       = wr_valid && (!finishes || post_ready);

  always_comb begin
    fw_consume = 1'b0;
    case (state)
      S_IDLE:            fw_consume = fw_valid && fw_end;
      S_FILTER:          fw_consume = fw_valid && !filt_done;
      S_WRITE:           fw_consume = take && !replaying;
      S_DRAIN, S_DRAINQ: fw_consume = fw_valid;
      default:           fw_consume = 1'b0;
    endcase
  end

  // The word being posted, with this byte folded in.
  wire [31:0] out_next  = (acc & ~(32'hff << (8*lane))) | ({24'h0, wr_byte} << (8*lane));
  wire [3:0]  sel_next  = acc_sel | (4'b1 << lane);
  wire [23:0] addr_next = (acc_sel == 4'h0) ? word_addr : acc_addr;

  // p. 27-28, the validity rules, applied where the flags are assembled rather
  // than left to the driver:
  //   FRAM only alongside a CRC error, and only with ENP set and OFLO clear;
  //   CRC  only with ENP set and OFLO clear;
  //   OFLO only when ENP is *not* set - an overflowed frame is not finished,
  //        so it does not get an end-of-packet marker either.
  wire ok_end = !err_oflo;
  wire [15:0] rmd1_end =
      (rmd1_q & ~(16'b1 << wish7990_pkg::R1_OWN))
      | (first_buf                       ? (16'b1 << wish7990_pkg::R1_STP)  : 16'h0)
      | (ok_end                          ? (16'b1 << wish7990_pkg::R1_ENP)  : 16'h0)
      | ((err_crc  && ok_end)            ? (16'b1 << wish7990_pkg::R1_CRC)  : 16'h0)
      | ((err_fram && err_crc && ok_end) ? (16'b1 << wish7990_pkg::R1_FRAM) : 16'h0)
      | (err_oflo                        ? (16'b1 << wish7990_pkg::R1_OFLO) : 16'h0)
      | (err_buff                        ? (16'b1 << wish7990_pkg::R1_BUFF) : 16'h0);
  wire [15:0] rmd1_wb = rmd1_end |
      ((|(rmd1_end & wish7990_pkg::R1_ERR_MASK))
          ? (16'b1 << wish7990_pkg::R1_ERR) : 16'h0000);

  // An intermediate buffer keeps STP if it was the first and gets nothing else.
  wire [15:0] rmd1_mid =
      (rmd1_q & ~(16'b1 << wish7990_pkg::R1_OWN))
      | (first_buf ? (16'b1 << wish7990_pkg::R1_STP) : 16'h0);

  always_comb begin
    bus_req_o   = 1'b0;
    bus_we_o    = 1'b0;
    bus_size_o  = SZ_HALF;
    bus_sel_o   = 4'b0000;
    bus_addr_o  = md_addr + wish7990_pkg::MD1_OFF[23:0];
    bus_wdata_o = 32'h0;

    case (state)
      S_POLL: bus_req_o = 1'b1;
      S_LOOK: begin
        bus_req_o  = 1'b1;
        bus_addr_o = rdra_i + {13'h0, idx_next, 3'b000}
                            + wish7990_pkg::MD1_OFF[23:0];
      end
      S_FETCH0: begin
        bus_req_o  = 1'b1;
        bus_addr_o = md_addr + wish7990_pkg::MD0_OFF[23:0];
      end
      S_FETCH2: begin
        bus_req_o  = 1'b1;
        bus_addr_o = md_addr + wish7990_pkg::MD2_OFF[23:0];
      end
      S_WRITE, S_POST: begin
        bus_req_o   = out_req;
        bus_we_o    = 1'b1;
        bus_size_o  = SZ_WORD;
        bus_sel_o   = out_sel;
        bus_addr_o  = out_addr;
        bus_wdata_o = out_data;
      end
      S_MID1: begin
        bus_req_o   = 1'b1;
        bus_we_o    = 1'b1;
        bus_wdata_o = {16'h0, rmd1_mid};
      end
      S_END3: begin
        bus_req_o   = 1'b1;
        bus_we_o    = 1'b1;
        bus_addr_o  = md_addr + wish7990_pkg::MD3_OFF[23:0];
        bus_wdata_o = {20'h0, mcnt};
      end
      S_END1: begin
        bus_req_o   = 1'b1;
        bus_we_o    = 1'b1;
        bus_wdata_o = {16'h0, rmd1_wb};
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state       <= S_IDLE;
      idx         <= 7'd0;
      rmd0_q      <= 16'h0;
      rmd1_q      <= 16'h0;
      next_rmd1_q <= 16'h0;
      buf_addr    <= 24'h0;
      buf_left    <= 12'h0;
      mcnt        <= 12'h0;
      first_buf   <= 1'b1;
      have_buf    <= 1'b0;
      want_replay <= 1'b0;
      err_crc     <= 1'b0;
      err_fram    <= 1'b0;
      err_oflo    <= 1'b0;
      err_buff    <= 1'b0;
      fill        <= 3'd0;
      replay      <= 3'd6;
      poll_cnt    <= 32'h0;
      fw_valid    <= 1'b0;
      fw          <= 12'h0;
      rint_o      <= 1'b0;
      miss_o      <= 1'b0;
      merr_o      <= 1'b0;
      fault_o     <= 1'b0;
      for (int i = 0; i < 8; i++) hdr[i] <= 8'h0;
    end else begin
      rint_o     <= 1'b0;
      miss_o     <= 1'b0;
      merr_o     <= 1'b0;

      // A word taken this cycle is here the next one; one finished with and not
      // refilled leaves the holding register empty.
      if (fifo_rd_o) begin
        fw       <= fifo_data_i;
        fw_valid <= 1'b1;
      end else if (fw_consume) begin
        fw_valid <= 1'b0;
      end

      // The posted write retiring.  Before the state machine below, so that a
      // word completing in the same cycle still gets posted.
      if (out_req && bus_ack_i) out_req <= 1'b0;

      if (stop_i || !rxon_i) begin
        state    <= S_IDLE;
        idx      <= 7'd0;
        poll_cnt <= 32'h0;
        fw_valid <= 1'b0;
        have_buf <= 1'b0;
        if (stop_i) fault_o <= 1'b0;
      end else begin
        if (poll_cnt >= POLL_TICKS[31:0]) poll_cnt <= 32'h0;
        else                              poll_cnt <= poll_cnt + 32'd1;

        case (state)
          S_IDLE: begin
            if (fw_valid) begin
              // A frame is arriving.  Address recognition comes first, whether
              // or not there is a buffer: a frame for somebody else must cost
              // nothing and report nothing.
              if (fw_end) begin
                // A carrier event, no frame.  fw_consume discards it.
              end else begin
                mcnt      <= 12'h0;
                first_buf <= 1'b1;
                err_crc   <= 1'b0;
                err_fram  <= 1'b0;
                err_oflo  <= 1'b0;
                err_buff  <= 1'b0;
                fill      <= 3'd0;
                state     <= S_FILTER;
              end
            end else if (!have_buf && poll_cnt == 32'h0) begin
              want_replay <= 1'b0;
              state       <= S_POLL;
            end
          end

          S_FILTER: begin
            if (filt_done) begin
              if (filt_accept) begin
                // The held bytes go into the buffer ahead of the rest of the
                // frame; want_replay also carries the buffer hunt, and stays
                // set across a chain so a mid-frame fetch returns here too.
                replay      <= 3'd0;
                want_replay <= 1'b1;
                // Local change: always S_POLL, so a buffer the host took
                // back after the idle fetch is seen as gone (MISS), as
                // tests/cpu ethtest t_eth_miss expects. The frame waits in
                // eth_hps or the loopback FIFO meanwhile.
                state       <= S_POLL;   // p. 31
              end else begin
                state <= S_DRAINQ;
              end
            end else if (fw_valid) begin
              if (fw_end) begin
                // Fewer than six bytes: nothing that can be addressed to us.
                state <= S_IDLE;
              end else begin
                hdr[fill] <= fw_byte;
                fill      <= fill + 3'd1;
              end
            end
          end

          S_POLL: begin
            if (bus_err_i) begin
              merr_o  <= 1'b1;
              fault_o <= 1'b1;
              state   <= S_IDLE;
            end else if (bus_ack_i) begin
              rmd1_q <= rd16;
              if (rd16[wish7990_pkg::R1_OWN]) begin
                state <= S_FETCH0;
              end else if (want_replay) begin
                // p. 20: "MISSED PACKET is set when the receiver loses a packet
                // because it does not own any receive buffer."  Only for a
                // frame that was actually addressed to us.
                miss_o <= 1'b1;
                state  <= S_DRAIN;
              end else begin
                state <= S_IDLE;
              end
            end
          end

          S_FETCH0: begin
            if (bus_err_i) begin
              merr_o  <= 1'b1;
              fault_o <= 1'b1;
              state   <= S_IDLE;
            end else if (bus_ack_i) begin
              rmd0_q <= rd16;
              state  <= S_FETCH2;
            end
          end

          S_FETCH2: begin
            if (bus_err_i) begin
              merr_o  <= 1'b1;
              fault_o <= 1'b1;
              state   <= S_IDLE;
            end else if (bus_ack_i) begin
              buf_addr <= {rmd1_q[7:0], rmd0_q};
              buf_left <= (~rd16[11:0]) + 12'd1;
              have_buf <= 1'b1;
              acc      <= 32'h0;
              acc_sel  <= 4'h0;
              state    <= want_replay ? S_WRITE : S_IDLE;
            end
          end

          S_WRITE: begin
            if (bus_err_i) begin
              merr_o  <= 1'b1;
              fault_o <= 1'b1;
              state   <= S_IDLE;
            end else if (!replaying && fw_valid && fw_end) begin
              err_crc     <= fw[10];
              err_fram    <= fw[9];
              err_oflo    <= fw[8];
              after_flush <= S_END3;
              state       <= S_POST;
            end else if (take) begin
              acc[8*lane +: 8] <= wr_byte;
              acc_sel          <= sel_next;
              if (acc_sel == 4'h0) acc_addr <= word_addr;
              buf_addr <= buf_addr + 24'd1;
              mcnt     <= mcnt + 12'd1;
              if (replaying) replay <= replay + 3'd1;

              if (finishes) begin
                // Hand the completed word to the posted write and start the
                // next one straight away; the bus catches up on its own.
                out_req  <= 1'b1;
                out_data <= out_next;
                out_sel  <= sel_next;
                out_addr <= addr_next;
                acc      <= 32'h0;
                acc_sel  <= 4'h0;
              end

              if (buf_left == 12'd1) begin
                after_flush <= S_LOOK;
                state       <= S_POST;
              end else begin
                buf_left <= buf_left - 12'd1;
              end
            end
          end

          S_POST: begin
            // Everything gathered has to be in memory before a descriptor is
            // touched, or the host could see MCNT for data that has not landed.
            if (bus_err_i) begin
              merr_o  <= 1'b1;
              fault_o <= 1'b1;
              state   <= S_IDLE;
            end else if (out_req) begin
              // waiting for the posted write; the ack below clears it
            end else if (acc_sel != 4'h0) begin
              out_req  <= 1'b1;
              out_data <= acc;
              out_sel  <= acc_sel;
              out_addr <= acc_addr;
              acc      <= 32'h0;
              acc_sel  <= 4'h0;
            end else begin
              state <= after_flush;
            end
          end

          S_LOOK: begin
            // The buffer is full and the frame has not ended.  Look at the next
            // descriptor before handing this one back, so a chain with nowhere
            // to go still has somewhere to report BUFF.
            if (fw_valid && fw_end) begin
              err_crc  <= fw[10];
              err_fram <= fw[9];
              err_oflo <= fw[8];
              fw_valid <= 1'b0;
              state    <= S_END3;
            end else if (bus_err_i) begin
              merr_o  <= 1'b1;
              fault_o <= 1'b1;
              state   <= S_IDLE;
            end else if (bus_ack_i) begin
              next_rmd1_q <= rd16;
              if (!rd16[wish7990_pkg::R1_OWN]) begin
                // p. 28: BUFF "is set any time the C-LANCE does not own the
                // next buffer while data chaining a received packet".
                err_buff <= 1'b1;
                state    <= S_END3;
              end else begin
                state <= S_MID1;
              end
            end
          end

          S_MID1: begin
            if (bus_err_i) begin
              merr_o  <= 1'b1;
              fault_o <= 1'b1;
              state   <= S_IDLE;
            end else if (bus_ack_i) begin
              idx       <= idx_next;
              rmd1_q    <= next_rmd1_q;
              first_buf <= 1'b0;
              state     <= S_FETCH0;
            end
          end

          S_END3: begin
            if (bus_err_i) begin
              merr_o  <= 1'b1;
              fault_o <= 1'b1;
              state   <= S_IDLE;
            end else if (bus_ack_i) begin
              state <= S_END1;
            end
          end

          S_END1: begin
            if (bus_err_i) begin
              merr_o  <= 1'b1;
              fault_o <= 1'b1;
              state   <= S_IDLE;
            end else if (bus_ack_i) begin
              // OWN cleared, and only then RINT.
              rint_o      <= 1'b1;
              idx         <= idx_next;
              have_buf    <= 1'b0;
              want_replay <= 1'b0;
              // Go looking for the next buffer straight away, so back-to-back
              // frames do not wait for the poll interval.
              state       <= S_POLL;
              // Local change: a BUFF error left the frame's tail (and its end
              // word) in the FIFO; S_IDLE would start a frame on it.
              if (err_buff) state <= S_DRAINQ;
            end
          end

          S_DRAIN, S_DRAINQ: begin
            if (fw_valid && fw_end) state <= S_IDLE;
          end

          default: state <= S_IDLE;
        endcase
      end
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, bus_rdata_i[31:16], fw[10:8], 1'b0};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
