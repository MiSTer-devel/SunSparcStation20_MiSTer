// SPDX-License-Identifier: GPL-2.0-or-later
//
// ss20_uart: ttya on the MiSTer's serial line (the HPS UART) at a fixed
// rate, whatever rate software programs into the ESCC. The ESCC's byte taps
// are used (escc_chan: the character its transmitter starts; a received
// byte into its receive FIFO), so the line rate and the guest's rate are
// independent — the "byte-level rate bridge" of VERILOG-PLAN.md §9 (phase 5
// exit note). 8N1 both ways.
//
// Transmit: each byte the ESCC starts is queued (64 deep) and sent at BAUD.
// Receive: a byte is offered to the ESCC (valid until it takes it); a
// queue of 64 holds the bytes it has not taken yet. A BREAK (the line low
// through a whole character, framing error with all zeros, as tcsendbreak
// sends) raises brk_o until the line returns high; the core holds the
// ESCC's RxD low meanwhile, which its receiver reports as a BREAK
// (hwtest's brk test).

module ss20_uart #(
  parameter int CLK_HZ = 55_000_000,
  parameter int BAUD   = 115_200
)(
  input  logic       clk,
  input  logic       rst,

  input  logic [7:0] tx_byte_i,
  input  logic       tx_valid_i,          // one cycle per byte
  output logic       txd_o,

  input  logic       rxd_i,
  output logic [7:0] rx_byte_o,
  output logic       rx_valid_o,
  input  logic       rx_ready_i,          // the ESCC takes rx_byte_o this cycle when both are high
  output logic       brk_o
);

  localparam int DIV = CLK_HZ / BAUD;
  localparam int DW  = $clog2(DIV + 1);

  // ------------------------------------------------------------- transmit
  logic [7:0] tq [64];
  logic [5:0] tq_wp, tq_rp;
  logic [6:0] tq_n;
  logic [9:0] tsh;
  logic [3:0] tbits;
  logic [DW-1:0] tdiv;

  always_ff @(posedge clk) begin
    if (rst) begin
      tq_wp <= '0; tq_rp <= '0; tq_n <= '0;
      tsh <= '1; tbits <= '0; tdiv <= '0;
      txd_o <= 1'b1;
    end else begin
      if (tx_valid_i && tq_n != 7'd64) begin
        tq[tq_wp] <= tx_byte_i;
        tq_wp <= tq_wp + 6'd1;
      end
      if (tbits == 4'd0) begin
        txd_o <= 1'b1;
        if (tq_n != 7'd0) begin
          tsh <= {1'b1, tq[tq_rp], 1'b0};
          tq_rp <= tq_rp + 6'd1;
          tbits <= 4'd10;
          tdiv <= '0;
        end
      end else begin
        txd_o <= tsh[0];
        if (tdiv == DW'(DIV - 1)) begin
          tdiv <= '0;
          tsh <= {1'b1, tsh[9:1]};
          tbits <= tbits - 4'd1;
        end else begin
          tdiv <= tdiv + 1'b1;
        end
      end
      tq_n <= tq_n + {6'd0, tx_valid_i && tq_n != 7'd64} - {6'd0, tbits == 4'd0 && tq_n != 7'd0};
    end
  end

  // -------------------------------------------------------------- receive
  logic [2:0] rs;                         // the line, synchronised
  logic       rline;
  assign rline = rs[2];
  logic [DW-1:0] rdiv;
  logic [3:0]  rbit;                      // 0 idle; 1 start; 2-9 data; 10 stop
  logic [7:0]  rsh;
  logic [7:0]  rq [64];
  logic [5:0]  rq_wp, rq_rp;
  logic [6:0]  rq_n;
  logic        push;
  logic [7:0]  push_byte;

  always_ff @(posedge clk) begin
    push <= 1'b0;
    if (rst) begin
      rs <= '1;
      rdiv <= '0; rbit <= '0; rsh <= '0;
      brk_o <= 1'b0;
      push_byte <= '0;
    end else begin
      rs <= {rs[1:0], rxd_i};
      if (brk_o && rline) brk_o <= 1'b0;
      if (rbit == 4'd0) begin
        if (!rline && !brk_o) begin rbit <= 4'd1; rdiv <= DW'(DIV / 2); end
      end else if (rdiv == DW'(DIV - 1)) begin
        rdiv <= '0;
        if (rbit == 4'd1) begin
          rbit <= rline ? 4'd0 : 4'd2;   // a glitch, not a start bit
        end else if (rbit <= 4'd9) begin
          rsh <= {rline, rsh[7:1]};
          rbit <= rbit + 4'd1;
        end else begin
          rbit <= 4'd0;
          if (rline) begin push <= 1'b1; push_byte <= rsh; end
          else if (rsh == 8'd0) brk_o <= 1'b1;   // all zeros and no stop bit: a BREAK
        end
      end else begin
        rdiv <= rdiv + 1'b1;
      end
    end
  end

  logic take;
  assign take = rx_valid_o && rx_ready_i;
  assign rx_valid_o = rq_n != 7'd0;
  assign rx_byte_o  = rq[rq_rp];
  always_ff @(posedge clk) begin
    if (rst) begin
      rq_wp <= '0; rq_rp <= '0; rq_n <= '0;
    end else begin
      if (push && rq_n != 7'd64) begin rq[rq_wp] <= push_byte; rq_wp <= rq_wp + 6'd1; end
      if (take) rq_rp <= rq_rp + 6'd1;
      rq_n <= rq_n + {6'd0, push && rq_n != 7'd64} - {6'd0, take};
    end
  end

endmodule
