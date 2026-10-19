// SPDX-License-Identifier: MIT
//
// Vendored from Wish7990 (MIT, rtl/sun4m/LICENSE.wish7990; MelkhiorVintageComputing,
// https://github.com/MelkhiorVintageComputing/Wish7990, commit 8610ef5,
// src/le_init.sv, as pinned by Sun-3_FPGA). Local changes: the module and
// the modules it instantiates take a wish7990_ prefix. See
// rtl/sun4m/lance.sv for how the SS20 uses it.
//
// The initialisation block reader.
//
// When the host sets CSR0.INIT the chip reads twelve 16-bit words from IADR
// and keeps what it finds: the mode word, our physical address, the logical
// address filter, and where the two descriptor rings are and how long they
// are (datasheet p. 23).  Then it sets IDON, and the driver waits up to 10 ms
// for that before giving up - `CDELAY((le->le_csr & LE_IDON), 10000)` in
// doc/drivers/SunOS414/if_le.c.
//
// **Twelve halfword reads, not six word reads.**  CSR1 forces bit 0 of IADR to
// zero and nothing more, so the block is only 16-bit aligned and a 32-bit read
// could straddle its end.  This happens once per INIT, so fidelity is worth
// more than six saved bus cycles; doc/interface.md records the choice and
// sys_initialise_reads_twelve_words holds it.
//
// This block also owns RXON and TXON, because it owns MODE.  p. 21: RXON "is
// set when STRT is set if DRX = 0 in the MODE register and the initialization
// block has been read by the C-LANCE"; TXON is the same with DTX.  Both are
// cleared by a memory error, and TXON also by an underflow or buffer error
// during transmission - which is why they are levels an engine can pull down.

module wish7990_le_init (
    input  logic        clk,
    input  logic        rst,

    // ---- from the register file --------------------------------------------
    input  logic        stop_i,
    input  logic        strt_i,
    input  logic        init_i,     // one-cycle pulse
    input  logic [23:0] iadr_i,

    // ---- to the register file ----------------------------------------------
    output logic        idon_o,     // one-cycle set strobe
    output logic        merr_o,     // one-cycle set strobe
    output logic        rxon_o,
    output logic        txon_o,

    // ---- what the block said -----------------------------------------------
    output logic [15:0] mode_o,
    output logic [47:0] padr_o,
    output logic [63:0] ladrf_o,
    output logic [23:0] rdra_o,
    output logic [2:0]  rlen_o,
    output logic [23:0] tdra_o,
    output logic [2:0]  tlen_o,
    output logic        ready_o,    // the block has been read at least once

    // ---- the engines pull these down when they fail ------------------------
    input  logic        rx_fault_i,
    input  logic        tx_fault_i,

    // ---- memory port, into wb_arb ------------------------------------------
    output logic        bus_req_o,
    output logic        bus_we_o,
    output logic [1:0]  bus_size_o,
    output logic [3:0]  bus_sel_o,
    output logic [23:0] bus_addr_o,
    output logic [31:0] bus_wdata_o,
    input  logic        bus_ack_i,
    // Halfword reads, so only the low sixteen bits ever carry anything.
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] bus_rdata_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic        bus_err_i
);

  localparam int NWORDS = wish7990_pkg::IB_SIZE / 2;   // twelve

  typedef enum logic [1:0] { ST_IDLE, ST_READ, ST_DONE } state_e;
  state_e     state;
  logic [3:0] idx;          // which of the twelve words

  logic [15:0] w [NWORDS];

  // The read never writes, always moves a halfword, and walks the block two
  // bytes at a time.  wb_master picks the byte lanes from the address itself
  // for a halfword, so sel_o is don't-care here.
  assign bus_we_o    = 1'b0;
  assign bus_size_o  = wish7990_pkg::BUS_SZ_HALF;
  assign bus_sel_o   = 4'b0000;
  assign bus_wdata_o = 32'h0;
  assign bus_req_o   = (state == ST_READ);
  assign bus_addr_o  = iadr_i + {19'h0, idx, 1'b0};

  assign mode_o  = w[0];
  assign padr_o  = {w[3], w[2], w[1]};
  assign ladrf_o = {w[7], w[6], w[5], w[4]};
  assign rdra_o  = {w[9][7:0],  w[8]};
  assign rlen_o  = w[9][15:13];
  assign tdra_o  = {w[11][7:0], w[10]};
  assign tlen_o  = w[11][15:13];

  // p. 21: the receiver and transmitter come on when STRT is set, the block
  // has been read, and MODE does not disable them.  An engine that has failed
  // pulls its own back down without stopping the other.
  wire drx = mode_o[wish7990_pkg::MODE_DRX];
  wire dtx = mode_o[wish7990_pkg::MODE_DTX];

  logic run_rx, run_tx;
  assign rxon_o = run_rx;
  assign txon_o = run_tx;

  always_ff @(posedge clk) begin
    if (rst) begin
      state   <= ST_IDLE;
      idx     <= 4'd0;
      idon_o  <= 1'b0;
      merr_o  <= 1'b0;
      ready_o <= 1'b0;
      run_rx  <= 1'b0;
      run_tx  <= 1'b0;
      for (int i = 0; i < NWORDS; i++) w[i] <= 16'h0000;
    end else begin
      idon_o <= 1'b0;
      merr_o <= 1'b0;

      // A stop abandons whatever was in progress and puts everything out.
      // ready_o survives: CSR1 and CSR2 are preserved across a stop and so is
      // what was read with them, so a STRT after a STOP needs no second INIT.
      if (stop_i) begin
        state  <= ST_IDLE;
        run_rx <= 1'b0;
        run_tx <= 1'b0;
      end else begin
        case (state)
          ST_IDLE: begin
            if (init_i) begin
              idx   <= 4'd0;
              state <= ST_READ;
            end
          end

          ST_READ: begin
            if (bus_err_i) begin
              // p. 21: a memory error turns the receiver and transmitter off
              // and interrupts.  There is nothing sensible to keep, so the
              // block is abandoned and IDON never comes - which is exactly
              // what the driver's 10 ms timeout is there to catch.
              merr_o <= 1'b1;
              run_rx <= 1'b0;
              run_tx <= 1'b0;
              state  <= ST_IDLE;
            end else if (bus_ack_i) begin
              w[idx] <= bus_rdata_i[15:0];
              if (idx == 4'(NWORDS - 1)) begin
                idon_o  <= 1'b1;
                ready_o <= 1'b1;
                state   <= ST_DONE;
              end else begin
                idx <= idx + 4'd1;
              end
            end
          end

          default: state <= ST_IDLE;   // ST_DONE, and anything unexpected
        endcase

        // Once the block has been read, STRT brings up whichever halves MODE
        // allows.  Written as a level rather than a pulse so that a fault can
        // take one down without the other noticing.
        if (strt_i && ready_o) begin
          if (!drx && !rx_fault_i) run_rx <= 1'b1;
          if (!dtx && !tx_fault_i) run_tx <= 1'b1;
        end
        if (rx_fault_i) run_rx <= 1'b0;
        if (tx_fault_i) run_tx <= 1'b0;
      end
    end
  end

endmodule
