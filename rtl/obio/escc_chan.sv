// SPDX-License-Identifier: GPL-2.0-or-later
//
// escc_chan: one channel of the Z85C30 / Am85C30 SCC, the asynchronous
// modes. escc.sv holds the two channels, the registers they share (the
// pointer, WR2, WR9) and the interrupt logic.
//
// From: AMD Am8530H/Am85C30 Serial Communications Controller Technical
//   Manual (1992): §6.2 write registers (WR0 commands, WR1 interrupt modes,
//   WR3/WR4/WR5 character format and enables, WR10, WR11 clock sources,
//   WR12/WR13 time constant, WR14 BRG and loopback, WR15 external/status
//   interrupt enables), §6.3 read registers (RR0 status and the latched
//   external/status bits, RR1 special conditions, RR8, RR10, RR12/13/15),
//   §7.1.1.4 Table 7-3 reset values, §7.2 the time constant formula.
//
// What this channel does:
//  - a transmitter: WR8 buffer and a shift register; 5-8 bits, parity,
//    1/1.5/2 stop bits, send break, Tx enable (TxD marks while disabled),
//    Tx Buffer Empty and All Sent, the Tx interrupt on the buffer emptying;
//  - a receiver with the 3-deep FIFO and its error FIFO: framing errors
//    travel with the character, parity error and overrun latch until Error
//    Reset (RR1), unused bits read as 1, break detection (RR0 bit 7, both
//    edges interrupt), the four Rx interrupt modes of WR1 including the
//    first-character arming and the special condition;
//  - the baud rate generator: a 16-bit down counter on PCLK or RTxC, output
//    period 2*(TC+2); the Rx/Tx clock sources of WR11 and the x1/16/32/64
//    modes of WR4; local loopback and auto echo (WR14); auto enables (WR3);
//  - the external/status latches of RR0 bits 7:3 and their interrupt: a
//    change on an enabled condition freezes the bits until Reset
//    External/Status Interrupts.
//
// Pins are active high as the chip sees them asserted: cts_i = 1 reads as
// RR0 bit 5 = 1; rts_o/dtr_o = 1 when WR5 says asserted.
//
// Left out: the synchronous and SDLC modes, the DPLL, WR6/WR7 (stored, no
// effect), WR7', the extended read of WR3/4/5/10, the 10x19 frame FIFO, the
// Wait/Request pin, the zero count status (RR0 bit 1 reads 0), the x1 clock
// mode in the receiver (needs a synchronised clock; x16 is used instead).

module escc_chan (
  input  logic       clk,
  input  logic       hw_rst,        // hardware reset, or WR9 Force Hardware Reset
  input  logic       chn_rst,       // WR9 Channel Reset for this channel

  // Register accesses, decoded by escc.sv. ctl_* use ptr; dat_* are WR8/RR8.
  input  logic       ctl_wr,
  input  logic       ctl_rd,
  input  logic       dat_wr,
  input  logic       dat_rd,
  input  logic [3:0] ptr,
  input  logic [7:0] wdata,
  output logic [7:0] rdata,         // the register at ptr (ctl) or RR8 (dat)

  // Clocks, as single-cycle enables
  input  logic       pclk_en,       // PCLK, also RTxC
  input  logic       trxc_en,       // the TRxC pin as an input

  // Pins
  output logic       txd_o,
  input  logic       rxd_i,
  input  logic       dcd_i,
  input  logic       cts_i,
  output logic       rts_o,
  output logic       dtr_o,

  // Interrupt sources, for the chip's IP bits
  // Byte-level taps, for a host that moves whole characters (the MiSTer's
  // HPS UART): every character the transmitter
  // starts is also presented as a byte; a byte offered here enters the
  // receive FIFO as a received character (no framing or parity error) when
  // the receiver is enabled and the FIFO has room.
  output logic [7:0] tx_byte_o,
  output logic       tx_byte_valid_o,
  input  logic [7:0] rx_byte_i,
  input  logic       rx_byte_valid_i,
  output logic       rx_byte_ready_o,

  output logic       rx_cond,       // receive condition present (level)
  output logic       rx_special,    // and it is a special receive condition
  output logic       tx_ip,         // Tx IP (set/cleared here)
  output logic       ext_ip         // External/Status IP (set/cleared here)
);

  // ---------------------------------------------------------------------
  // Write registers
  // ---------------------------------------------------------------------
  logic [7:0] wr1, wr3, wr4, wr5, wr6, wr7, wr10, wr11, wr12, wr13, wr14, wr15;

  // Commands from WR0 (pulses in the write cycle)
  logic cmd_reset_ext, cmd_int_next_rx, cmd_reset_txip, cmd_error_reset, cmd_send_abort;
  logic rst_any;
  assign rst_any = hw_rst | chn_rst;

  always_comb begin
    cmd_reset_ext   = ctl_wr && ptr == 4'd0 && wdata[5:3] == 3'b010;
    cmd_send_abort  = ctl_wr && ptr == 4'd0 && wdata[5:3] == 3'b011;
    cmd_int_next_rx = ctl_wr && ptr == 4'd0 && wdata[5:3] == 3'b100;
    cmd_reset_txip  = ctl_wr && ptr == 4'd0 && wdata[5:3] == 3'b101;
    cmd_error_reset = ctl_wr && ptr == 4'd0 && wdata[5:3] == 3'b110;
  end

  always_ff @(posedge clk) begin
    if (rst_any) begin
      // Table 7-3; a channel reset leaves WR12/13 and the BRG bits alone
      wr1  <= 8'h00;
      wr3  <= {wr3[7:1], 1'b0};
      wr4  <= {wr4[7:3], 1'b1, wr4[1:0]};  // one stop bit: the SYNC pin is defined
      wr5  <= {1'b0, wr5[6:5], 4'b0000, wr5[0]};
      wr10 <= 8'h00;
      wr15 <= 8'hF8;
      wr14 <= {wr14[7:5], 3'b000, wr14[1:0]};
      if (hw_rst) begin
        wr3  <= 8'h00;
        wr4  <= 8'h04;
        wr5  <= 8'h00;
        wr11 <= 8'h08;
        wr14 <= 8'h20;                      // DPLL disabled, BRG off, source RTxC
      end
    end else if (ctl_wr) begin
      case (ptr)
        4'd1:  wr1  <= wdata;
        4'd3:  wr3  <= wdata;
        4'd4:  wr4  <= wdata;
        4'd5:  wr5  <= wdata;
        4'd6:  wr6  <= wdata;
        4'd7:  wr7  <= wdata;
        4'd10: wr10 <= wdata;
        4'd11: wr11 <= wdata;
        4'd12: wr12 <= wdata;
        4'd13: wr13 <= wdata;
        4'd14: wr14 <= wdata;
        4'd15: wr15 <= wdata;
        default: ;
      endcase
    end
  end

  // Decoded modes
  logic       rx_en, tx_en, auto_en, send_break, parity_en, parity_even;
  logic [1:0] rx_bits_sel, tx_bits_sel, stop_sel, clk_mode;
  logic       loopback, auto_echo, brg_en, brg_src_pclk;

  assign rx_en       = wr3[0];
  assign auto_en     = wr3[5];
  assign rx_bits_sel = wr3[7:6];
  assign parity_en   = wr4[0];
  assign parity_even = wr4[1];
  assign stop_sel    = wr4[3:2];
  assign clk_mode    = wr4[7:6];
  assign tx_en       = wr5[3];
  assign send_break  = wr5[4];
  assign tx_bits_sel = wr5[6:5];
  assign rts_o       = wr5[1];
  assign dtr_o       = wr5[7];
  assign auto_echo   = wr14[3];
  assign loopback    = wr14[4];
  assign brg_en      = wr14[0];
  assign brg_src_pclk = wr14[1];

  // Bits per character: 00 five, 01 seven, 10 six, 11 eight
  function automatic logic [3:0] nbits(input logic [1:0] sel);
    case (sel)
      2'b00: return 4'd5;
      2'b01: return 4'd7;
      2'b10: return 4'd6;
      default: return 4'd8;
    endcase
  endfunction

  // ---------------------------------------------------------------------
  // Baud rate generator and the clock sources
  // ---------------------------------------------------------------------
  logic [15:0] brg_cnt;
  logic        brg_out;        // the square wave
  logic        brg_tick;       // its rising edge
  logic        brg_clk;

  assign brg_clk = brg_src_pclk ? pclk_en : pclk_en;   // RTxC is PCLK's rate on a Sun

  always_ff @(posedge clk) begin
    brg_tick <= 1'b0;
    if (hw_rst) begin
      brg_cnt <= '0;
      brg_out <= 1'b0;
    end else if (!brg_en) begin
      brg_cnt <= {wr13, wr12} + 16'd1;
    end else if (brg_clk) begin
      if (brg_cnt == '0) begin
        brg_cnt  <= {wr13, wr12} + 16'd1;     // TC+2 clocks per half period
        brg_out  <= ~brg_out;
        brg_tick <= ~brg_out;
      end else begin
        brg_cnt <= brg_cnt - 16'd1;
      end
    end
  end

  // WR11: 00 RTxC, 01 TRxC, 10 BRG, 11 DPLL (as BRG here)
  logic rx_clk, tx_clk;
  always_comb begin
    case (wr11[6:5])
      2'b00: rx_clk = pclk_en;
      2'b01: rx_clk = trxc_en;
      default: rx_clk = brg_tick;
    endcase
    case (wr11[4:3])
      2'b00: tx_clk = pclk_en;
      2'b01: tx_clk = trxc_en;
      default: tx_clk = brg_tick;
    endcase
  end

  // Clock mode: clocks per bit. x1 is treated as x16 (see the header).
  logic [6:0] clks_per_bit;
  always_comb begin
    case (clk_mode)
      2'b10: clks_per_bit = 7'd32;
      2'b11: clks_per_bit = 7'd64;
      default: clks_per_bit = 7'd16;
    endcase
  end

  // ---------------------------------------------------------------------
  // Transmitter
  // ---------------------------------------------------------------------
  logic [7:0] tx_buf;
  logic       tx_buf_full;
  logic [9:0] tx_shift;        // data bits, then parity, LSB first
  logic [3:0] tx_nbits;        // bits left to send (data + parity)
  logic       tx_busy;         // shifting a character
  logic [6:0] tx_clk_cnt;      // clocks within the bit
  logic [1:0] tx_stop_left;    // half-stop-bits left: 2, 3 or 4 halves
  logic       tx_phase_stop;
  logic       tx_line;         // the serial output before break/echo
  logic       tx_all_sent;
  logic       tx_cts_ok;

  assign tx_cts_ok = ~auto_en | cts_i | loopback | auto_echo;

  // "5 or less" format (Table 6-3): the leading ones say how many bits
  function automatic logic [3:0] five_or_less(input logic [4:0] d);   // bits 7:3
    if (d == 5'b11110)      return 4'd1;
    if (d[4:1] == 4'b1110)  return 4'd2;
    if (d[4:2] == 3'b110)   return 4'd3;
    if (d[4:3] == 2'b10)    return 4'd4;
    return 4'd5;
  endfunction

  function automatic logic parity_of(input logic [7:0] d, input logic [3:0] n, input logic even);
    logic p;
    p = 1'b0;
    for (int b = 0; b < 8; b++) if (b < int'(n)) p ^= d[b];
    return even ? p : ~p;
  endfunction

  logic tx_load;               // buffer -> shift register this cycle
  logic [3:0] tx_data_n;
  assign tx_data_n = (tx_bits_sel == 2'b00) ? five_or_less(tx_buf[7:3]) : nbits(tx_bits_sel);
  assign tx_load = tx_buf_full && !tx_busy && tx_en && tx_cts_ok && tx_clk;
  assign tx_byte_o       = tx_buf;
  assign tx_byte_valid_o = tx_load;

  always_ff @(posedge clk) begin
    if (rst_any) begin
      tx_buf_full <= 1'b0;
      tx_busy     <= 1'b0;
      tx_line     <= 1'b1;
      tx_ip       <= 1'b0;
      tx_clk_cnt  <= '0;
      tx_phase_stop <= 1'b0;
      tx_stop_left <= '0;
      tx_nbits    <= '0;
      tx_shift    <= '0;
      tx_buf      <= '0;
    end else begin
      if (dat_wr || (ctl_wr && ptr == 4'd8)) begin
        tx_buf      <= wdata;
        tx_buf_full <= 1'b1;
        tx_ip       <= 1'b0;                 // writing the buffer clears the Tx IP
      end
      if (cmd_reset_txip) tx_ip <= 1'b0;
      if (cmd_send_abort) begin               // async: empties the buffer
        tx_buf_full <= 1'b0;
      end

      if (tx_load) begin
        // start bit now; the data follows at the next bit time
        tx_buf_full <= 1'b0;
        tx_busy     <= 1'b1;
        tx_line     <= 1'b0;
        tx_clk_cnt  <= 7'd1;
        tx_phase_stop <= 1'b0;
        tx_shift    <= {1'b0, parity_of(tx_buf, tx_data_n, parity_even), tx_buf};
        tx_nbits    <= tx_data_n + (parity_en ? 4'd1 : 4'd0);
        case (stop_sel)
          2'b10:   tx_stop_left <= 2'd3;      // 1.5
          2'b11:   tx_stop_left <= 2'd0;      // 2, coded as 4 halves
          default: tx_stop_left <= 2'd2;      // 1
        endcase
        if (wr1[1]) tx_ip <= 1'b1;            // the buffer became empty
      end else if (tx_busy && tx_clk) begin
        if (!tx_phase_stop) begin
          if (tx_clk_cnt == clks_per_bit - 7'd1) begin
            tx_clk_cnt <= '0;
            if (tx_nbits == '0) begin
              // start -> first data bit happened; data bits done -> stop
              tx_phase_stop <= 1'b1;
              tx_line <= 1'b1;
            end else begin
              tx_line  <= tx_shift[0];
              tx_shift <= {1'b1, tx_shift[9:1]};
              tx_nbits <= tx_nbits - 4'd1;
            end
          end else begin
            tx_clk_cnt <= tx_clk_cnt + 7'd1;
          end
        end else begin
          // stop bits, counted in halves
          if (tx_clk_cnt == (clks_per_bit >> 1) - 7'd1) begin
            tx_clk_cnt <= '0;
            if (tx_stop_left == 2'd1) begin
              tx_busy <= 1'b0;
            end else begin
              tx_stop_left <= tx_stop_left - 2'd1;
            end
          end else begin
            tx_clk_cnt <= tx_clk_cnt + 7'd1;
          end
        end
      end
    end
  end

  assign tx_all_sent = ~tx_busy & ~tx_buf_full;

  always_comb begin
    if (send_break)      txd_o = 1'b0;
    else if (auto_echo)  txd_o = rxd_i;
    else                 txd_o = tx_line;
  end

  // ---------------------------------------------------------------------
  // Receiver
  // ---------------------------------------------------------------------
  logic       rx_in;           // the line the receiver listens to
  assign rx_in = loopback ? tx_line : rxd_i;

  logic       rx_dcd_ok;
  assign rx_dcd_ok = ~auto_en | dcd_i | loopback;

  // FIFO: 3 entries of {framing, data[7:0]}
  logic [8:0] rx_fifo [3];
  logic [1:0] rx_count;
  logic       rx_pop;
  logic       rx_overrun;      // latched: RR1 bit 5
  logic       rx_parity_err;   // latched: RR1 bit 4
  logic       rx_break;        // RR0 bit 7
  logic       rx_first_armed;  // WR1 mode 01: waiting for the first character
  logic       rx_special_held; // a special condition holds the FIFO (modes 01, 11)

  logic [3:0] rx_data_n;
  assign rx_data_n = nbits(rx_bits_sel);

  assign rx_pop = (dat_rd || (ctl_rd && ptr == 4'd8)) && rx_count != '0 && !rx_special_held;

  // ---------------------------------------------------------------------
  // Receiver state machine
  // ---------------------------------------------------------------------
  typedef enum logic [1:0] {RX_IDLE, RX_START, RX_DATA, RX_STOP} rx_state_t;
  rx_state_t  rs;
  logic [6:0] rs_cnt;
  logic [3:0] rs_bit;          // bits sampled so far
  logic [8:0] rs_shift;
  logic       rs_in_q;
  logic       rs_framing;
  logic [7:0] rs_char;         // the completed character as RR8 shows it
  logic       rs_push;
  logic       rs_break_char;   // the completed character was a break (zeros + framing)

  always_ff @(posedge clk) begin
    rs_push <= 1'b0;
    if (rst_any) begin
      rs <= RX_IDLE;
      rs_cnt <= '0;
      rs_bit <= '0;
      rs_shift <= '0;
      rs_in_q <= 1'b1;
      rs_char <= '0;
      rs_framing <= 1'b0;
      rs_break_char <= 1'b0;
    end else begin
      if (rx_clk) rs_in_q <= rx_in;
      if (!rx_en || !rx_dcd_ok) begin
        rs <= RX_IDLE;
      end else if (rx_clk) begin
        case (rs)
          RX_IDLE: begin
            if (!rx_in && rs_in_q) begin       // falling edge: a start bit
              rs <= RX_START;
              rs_cnt <= 7'd1;
              rs_bit <= '0;
              rs_shift <= '0;
            end
          end
          RX_START: begin
            if (rs_cnt == (clks_per_bit >> 1)) begin
              if (rx_in) rs <= RX_IDLE;        // not a start bit after all
            end
            if (rs_cnt == clks_per_bit - 7'd1) begin
              rs_cnt <= '0;
              rs <= RX_DATA;
            end else begin
              rs_cnt <= rs_cnt + 7'd1;
            end
          end
          RX_DATA: begin
            if (rs_cnt == (clks_per_bit >> 1)) begin
              rs_shift[rs_bit] <= rx_in;
              rs_bit <= rs_bit + 4'd1;
            end
            if (rs_cnt == clks_per_bit - 7'd1) begin
              rs_cnt <= '0;
              if (rs_bit == rx_data_n + (parity_en ? 4'd1 : 4'd0)) rs <= RX_STOP;
            end else begin
              rs_cnt <= rs_cnt + 7'd1;
            end
          end
          RX_STOP: begin
            // one stop bit is checked (WR4: the receiver always checks one)
            if (rs_cnt == (clks_per_bit >> 1)) begin
              rs_framing <= ~rx_in;
              rs_char <= rs_present(rs_shift, rx_data_n + (parity_en ? 4'd1 : 4'd0));
              rs_break_char <= ~rx_in && rs_shift == '0;
              rs_push <= 1'b1;
              // a framing error adds half a bit so the error is not taken
              // as a new start bit: go idle now and resume hunting
              rs <= RX_IDLE;
              rs_cnt <= '0;
            end else begin
              rs_cnt <= rs_cnt + 7'd1;
            end
          end
          default: rs <= RX_IDLE;
        endcase
      end
    end
  end

  function automatic logic [7:0] rs_present(input logic [8:0] sh, input logic [3:0] total);
    logic [7:0] r;
    r = 8'hFF;
    for (int i = 0; i < 8; i++) if (i < int'(total)) r[i] = sh[i];
    return r;
  endfunction

  // Parity of the received bits (data and the parity bit): with even
  // parity the count of ones is even, so the XOR is 0.
  function automatic logic parity_bad_f(input logic [8:0] sh, input logic [3:0] total, input logic even);
    logic p;
    p = 1'b0;
    for (int i = 0; i < 9; i++) if (i < int'(total)) p ^= sh[i];
    return even ? p : ~p;
  endfunction

  logic rs_parity_bad;
  assign rs_parity_bad = parity_en & parity_bad_f(rs_shift, rx_data_n + 4'd1, parity_even);

  // What enters the FIFO: the line receiver's character, or a byte from the
  // byte port (the line receiver first, if both in one cycle)
  logic       fq_push, fq_framing, fq_parity_bad;
  logic [7:0] fq_char;
  assign fq_push       = rs_push | (rx_byte_valid_i & rx_en);
  assign fq_char       = rs_push ? rs_char : rx_byte_i;
  assign fq_framing    = rs_push & rs_framing;
  assign fq_parity_bad = rs_push & rs_parity_bad;
  assign rx_byte_ready_o = rx_en && rx_count != 2'd3;

  // FIFO, errors, break
  always_ff @(posedge clk) begin
    if (rst_any) begin
      rx_count       <= '0;
      rx_overrun     <= 1'b0;
      rx_parity_err  <= 1'b0;
      rx_break       <= 1'b0;
      rx_first_armed <= 1'b1;
      rx_special_held <= 1'b0;
      for (int i = 0; i < 3; i++) rx_fifo[i] <= '0;
    end else begin
      // Break: the line held low through a whole character, with the
      // framing error; released when the line returns high.
      if (rs_push && rs_break_char) rx_break <= 1'b1;
      else if (rx_break && rx_in)   rx_break <= 1'b0;

      if (cmd_error_reset) begin
        rx_overrun      <= 1'b0;
        rx_parity_err   <= 1'b0;
        rx_special_held <= 1'b0;
      end
      if (cmd_int_next_rx) rx_first_armed <= 1'b1;
      if (!rx_en) rx_first_armed <= 1'b1;

      if (fq_push && !(rs_push && rx_break && rs_break_char && rx_count != '0 && rx_fifo[rx_count-1] == 9'h100)) begin
        if (rx_count == 2'd3) begin
          rx_overrun <= 1'b1;                // the newest is overwritten
          rx_fifo[2] <= {fq_framing, fq_char};
        end else begin
          rx_fifo[rx_count] <= {fq_framing, fq_char};
          rx_count <= rx_count + 2'd1;
        end
        if (fq_parity_bad) rx_parity_err <= 1'b1;
        // In the first-character and special-only modes the data with a
        // special condition is held until Error Reset.
        if ((fq_parity_bad && wr1[2]) || fq_framing || rx_count == 2'd3) begin
          if (wr1[4:3] == 2'b01 || wr1[4:3] == 2'b11) rx_special_held <= 1'b1;
        end
      end
      if (rx_pop) begin
        rx_fifo[0] <= rx_fifo[1];
        rx_fifo[1] <= rx_fifo[2];
        rx_count   <= rx_count - 2'd1;
        if (wr1[4:3] == 2'b01) rx_first_armed <= 1'b0;   // one interrupt per arming
      end
    end
  end

  // Receive conditions for the interrupt logic
  logic rx_avail, rx_spec_now;
  assign rx_avail    = rx_count != '0;
  // special condition on the top character: its framing error, or the
  // latched parity (if special) / overrun errors
  assign rx_spec_now = rx_avail && (rx_fifo[0][8] || rx_overrun || (rx_parity_err && wr1[2]));

  always_comb begin
    rx_special = rx_spec_now;
    case (wr1[4:3])
      2'b00: rx_cond = 1'b0;
      2'b01: rx_cond = (rx_avail && rx_first_armed) || rx_spec_now;
      2'b10: rx_cond = rx_avail;
      default: rx_cond = rx_spec_now;
    endcase
  end

  // ---------------------------------------------------------------------
  // External/Status: RR0 bits 7:3 and their latch
  // ---------------------------------------------------------------------
  logic       tx_underrun;     // RR0 bit 6: set by reset, Tx disable, Send Abort; reset by WR0 cmd 11
  logic       ext_latched;
  logic [4:0] ext_live, ext_held;   // {break, underrun, cts, sync, dcd}
  logic [4:0] ext_shown;
  logic       cmd_reset_eom;
  assign cmd_reset_eom = ctl_wr && ptr == 4'd0 && wdata[7:6] == 2'b11;

  always_ff @(posedge clk) begin
    if (rst_any) tx_underrun <= 1'b1;
    else if (cmd_reset_eom && tx_en) tx_underrun <= 1'b0;
    else if (!tx_en || cmd_send_abort) tx_underrun <= 1'b1;
  end

  assign ext_live = {rx_break, tx_underrun, cts_i, 1'b0, dcd_i};
  assign ext_shown = ext_latched ? ext_held : ext_live;

  // An enabled condition changing while not latched -> latch and interrupt.
  // Break/Abort interrupts on both edges even while latched; Tx underrun
  // only on 0->1.
  logic [4:0] ext_ie, ext_prev, ext_change;
  assign ext_ie = {wr15[7], wr15[6], wr15[5], wr15[4], wr15[3]};
  assign ext_change = (ext_live ^ ext_prev) & ext_ie & {1'b1, ext_live[3], 3'b111};

  always_ff @(posedge clk) begin
    if (rst_any) begin
      ext_latched <= 1'b0;
      ext_held    <= '0;
      ext_prev    <= ext_live;
      ext_ip      <= 1'b0;
    end else begin
      ext_prev <= ext_live;
      if (cmd_reset_ext) begin
        ext_latched <= 1'b0;
        ext_ip      <= 1'b0;
      end else if (!ext_latched && ext_change != '0) begin
        ext_latched <= 1'b1;
        ext_held    <= ext_live;
        if (wr1[0]) ext_ip <= 1'b1;
      end else if (ext_latched && ext_change[4]) begin
        // a break edge while latched: still an interrupt (RR0 bit 7 text)
        ext_held[4] <= ext_live[4];
        if (wr1[0]) ext_ip <= 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------
  // Read registers
  // ---------------------------------------------------------------------
  logic [7:0] rr0, rr1, rr8;
  assign rr0 = {ext_shown[4], ext_shown[3], ext_shown[2], ext_shown[1], ext_shown[0],
                ~tx_buf_full, 1'b0, rx_avail};
  assign rr1 = {1'b0, rx_avail & rx_fifo[0][8], rx_overrun, rx_parity_err, 3'b011, tx_all_sent};
  assign rr8 = rx_avail ? rx_fifo[0][7:0] : 8'hFF;

  always_comb begin
    if (dat_rd) rdata = rr8;
    else begin
      case (ptr)
        4'd0, 4'd4:  rdata = rr0;
        4'd1, 4'd5:  rdata = rr1;
        4'd8:        rdata = rr8;
        4'd10, 4'd14: rdata = 8'h00;        // RR10: no loop, no DPLL
        4'd12:       rdata = wr12;
        4'd13, 4'd9: rdata = wr13;
        4'd15, 4'd11: rdata = wr15 & 8'hFA;  // bits 0 and 2 read 0 (no WR7', no frame FIFO)
        default:     rdata = 8'h00;         // RR2, RR3, RR6, RR7: escc.sv supplies 2 and 3
      endcase
    end
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, wr6, wr7, wr10, wr11[7], wr11[2:0], wr14[7:5], wr14[2], wr15[2:0],
                       wr1[7:5], wr5[2], wr5[0], wr3[4:1], wr4[5:4], rx_fifo[1][8], rx_fifo[2][8]};

endmodule
