// SPDX-License-Identifier: MIT
//
// Vendored from Wish7990 (MIT, rtl/sun4m/LICENSE.wish7990; MelkhiorVintageComputing,
// https://github.com/MelkhiorVintageComputing/Wish7990, commit 8610ef5,
// src/le_regs.sv, as pinned by Sun-3_FPGA). Local changes: the module and
// the modules it instantiates take a wish7990_ prefix. See
// rtl/sun4m/lance.sv for how the SS20 uses it.
//
// The C-LANCE's four Control and Status Registers, and the address port that
// hides them behind two locations.
//
// This is its own file because CSR0's write semantics are unlike anything else
// in the tree.  The chip sets bits and the host clears them: the datasheet
// (p. 20) puts it as "the C-LANCE updates CSR0 by logical ORing the previous
// and present value of CSR0".  So a host write is a mask - only the functions
// with a one in it are affected - with one exception, INEA, which is a plain
// read/write bit and therefore has to be written to the value it should have
// every single time.  That is why every driver in doc/drivers ORs LE_INEA into
// its acknowledges rather than writing the acknowledge alone.
//
// The engines only ever pulse a *_set_i for one cycle.  They never clear
// anything here, and they cannot: a bit the host has not seen must not vanish.
//
// RAP and the CSRs are on the die, so they are inside the MAC rather than in a
// machine's register block - see doc/interface.md, which argues that at
// length.  What a machine supplies is where these two ports sit in its address
// map, in wb_le.

module wish7990_le_regs (
    input  logic        clk,
    input  logic        rst,

    // The RESET pin.  Narrower than rst: it clears RAP, CSR3 and the CSR0
    // status bits, and leaves STOP set, which is what "comes up stopped" means.
    input  logic        reset_i,

    // ---- the part's slave port, one demultiplexed transaction --------------
    input  logic        cs_i,
    input  logic        adr_i,      // the ADR pin: 0 = RDP, 1 = RAP
    input  logic        we_i,       // the inverse of the READ pin
    input  logic [15:0] wdata_i,
    output logic [15:0] rdata_o,
    output logic        ready_o,    // the READY pin

    output logic        intr_o,     // the INTR pin, active high here

    // ---- out to the engines ------------------------------------------------
    output logic [23:0] iadr_o,
    output logic        bswp_o,
    output logic        acon_o,
    output logic        bcon_o,
    output logic        init_o,     // pulse: read the initialisation block
    output logic        strt_o,     // level: the engines may run
    output logic        stop_o,     // level: everything is held stopped
    output logic        tdmd_o,     // pulse: poll the transmit ring now
    output logic        inea_o,

    // ---- in from the engines: one-cycle set strobes and two levels ---------
    input  logic        idon_set_i,
    input  logic        rint_set_i,
    input  logic        tint_set_i,
    input  logic        babl_set_i,
    input  logic        cerr_set_i,
    input  logic        miss_set_i,
    input  logic        merr_set_i,
    input  logic        rxon_i,
    input  logic        txon_i
);

  localparam int C0_ERR  = wish7990_pkg::C0_ERR;
  localparam int C0_BABL = wish7990_pkg::C0_BABL;
  localparam int C0_CERR = wish7990_pkg::C0_CERR;
  localparam int C0_MISS = wish7990_pkg::C0_MISS;
  localparam int C0_MERR = wish7990_pkg::C0_MERR;
  localparam int C0_RINT = wish7990_pkg::C0_RINT;
  localparam int C0_TINT = wish7990_pkg::C0_TINT;
  localparam int C0_IDON = wish7990_pkg::C0_IDON;
  localparam int C0_INTR = wish7990_pkg::C0_INTR;
  localparam int C0_INEA = wish7990_pkg::C0_INEA;
  localparam int C0_RXON = wish7990_pkg::C0_RXON;
  localparam int C0_TXON = wish7990_pkg::C0_TXON;
  localparam int C0_TDMD = wish7990_pkg::C0_TDMD;
  localparam int C0_STOP = wish7990_pkg::C0_STOP;
  localparam int C0_STRT = wish7990_pkg::C0_STRT;
  localparam int C0_INIT = wish7990_pkg::C0_INIT;

  // ---- the registers --------------------------------------------------------
  logic [1:0]  rap_q;

  // CSR0, one bit at a time, because they do not share a write rule.
  logic        babl_q, cerr_q, miss_q, merr_q;
  logic        rint_q, tint_q, idon_q;
  logic        inea_q;
  logic        stop_q, strt_q, init_q;

  // CSR1 bit 0 must be zero (p. 22), so it is not stored at all.
  logic [15:1] csr1_q;      // IADR[15:1]
  logic [7:0]  csr2_q;      // IADR[23:16]
  logic [2:0]  csr3_q;      // {BSWP, ACON, BCON}

  // A slave access happens in the cycle cs_i is high; the port is not pipelined
  // and every register answers in one cycle, so READY is simply asserted.  It
  // exists because the datasheet distinguishes a short CSR0 access from a
  // longer CSR1/CSR2 one, and a machine that cares can stretch its own ACK.
  assign ready_o = 1'b1;

  wire acc      = cs_i;
  wire wr_rap   = acc &&  we_i &&  adr_i;
  wire wr_rdp   = acc &&  we_i && !adr_i;
  wire wr_csr0  = wr_rdp && (rap_q == wish7990_pkg::CSR0);
  // CSR1, CSR2 and CSR3 are "accessible only when the STOP bit of CSR0 is a
  // ONE" (p. 22).  Otherwise the write is ignored and a read is undefined; we
  // return zero, and say so in doc/interface.md.
  wire wr_csr1  = wr_rdp && (rap_q == wish7990_pkg::CSR1) && stop_q;
  wire wr_csr2  = wr_rdp && (rap_q == wish7990_pkg::CSR2) && stop_q;
  wire wr_csr3  = wr_rdp && (rap_q == wish7990_pkg::CSR3) && stop_q;

  // Assembled CSR0, used for reads and for the interrupt.  ERR and INTR are
  // combinational over the rest, and RXON and TXON are the engines'.
  logic [15:0] csr0;
  always_comb begin
    csr0 = 16'h0000;
    csr0[C0_BABL] = babl_q;
    csr0[C0_CERR] = cerr_q;
    csr0[C0_MISS] = miss_q;
    csr0[C0_MERR] = merr_q;
    csr0[C0_RINT] = rint_q;
    csr0[C0_TINT] = tint_q;
    csr0[C0_IDON] = idon_q;
    csr0[C0_INEA] = inea_q;
    csr0[C0_RXON] = rxon_i;
    csr0[C0_TXON] = txon_i;
    csr0[C0_STOP] = stop_q;
    csr0[C0_STRT] = strt_q;
    csr0[C0_INIT] = init_q;
    // TDMD is write-with-one-only and self-clearing; it reads back as zero.
    csr0[C0_ERR]  = babl_q | cerr_q | miss_q | merr_q;
    // CERR is deliberately not in here (p. 20).
    csr0[C0_INTR] = babl_q | miss_q | merr_q | rint_q | tint_q | idon_q;
  end

  // The interrupt pin follows INTR gated by INEA, because INEA is a bit of
  // this register - unlike Wish82586, where masking belongs to the machine.
  assign intr_o = csr0[C0_INTR] & inea_q;

  assign iadr_o = {csr2_q, csr1_q, 1'b0};
  assign bswp_o = csr3_q[2];
  assign acon_o = csr3_q[1];
  assign bcon_o = csr3_q[0];
  assign strt_o = strt_q;
  assign stop_o = stop_q;
  assign inea_o = inea_q;

  // ---- reads ----------------------------------------------------------------
  always_comb begin
    if (adr_i) begin
      rdata_o = {14'h0, rap_q};
    end else begin
      case (rap_q)
        wish7990_pkg::CSR1: rdata_o = stop_q ? {csr1_q, 1'b0} : 16'h0000;
        wish7990_pkg::CSR2: rdata_o = stop_q ? {8'h00, csr2_q}      : 16'h0000;
        wish7990_pkg::CSR3: rdata_o = stop_q ? {13'h0, csr3_q}      : 16'h0000;
        default:            rdata_o = csr0;
      endcase
    end
  end

  // ---- writes ---------------------------------------------------------------
  //
  // Two things settle what a CSR0 write does before any individual bit is
  // considered.  STOP wins: "If STRT, INIT and STOP are all set together, STOP
  // will override the other bits and only STOP will be set" (p. 22).  And
  // setting STOP clears the status bits and CSR3 as well as halting the
  // engines, which is why a driver that stops the chip to reprogram it has to
  // rewrite CSR3 - and every driver in doc/drivers does.
  wire set_stop = wr_csr0 && wdata_i[C0_STOP];
  wire set_strt = wr_csr0 && wdata_i[C0_STRT] && !set_stop;
  wire set_init = wr_csr0 && wdata_i[C0_INIT] && !set_stop;

  // A hard stop: the RESET pin, or the host setting STOP.
  wire stopping = reset_i || set_stop;

  always_ff @(posedge clk) begin
    if (rst) begin
      rap_q  <= 2'd0;
      babl_q <= 1'b0;
      cerr_q <= 1'b0;
      miss_q <= 1'b0;
      merr_q <= 1'b0;
      rint_q <= 1'b0;
      tint_q <= 1'b0;
      idon_q <= 1'b0;
      inea_q <= 1'b0;
      stop_q <= 1'b1;          // the part comes out of reset stopped
      strt_q <= 1'b0;
      init_q <= 1'b0;
      csr1_q <= 15'h0000;
      csr2_q <= 8'h00;
      csr3_q <= 3'b000;
      tdmd_o <= 1'b0;
      init_o <= 1'b0;
    end else begin
      tdmd_o <= 1'b0;
      init_o <= 1'b0;

      // The address port.  Cleared by RESET, and only two bits are kept.
      if (reset_i)      rap_q <= 2'd0;
      else if (wr_rap)  rap_q <= wdata_i[1:0];

      // ---- the run/stop trio ------------------------------------------------
      if (stopping) begin
        stop_q <= 1'b1;
        strt_q <= 1'b0;
        init_q <= 1'b0;
      end else begin
        if (set_strt) begin
          strt_q <= 1'b1;
          stop_q <= 1'b0;
        end
        if (set_init) begin
          init_q <= 1'b1;
          stop_q <= 1'b0;
          init_o <= 1'b1;      // one cycle, to le_init
        end
      end

      // TDMD is a pulse to the transmit engine.  Write-with-one-only, ignored
      // while stopped, and it reads back as zero.
      if (wr_csr0 && wdata_i[C0_TDMD] && !stopping) tdmd_o <= 1'b1;

      // ---- the status bits --------------------------------------------------
      //
      // Set by an engine, cleared by the host writing a one or by a stop.  The
      // set strobe wins a tie: an event the host has not seen yet must not be
      // lost to an acknowledge of the previous one.
      if      (idon_set_i)                          idon_q <= 1'b1;
      else if (stopping || (wr_csr0 && wdata_i[C0_IDON])) idon_q <= 1'b0;

      if      (rint_set_i)                          rint_q <= 1'b1;
      else if (stopping || (wr_csr0 && wdata_i[C0_RINT])) rint_q <= 1'b0;

      if      (tint_set_i)                          tint_q <= 1'b1;
      else if (stopping || (wr_csr0 && wdata_i[C0_TINT])) tint_q <= 1'b0;

      if      (babl_set_i)                          babl_q <= 1'b1;
      else if (stopping || (wr_csr0 && wdata_i[C0_BABL])) babl_q <= 1'b0;

      if      (cerr_set_i)                          cerr_q <= 1'b1;
      else if (stopping || (wr_csr0 && wdata_i[C0_CERR])) cerr_q <= 1'b0;

      if      (miss_set_i)                          miss_q <= 1'b1;
      else if (stopping || (wr_csr0 && wdata_i[C0_MISS])) miss_q <= 1'b0;

      if      (merr_set_i)                          merr_q <= 1'b1;
      else if (stopping || (wr_csr0 && wdata_i[C0_MERR])) merr_q <= 1'b0;

      // ---- the one plain read/write bit -------------------------------------
      //
      // "INEA can be set at any time, regardless of the state of the STOP bit"
      // (p. 21), and it takes the value written rather than being ORed - which
      // is exactly why the drivers rewrite it on every acknowledge.  RESET
      // clears it; so does setting STOP.  Writing STOP and INEA together is
      // therefore ambiguous, and STOP is taken to win; no driver in
      // doc/drivers does it, they all write STOP on its own.
      if      (reset_i)  inea_q <= 1'b0;
      else if (set_stop) inea_q <= 1'b0;
      else if (wr_csr0)  inea_q <= wdata_i[C0_INEA];

      // ---- CSR1, CSR2, CSR3 ---------------------------------------------------
      //
      // Writable only while stopped.  The chip preserves CSR1 and CSR2 across a
      // stop (p. 22) but clears CSR3 (p. 23), so they are not reset together.
      if (wr_csr1) csr1_q <= wdata_i[15:1];
      if (wr_csr2) csr2_q <= wdata_i[7:0];

      if      (reset_i || set_stop) csr3_q <= 3'b000;
      else if (wr_csr3)             csr3_q <= {wdata_i[wish7990_pkg::C3_BSWP],
                                               wdata_i[wish7990_pkg::C3_ACON],
                                               wdata_i[wish7990_pkg::C3_BCON]};
    end
  end

endmodule
