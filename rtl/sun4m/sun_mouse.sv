// SPDX-License-Identifier: GPL-2.0-or-later
//
// sun_mouse: a Sun mouse (Mouse Systems 5-byte protocol) on the keyboard/
// mouse ESCC's channel B, fed by hps_io's PS/2 mouse packets.
//
// From: QEMU hw/char/escc.c (sunmouse_sync: the packet, the clamp, the
//   remainder carried over) and NetBSD sys/dev/sun/ms.c (the decoder: byte 0
//   is ~buttons in bits 2:0 with L, M, R at 2, 1, 0; dx, dy, then the second
//   halves added to them; dy positive is up, wscons' convention). hps_io's
//   PS/2 packet layout: byte 0 = {yovf, xovf, ysign, xsign, 1, M, R, L},
//   byte 1 = dx[7:0], byte 2 = dy[7:0] (PS/2's dy is positive up as well, so
//   it is passed on without a sign change).
//
// A packet is 0x80 | ~{L,M,R}, dx1, dy1, dx2, dy2. Motion is accumulated
// between reports; when it is non-zero or a button changed, a packet takes
// the accumulated motion, split over the two halves and clamped to +-127
// each (the remainder, at most a few packets' worth, stays accumulated).
// Bytes are paced at 1200 baud 8N1: BYTE_CLKS clocks per character, the
// first after the packet was started, a byte waiting while the ESCC's
// receiver is off or its FIFO full. The mouse takes no commands.

module sun_mouse #(
  parameter int CLK_HZ     = 55_000_000,
  parameter int BAUD       = 1200,
  parameter int BYTE_CLKS  = CLK_HZ * 10 / BAUD
)(
  input  logic        clk,
  input  logic        rst,

  input  logic [24:0] ps2_mouse_i,      // bytes 0-2 of the PS/2 packet, [24] toggles per packet

  // the ESCC channel B byte port (escc.sv rx_byte_b_*)
  output logic [7:0]  rx_byte_o,
  output logic        rx_byte_valid_o,
  input  logic        rx_byte_ready_i
);

  localparam int AW = 12;               // accumulator width (signed)
  localparam logic signed [AW-1:0] AMAX = 12'sd2047;

  logic               tog_q;
  logic signed [AW-1:0] acc_dx, acc_dy;
  logic [2:0]         btn;              // latest, active high: {L, M, R}
  logic [2:0]         btn_sent;

  // the packet in flight
  logic [7:0]         pkt [5];
  logic [2:0]         idx;              // next byte to hand over
  logic               busy, pend;
  logic [7:0]         pend_byte;
  logic [31:0]        baud_cnt;

  assign rx_byte_o       = pend_byte;
  assign rx_byte_valid_o = pend && rx_byte_ready_i;

  // PS/2 packet -> signed deltas (an overflow saturates at +-255)
  logic signed [AW-1:0] pdx, pdy;
  always_comb begin
    pdx = ps2_mouse_i[6] ? (ps2_mouse_i[4] ? -12'sd255 : 12'sd255)
                         : {{(AW-9){ps2_mouse_i[4]}}, ps2_mouse_i[4], ps2_mouse_i[15:8]};
    pdy = ps2_mouse_i[7] ? (ps2_mouse_i[5] ? -12'sd255 : 12'sd255)
                         : {{(AW-9){ps2_mouse_i[5]}}, ps2_mouse_i[5], ps2_mouse_i[23:16]};
  end

  function automatic logic signed [AW-1:0] sat(input logic signed [AW:0] v);
    if (v > 13'sd2047)       return AMAX;
    else if (v < -13'sd2047) return -AMAX;
    else                        return v[AW-1:0];
  endfunction

  function automatic logic signed [AW-1:0] clamp127(input logic signed [AW-1:0] v);
    if (v > 12'sd127)       return 12'sd127;
    else if (v < -12'sd127) return -12'sd127;
    else                    return v;
  endfunction

  // the halves of the accumulated motion
  logic signed [AW-1:0] dx1, dy1, dx2, dy2;
  always_comb begin
    dx1 = clamp127(acc_dx);
    dy1 = clamp127(acc_dy);
    dx2 = clamp127(acc_dx - dx1);
    dy2 = clamp127(acc_dy - dy1);
  end

  logic new_pkt, start;
  assign new_pkt = ps2_mouse_i[24] != tog_q;
  assign start   = !busy && (acc_dx != '0 || acc_dy != '0 || btn != btn_sent);

  always_ff @(posedge clk) begin
    if (rst) begin
      tog_q    <= ps2_mouse_i[24];
      acc_dx   <= '0;
      acc_dy   <= '0;
      btn      <= 3'b000;
      btn_sent <= 3'b000;
      busy     <= 1'b0;
      pend     <= 1'b0;
      idx      <= 3'd0;
      baud_cnt <= '0;
    end else begin
      tog_q <= ps2_mouse_i[24];

      // motion: what a starting packet takes out, what a new report adds
      begin : accum
        logic signed [AW:0] nx, ny;
        nx = {acc_dx[AW-1], acc_dx};
        ny = {acc_dy[AW-1], acc_dy};
        if (start) begin
          nx = nx - {{1{dx1[AW-1]}}, dx1} - {{1{dx2[AW-1]}}, dx2};
          ny = ny - {{1{dy1[AW-1]}}, dy1} - {{1{dy2[AW-1]}}, dy2};
        end
        if (new_pkt) begin
          nx = nx + {pdx[AW-1], pdx};
          ny = ny + {pdy[AW-1], pdy};
          btn <= {ps2_mouse_i[0], ps2_mouse_i[2], ps2_mouse_i[1]};   // L, M, R
        end
        acc_dx <= sat(nx);
        acc_dy <= sat(ny);
      end

      if (start) begin
        busy     <= 1'b1;
        idx      <= 3'd0;
        baud_cnt <= '0;
        btn_sent <= btn;
        pkt[0]   <= {1'b1, 4'b0000, ~btn};
        pkt[1]   <= dx1[7:0];
        pkt[2]   <= dy1[7:0];
        pkt[3]   <= dx2[7:0];
        pkt[4]   <= dy2[7:0];
      end

      if (rx_byte_valid_o) begin
        pend <= 1'b0;
        if (idx == 3'd5) busy <= 1'b0;
      end

      if (busy && !pend && idx != 3'd5) begin
        if (baud_cnt == 32'(BYTE_CLKS - 1)) begin
          pend      <= 1'b1;
          pend_byte <= pkt[idx[2:0]];
          idx       <= idx + 3'd1;
          baud_cnt  <= '0;
        end else begin
          baud_cnt <= baud_cnt + 32'd1;
        end
      end
    end
  end

  wire unused_bits = ^{ps2_mouse_i[3]};   // the PS/2 packet's always-1 bit

endmodule
