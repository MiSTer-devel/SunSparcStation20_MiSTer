// SPDX-License-Identifier: GPL-2.0-or-later
//
// video_timing: a raster generator. The defaults are VESA 1024x768 at
// 60 Hz (65 MHz pixel clock, 1344 x 806 total), the TCX's resolution on
// an SS20, and the mode the empty machine shows so the OSD has a picture
// to sit on. The TCX (phase 6) scans out with the same counters.
//
// Every output is registered and they all describe the same pixel: x_o and
// y_o are its position in the active area (held at the last value in the
// blanking), de_o is high inside the active area, hs_o/vs_o are the sync
// pulses. The syncs are active high whatever the mode's VESA polarity:
// that is what the MiSTer framework (ascal, vga_out) expects from a core.
// frame_o is high for the first pixel of a frame (x = 0, y = 0).
//
// ce_i advances one pixel; tie it high for one pixel per clock.

module video_timing #(
  parameter int H_ACTIVE = 1024,
  parameter int H_FP     = 24,
  parameter int H_SYNC   = 136,
  parameter int H_BP     = 160,
  parameter int V_ACTIVE = 768,
  parameter int V_FP     = 3,
  parameter int V_SYNC   = 6,
  parameter int V_BP     = 29
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        ce_i,
  output logic [11:0] x_o,
  output logic [11:0] y_o,
  output logic        de_o,
  output logic        hs_o,
  output logic        vs_o,
  output logic        frame_o
);

  localparam int H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;
  localparam int V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;

  // h and v count the raster from the first active pixel; the outputs are
  // decoded from them one clock later.
  logic [11:0] h, v;
  wire h_last = (h == 12'(H_TOTAL - 1));
  wire v_last = (v == 12'(V_TOTAL - 1));

  always_ff @(posedge clk) begin
    if (rst) begin
      h <= '0;
      v <= '0;
    end else if (ce_i) begin
      h <= h_last ? '0 : h + 12'd1;
      if (h_last) v <= v_last ? '0 : v + 12'd1;
    end
  end

  wire h_act = (h < 12'(H_ACTIVE));
  wire v_act = (v < 12'(V_ACTIVE));

  always_ff @(posedge clk) begin
    if (rst) begin
      x_o <= '0;
      y_o <= '0;
      de_o <= 1'b0;
      hs_o <= 1'b0;
      vs_o <= 1'b0;
      frame_o <= 1'b0;
    end else if (ce_i) begin
      if (h_act) x_o <= h;
      if (v_act) y_o <= v;
      de_o <= h_act && v_act;
      hs_o <= (h >= 12'(H_ACTIVE + H_FP)) && (h < 12'(H_ACTIVE + H_FP + H_SYNC));
      // vsync starts and ends at the start of a line, as VESA times it
      vs_o <= (v >= 12'(V_ACTIVE + V_FP)) && (v < 12'(V_ACTIVE + V_FP + V_SYNC));
      frame_o <= (h == '0) && (v == '0);
    end
  end

endmodule
