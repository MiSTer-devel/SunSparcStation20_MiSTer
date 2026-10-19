// SPDX-License-Identifier: GPL-2.0-or-later
//
// dma2: the SS20's DMA2 ("DMA+" compatible) in the MACIO as software sees
// it: the ESP's DMA channel (espdma), the LANCE's (ledma) and a parallel
// port stub. Slot F offset 0x0040_0000 (PA 0xE_F040_0000); bus_i.addr is
// the offset from there, decoded on bits 5:2 (the rest of the window
// aliases).
//
// From: the DMA2 core specification (scratch/reference/chipset/dma2.txt:
//   D_CSR, D_ADDR, D_BCNT, the D-FIFO drain rules, E_CSR, E_BASE_ADDR);
//   NetBSD dev/ic/lsi64854reg.h, lsi64854.c (the bits drivers use, the
//   parallel port's layout); QEMU hw/dma/sparc32_dma.c (ledma's address
//   = E_BASE_ADDR | the LANCE's 24 bits); OpenBIOS drivers/esp.c;
//   docs/VERILOG-PLAN.md §6 DMA-5.
//
// Registers (32-bit; byte writes merge by byte enables, except to D_CSR,
// D_ADDR, D_BCNT and E_CSR, which take only whole words: a narrower write
// is dropped with an error ack and sets the channel's SLAVE_ERR -- the
// LANCE's own wrong-size writes, le_size_err_i, set E_CSR's):
//   +00 D_CSR   [31:28] DEV_ID 0xA, 27 NA_LOADED (0), 26 A_LOADED,
//               25 DMA_ON, 24 EN_NEXT, 23 TCI_DIS, 22 FASTER, 21 TWO_CYCLE,
//               20 DIAG, 19:18 BURST_SIZE, 17 DSBL_SCSI_DRN, 16 DSBL_CSR_DRN,
//               14 TC (W1C with EN_NEXT), 13 EN_CNT, 9 EN_DMA, 8 WRITE (to
//               memory), 7 RESET (held: esp_rst_o), 6 SLAVE_ERR (W1C),
//               5 INVALIDATE (W), 4 INT_EN, 3:2 DRAINING, 1 ERR_PEND,
//               0 INT_PEND (the ESP's interrupt, or TC unless TCI_DIS)
//   +04 D_ADDR  the address counter: the next byte the ESP moves
//   +08 D_BCNT  24-bit byte counter (counts with EN_CNT; TC at 0, DMA stops)
//   +0C D_TST   reads 0
//   +10 E_CSR   [31:28] 0xA, 22 TP_AUI, 21 LOOP_TEST, 20, 19:18 BURST,
//               17, 16, 15 ILACC, 12, 11 (stored), 10 DRAIN (reads 0),
//               7 RESET (held: le_rst_o), 6 SLAVE_ERR (W1C), 5 INVALIDATE (W), 4 INT_EN,
//               1 ERR_PEND, 0 INT_PEND (the LANCE's INTR, ungated: DMA-3)
//   +14 E_TST_CSR [23:0] the LANCE's last address
//   +18 E_VLD   reads 0 (no E-cache)
//   +1C E_BASE_ADDR [31:24], 0xFF after reset (DMA-2)
//   +20 P_CSR, +24 P_ADDR, +28 P_BCNT, +2C P_TST, +30 HCR|OCR,
//       +34 DR|TCR|OR|IR, +38 ICR (the integrator also maps them at the
//       parallel port's own slot-F offset 0x480_0000, +0 for +20 here):
//       the parallel port, a stub: OCR 0x200A and TCR.DIR after reset
//       (P_CSR RESET), OCR.EN_DIAG loops OR back to IR and lets ACK/BUSY
//       be written in TCR (the POST's PPORT tests); the control
//       bits are stored and read back, DEV_ID 0xA, no transfers, no
//       interrupt, the printer lines idle (TCR's BUSY/ACK, IR read 0).
//
// The ESP channel. The byte handshake with esp.sv: esp_dreq_i asks for a
// byte, esp_dtomem_i its direction (1: to memory); a byte moves in a
// cycle with esp_dreq_i and esp_dack_o high. dack needs EN_DMA, WRITE
// matching the ESP's direction (otherwise nothing moves, as on the chip),
// no ERR_PEND, no RESET, and with EN_CNT an address loaded since the
// count expired. Each byte moves D_ADDR on (and D_BCNT down with EN_CNT).
//  - To memory: bytes gather in a doubleword buffer, written (one beat,
//    the bytes' enables) once the address leaves its doubleword, and
//    drained -- a partial doubleword, only its bytes (DMA-5) -- when the
//    ESP interrupts, the count expires, or the CPU writes D_CSR, D_ADDR or
//    D_BCNT (that write waits, its ack held, until the buffer is in
//    memory). INT_PEND (and the interrupt) wait for the drain, so the
//    driver that sees the interrupt finds every byte in memory; DRAINING
//    shows it meanwhile.
//  - From memory: the doubleword holding D_ADDR is read when the ESP asks
//    for a byte, its bytes handed over in turn; a D_ADDR or D_CSR write
//    drops it. No read-ahead beyond what the ESP asks for (a select's CDB
//    never reads past its doubleword).
//  - BURST_SIZE is stored; every access is a single doubleword beat.
//  - A DVMA error sets ERR_PEND (the interrupt with INT_EN) and stops the
//    channel until INVALIDATE or RESET; a buffer it could not write is
//    dropped then.
//  - Not modelled: EN_NEXT's next-address/count registers (a D_ADDR write
//    always loads D_ADDR), the transfer rate bits.
//
// The LANCE channel: the LANCE's requests (le_req_i, its 24-bit address
// in va[23:0]) pass through to le_dvma_o with va[31:24] = E_BASE_ADDR;
// the answer comes back unchanged. A DVMA error sets E_ERR_PEND.
//
// Interrupts (level): irq_esp_o = D_INT_EN & (INT_PEND | ERR_PEND) (the
// integrator maps it to SI_SC); irq_le_o = E_INT_EN & (E_INT_PEND |
// E_ERR_PEND) (SI_E). Resets: esp_rst_o = D_CSR.RESET (to esp.sv's
// chip_rst_i), le_rst_o = E_CSR.RESET; the machine reset is the
// integrator's to add.

module dma2
  import iobus_pkg::*, sbus_pkg::*, mem_pkg::*;
(
  input  logic      clk,
  input  logic      rst,

  input  iob_req_t  bus_i,
  output iob_rsp_t  bus_o,

  // The ESP channel
  input  logic      esp_irq_i,           // esp.sv irq_o
  input  logic      esp_dreq_i,
  input  logic      esp_dtomem_i,
  input  logic [7:0] esp_ddata_i,        // a byte to memory
  output logic      esp_dack_o,
  output logic [7:0] esp_ddata_o,        // a byte from memory
  output logic      esp_rst_o,
  output logic      irq_esp_o,
  output dvma_req_t esp_dvma_o,
  input  mem_rsp_t  esp_dvma_i,

  // The LANCE channel
  input  dvma_req_t le_req_i,            // va[23:0]: the LANCE's address
  output mem_rsp_t  le_rsp_o,
  output dvma_req_t le_dvma_o,
  input  mem_rsp_t  le_dvma_i,
  input  logic      le_irq_i,
  input  logic      le_size_err_i,       // pulse: a wrong-size write to the LANCE (E_CSR SLAVE_ERR)
  output logic      irq_le_o,
  output logic      le_rst_o
);

  localparam logic [31:0] D_RW = 32'h01FF_2390;   // D_CSR's stored bits
  localparam logic [31:0] E_RW = 32'h007F_9890;   // E_CSR's
  localparam logic [31:0] P_RW = 32'h01FF_2390;   // P_CSR's

  // ---------------------------------------------------------------------
  // Register access
  // ---------------------------------------------------------------------
  wire        req_new = bus_i.req & ~bus_o.ack;
  wire [3:0]  ra      = bus_i.addr[5:2];
  wire [31:0] bm      = {{8{bus_i.be[3]}}, {8{bus_i.be[2]}}, {8{bus_i.be[1]}}, {8{bus_i.be[0]}}};
  // D_CSR, D_ADDR, D_BCNT writes wait for the drain
  wire        dwr     = bus_i.we && ra <= 4'd2;
  logic       drained;
  wire        access  = req_new && (!dwr || drained);
  wire        wr_wait = req_new && dwr && !drained;
  // a write of less than a word to a word-only register (the CSRs, D_ADDR,
  // D_BCNT): dropped, SLAVE_ERR set in the channel's CSR, and an error ack
  // (the MSI's write buffer reports it: AFSR, level 15). OBP 2.25's POST
  // checks this with byte stores ("DMA2/MACIO ... Reg. Test")
  wire        size_bad = bus_i.we && bus_i.be != 4'hF && (ra <= 4'd2 || ra == 4'd4);

  function automatic logic [31:0] merge(input logic [31:0] old, input logic [31:0] nw,
                                        input logic [31:0] m);
    return (old & ~m) | (nw & m);
  endfunction

  logic unused_ok;
  assign unused_ok = &{1'b0, bus_i.addr[IOB_AW-1:6], bus_i.addr[1:0], bus_i.pair,
                       le_req_i.va[31:24]};

  // ---------------------------------------------------------------------
  // The ESP channel
  // ---------------------------------------------------------------------
  logic [31:0] d_rw;                     // the stored D_CSR bits
  logic [31:0] daddr;
  logic [23:0] dbcnt;
  logic        d_err, d_tc, a_loaded;
  logic        d_serr, e_serr;            // SLAVE_ERR (bit 6) of D_CSR, E_CSR

  wire d_int_en  = d_rw[4];
  wire d_reset   = d_rw[7];
  wire d_write   = d_rw[8];
  wire d_en_dma  = d_rw[9];
  wire d_en_cnt  = d_rw[13];
  wire d_tci_dis = d_rw[23];
  wire d_en_next = d_rw[24];

  // to memory: the gathering doubleword
  logic [31:3] wb_dw;
  logic [63:0] wb_data;
  logic [7:0]  wb_be;
  // from memory: the doubleword read
  logic [31:3] rb_dw;
  logic [63:0] rb_data;
  logic        rb_v;
  // the request on the DVMA port
  dvma_req_t   wq;

  wire d_en  = d_en_dma && !d_err && !d_reset && !(d_en_cnt && !a_loaded);
  wire wsel  = d_en && esp_dtomem_i && d_write && !wr_wait;
  wire rsel  = d_en && !esp_dtomem_i && !d_write && !wr_wait;
  wire rhit  = rb_v && rb_dw == daddr[31:3];

  assign esp_dack_o  = (wsel && !(wb_be != 8'h00 && wb_dw != daddr[31:3])) || (rsel && rhit);
  assign esp_ddata_o = rb_data[8 * (7 - int'(daddr[2:0])) +: 8];
  wire   dx = esp_dreq_i && esp_dack_o;

  wire draining = (wb_be != 8'h00 && !d_err) || (wq.valid && wq.write);
  assign drained = (wb_be == 8'h00 || d_err) && !wq.valid;
  wire drain    = esp_irq_i || wr_wait || d_tc;
  wire int_pend = (esp_irq_i && !draining) || (d_tc && !d_tci_dis);

  assign irq_esp_o  = d_int_en && (int_pend || d_err);
  assign esp_rst_o  = d_reset;
  assign esp_dvma_o = wq;

  wire [31:0] d_csr_rd = {4'hA, 1'b0, a_loaded, a_loaded && d_en_dma && !d_err,
                          d_rw[24:16], 1'b0, d_tc, d_rw[13:7], d_serr, 1'b0,
                          d_rw[4], {2{draining}}, d_err, int_pend};

  // ---------------------------------------------------------------------
  // The LANCE channel
  // ---------------------------------------------------------------------
  logic [31:0] e_rw;
  logic        e_err;
  logic [7:0]  ebase;
  logic [23:0] e_addr;

  always_comb begin
    le_dvma_o    = le_req_i;
    le_dvma_o.va = {ebase, le_req_i.va[23:0]};
  end
  assign le_rsp_o = le_dvma_i;
  assign irq_le_o = e_rw[4] && (le_irq_i || e_err);
  assign le_rst_o = e_rw[7];

  wire [31:0] e_csr_rd = {4'hA, e_rw[27:7], e_serr, e_rw[5:2], e_err, le_irq_i};

  // ---------------------------------------------------------------------
  // The parallel port stub
  // ---------------------------------------------------------------------
  logic [31:0] p_rw, paddr;
  logic [23:0] pbcnt;
  logic [15:0] p_hcr, p_ocr, p_icr;
  logic [7:0]  p_dr, p_tcr, p_or;
  // IR: the printer's status lines, idle; with OCR.EN_DIAG (bit 10) the
  // diagnostic loopback returns OR's INIT/AFXN/SLCT_IN (2:0) there
  wire  [7:0]  p_ir = p_ocr[10] ? {5'd0, p_or[2:0]} : 8'h00;

  // ---------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------
  logic [31:0] rdata;
  always_comb begin
    case (ra)
      4'h0:    rdata = d_csr_rd;
      4'h1:    rdata = daddr;
      4'h2:    rdata = {8'h00, dbcnt};
      4'h4:    rdata = e_csr_rd;
      4'h5:    rdata = {8'h00, e_addr};
      4'h7:    rdata = {ebase, 24'h0};
      4'h8:    rdata = {4'hA, p_rw[27:0]};
      4'h9:    rdata = paddr;
      4'hA:    rdata = {8'h00, pbcnt};
      4'hC:    rdata = {p_hcr, p_ocr};
      4'hD:    rdata = {p_dr, p_tcr, p_or, p_ir};
      4'hE:    rdata = {p_icr, 16'h0};
      default: rdata = 32'h0;
    endcase
  end

  // ---------------------------------------------------------------------
  // Sequential
  // ---------------------------------------------------------------------
  always_ff @(posedge clk) begin : p_seq
    logic [31:0] wd;
    logic [2:0]  lane;
    logic        flush;

    wd    = bus_i.wdata;
    lane  = daddr[2:0];
    flush = !wq.valid && wb_be != 8'h00 && !d_err && (wb_dw != daddr[31:3] || drain);

    if (rst) begin
      bus_o    <= IOB_RSP_IDLE;
      d_rw     <= 32'h0;
      daddr    <= 32'h0;
      dbcnt    <= 24'h0;
      d_err    <= 1'b0;
      d_tc     <= 1'b0;
      a_loaded <= 1'b0;
      wb_be    <= 8'h00;
      rb_v     <= 1'b0;
      wq       <= DVMA_REQ_IDLE;
      e_rw     <= 32'h0;
      e_err    <= 1'b0;
      d_serr   <= 1'b0;
      e_serr   <= 1'b0;
      ebase    <= 8'hFF;
      e_addr   <= 24'h0;
      p_rw     <= 32'h0;
      paddr    <= 32'h0;
      pbcnt    <= 24'h0;
      p_hcr    <= 16'h0;
      p_ocr    <= 16'h200A;
      p_icr    <= 16'h0;
      p_dr     <= 8'h00;
      p_tcr    <= 8'h08;
      p_or     <= 8'h00;
    end else begin
      bus_o.ack   <= access && !size_bad;
      bus_o.err   <= access && size_bad;
      bus_o.rdata <= rdata;

      // ---------------------------------------------------------------
      // The ESP channel: a byte moves
      if (dx) begin
        daddr <= daddr + 32'd1;
        if (d_en_cnt) begin
          dbcnt <= dbcnt - 24'd1;
          if (dbcnt == 24'd1) begin d_tc <= 1'b1; a_loaded <= 1'b0; end
        end
      end

      // the gathering doubleword: written out (all of it, or what a drain
      // finds), and the byte of this cycle
      if (flush) begin
        wq <= '{valid: 1'b1, write: 1'b1, burst: 1'b0, va: {wb_dw, 3'b000},
                be: wb_be, wdata: wb_data};
      end
      if (dx && esp_dtomem_i) begin
        wb_dw <= daddr[31:3];
        wb_data[8 * (7 - int'(lane)) +: 8] <= esp_ddata_i;
        wb_be <= (flush ? 8'h00 : wb_be) | (8'h80 >> lane);
      end else if (flush)
        wb_be <= 8'h00;

      // a doubleword for the ESP to read
      if (!wq.valid && !flush && rsel && esp_dreq_i && !rhit && wb_be == 8'h00)
        wq <= '{valid: 1'b1, write: 1'b0, burst: 1'b0, va: {daddr[31:3], 3'b000},
                be: 8'hFF, wdata: 64'h0};

      if (wq.valid && esp_dvma_i.ack) begin
        wq.valid <= 1'b0;
        if (esp_dvma_i.err)
          d_err <= 1'b1;
        else if (!wq.write) begin
          rb_data <= esp_dvma_i.rdata;
          rb_dw   <= wq.va[31:3];
          rb_v    <= 1'b1;
        end
      end

      // RESET held: the channel idles (the write that set it waited for
      // the drain)
      if (d_reset) begin
        d_err    <= 1'b0;
        d_tc     <= 1'b0;
        a_loaded <= 1'b0;
        rb_v     <= 1'b0;
        wb_be    <= 8'h00;
      end

      // ---------------------------------------------------------------
      // The LANCE channel
      if (le_req_i.valid) e_addr <= le_req_i.va[23:0];
      if (le_dvma_i.ack && le_dvma_i.err) e_err <= 1'b1;
      if (e_rw[7]) e_err <= 1'b0;

      // ---------------------------------------------------------------
      // Register writes
      // the parallel port's RESET (P_CSR bit 7, held) resets its stub
      if (p_rw[7]) begin
        p_hcr <= 16'h0; p_ocr <= 16'h200A; p_icr <= 16'h0;
        p_tcr <= 8'h08; p_or <= 8'h00;
      end

      // SLAVE_ERR: set by a wrong-size write, cleared by writing 1 to it
      // or by RESET
      if (access && size_bad) begin
        if (ra == 4'd4) e_serr <= 1'b1; else d_serr <= 1'b1;
      end
      if (le_size_err_i) e_serr <= 1'b1;
      if (access && bus_i.we && !size_bad && ra == 4'd0 && wd[6]) d_serr <= 1'b0;
      if (access && bus_i.we && !size_bad && ra == 4'd4 && wd[6]) e_serr <= 1'b0;
      if (d_reset) d_serr <= 1'b0;
      if (e_rw[7]) e_serr <= 1'b0;

      if (access && bus_i.we && !size_bad) begin
        case (ra)
          4'h0: begin
            d_rw <= merge(d_rw, wd, bm) & D_RW;
            rb_v <= 1'b0;
            if (bm[5] && wd[5]) begin                    // INVALIDATE
              d_err <= 1'b0;
              d_tc  <= 1'b0;
              wb_be <= 8'h00;                            // only left there after an error
            end
            if (bm[14] && wd[14] && d_en_next) d_tc <= 1'b0;
          end
          4'h1: begin
            daddr    <= merge(daddr, wd, bm);
            a_loaded <= 1'b1;
            rb_v     <= 1'b0;
            if (d_err) wb_be <= 8'h00;
          end
          4'h2: dbcnt <= (dbcnt & ~bm[23:0]) | (wd[23:0] & bm[23:0]);
          4'h4: begin
            e_rw <= merge(e_rw, wd, bm) & E_RW;
            if (bm[5] && wd[5]) e_err <= 1'b0;
          end
          4'h7: if (bus_i.be[3]) ebase <= wd[31:24];
          4'h8: p_rw  <= merge(p_rw, wd, bm) & P_RW;
          4'h9: paddr <= merge(paddr, wd, bm);
          4'hA: pbcnt <= (pbcnt & ~bm[23:0]) | (wd[23:0] & bm[23:0]);
          4'hC: begin
            if (bus_i.be[3]) p_hcr[15:8] <= wd[31:24];
            if (bus_i.be[2]) p_hcr[7:0]  <= wd[23:16];
            if (bus_i.be[1]) p_ocr[15:8] <= wd[15:8];
            if (bus_i.be[0]) p_ocr[7:0]  <= wd[7:0];
          end
          4'hD: begin
            if (bus_i.be[3]) p_dr  <= wd[31:24];
            // DS, DIR; ACK and BUSY too in the diagnostic loopback
            if (bus_i.be[2]) p_tcr <= wd[23:16] & (p_ocr[10] ? 8'h0F : 8'h09);
            if (bus_i.be[1]) p_or  <= wd[15:8];
          end
          4'hE: begin
            // the enables; the status bits (15:10) are W1C and never set
            if (bus_i.be[3]) p_icr[15:8] <= wd[31:24] & 8'h03;
            if (bus_i.be[2]) p_icr[7:0]  <= wd[23:16];
          end
          default: ;
        endcase
      end
    end
  end

endmodule
