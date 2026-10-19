// SPDX-License-Identifier: GPL-2.0-or-later
//
// kbd_beep: the Sun keyboard's own sounds, which on a real machine come
// from a buzzer in the keyboard: the bell (on while the host's bell-on
// command holds it, sun_kbd's bell_o) and the key click (a short tick per
// key make while click is on, sun_kbd's click_o pulse).
//
// A square wave at TONE_HZ (the Type 4/5 buzzer is roughly 2 kHz) at a
// modest amplitude for the bell, and CLICK_US of the same tone for a click.
// Output: signed 16-bit, in clk, for the machine's audio mix.

module kbd_beep #(
  parameter int CLK_HZ   = 55_000_000,
  parameter int TONE_HZ  = 2_000,
  parameter int CLICK_US = 2_000,
  parameter logic signed [15:0] AMP = 16'sd6000
)(
  input  logic        clk,
  input  logic        rst,
  input  logic        bell_i,
  input  logic        click_i,
  output logic [15:0] audio_o
);

  localparam int HALF  = CLK_HZ / (2 * TONE_HZ);            // clocks per half period
  localparam int CLICK = CLK_HZ / 1_000_000 * CLICK_US;      // clocks of one click

  logic [$clog2(HALF + 1)-1:0]  ph;
  logic                         sq;
  logic [$clog2(CLICK + 1)-1:0] ck;

  always_ff @(posedge clk) begin
    if (rst) begin
      ph <= '0; sq <= 1'b0; ck <= '0;
    end else begin
      if (ph == ($bits(ph))'(HALF - 1)) begin ph <= '0; sq <= !sq; end
      else ph <= ph + 1'b1;
      if (click_i) ck <= ($bits(ck))'(CLICK);
      else if (ck != '0) ck <= ck - 1'b1;
    end
  end

  assign audio_o = (bell_i || ck != '0) ? (sq ? AMP : -AMP) : 16'sd0;

endmodule
