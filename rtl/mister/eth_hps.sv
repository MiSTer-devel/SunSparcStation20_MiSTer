// SPDX-License-Identifier: GPL-2.0-or-later
//
// eth_hps: the LANCE's MAC, bridged to Main through a frame mailbox in DDR3.
// The mailbox protocol is SSETH002 (an 8-slot TX ring, a 16-slot RX ring).
//
// The LANCE (phase 8) keeps its descriptor rings and its DMA through the
// IOMMU; this is the "wire" behind it. Frames go to Main (support/sun,
// sun_enet.cpp) and come back from it through a mailbox in the DDR3 at ARM
// physical address 0x1FF0_0000, outside the core's memory (the A2065 and the
// NeXT core use the same window; one core runs at a time). Main moves the
// frames to a raw socket, a macvlan or a tap interface.
//
// The mailbox, 64-bit little-endian words (frame byte i is byte lane i mod 8
// of word 1 + i / 8 of its slot):
//   +0x0000 MAGIC   "SSETH002", written last at start-up; it gives Main the
//           RX ring's depth ("SSETH001" was the 8-slot RX ring)
//   +0x0008 GEN     a new value at every start-up (Main resynchronises)
//   +0x0010 TX_WPTR ours: frames posted
//   +0x0018 TX_RPTR Main's: frames taken
//   +0x0020 RX_WPTR Main's: frames posted
//   +0x0028 RX_RPTR ours: frames taken
//   +0x0030 MAC     ours: bit 63 valid, 47:40 the first byte ... 7:0 the last
//   +0x1000 TX ring, TX_RING (8) slots of 2048 bytes: header (10:0 length),
//           frame
//   +0x5000 RX ring, RX_RING (16) slots of 2048 bytes, to +0xD000: header
//           (10:0 length with the 4-byte FCS Main appends, 21:16 the LADRF
//           index of the destination address, which Main computes), frame
// Pointers are free-running counts (32 bits used); slot = count mod ring.
//
// Transmit: the LANCE pushes the frame 16 bits at a time (the first push
// with tx_stp), one or both bytes of each (tx_be: a buffer may start or end
// on an odd byte, so a frame in several buffers needs byte granularity);
// tx_busy from the first push until the frame is in the mailbox stops it
// from starting another. A frame is complete when its bytes reach tx_len
// with tx_enp. While the TX ring is full the LANCE waits (busy), as on a busy
// wire; TX_RPTR is read again every 64 cycles, and the frame is dropped when
// Main has taken nothing for TXWAIT (50 ms: it is not running), when the
// network is off, or when it is longer than a slot (2040 bytes) or shorter
// than 14.
// Receive: with the buffer empty and the wire idle, RX_WPTR is polled every
// POLL cycles. A frame takes its wire time at 10 Mb/s (its bytes, FCS
// included, plus 8 of preamble and 12 of gap, 0.8 us each) before the next
// is offered: a host hands over a datagram's fragments together, and a
// guest's LANCE ring (NetBSD's le on ledma: 8 descriptors) misses frames
// offered faster than its interrupt handler can recycle them (C3). A frame
// is read into the buffer, and kept if its destination is ours: the PADR,
// broadcast, a multicast group set in the LADRF, or anything in promiscuous
// mode. A frame shorter than 18 or longer than RXMAX (1522, FCS and a VLAN
// tag included: the guests' buffers are 1536 bytes, LAN-2) is skipped. The
// whole frame is then offered to the LANCE: rx_fifordy while words remain,
// rx_deof with the last. No eof pulse: the LANCE latches eof until it pops
// the last word, so a frame offered and then withdrawn would leave it set;
// a frame it never takes (receiver off) is dropped after STALE (200 ms), or
// at rx_clr (the LANCE's INIT/STOP).
// Loopback (rx_lpbk, MODE LOOP, which the Sun PROM's le driver tests at
// open): the transmitted frame comes back as a received one at once,
// through the filter (PADR, any multicast or broadcast, promiscuous), with
// the 4 FCS bytes counted; nothing goes to the mailbox, and the network is
// not polled meanwhile.
//
// The LANCE side (plain ports):
//  TX (mac_emi_w/r):
//   tx_push   a 16-bit word this cycle; always taken unless a frame is
//             complete and waiting (tx_busy covers that: the LANCE starts a
//             new frame only when !tx_busy, and continues a chained one)
//   tx_stp    with tx_push: the first word of a frame (restarts the count)
//   tx_be     [1] tx_d[15:8] is a byte, [0] tx_d[7:0] is a byte; [15:8] is
//             the earlier byte on the wire
//   tx_enp    level: the current buffer is the frame's last
//   tx_len    level: the frame's length in bytes so far (cumulative over a
//             chain); complete when the bytes pushed reach it with tx_enp
//   tx_crcgen level: 1 = the FCS is to be generated (Main appends it); 0 =
//             the frame's last 4 bytes are the driver's FCS: not sent
//   tx_clr    the LANCE's INIT/STOP: forget the frame in progress
//   tx_fifordy always 1;  tx_busy as above
//  RX (mac_rec_w/r):
//   rx_fifordy a frame is offered and words remain; rx_d is the head word,
//             valid whenever rx_fifordy (first byte in [15:8])
//   rx_pop    take the head word (ignored without rx_fifordy)
//   rx_deof   rx_d is the frame's last word (odd lengths: [7:0] is padding)
//   rx_len    the offered frame's length in bytes, FCS included
//   rx_crcok  always 1 (Main checks nothing; the host NIC did); rx_eof 0
//   rx_clr    drop an offered frame and its wire time (INIT/STOP)
//  Mode (mac_rec_w): rx_lpbk MODE LOOP; rx_prom MODE PROM; rx_padr the
//   station address, [7:0] the first byte on the wire (the init block's
//   words are byte-swapped on a big-endian Sun, as every sun4m driver
//   writes them); rx_ladrf the logical address filter, bit n = hash n.
//   The PADR is published in the mailbox's MAC word whenever it changes
//   (bit 63 clear while it is 0).
//
// The DDR side: an Avalon-MM master, single 64-bit beats (burstcount 1, all
// byte enables), one access at a time; avl_address is the DDR word address
// (ARM physical / 8: 0x03FE_0000 + word). It is one master of ddram_arb.
// `ena` is the OSD's Network not Off: off, frames are dropped and RX_WPTR is
// not polled (the mailbox is still initialised and the MAC published).
// `rst` is synchronous; a reset starts the mailbox again (a new GEN).
//
// rx_d is valid in the first cycle of rx_fifordy; a looped-back frame
// longer than a slot is dropped like a transmitted one.

module eth_hps #(
  parameter int CLK_HZ = 55_000_000,
  parameter bit SIMU   = 1'b0          // 1: short timers (benches, sim/)
)(
  input  logic        clk,
  input  logic        rst,

  input  logic        ena,             // the OSD's Network is not Off

  // The LANCE: transmit
  input  logic        tx_push,
  input  logic        tx_stp,
  input  logic [1:0]  tx_be,
  input  logic [15:0] tx_d,
  input  logic        tx_enp,
  input  logic [11:0] tx_len,
  input  logic        tx_crcgen,
  input  logic        tx_clr,
  output logic        tx_fifordy,
  output logic        tx_busy,

  // The LANCE: receive
  input  logic        rx_pop,
  input  logic        rx_clr,
  output logic [15:0] rx_d,
  output logic        rx_deof,
  output logic        rx_fifordy,
  output logic [11:0] rx_len,
  output logic        rx_crcok,
  output logic        rx_eof,

  // The LANCE: mode
  input  logic        rx_lpbk,
  input  logic        rx_prom,
  input  logic [47:0] rx_padr,
  input  logic [63:0] rx_ladrf,

  // Avalon-MM master on the DDR3: single beats, one at a time
  input  logic        avl_waitrequest,
  output logic [28:0] avl_address,
  output logic        avl_read,
  output logic        avl_write,
  output logic [63:0] avl_writedata,
  output logic [7:0]  avl_byteenable,
  output logic [7:0]  avl_burstcount,
  input  logic [63:0] avl_readdata,
  input  logic        avl_readdatavalid
);

  // The mailbox, in 64-bit words
  localparam logic [28:0] BASE    = 29'(32'h1FF0_0000 / 8);
  localparam logic [28:0] W_MAGIC = 29'd0;
  localparam logic [28:0] W_GEN   = 29'd1;
  localparam logic [28:0] W_TXW   = 29'd2;
  localparam logic [28:0] W_TXR   = 29'd3;
  localparam logic [28:0] W_RXW   = 29'd4;
  localparam logic [28:0] W_RXR   = 29'd5;
  localparam logic [28:0] W_MAC   = 29'd6;
  localparam logic [28:0] W_TX    = 29'h200;                    // +0x1000
  localparam logic [28:0] W_RX    = 29'hA00;                    // +0x5000
  localparam logic [63:0] MAGIC   = 64'h5353_4554_4830_3032;   // "SSETH002"
  localparam int          TX_RING = 8;                         // tx_wptr[2:0] is the slot
  // 16: a host hands over a datagram's fragments together (8 KB: 6, 16 KB: 11)
  localparam int          RX_RING = 16;                        // rx_rptr[3:0] is the slot
  localparam int          MAXLEN  = 2048 - 8;                  // a slot's frame bytes
  localparam int          RXMAX   = 1522;

  localparam int POLL    = SIMU ? 200    : 1024;
  localparam int STALE   = SIMU ? 20_000 : CLK_HZ / 5;
  localparam int TXWAIT  = SIMU ? 20_000 : CLK_HZ / 20;
  localparam int BYTECYC = CLK_HZ / 1_250_000;                 // a byte at 10 Mb/s
  localparam int STW = $clog2(STALE + 1);
  localparam int TWW = $clog2(TXWAIT + 1);
  localparam int BCW = (BYTECYC > 1) ? $clog2(BYTECYC) : 1;
  localparam int PLW = $clog2(POLL + 1);

  // ------------------------------------------------------------- buffers --
  // 256 words of 64 bits each (2 KB), one write and one registered read port
  logic [63:0] txbuf [256];
  logic [63:0] rxbuf [256];
  logic [63:0] txbuf_q, rxbuf_q;
  logic [7:0]  txbuf_ra, txbuf_wa, rxbuf_ra, rxbuf_wa;
  logic        txbuf_wr, rxbuf_wr;
  logic [63:0] txbuf_d, rxbuf_d;

  always_ff @(posedge clk) begin
    if (txbuf_wr) txbuf[txbuf_wa] <= txbuf_d;
    txbuf_q <= txbuf[txbuf_ra];
  end

  always_ff @(posedge clk) begin
    if (rxbuf_wr) rxbuf[rxbuf_wa] <= rxbuf_d;
    rxbuf_q <= rxbuf[rxbuf_ra];
  end

  // ------------------------------------------------------------ transmit --
  logic [63:0] tx_acc;          // the word being filled
  logic [11:0] tx_cnt;          // bytes received
  logic        tx_over;         // longer than a slot
  logic        tx_done;         // complete, to be posted
  logic [11:0] tx_flen;         // its length, the driver's FCS removed
  logic        tx_flush;        // the last partial word
  logic        tx_posted;       // the mailbox FSM has finished with it

  always_ff @(posedge clk) begin : tx_in
    logic [11:0] cnt_v;
    logic [63:0] acc_v;
    tx_flush <= 1'b0;
    txbuf_wr <= 1'b0;
    if (tx_push && !tx_done) begin
      if (tx_stp) begin
        cnt_v   = '0;
        acc_v   = '0;
        tx_over <= 1'b0;
      end else begin
        cnt_v = tx_cnt;
        acc_v = tx_acc;
      end
      tx_busy <= 1'b1;
      // up to two bytes, tx_d[15:8] first; frame byte i is byte i mod 8 of
      // its 64-bit word. Two bytes complete at most one word.
      for (int j = 1; j >= 0; j--) begin
        if (tx_be[j]) begin
          acc_v[{cnt_v[2:0], 3'b000} +: 8] = tx_d[8 * j +: 8];
          if (cnt_v[2:0] == 3'd7) begin
            if (cnt_v[11:3] < 9'(MAXLEN / 8)) begin
              txbuf_wr <= 1'b1;
              txbuf_wa <= cnt_v[10:3];
              txbuf_d  <= acc_v;
            end else begin
              tx_over <= 1'b1;
            end
            acc_v = '0;
          end
          cnt_v = cnt_v + 1'b1;
        end
      end
      tx_acc <= acc_v;
      tx_cnt <= cnt_v;
    end

    // Complete: its bytes reached the length of its last buffer
    if (tx_busy && !tx_done && !tx_push && tx_enp && tx_cnt >= tx_len && tx_len != 12'd0) begin
      tx_done  <= 1'b1;
      tx_flush <= 1'b1;
      tx_flen  <= tx_crcgen ? tx_len : tx_len - 12'd4;   // the FCS came with the frame
    end
    if (tx_flush && tx_cnt[2:0] != 3'd0 && tx_cnt[11:3] < 9'(MAXLEN / 8)) begin
      txbuf_wr <= 1'b1;
      txbuf_wa <= tx_cnt[10:3];
      txbuf_d  <= tx_acc;
    end

    if (tx_posted || tx_clr) begin
      tx_busy <= 1'b0;
      tx_done <= 1'b0;
    end
    if (rst) begin
      tx_busy <= 1'b0;
      tx_done <= 1'b0;
      tx_cnt  <= '0;
      tx_over <= 1'b0;
    end
  end

  assign tx_fifordy = 1'b1;

  // ------------------------------------------------------------- receive --
  logic           rx_full;      // a frame is offered
  logic [9:0]     rx_head;      // the next 16-bit word
  logic [9:0]     rx_next;      // rx_head after this cycle
  logic [9:0]     rx_last;
  logic [1:0]     rx_sel;       // rxbuf_q's 16-bit lane
  logic           rx_popped;
  logic [STW-1:0] rx_stale;
  logic           rx_load;      // the FSM offers a frame
  logic [11:0]    rx_ldlen;
  logic [11:0]    wire_byt;     // wire time left, in bytes
  logic [BCW-1:0] wire_pre;

  // rxbuf_ra follows the head, one ahead on a pop, so rxbuf_q is always the
  // head's word; at an offer it starts at word 0.
  assign rx_next  = (rx_full && rx_pop) ? rx_head + 10'd1 : rx_head;
  assign rxbuf_ra = rx_load ? 8'd0 : rx_next[9:2];

  always_ff @(posedge clk) begin
    if (rx_full && rx_pop) begin
      rx_popped <= 1'b1;
      if (rx_head == rx_last) rx_full <= 1'b0;
    end
    rx_head <= rx_next;
    rx_sel  <= rx_next[1:0];

    if (rx_full && !rx_popped) begin
      if (rx_stale == STW'(STALE)) rx_full <= 1'b0;   // the receiver is off
      else                         rx_stale <= rx_stale + 1'b1;
    end

    // The wire time of the frame offered
    if (wire_byt != 12'd0) begin
      if (wire_pre == BCW'(BYTECYC - 1)) begin
        wire_pre <= '0;
        wire_byt <= wire_byt - 1'b1;
      end else begin
        wire_pre <= wire_pre + 1'b1;
      end
    end

    if (rx_load) begin
      wire_byt  <= rx_ldlen + 12'd20;
      wire_pre  <= '0;
      rx_full   <= 1'b1;
      rx_popped <= 1'b0;
      rx_stale  <= '0;
      rx_head   <= '0;
      rx_sel    <= 2'd0;
      rx_len    <= rx_ldlen;
      rx_last   <= 10'((rx_ldlen + 12'd1) / 12'd2 - 12'd1);
    end
    if (rx_clr || rst) begin
      rx_full  <= 1'b0;
      wire_byt <= '0;
    end
  end

  // A 16-bit LANCE word (first byte in 15:8) from byte lanes 2l, 2l+1
  always_comb begin
    case (rx_sel)
      2'd0:    rx_d = {rxbuf_q[7:0],   rxbuf_q[15:8]};
      2'd1:    rx_d = {rxbuf_q[23:16], rxbuf_q[31:24]};
      2'd2:    rx_d = {rxbuf_q[39:32], rxbuf_q[47:40]};
      default: rx_d = {rxbuf_q[55:48], rxbuf_q[63:56]};
    endcase
  end
  assign rx_deof    = rx_full & (rx_head == rx_last);
  assign rx_fifordy = rx_full;
  assign rx_crcok   = 1'b1;
  assign rx_eof     = 1'b0;

  // ------------------------------------------------------------- mailbox --
  typedef enum logic [3:0] {
    S_INIT, S_IDLE,
    S_TX_RPTR, S_TX_FETCH, S_TX_DATA, S_TX_WPTR,
    S_RX_WPTR, S_RX_HDR, S_RX_DATA, S_RX_RPTR, S_RX_OFFER,
    S_LOOP_RD, S_LOOP_WR, S_MAC
  } state_t;

  state_t         state;
  logic [3:0]     step;
  logic           acc_rd, acc_wr;
  logic           acc_wait;     // a read waits for its data
  logic [28:0]    acc_a;
  logic [63:0]    acc_d;
  logic [31:0]    gen;
  logic [31:0]    tx_wptr, rx_rptr;
  logic [8:0]     k, nwords;
  logic [PLW-1:0] poll_cpt;
  logic [TWW-1:0] txw_cpt;      // the frame has waited
  logic [5:0]     tx_retry;     // the next TX_RPTR read
  logic [47:0]    mac_pub;
  logic           mac_ok;
  logic [5:0]     rx_hash;
  logic           rx_keep;
  logic [11:0]    rx_flen;

  assign avl_address    = acc_a;
  assign avl_read       = acc_rd;
  assign avl_write      = acc_wr;
  assign avl_writedata  = acc_d;
  assign avl_byteenable = 8'hFF;
  assign avl_burstcount = 8'd1;

  // A slot's first word (its header)
  logic [28:0] tx_slot, rx_slot;
  assign tx_slot = BASE + W_TX + {18'd0, tx_wptr[2:0], 8'd0};
  assign rx_slot = BASE + W_RX + {17'd0, rx_rptr[3:0], 8'd0};

  always_ff @(posedge clk) begin : mbox
    logic [47:0] dst_v;
    logic [63:0] q_v;
    gen <= gen + 1'b1;
    if (tx_done && !tx_posted) begin
      if (txw_cpt != TWW'(TXWAIT)) txw_cpt <= txw_cpt + 1'b1;
    end else begin
      txw_cpt <= '0;
    end
    tx_posted <= 1'b0;
    rx_load   <= 1'b0;
    rxbuf_wr  <= 1'b0;

    // The access in flight: the command until accepted, then a read's data
    if ((acc_rd || acc_wr) && !avl_waitrequest) begin
      acc_rd <= 1'b0;
      acc_wr <= 1'b0;
    end
    if (acc_wait && avl_readdatavalid) acc_wait <= 1'b0;
    q_v = avl_readdata;

    if (!acc_rd && !acc_wr && (!acc_wait || avl_readdatavalid)) begin
      case (state)
        // Zero the header words, then the magic
        S_INIT: begin
          acc_wr <= 1'b1;
          acc_d  <= '0;
          acc_a  <= BASE + 29'(step);
          if (29'(step) == W_GEN) acc_d <= {32'd0, gen};
          if (step == 4'd7) begin
            acc_a <= BASE + W_MAGIC;
            acc_d <= MAGIC;
            state <= S_IDLE;
          end
          step    <= step + 1'b1;
          tx_wptr <= '0;
          rx_rptr <= '0;
          mac_ok  <= 1'b0;
        end

        S_IDLE: begin
          if (poll_cpt != PLW'(POLL)) poll_cpt <= poll_cpt + 1'b1;
          if (tx_retry != 6'd0) tx_retry <= tx_retry - 1'b1;
          if (tx_done && !tx_posted && rx_lpbk) begin
            if (tx_over || tx_flen < 12'd14 || tx_flen > 12'(MAXLEN)) begin
              tx_posted <= 1'b1;                    // dropped
            end else if (!rx_full) begin
              k        <= '0;
              nwords   <= 9'((tx_flen + 12'd11) / 12'd8);   // the frame + the FCS
              txbuf_ra <= '0;
              rx_keep  <= 1'b0;
              state    <= S_LOOP_RD;
            end                                     // else: once the LANCE took the last
          end else if (tx_done && !tx_posted && tx_retry == 6'd0) begin
            if (ena && !tx_over && tx_flen >= 12'd14 && tx_flen <= 12'(MAXLEN)) begin
              acc_rd   <= 1'b1;
              acc_wait <= 1'b1;
              acc_a    <= BASE + W_TXR;
              state    <= S_TX_RPTR;
            end else begin
              tx_posted <= 1'b1;                    // dropped
            end
          end else if (!mac_ok || mac_pub != rx_padr) begin
            state <= S_MAC;
          end else if (!rx_full && wire_byt == 12'd0 && ena && poll_cpt == PLW'(POLL) && !rx_lpbk) begin
            poll_cpt <= '0;
            acc_rd   <= 1'b1;
            acc_wait <= 1'b1;
            acc_a    <= BASE + W_RXW;
            state    <= S_RX_WPTR;
          end
        end

        // ---- transmit
        S_TX_RPTR: begin
          if (tx_wptr - q_v[31:0] < 32'(TX_RING)) begin
            acc_wr   <= 1'b1;                       // the header: the length
            acc_a    <= tx_slot;
            acc_d    <= {52'd0, tx_flen};
            k        <= '0;
            nwords   <= 9'((tx_flen + 12'd7) / 12'd8);
            txbuf_ra <= '0;
            state    <= S_TX_FETCH;
          end else if (txw_cpt == TWW'(TXWAIT)) begin
            tx_posted <= 1'b1;                      // Main takes nothing: dropped
            state     <= S_IDLE;
          end else begin
            tx_retry <= 6'd63;                      // full: the LANCE waits; again soon
            state    <= S_IDLE;
          end
        end

        S_TX_FETCH: state <= S_TX_DATA;             // txbuf_q is txbuf[k] from this cycle

        S_TX_DATA: begin
          if (k == nwords) begin
            tx_wptr <= tx_wptr + 1'b1;
            acc_wr  <= 1'b1;
            acc_a   <= BASE + W_TXW;
            acc_d   <= {32'd0, tx_wptr + 32'd1};
            state   <= S_TX_WPTR;
          end else begin
            acc_wr   <= 1'b1;
            acc_a    <= tx_slot + 29'(k) + 29'd1;
            acc_d    <= txbuf_q;
            k        <= k + 1'b1;
            txbuf_ra <= k[7:0] + 8'd1;
            state    <= S_TX_FETCH;
          end
        end

        S_TX_WPTR: begin
          tx_posted <= 1'b1;
          state     <= S_IDLE;
        end

        // ---- receive
        S_RX_WPTR: begin
          if (q_v[31:0] != rx_rptr) begin
            acc_rd   <= 1'b1;
            acc_wait <= 1'b1;
            acc_a    <= rx_slot;
            state    <= S_RX_HDR;
          end else begin
            state <= S_IDLE;
          end
        end

        S_RX_HDR: begin
          rx_flen <= q_v[11:0];
          rx_hash <= q_v[21:16];
          rx_keep <= 1'b0;
          if (q_v[11:0] >= 12'd18 && q_v[11:0] <= 12'(RXMAX)) begin
            k        <= '0;
            nwords   <= 9'((q_v[11:0] + 12'd7) / 12'd8);
            acc_rd   <= 1'b1;
            acc_wait <= 1'b1;
            acc_a    <= rx_slot + 29'd1;
            state    <= S_RX_DATA;
          end else begin
            state <= S_RX_RPTR;                     // a bad length: skipped
          end
        end

        S_RX_DATA: begin
          rxbuf_wr <= 1'b1;
          rxbuf_wa <= k[7:0];
          rxbuf_d  <= q_v;
          if (k == 9'd0) begin
            // The destination address: ours?
            dst_v = q_v[47:0];
            if (rx_prom || dst_v == rx_padr || dst_v == 48'hFFFF_FFFF_FFFF ||
                (dst_v[0] && rx_ladrf[rx_hash]))
              rx_keep <= 1'b1;
          end
          k <= k + 1'b1;
          if (k + 9'd1 == nwords) begin
            state <= S_RX_RPTR;
          end else begin
            acc_rd   <= 1'b1;
            acc_wait <= 1'b1;
            acc_a    <= rx_slot + 29'(k) + 29'd2;
          end
        end

        S_RX_RPTR: begin
          rx_rptr <= rx_rptr + 1'b1;
          acc_wr  <= 1'b1;
          acc_a   <= BASE + W_RXR;
          acc_d   <= {32'd0, rx_rptr + 32'd1};
          state   <= S_RX_OFFER;
        end

        S_RX_OFFER: begin
          if (rx_keep && !rx_clr) begin
            rx_load  <= 1'b1;
            rx_ldlen <= rx_flen;
          end
          state <= S_IDLE;
        end

        // ---- loopback: txbuf to rxbuf, then offered
        S_LOOP_RD: state <= S_LOOP_WR;              // txbuf_q: txbuf[k] next cycle

        S_LOOP_WR: begin
          rxbuf_wr <= 1'b1;
          rxbuf_wa <= k[7:0];
          rxbuf_d  <= txbuf_q;
          if (k == 9'd0) begin
            dst_v = txbuf_q[47:0];
            if (rx_prom || dst_v == rx_padr || dst_v[0])
              rx_keep <= 1'b1;                      // ours, broadcast, multicast
          end
          k        <= k + 1'b1;
          txbuf_ra <= k[7:0] + 8'd1;
          if (k + 9'd1 == nwords) begin
            rx_flen   <= tx_flen + 12'd4;
            tx_posted <= 1'b1;
            state     <= S_RX_OFFER;
          end else begin
            state <= S_LOOP_RD;
          end
        end

        S_MAC: begin
          mac_pub <= rx_padr;
          mac_ok  <= 1'b1;
          acc_wr  <= 1'b1;
          acc_a   <= BASE + W_MAC;
          acc_d   <= '0;
          if (rx_padr != 48'd0)
            acc_d <= {1'b1, 15'd0, rx_padr[7:0], rx_padr[15:8], rx_padr[23:16],
                      rx_padr[31:24], rx_padr[39:32], rx_padr[47:40]};
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end

    if (rst) begin
      state    <= S_INIT;
      step     <= 4'd0;
      acc_rd   <= 1'b0;
      acc_wr   <= 1'b0;
      acc_wait <= 1'b0;
      poll_cpt <= '0;
      tx_retry <= 6'd0;
      mac_ok   <= 1'b0;
    end
  end

endmodule
