// SPDX-License-Identifier: MIT
//
// Vendored from Wish7990 (MIT, rtl/sun4m/LICENSE.wish7990; MelkhiorVintageComputing,
// https://github.com/MelkhiorVintageComputing/Wish7990, commit 8610ef5,
// src/le_tx.sv, as pinned by Sun-3_FPGA). Local changes: the module and
// the modules it instantiates take a wish7990_ prefix; internal loopback
// carries LOOPBACK_MAX bytes (a parameter, upstream's 32 by default) and
// waits while the loopback FIFO is full instead of losing the byte. See
// rtl/sun4m/lance.sv for how the SS20 uses it.
//
// The transmit ring engine.
//
// The chip owns whichever transmit descriptors have OWN set.  It finds them by
// polling: every 1.6 ms while STRT is set, or immediately when the host writes
// CSR0.TDMD.  A poll reads TMD1 and nothing else (datasheet p. 30); only once
// OWN is found set does it read TMD0 and TMD2 for the address and the count.
//
// A descriptor with OWN set but STP clear is *skipped* - p. 29: "The STP bit
// must be set in the first buffer of the packet, or the C-LANCE will skip over
// this descriptor and poll the next descriptor(s) until the OWN and STP bits
// are set."  Skipped, not an error, and nothing is written back.
//
// The whole frame is staged in dp_ram before mii_tx starts, so a collision
// retry costs nothing: mii_tx reads the RAM again and no host memory is touched
// twice.  That is inherited from Wish82586's command unit and is why the retry
// loop over in mii_tx is as simple as it is.
//
// Two orderings come straight from the datasheet and are the easy things to
// get plausibly wrong:
//
//   * **The lookahead precedes the release.**  p. 30-31: while chaining, the
//     chip reads the next descriptor before it relinquishes the current one,
//     "clears the OWN bit for this buffer, and immediately starts loading the
//     Transmit FIFO from the next buffer".  Doing it the other way round would
//     hand a buffer back and only then discover there was nowhere to put the
//     BUFF error describing why the frame died.
//   * **Status lands in the last descriptor, OWN goes out alone and last.**
//     p. 31: "Once the last part of the packet has been transmitted to the
//     medium, the C-LANCE will update the status in TMD1, TMD3 ... and will
//     relinquish the last buffer to the CPU."  And
//     doc/drivers/SunOS414/if_le.c lines 1434-1444 states what the driver
//     relies on: "since the chip uses the order <clear own bit, set RINT>, we
//     must use the opposite order <clear RINT, set own bit>".  So TMD3 first
//     when there is anything to say, then TMD1 as a 16-bit write of its own,
//     then TINT.

module wish7990_le_tx #(
    // How many system clocks 1.6 ms is.  The real interval is implemented
    // rather than a simulation-only shortcut, because a driver that relies on
    // the poll rather than on TDMD has to see the latency it would on
    // hardware.  The default is 1.6 ms at 50 MHz.
    parameter int POLL_TICKS = 80000,
    // Local change: the internal loopback limit, upstream's 32 (p. 24) by
    // default. The SS20's tests loop a 70-byte frame (tests/cpu ethtest
    // t_eth_loopback), so lance.sv raises it.
    parameter int LOOPBACK_MAX = 32
) (
    input  logic        clk,
    input  logic        rst,

    // ---- from the register file and le_init --------------------------------
    input  logic        stop_i,
    input  logic        txon_i,
    input  logic        tdmd_i,       // one-cycle pulse
    input  logic [23:0] tdra_i,
    input  logic [2:0]  tlen_i,
    input  logic        dtcr_i,       // MODE.DTCR: do not append an FCS
    input  logic        drty_i,       // MODE.DRTY: one attempt, then RTRY
    input  logic        loop_i,       // MODE.LOOP
    input  logic        intl_i,       // MODE.INTL, only meaningful with LOOP
    input  logic        coll_i,       // MODE.COLL, only valid in internal loopback
    input  logic        bswp_i,

    // ---- to the register file ----------------------------------------------
    output logic        tint_o,       // one-cycle set strobe
    output logic        babl_o,
    output logic        merr_o,
    output logic        fault_o,      // level: pull TXON down

    // ---- staging RAM, written from this clock ------------------------------
    output logic        ram_we_o,
    output logic [10:0] ram_addr_o,
    output logic [7:0]  ram_data_o,

    // ---- internal loopback: straight into the receive engine ---------------
    // {end, err[2:0], data[7:0]}, the same word mii_rx produces, so le_rx does
    // not know or care which side a frame came from.
    output logic        lb_wr_o,
    output logic [11:0] lb_data_o,
    input  logic        lb_full_i,
    output logic        lb_active_o,  // le_rx should listen to the loopback FIFO

    // ---- mii_tx, four-phase go/done ----------------------------------------
    output logic        tx_go_o,
    output logic [15:0] tx_len_o,
    output logic        tx_no_crc_o,
    output logic [3:0]  tx_retry_limit_o,
    input  logic        tx_done_i,
    input  logic        tx_ok_i,
    input  logic [3:0]  tx_ncoll_i,
    input  logic        tx_xcoll_i,
    input  logic        tx_defer_i,
    input  logic        tx_no_crs_i,
    input  logic        tx_late_i,

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
    S_IDLE,
    S_POLL,      // read TMD1 of the current descriptor
    S_FETCH0,    // read TMD0 for the low address
    S_FETCH2,    // read TMD2 for the count
    S_STAGE,     // read a word of the buffer
    S_PUSH,      // push its bytes into the staging RAM
    S_LOOK,      // no ENP: read the next descriptor's TMD1 before releasing
    S_RELEASE,   // hand an intermediate buffer back, OWN cleared
    S_SEND,      // hand the staged frame to mii_tx and wait
    S_LB_WAIT,   // internal loopback: let the CRC absorb the last byte
    S_LB_FCS,    // internal loopback: append the FCS the transmitter would
    S_LB_END,    // internal loopback: close the frame
    S_WB3,       // write TMD3, when there is anything to say
    S_WB1,       // write TMD1, clearing OWN.  Last, and on its own.
    S_ADVANCE
  } state_e;

  state_e state;

  // Where we are in the ring.  Seven bits because a ring holds up to 128
  // entries; tlen_i says how many of them are real.
  logic [6:0]  idx;
  wire  [6:0]  ring_mask = (7'b1 << tlen_i) - 7'b1;
  wire  [6:0]  idx_next  = (idx + 7'd1) & ring_mask;
  wire  [23:0] md_addr   = tdra_i + {13'h0, idx, 3'b000};

  logic [15:0] tmd0_q, tmd1_q;      // the descriptor being worked on
  logic [15:0] next_tmd1_q;         // what the lookahead found
  logic [15:0] tmd3_q;              // errors accumulated for this frame
  logic        add_fcs_q;           // TMD1.ADD_FCS of the STP descriptor

  logic [23:0] buf_addr;
  logic [11:0] buf_left;
  logic [11:0] staged;              // bytes put into the RAM so far
  logic [10:0] ram_waddr_q;         // the slot the byte in flight belongs in

  // One bus read brings back up to four bytes; S_PUSH walks them out.
  logic [31:0] word_q;
  logic [1:0]  lane;                // which byte of word_q is next
  logic [2:0]  run;                 // how many of them are still to go

  // p. 24: "Internal loopback allows the C-LANCE to receive its own
  // transmitted packet.  Since this represents full duplex operation, the
  // packet size is limited to 8-32 bytes."  On the real part that limit comes
  // from the frame having to live in the FIFO; here the loopback path is not
  // FIFO limited, so it is enforced outright.  It is reproduced rather than
  // relaxed - see doc/interface.md - so a driver self-test that loops a
  // 60-byte frame fails here exactly as it would on hardware, instead of
  // passing in simulation and failing on a board.
  wire internal = loop_i && intl_i;
  wire lb_room  = staged < 12'(LOOPBACK_MAX);

  logic [2:0]  fcs_cnt;
  logic        lb_overrun;

  logic [31:0] poll_cnt;
  logic        poll_due;
  // A transmit fault turns TXON off, which stops this engine - so it must not
  // be raised until the descriptor describing the fault has been written back.
  // Raising it where the fault is found would abandon the write-back and leave
  // the driver with a descriptor the chip still owns and no explanation.
  logic        fault_pending;

  wire [15:0] rd16 = bus_rdata_i[15:0];

  wire enp = tmd1_q[wish7990_pkg::T1_ENP];

  // Frame data moves a word at a time: one bus transaction per word of buffer
  // touched, whatever the alignment.  At gigabit a byte arrives every eight
  // nanoseconds and the bus is shared with the receive engine, which cannot
  // ask the wire to wait - see doc/interface.md.
  //
  // BSWP swaps the two bytes of every word of *frame data* and nothing else
  // (p. 23, p. 32), which is address bit 0 inverted.  Inverting bit 0 never
  // leaves the word, so the word address is the same either way and only the
  // lane changes - which is why there is no swap stage in front of wb_arb and
  // so no bypass tag for descriptor accesses to get wrong.
  wire [23:0] word_addr = {buf_addr[23:2], 2'b00};
  wire [1:0]  lane_now  = bswp_i ? (lane ^ 2'b01) : lane;

  // How many bytes of this word belong to this buffer: from the current byte
  // to the end of the word, capped by what is left.
  wire [2:0] to_word_end = 3'd4 - {1'b0, buf_addr[1:0]};
  wire [2:0] run_next    = (buf_left < {9'd0, to_word_end}) ? buf_left[2:0]
                                                            : to_word_end;

  // What S_WB1 puts on the bus: OWN cleared, and ERR set if TMD3 says so.
  // p. 29: ERR is "the OR of LCOL, LCAR, UFLO or RTRY".
  wire tmd3_any = |(tmd3_q & wish7990_pkg::T3_ERR_MASK);
  wire [15:0] tmd1_wb =
      (tmd1_q & ~(16'b1 << wish7990_pkg::T1_OWN)) |
      (tmd3_any ? (16'b1 << wish7990_pkg::T1_ERR) : 16'h0000);
  // An intermediate buffer is handed back with OWN cleared and nothing else
  // touched; its status is not this frame's.
  wire [15:0] tmd1_mid = tmd1_q & ~(16'b1 << wish7990_pkg::T1_OWN);

  // ---- the memory request, decoded combinationally --------------------------
  always_comb begin
    bus_req_o   = 1'b0;
    bus_we_o    = 1'b0;
    bus_size_o  = SZ_HALF;
    bus_sel_o   = 4'b0000;
    bus_addr_o  = md_addr + wish7990_pkg::MD1_OFF[23:0];
    bus_wdata_o = 32'h0;

    case (state)
      S_POLL: begin
        bus_req_o = 1'b1;
      end
      S_LOOK: begin
        // The next descriptor's status word, without moving idx yet.
        bus_req_o  = 1'b1;
        bus_addr_o = tdra_i + {13'h0, idx_next, 3'b000}
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
      S_STAGE: begin
        bus_req_o  = 1'b1;
        bus_size_o = SZ_WORD;
        bus_sel_o  = 4'b1111;      // a read; the lanes are picked out below
        bus_addr_o = word_addr;
      end
      S_RELEASE: begin
        bus_req_o   = 1'b1;
        bus_we_o    = 1'b1;
        bus_wdata_o = {16'h0, tmd1_mid};
      end
      S_WB3: begin
        // Only when there is something to say.  Asserting the request
        // unconditionally would start a transaction the state machine then
        // walks away from, and S_WB1 would take its acknowledgement for its
        // own - so TMD1 would never be written and OWN would never clear.
        bus_req_o   = (tmd3_q != 16'h0000);
        bus_we_o    = 1'b1;
        bus_addr_o  = md_addr + wish7990_pkg::MD3_OFF[23:0];
        bus_wdata_o = {16'h0, tmd3_q};
      end
      S_WB1: begin
        bus_req_o   = 1'b1;
        bus_we_o    = 1'b1;
        bus_wdata_o = {16'h0, tmd1_wb};
      end
      default: ;
    endcase
  end

  // The write enable and data are registered, so the address has to be too:
  // by the time the write happens, staged has already moved on.
  // The FCS the loopback path appends, computed over the bytes as they are
  // staged.  p. 24: "During loopback, DTCR = 0 will cause a CRC to be
  // generated on the transmitted packet ... The generated CRC will be written
  // into memory with the data and can be checked by the host software."
  // The byte is registered alongside the enable: by the time the enable is
  // high the lane counter has already moved on, and feeding the CRC from it
  // would checksum the frame one byte out of step.
  logic        lb_crc_init, lb_crc_en;
  logic [7:0]  lb_crc_byte;
  logic [31:0] lb_fcs, lb_crc_unused;
  logic        lb_crc_ok_unused;
  wish7990_crc32_eth #(.DATA_W(8)) u_lb_crc (
      .clk      (clk),
      .rst      (rst),
      .init     (lb_crc_init),
      .en       (lb_crc_en),
      .data_i   (lb_crc_byte),
      .crc_o    (lb_crc_unused),
      .fcs_o    (lb_fcs),
      .crc_ok_o (lb_crc_ok_unused)
  );

  assign lb_active_o = internal;
  assign ram_addr_o  = ram_waddr_q;
  assign tx_len_o    = {4'h0, staged};
  // p. 29: ADD_FCS "instructs the controller to append a CRC to this
  // transmitted frame, regardless of the setting of the DTCR bit", and it is
  // only valid in the descriptor that carries STP - which is why it is latched
  // there rather than read out of whichever descriptor is current.
  assign tx_no_crc_o = dtcr_i && !add_fcs_q;
  // p. 24: with DRTY set "the C-LANCE will attempt only one transmission of a
  // packet.  If there is a collision on the first transmission attempt, a
  // Retry Error (RTRY) will be reported in TMD3."  Otherwise sixteen attempts.
  assign tx_retry_limit_o = drty_i ? 4'd0 : 4'd15;

  // p. 20: BABL "is a flag which indicates excessive length in the transmit
  // buffer.  It will be set after 1519 bytes have been transmitted, excluding
  // preamble and start frame delimiter."  The frame is staged whole before it
  // goes out, so the length is known before a symbol reaches the wire.
  wire [15:0] wire_len = {4'h0, staged} + (tx_no_crc_o ? 16'd0 : 16'd4);
  wire        babbling = wire_len > 16'd1518;

  always_ff @(posedge clk) begin
    if (rst) begin
      state       <= S_IDLE;
      idx         <= 7'd0;
      word_q      <= 32'h0;
      lane        <= 2'd0;
      run         <= 3'd0;
      tmd0_q      <= 16'h0;
      tmd1_q      <= 16'h0;
      next_tmd1_q <= 16'h0;
      tmd3_q      <= 16'h0;
      add_fcs_q   <= 1'b0;
      buf_addr    <= 24'h0;
      buf_left    <= 12'h0;
      staged      <= 12'h0;
      ram_waddr_q <= 11'h0;
      poll_cnt    <= 32'h0;
      poll_due    <= 1'b0;
      tint_o      <= 1'b0;
      babl_o      <= 1'b0;
      merr_o      <= 1'b0;
      fault_o     <= 1'b0;
      tx_go_o       <= 1'b0;
      fault_pending <= 1'b0;
      lb_wr_o       <= 1'b0;
      lb_data_o     <= 12'h0;
      lb_overrun    <= 1'b0;
      fcs_cnt       <= 3'd0;
      lb_crc_init   <= 1'b0;
      lb_crc_en     <= 1'b0;
      lb_crc_byte   <= 8'h0;
      ram_we_o    <= 1'b0;
      ram_data_o  <= 8'h0;
    end else begin
      tint_o      <= 1'b0;
      babl_o      <= 1'b0;
      merr_o      <= 1'b0;
      ram_we_o    <= 1'b0;
      lb_wr_o     <= 1'b0;
      lb_crc_init <= 1'b0;
      lb_crc_en   <= 1'b0;

      if (stop_i || !txon_i) begin
        // A stop, or the transmitter being off, abandons everything in flight.
        // Nothing is written back: the descriptor stays owned by the chip,
        // which is what a driver re-initialising after a stop expects.
        state    <= S_IDLE;
        tx_go_o  <= 1'b0;
        idx      <= 7'd0;
        poll_cnt <= 32'h0;
        poll_due <= 1'b0;
        if (stop_i) begin
          fault_o       <= 1'b0;
          fault_pending <= 1'b0;
        end
      end else begin
        // The 1.6 ms poll.  TDMD short-circuits it, which is the whole point of
        // TDMD: "it merely hastens the C-LANCE's response to a Transmit
        // Descriptor Ring entry insertion by the host" (p. 22).
        if (tdmd_i) begin
          poll_due <= 1'b1;
          poll_cnt <= 32'h0;
        end else if (poll_cnt >= POLL_TICKS[31:0]) begin
          poll_due <= 1'b1;
          poll_cnt <= 32'h0;
        end else begin
          poll_cnt <= poll_cnt + 32'd1;
        end

        case (state)
          S_IDLE: begin
            if (poll_due) begin
              poll_due <= 1'b0;
              state    <= S_POLL;
            end
          end

          S_POLL: begin
            if (bus_err_i) begin
              merr_o  <= 1'b1;
              fault_o <= 1'b1;
              state   <= S_IDLE;
            end else if (bus_ack_i) begin
              tmd1_q <= rd16;
              if (!rd16[wish7990_pkg::T1_OWN]) begin
                state <= S_IDLE;              // the host still owns it
              end else if (!rd16[wish7990_pkg::T1_STP]) begin
                idx   <= idx_next;            // skipped, silently
                state <= S_POLL;
              end else begin
                tmd3_q      <= 16'h0000;
                staged      <= 12'h0;
                add_fcs_q   <= rd16[wish7990_pkg::T1_ADD_FCS];
                lb_overrun  <= 1'b0;
                lb_crc_init <= 1'b1;
                state       <= S_FETCH0;
              end
            end
          end

          S_FETCH0: begin
            if (bus_err_i) begin
              merr_o  <= 1'b1;
              fault_o <= 1'b1;
              state   <= S_IDLE;
            end else if (bus_ack_i) begin
              tmd0_q <= rd16;
              state  <= S_FETCH2;
            end
          end

          S_FETCH2: begin
            if (bus_err_i) begin
              merr_o  <= 1'b1;
              fault_o <= 1'b1;
              state   <= S_IDLE;
            end else if (bus_ack_i) begin
              buf_addr <= {tmd1_q[7:0], tmd0_q};
              // BCNT is a negative twelve-bit count: length = (~BCNT) + 1.
              // Zero means the full 4096, which twelve bits cannot hold.
              buf_left <= (~rd16[11:0]) + 12'd1;
              state    <= S_STAGE;
            end
          end

          S_STAGE: begin
            if (bus_err_i) begin
              merr_o  <= 1'b1;
              fault_o <= 1'b1;
              state   <= S_IDLE;
            end else if (bus_ack_i) begin
              word_q <= bus_rdata_i;
              lane   <= buf_addr[1:0];
              run    <= run_next;
              state  <= S_PUSH;
            end
          end

          S_PUSH: if (!(internal && lb_room && lb_full_i)) begin
            // Local change: a byte bound for a full loopback FIFO waits
            // (lb_full_i is the FIFO's almost-full, the writes being
            // registered) rather than being lost.
            // One byte a cycle into the staging RAM.  The bus is free while
            // this happens, which is the whole point: the receive engine gets
            // it instead of waiting a transaction per byte.
            ram_we_o    <= 1'b1;
            ram_data_o  <= word_q[8*lane_now +: 8];
            ram_waddr_q <= staged[10:0];
            if (internal && lb_room) begin
              // The same byte goes to the receive engine, through a FIFO in
              // this clock domain - so a looped frame never crosses a clock
              // boundary at all, let alone twice.
              lb_wr_o   <= 1'b1;
              lb_data_o   <= {4'h0, word_q[8*lane_now +: 8]};
              lb_crc_en   <= 1'b1;
              lb_crc_byte <= word_q[8*lane_now +: 8];
              if (lb_full_i) lb_overrun <= 1'b1;
            end else if (internal) begin
              // Past what the loopback path carries: the rest of the frame is
              // lost, and the receive side is told so.
              lb_overrun <= 1'b1;
            end
            staged      <= staged + 12'd1;
            buf_addr    <= buf_addr + 24'd1;
            lane        <= lane + 2'd1;
            run         <= run - 3'd1;
            if (buf_left == 12'd1) begin
              if (!enp) begin
                state <= S_LOOK;
              end else if (!internal) begin
                state <= S_SEND;
              end else if (coll_i) begin
                // p. 24: COLL "allows the collision logic to be tested.  The
                // C-LANCE must be in internal loopback mode for COLL to be
                // valid ... This will result in 16 total transmission attempts
                // with a retry error reported in TMD3."  Nothing comes back.
                tmd3_q <= tmd3_q | (16'b1 << wish7990_pkg::T3_RTRY);
                state  <= S_WB3;
              end else begin
                fcs_cnt <= 3'd0;
                state   <= tx_no_crc_o ? S_LB_END : S_LB_WAIT;
              end
            end else begin
              buf_left <= buf_left - 12'd1;
              if (run == 3'd1) state <= S_STAGE;
            end
          end

          S_LOOK: begin
            if (bus_err_i) begin
              merr_o  <= 1'b1;
              fault_o <= 1'b1;
              state   <= S_IDLE;
            end else if (bus_ack_i) begin
              next_tmd1_q <= rd16;
              if (!rd16[wish7990_pkg::T1_OWN]) begin
                // p. 30: BUFF "is set by the C-LANCE during transmission when
                // the C-LANCE does not find the ENP flag in the current buffer
                // and does not own the next buffer", and "If a Buffer Error
                // occurs, an Underflow Error will also occur".  The status
                // goes into *this* descriptor, which is exactly why the
                // lookahead happens before it is handed back.
                tmd3_q        <= tmd3_q | (16'b1 << wish7990_pkg::T3_BUFF)
                                        | (16'b1 << wish7990_pkg::T3_UFLO);
                fault_pending <= 1'b1;    // p. 30: the transmitter goes off
                state         <= S_WB3;
              end else begin
                state <= S_RELEASE;
              end
            end
          end

          S_RELEASE: begin
            if (bus_err_i) begin
              merr_o  <= 1'b1;
              fault_o <= 1'b1;
              state   <= S_IDLE;
            end else if (bus_ack_i) begin
              // The buffer is the host's again; carry on with the one the
              // lookahead already read the status word of.
              idx    <= idx_next;
              tmd1_q <= next_tmd1_q;
              state  <= S_FETCH0;
            end
          end

          S_SEND: begin
            if (!tx_go_o) begin
              tx_go_o <= 1'b1;
            end else if (tx_done_i) begin
              tx_go_o <= 1'b0;
              // Everything mii_tx reports, in one assignment each so that two
              // faults at once do not overwrite one another.
              if (tx_defer_i) tmd1_q[wish7990_pkg::T1_DEF] <= 1'b1;
              // p. 29: ONE is "not valid when LCOL is set", so the retry count
              // is only recorded for an attempt that actually got through.
              if (tx_ok_i && tx_ncoll_i == 4'd1)
                tmd1_q[wish7990_pkg::T1_ONE] <= 1'b1;
              if (tx_ok_i && tx_ncoll_i > 4'd1)
                tmd1_q[wish7990_pkg::T1_MORE] <= 1'b1;
              tmd3_q <= tmd3_q
                      | (tx_xcoll_i  ? (16'b1 << wish7990_pkg::T3_RTRY) : 16'h0)
                      | (tx_no_crs_i ? (16'b1 << wish7990_pkg::T3_LCAR) : 16'h0)
                      | (tx_late_i   ? (16'b1 << wish7990_pkg::T3_LCOL) : 16'h0);
              if (babbling) babl_o <= 1'b1;
              state <= S_WB3;
            end
          end

          S_LB_WAIT: begin
            // lb_crc_en is registered, so the last data byte only reaches the
            // CRC at the end of this cycle.  Emitting the FCS without waiting
            // would checksum every frame one byte short - which shows up as
            // three correct FCS bytes and one wrong one, and looks like
            // anything but a timing problem.
            state <= S_LB_FCS;
          end

          S_LB_FCS: if (!lb_full_i) begin
            // Least significant byte first, as it goes on the wire.
            lb_wr_o   <= 1'b1;
            lb_data_o <= {4'h0, lb_fcs[8*fcs_cnt[1:0] +: 8]};
            if (lb_full_i) lb_overrun <= 1'b1;
            if (fcs_cnt == 3'd3) state   <= S_LB_END;
            else                 fcs_cnt <= fcs_cnt + 3'd1;
          end

          S_LB_END: if (!lb_full_i) begin
            // One end word closes the frame.  An overrun on the way is what a
            // frame too long for the loopback path looks like from the receive
            // side, which is how the 8-32 byte limit makes itself felt.
            lb_wr_o   <= 1'b1;
            lb_data_o <= {1'b1, 1'b0, 1'b0, lb_overrun, 8'h00};
            state     <= S_WB3;
          end

          S_WB3: begin
            // p. 31: "TMD3 is updated only when there is an error".  A driver
            // that reads it unconditionally sees whatever it left there.
            if (tmd3_q == 16'h0000) begin
              state <= S_WB1;
            end else if (bus_err_i) begin
              merr_o  <= 1'b1;
              fault_o <= 1'b1;
              state   <= S_IDLE;
            end else if (bus_ack_i) begin
              state <= S_WB1;
            end
          end

          S_WB1: begin
            if (bus_err_i) begin
              merr_o  <= 1'b1;
              fault_o <= 1'b1;
              state   <= S_IDLE;
            end else if (bus_ack_i) begin
              // OWN cleared, and only then TINT.  Never the other way round.
              tint_o  <= 1'b1;
              // Now that the status has landed, the fault may take the
              // transmitter down.
              fault_o <= fault_pending;
              state   <= S_ADVANCE;
            end
          end

          S_ADVANCE: begin
            // p. 31: "The C-LANCE tries to own the next buffer ... immediately
            // after it relinquishes the last buffer of the current packet.
            // This guarantees the back-to-back transmission of the packets."
            idx      <= idx_next;
            poll_due <= 1'b1;
            state    <= S_IDLE;
          end

          default: state <= S_IDLE;
        endcase
      end
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, 1'b0};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
