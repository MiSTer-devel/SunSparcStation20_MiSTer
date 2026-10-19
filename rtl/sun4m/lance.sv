// SPDX-License-Identifier: GPL-2.0-or-later
//
// lance: the SS20's on-board Ethernet, the Am7990 LANCE in the MACIO (the
// NCR92C990 core), at SBus slot F offset 0x00C0_0000 (pa 0xE_F0C0_0000),
// with its wire: eth_hps, the frame mailbox to Main in DDR3.
//
// From: the Am79C90 C-LANCE data sheet and the Am7990 technical manual
//   (scratch/reference/ethernet: CSR0-3, the init block, the rings, MODE);
//   QEMU hw/net/pcnet.c + hw/dma/sparc32_dma.c (ledma_memory_read/write:
//   "on sparc, the lance 16 bit bus is swapped") and MAME am79c90.cpp
//   (dma_in/dma_out) for the Sun's byte lanes and CSR3.BSWP; NetBSD
//   dev/ic/am7990.c, lance.c, Linux sunlance.c for what drivers expect;
//   docs/rom-disassembly/ss20-obp-2.25/post-tests.md (the OBP's loopback
//   test, CSR3 = ACON|BCON, no BSWP); tests/cpu/src/ethtest.S.
//
// Structure: Wish7990's register file and engines (MIT, vendored as
// rtl/sun4m/wish7990_*.sv: le_regs, le_init, le_tx, le_rx with le_filt,
// wb_arb) with their PHY side replaced. Wrapping them was less work than a
// new LANCE: the CSR0 rules, the ring polling, chaining at any byte, the
// write-back order drivers rely on and the internal loopback are done and
// were run against SunOS 4 and NetBSD on the Sun-3 core. What is ours:
//  - the iobus slave (RDP/RAP on a 32-bit big-endian bus);
//  - the memory port: Wish7990's (size, sel, 24-bit address) requests as
//    single DVMA beats, with the Sun's byte lanes (below);
//  - tx pump: the frame le_tx staged in its RAM pushed into eth_hps 16 bits
//    at a time (le_tx's four-phase go/done, which mii_tx answered);
//  - rx feed: eth_hps's offered frame as the byte stream mii_rx produced
//    ({end, err[2:0], data[7:0]} words, one end word per frame);
//  - eth_hps inside, so the integrator wires one block: its Avalon master
//    to ddram_arb and `ena` from the OSD.
//
// Byte lanes. The LANCE is a little-endian 16-bit device: its byte address
// L is D7:0 of the word at L & ~1 when L is even. The Sun wires D15:8 to
// the lower address, so the LANCE's byte L is memory byte L ^ 1, and a
// 16-bit word (descriptor, init block) is a big-endian halfword in memory:
// a driver writes it with a plain sth. CSR3.BSWP swaps the bytes of frame
// data only (le_tx/le_rx flip address bit 0), so with BSWP = 1 a frame is
// in memory in wire order: what every OS driver sets (NetBSD, Linux,
// Solaris: BSWP|ACON|BCON). The OBP's POST loopback test runs with BSWP = 0
// and an init block PADR of 0x0200: the frame's "02 00" in memory goes out
// as "00 02" and matches, as on QEMU (ledma swaps) and the real chip. In
// Wish7990's 32-bit little-endian view (lane k = LANCE byte W + k), lane k
// is memory byte W + (k ^ 1): a 32-bit big-endian word is the halfword
// swap of Wish7990's, and a 16-bit field the natural big-endian halfword.
//
// MODE LOOP: internal loopback (LOOP|INTL) is Wish7990's own path, which
// computes the FCS and never touches the wire; its length limit is raised
// from the chip's 32 bytes (ethtest loops 70). External loopback (LOOP
// alone) goes to eth_hps's rx_lpbk: the frame comes back without reaching
// the mailbox, as through a loopback connector (the FCS bytes are not
// computed there: whatever was in eth_hps's buffer).
//
// Oversize: eth_hps drops a received frame over 1522 bytes before the
// LANCE sees it (LAN-2: no RINT, no MISS) and a transmitted one over 2040;
// le_tx sets BABL over 1518. A frame longer than its RX buffer chains into
// the next descriptor (or ends with BUFF), as on the chip.
//
// iobus slave (addr = offset from 0xE_F0C0_0000; only bit 1 decodes, the
// rest alias): RDP at +0 (data[31:16], be[3:2]), RAP at +2 (data[15:0],
// be[1:0]). A 32-bit access does RDP then RAP; a read has no side effects.
// The answer takes 2-3 cycles.
//
// DVMA master (mem_o/mem_i, sbus_pkg protocol): single beats only (no
// bursts), one at a time; va[23:0] is the LANCE's 24-bit address, va[31:24]
// is 0 (DMA2's ledma supplies E_BASE). `err` on a beat sets MERR and stops
// the engine that made it (TXON/RXON off), as a memory time-out would.
//
// le_reset is the LANCE's RESET pin (DMA2 E_CSR bit 7, level): it stops
// the chip and clears RAP, CSR3 and the status bits, as STOP does.
// irq_o is the INTR pin, active high: CSR0.INTR and INEA.

module lance
  import iobus_pkg::*;
#(
  parameter int CLK_HZ       = 55_000_000,
  parameter bit SIMU         = 1'b0,                    // eth_hps's short timers
  parameter int POLL_TICKS   = CLK_HZ / 625,            // 1.6 ms: the ring poll
  parameter bit IGNORE_BSWP  = 1'b0                     // 1: frame data always as BSWP = 1
)(
  input  logic                clk,
  input  logic                rst,

  input  iob_req_t            bus_i,
  output iob_rsp_t            bus_o,

  input  logic                le_reset,
  output logic                irq_o,

  output sbus_pkg::dvma_req_t mem_o,
  input  mem_pkg::mem_rsp_t   mem_i,

  input  logic                ena,                     // the OSD's Network is not Off

  // eth_hps's Avalon-MM master to the DDR3 (a ddram_arb port)
  input  logic                avl_waitrequest,
  output logic [28:0]         avl_address,
  output logic                avl_read,
  output logic                avl_write,
  output logic [63:0]         avl_writedata,
  output logic [7:0]          avl_byteenable,
  output logic [7:0]          avl_burstcount,
  input  logic [63:0]         avl_readdata,
  input  logic                avl_readdatavalid
);

  localparam logic [1:0] SZ_BYTE = wish7990_pkg::BUS_SZ_BYTE;
  localparam logic [1:0] SZ_HALF = wish7990_pkg::BUS_SZ_HALF;

  // ------------------------------------------------------- iobus slave --
  // Two le_regs accesses at most (RDP, then RAP), then the ack.
  logic        r_cs, r_adr, r_we;
  logic [15:0] r_wdata, r_rdata;
  logic [1:0]  r_step;          // 0: RDP, 1: RAP, 2: ack
  logic [15:0] r_hi, r_lo;

  wire want_hi = |bus_i.be[3:2];
  wire want_lo = |bus_i.be[1:0];

  always_comb begin
    r_cs    = bus_i.req && !bus_o.ack && ((r_step == 2'd0 && want_hi) || (r_step == 2'd1 && want_lo));
    r_adr   = (r_step == 2'd1);
    r_we    = bus_i.we;
    r_wdata = r_adr ? bus_i.wdata[15:0] : bus_i.wdata[31:16];
  end

  always_ff @(posedge clk) begin
    bus_o.ack <= 1'b0;
    bus_o.err <= 1'b0;
    if (rst) begin
      r_step      <= 2'd0;
      bus_o.rdata <= '0;
    end else if (bus_i.req && !bus_o.ack) begin
      case (r_step)
        2'd0: begin
          r_hi   <= want_hi ? r_rdata : 16'h0;
          r_step <= 2'd1;
        end
        2'd1: begin
          r_lo   <= want_lo ? r_rdata : 16'h0;
          r_step <= 2'd2;
        end
        default: begin
          bus_o.ack   <= 1'b1;
          bus_o.rdata <= {r_hi, r_lo};
          r_step      <= 2'd0;
        end
      endcase
    end
  end

  // ------------------------------------------------- the register file --
  logic [23:0] iadr;
  logic        bswp_reg, bswp, init_pulse, strt, stop, tdmd;
  logic        idon, merr_init, rxon, txon;
  logic        rint, miss, merr_rx, rx_fault;
  logic        tint, babl, merr_tx, tx_fault;
  logic        inea_unused, acon_unused, bcon_unused, ready_unused;

  wish7990_le_regs u_regs (
    .clk, .rst,
    .reset_i    (le_reset),
    .cs_i       (r_cs),
    .adr_i      (r_adr),
    .we_i       (r_we),
    .wdata_i    (r_wdata),
    .rdata_o    (r_rdata),
    .ready_o    (ready_unused),
    .intr_o     (irq_o),
    .iadr_o     (iadr),
    .bswp_o     (bswp_reg),
    .acon_o     (acon_unused),
    .bcon_o     (bcon_unused),
    .init_o     (init_pulse),
    .strt_o     (strt),
    .stop_o     (stop),
    .tdmd_o     (tdmd),
    .inea_o     (inea_unused),
    .idon_set_i (idon),
    .rint_set_i (rint),
    .tint_set_i (tint),
    .babl_set_i (babl),
    .cerr_set_i (1'b0),         // no heartbeat on this wire
    .miss_set_i (miss),
    .merr_set_i (merr_init | merr_tx | merr_rx),
    .rxon_i     (rxon),
    .txon_i     (txon)
  );

  assign bswp = IGNORE_BSWP ? 1'b1 : bswp_reg;

  // ------------------------------------------------------- init block --
  logic [15:0] mode;
  logic [47:0] padr;
  logic [63:0] ladrf;
  logic [23:0] rdra, tdra;
  logic [2:0]  rlen, tlen;
  logic        ib_ready;

  logic        p0_req, p0_we, p0_ack, p0_err;
  logic [1:0]  p0_size;
  logic [3:0]  p0_sel;
  logic [23:0] p0_addr;
  logic [31:0] p0_wdata;
  logic [31:0] bus_rdata;

  wish7990_le_init u_init (
    .clk, .rst,
    .stop_i      (stop),
    .strt_i      (strt),
    .init_i      (init_pulse),
    .iadr_i      (iadr),
    .idon_o      (idon),
    .merr_o      (merr_init),
    .rxon_o      (rxon),
    .txon_o      (txon),
    .mode_o      (mode),
    .padr_o      (padr),
    .ladrf_o     (ladrf),
    .rdra_o      (rdra),
    .rlen_o      (rlen),
    .tdra_o      (tdra),
    .tlen_o      (tlen),
    .ready_o     (ib_ready),
    .rx_fault_i  (rx_fault),
    .tx_fault_i  (tx_fault),
    .bus_req_o   (p0_req),
    .bus_we_o    (p0_we),
    .bus_size_o  (p0_size),
    .bus_sel_o   (p0_sel),
    .bus_addr_o  (p0_addr),
    .bus_wdata_o (p0_wdata),
    .bus_ack_i   (p0_ack),
    .bus_rdata_i (bus_rdata),
    .bus_err_i   (p0_err)
  );

  // ----------------------------------------------------------- receive --
  // le_rx listens to the internal loopback FIFO in LOOP|INTL, else to the
  // feed from eth_hps.
  logic        lb_wr, lb_empty, lb_rd, lb_active, lb_afull;
  logic [11:0] lb_word, lb_data;
  logic [6:0]  lb_level;
  logic        rxf_empty, rxf_rd, rx_fifo_rd;
  logic [11:0] rxf_data;

  wire        rx_fifo_empty = lb_active ? lb_empty : rxf_empty;
  wire [11:0] rx_fifo_data  = lb_active ? lb_data  : rxf_data;
  assign      rxf_rd        = !lb_active && rx_fifo_rd && !rxf_empty;
  assign      lb_rd         =  lb_active && rx_fifo_rd;

  logic        lb_full_unused;
  wish7990_sync_fifo #(.WIDTH(12), .DEPTH(64)) u_lb_fifo (
    .clk, .rst,
    .flush   (1'b0),
    .wr_en   (lb_wr),
    .wr_data (lb_word),
    .full    (lb_full_unused),
    .rd_en   (lb_rd),
    .rd_data (lb_data),
    .empty   (lb_empty),
    .level   (lb_level)
  );
  // le_tx's writes are registered: it stops one word short of full.
  assign lb_afull = lb_level >= 7'd62;

  logic        p1_req, p1_we, p1_ack, p1_err;
  logic [1:0]  p1_size;
  logic [3:0]  p1_sel;
  logic [23:0] p1_addr;
  logic [31:0] p1_wdata;

  wish7990_le_rx #(.POLL_TICKS(POLL_TICKS)) u_rx (
    .clk, .rst,
    .stop_i       (stop),
    .rxon_i       (rxon),
    .rdra_i       (rdra),
    .rlen_i       (rlen),
    .bswp_i       (bswp),
    .padr_i       (padr),
    .ladrf_i      (ladrf),
    .prom_i       (mode[wish7990_pkg::MODE_PROM]),
    .rint_o       (rint),
    .miss_o       (miss),
    .merr_o       (merr_rx),
    .fault_o      (rx_fault),
    .fifo_empty_i (rx_fifo_empty),
    .fifo_data_i  (rx_fifo_data),
    .fifo_rd_o    (rx_fifo_rd),
    .bus_req_o    (p1_req),
    .bus_we_o     (p1_we),
    .bus_size_o   (p1_size),
    .bus_sel_o    (p1_sel),
    .bus_addr_o   (p1_addr),
    .bus_wdata_o  (p1_wdata),
    .bus_ack_i    (p1_ack),
    .bus_rdata_i  (bus_rdata),
    .bus_err_i    (p1_err)
  );

  // ---------------------------------------------------------- transmit --
  logic        tx_ram_we;
  logic [10:0] tx_ram_waddr, tx_ram_raddr;
  logic [7:0]  tx_ram_wdata, tx_ram_rdata;
  logic        tx_go, tx_no_crc, tx_done;
  logic [15:0] tx_flen;
  logic [3:0]  tx_retry_unused;

  logic        p2_req, p2_we, p2_ack, p2_err;
  logic [1:0]  p2_size;
  logic [3:0]  p2_sel;
  logic [23:0] p2_addr;
  logic [31:0] p2_wdata;

  wish7990_le_tx #(.POLL_TICKS(POLL_TICKS), .LOOPBACK_MAX(2040)) u_tx (
    .clk, .rst,
    .stop_i      (stop),
    .txon_i      (txon),
    .tdmd_i      (tdmd),
    .tdra_i      (tdra),
    .tlen_i      (tlen),
    .dtcr_i      (mode[wish7990_pkg::MODE_DTCR]),
    .drty_i      (mode[wish7990_pkg::MODE_DRTY]),
    .loop_i      (mode[wish7990_pkg::MODE_LOOP]),
    .intl_i      (mode[wish7990_pkg::MODE_INTL]),
    .coll_i      (mode[wish7990_pkg::MODE_COLL]),
    .bswp_i      (bswp),
    .tint_o      (tint),
    .babl_o      (babl),
    .merr_o      (merr_tx),
    .fault_o     (tx_fault),
    .lb_wr_o     (lb_wr),
    .lb_data_o   (lb_word),
    .lb_full_i   (lb_afull),
    .lb_active_o (lb_active),
    .ram_we_o    (tx_ram_we),
    .ram_addr_o  (tx_ram_waddr),
    .ram_data_o  (tx_ram_wdata),
    .tx_go_o     (tx_go),
    .tx_len_o    (tx_flen),
    .tx_no_crc_o (tx_no_crc),
    .tx_retry_limit_o (tx_retry_unused),
    // The mailbox is a wire without collisions, carrier loss or deferral.
    .tx_done_i   (tx_done),
    .tx_ok_i     (1'b1),
    .tx_ncoll_i  (4'd0),
    .tx_xcoll_i  (1'b0),
    .tx_defer_i  (1'b0),
    .tx_no_crs_i (1'b0),
    .tx_late_i   (1'b0),
    .bus_req_o   (p2_req),
    .bus_we_o    (p2_we),
    .bus_size_o  (p2_size),
    .bus_sel_o   (p2_sel),
    .bus_addr_o  (p2_addr),
    .bus_wdata_o (p2_wdata),
    .bus_ack_i   (p2_ack),
    .bus_rdata_i (bus_rdata),
    .bus_err_i   (p2_err)
  );

  wish7990_dp_ram #(.WIDTH(8), .DEPTH(2048)) u_tx_ram (
    .wclk    (clk),
    .wr_en   (tx_ram_we),
    .wr_addr (tx_ram_waddr),
    .wr_data (tx_ram_wdata),
    .rclk    (clk),
    .rd_addr (tx_ram_raddr),
    .rd_data (tx_ram_rdata)
  );

  // ------------------------------------------------------ eth_hps side --
  logic        e_tx_push, e_tx_stp, e_tx_clr, e_tx_busy, e_tx_fifordy;
  logic [1:0]  e_tx_be;
  logic [15:0] e_tx_d;
  logic        e_rx_pop, e_rx_deof, e_rx_fifordy, e_rx_crcok, e_rx_eof;
  logic [15:0] e_rx_d;
  logic [11:0] e_rx_len;

  // tx pump: on go, wait for the wire (eth_hps done with the last frame),
  // then read the staged bytes one a cycle and push them in pairs, the
  // earlier byte in [15:8]; done until go falls. A frame le_tx abandons
  // (STOP, a fault) is cleared from eth_hps.
  typedef enum logic [1:0] { P_IDLE, P_RUN, P_DONE } pump_e;
  pump_e       p_st;
  logic [11:0] p_rp;            // the next byte to read
  logic [11:0] p_bi;            // the byte arriving from the RAM this cycle
  logic        p_vld;
  logic [7:0]  p_hi;
  logic        p_abort;
  wire  [11:0] p_len = tx_flen[11:0];

  assign tx_ram_raddr = p_rp[10:0];
  assign tx_done      = (p_st == P_DONE);

  always_ff @(posedge clk) begin
    e_tx_push <= 1'b0;
    p_abort   <= 1'b0;
    if (rst) begin
      p_st  <= P_IDLE;
      p_vld <= 1'b0;
      e_tx_stp <= 1'b0;
      e_tx_be  <= 2'b00;
      e_tx_d   <= '0;
    end else if (!tx_go) begin
      if (p_st == P_RUN) p_abort <= 1'b1;
      p_st  <= P_IDLE;
      p_vld <= 1'b0;
    end else begin
      case (p_st)
        P_IDLE: begin
          if (p_len == 12'd0) begin
            p_st <= P_DONE;                 // nothing to send (BCNT wrapped)
          end else if (!e_tx_busy) begin
            p_rp  <= 12'd0;
            p_vld <= 1'b0;
            p_st  <= P_RUN;
          end
        end
        P_RUN: begin
          p_vld <= (p_rp != p_len);
          p_bi  <= p_rp;
          if (p_rp != p_len) p_rp <= p_rp + 12'd1;
          if (p_vld) begin
            if (!p_bi[0]) p_hi <= tx_ram_rdata;
            if (p_bi[0] || p_bi == p_len - 12'd1) begin
              e_tx_push <= 1'b1;
              e_tx_stp  <= (p_bi[11:1] == 11'd0);
              e_tx_d    <= p_bi[0] ? {p_hi, tx_ram_rdata} : {tx_ram_rdata, 8'h00};
              e_tx_be   <= p_bi[0] ? 2'b11 : 2'b10;
            end
            if (p_bi == p_len - 12'd1) begin
              p_vld <= 1'b0;
              p_st  <= P_DONE;
            end
          end
        end
        default: ;                          // P_DONE: until go falls
      endcase
    end
  end

  assign e_tx_clr = stop || p_abort;

  // rx feed: the offered frame a byte at a time ([15:8] first), then an end
  // word; a word is popped with its last byte. Errors never: eth_hps (and
  // the host's NIC before it) passed only good frames.
  logic [1:0]  f_ph;            // 0: [15:8] next, 1: [7:0] next, 2: the end word
  logic [11:0] f_cnt;
  wire         f_take = rxf_rd;
  wire         f_last = (f_cnt + 12'd1 == e_rx_len);

  assign rxf_empty = (f_ph == 2'd2) ? 1'b0 : !e_rx_fifordy;
  assign rxf_data  = (f_ph == 2'd2) ? 12'h800 :
                     (f_ph == 2'd0) ? {4'h0, e_rx_d[15:8]} : {4'h0, e_rx_d[7:0]};
  assign e_rx_pop  = f_take && ((f_ph == 2'd1) || (f_ph == 2'd0 && f_last));

  always_ff @(posedge clk) begin
    if (rst || stop) begin
      f_ph  <= 2'd0;
      f_cnt <= '0;
    end else if (f_take) begin
      if (f_ph == 2'd2) begin
        f_ph  <= 2'd0;
        f_cnt <= '0;
      end else begin
        f_cnt <= f_cnt + 12'd1;
        f_ph  <= f_last ? 2'd2 : (f_ph == 2'd0 ? 2'd1 : 2'd0);
      end
    end
  end

  eth_hps #(.CLK_HZ(CLK_HZ), .SIMU(SIMU)) u_eth (
    .clk, .rst, .ena,
    .tx_push    (e_tx_push),
    .tx_stp     (e_tx_stp),
    .tx_be      (e_tx_be),
    .tx_d       (e_tx_d),
    .tx_enp     (1'b1),                     // the whole frame is pushed at once
    .tx_len     (p_len),
    .tx_crcgen  (!tx_no_crc),
    .tx_clr     (e_tx_clr),
    .tx_fifordy (e_tx_fifordy),
    .tx_busy    (e_tx_busy),
    .rx_pop     (e_rx_pop),
    .rx_clr     (stop),
    .rx_d       (e_rx_d),
    .rx_deof    (e_rx_deof),
    .rx_fifordy (e_rx_fifordy),
    .rx_len     (e_rx_len),
    .rx_crcok   (e_rx_crcok),
    .rx_eof     (e_rx_eof),
    .rx_lpbk    (mode[wish7990_pkg::MODE_LOOP] && !mode[wish7990_pkg::MODE_INTL]),
    .rx_prom    (mode[wish7990_pkg::MODE_PROM]),
    .rx_padr    (padr),
    .rx_ladrf   (ladrf),
    .avl_waitrequest, .avl_address, .avl_read, .avl_write, .avl_writedata,
    .avl_byteenable, .avl_burstcount, .avl_readdata, .avl_readdatavalid
  );

  // ------------------------------------------------------- memory port --
  logic        m_req, m_we, m_ack, m_err;
  logic [1:0]  m_size;
  logic [3:0]  m_sel;
  logic [23:0] m_addr;
  logic [31:0] m_wdata, m_rdata;

  wish7990_wb_arb u_arb (
    .clk, .rst,
    .p0_req_i (p0_req), .p0_we_i (p0_we), .p0_size_i (p0_size), .p0_sel_i (p0_sel),
    .p0_addr_i (p0_addr), .p0_wdata_i (p0_wdata), .p0_ack_o (p0_ack), .p0_err_o (p0_err),
    .p1_req_i (p1_req), .p1_we_i (p1_we), .p1_size_i (p1_size), .p1_sel_i (p1_sel),
    .p1_addr_i (p1_addr), .p1_wdata_i (p1_wdata), .p1_ack_o (p1_ack), .p1_err_o (p1_err),
    .p2_req_i (p2_req), .p2_we_i (p2_we), .p2_size_i (p2_size), .p2_sel_i (p2_sel),
    .p2_addr_i (p2_addr), .p2_wdata_i (p2_wdata), .p2_ack_o (p2_ack), .p2_err_o (p2_err),
    .rdata_o  (bus_rdata),
    .req_o    (m_req), .we_o (m_we), .size_o (m_size), .sel_o (m_sel),
    .addr_o   (m_addr), .wdata_o (m_wdata),
    .ack_i    (m_ack), .err_i (m_err), .rdata_i (m_rdata)
  );

  // One request to one DVMA beat (the role of Wish7990's wb_master). The
  // 32-bit word with lanes k is memory bytes (W + k) ^ 1: a byte keeps its
  // LANCE address with bit 0 flipped, a halfword or a word goes out as the
  // big-endian halfword(s) in their doubleword lanes.
  logic [3:0]  be4;             // the 32-bit word's big-endian byte enables
  logic [31:0] wd4;             // and its data
  logic [31:0] rd4;
  logic [2:0]  m_off_q;
  logic [1:0]  m_size_q;

  always_comb begin
    case (m_size)
      SZ_BYTE: begin
        // LANCE byte addr[1:0] is memory byte addr[1:0] ^ 1 of the word
        be4 = 4'b1000 >> (m_addr[1:0] ^ 2'b01);
        wd4 = {4{m_wdata[7:0]}};
      end
      SZ_HALF: begin
        be4 = m_addr[1] ? 4'b0011 : 4'b1100;
        wd4 = {2{m_wdata[15:0]}};
      end
      default: begin
        be4 = {m_sel[1], m_sel[0], m_sel[3], m_sel[2]};
        wd4 = {m_wdata[15:0], m_wdata[31:16]};
      end
    endcase
  end

  // The addressed 32-bit word of the doubleword read
  assign rd4 = m_off_q[2] ? mem_i.rdata[31:0] : mem_i.rdata[63:32];

  always_ff @(posedge clk) begin
    m_ack <= 1'b0;
    m_err <= 1'b0;
    if (rst) begin
      mem_o <= sbus_pkg::DVMA_REQ_IDLE;
    end else if (mem_o.valid) begin
      if (mem_i.ack) begin
        mem_o.valid <= 1'b0;
        m_ack       <= 1'b1;
        m_err       <= mem_i.err;
        case (m_size_q)
          SZ_BYTE: m_rdata <= {24'h0, rd4[{~(m_off_q[1:0] ^ 2'b01), 3'b000} +: 8]};
          SZ_HALF: m_rdata <= {16'h0, m_off_q[1] ? rd4[15:0] : rd4[31:16]};
          default: m_rdata <= {rd4[15:0], rd4[31:16]};
        endcase
      end
    end else if (m_req && !m_ack) begin
      // m_ack still high: the access just finished and req has not fallen
      mem_o.valid <= 1'b1;
      mem_o.write <= m_we;
      mem_o.burst <= 1'b0;
      mem_o.va    <= {8'h00, m_addr};
      mem_o.be    <= m_addr[2] ? {4'h0, be4} : {be4, 4'h0};
      mem_o.wdata <= {wd4, wd4};
      m_off_q     <= m_addr[2:0];
      m_size_q    <= m_size;
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, inea_unused, acon_unused, bcon_unused, ready_unused, ib_ready,
                   tx_flen[15:12], tx_retry_unused, lb_full_unused, e_tx_fifordy, e_rx_deof,
                   e_rx_crcok, e_rx_eof, bus_i.addr, bus_i.pair, 1'b0};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
