// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_video_timing: the raster generator's frame against its parameters, in
// a tiny mode with a pixel every other clock (ce_i) and in the default VESA
// 1024x768 mode with a pixel every clock. For each, over two frames: pixels
// and lines per frame, the active area's size, x/y at every active pixel,
// the sync pulses' positions and widths, and frame_o.

module vt_check #(
  parameter int H_ACTIVE = 1024, parameter int H_FP = 24, parameter int H_SYNC = 136, parameter int H_BP = 160,
  parameter int V_ACTIVE = 768,  parameter int V_FP = 3,  parameter int V_SYNC = 6,   parameter int V_BP = 29,
  parameter int CE_DIV = 1, parameter string NAME = "vesa"
) (
  input logic clk,
  output logic done
);
  import tb_pkg::*;

  localparam int H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;
  localparam int V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;

  logic rst;
  logic ce;
  int unsigned div;
  always_ff @(posedge clk) begin
    if (rst) div <= 0;
    else div <= (div == CE_DIV - 1) ? 0 : div + 1;
  end
  assign ce = (div == 0);

  logic [11:0] x, y;
  logic de, hs, vs, frame;
  video_timing #(.H_ACTIVE(H_ACTIVE), .H_FP(H_FP), .H_SYNC(H_SYNC), .H_BP(H_BP),
                 .V_ACTIVE(V_ACTIVE), .V_FP(V_FP), .V_SYNC(V_SYNC), .V_BP(V_BP)) dut (
    .clk, .rst, .ce_i(ce), .x_o(x), .y_o(y), .de_o(de), .hs_o(hs), .vs_o(vs), .frame_o(frame));

  int frames;                    // frame_o pulses seen; counting starts at the first
  int pix, des, lines, line_pix, hs_len, vs_lines;
  logic hs_q, vs_q, ce_now;

  // One sample per pixel: the outputs change only at an edge where ce was
  // high, so look just after each such edge.
  initial begin
    done = 1'b0; rst = 1'b1; frames = -1; hs_q = 1'b0; vs_q = 1'b0;
    pix = 0; des = 0; lines = 0; line_pix = 0; hs_len = 0; vs_lines = 0;
    repeat (5) @(posedge clk);
    #1 rst = 1'b0;
    while (!done) begin
      ce_now = ce;
      @(posedge clk);
      #1;
      if (!ce_now) continue;
      if (frame) begin
        if (frames >= 0) begin
          check(pix == H_TOTAL * V_TOTAL, $sformatf("%s: %0d pixels in a frame", NAME, pix));
          check(des == H_ACTIVE * V_ACTIVE, $sformatf("%s: %0d active pixels in a frame", NAME, des));
          check(lines + 1 == V_TOTAL, $sformatf("%s: %0d lines in a frame", NAME, lines + 1));
          check(vs_lines == V_SYNC, $sformatf("%s: vsync %0d lines", NAME, vs_lines));
        end
        check(de && x == 0 && y == 0, $sformatf("%s: frame_o on the first active pixel", NAME));
        frames++;
        pix = 0; des = 0; lines = 0; vs_lines = 0; line_pix = 0;
        if (frames == 2) done = 1'b1;
      end
      if (frames < 0 || done) continue;
      pix++;
      // a line starts with its first active pixel (h = 0)
      if (line_pix == H_TOTAL) begin
        line_pix = 0;
        lines++;
      end
      if (line_pix == 0 && vs) vs_lines++;
      if (de) begin
        des++;
        check(x == 12'(line_pix) && y == 12'(lines),
              $sformatf("%s: x/y %0d/%0d at pixel %0d of line %0d", NAME, x, y, line_pix, lines));
        check(line_pix < H_ACTIVE && lines < V_ACTIVE, $sformatf("%s: de outside the active area", NAME));
      end else begin
        check(!(line_pix < H_ACTIVE && lines < V_ACTIVE), $sformatf("%s: de low inside the active area", NAME));
      end
      if (hs && !hs_q) begin
        hs_len = 0;
        check(line_pix == H_ACTIVE + H_FP, $sformatf("%s: hsync at pixel %0d", NAME, line_pix));
      end
      if (hs) hs_len++;
      if (!hs && hs_q) check(hs_len == H_SYNC, $sformatf("%s: hsync %0d pixels", NAME, hs_len));
      if (vs && !vs_q) check(lines == V_ACTIVE + V_FP && line_pix == 0,
                             $sformatf("%s: vsync at line %0d pixel %0d", NAME, lines, line_pix));
      line_pix++;
      hs_q = hs; vs_q = vs;
    end
  end
endmodule

module tb_video_timing;
  import tb_pkg::*;

  logic clk;
  initial clk = 1'b0;
  always #5 clk = ~clk;

  logic done_small, done_vesa;

  vt_check #(.H_ACTIVE(8), .H_FP(2), .H_SYNC(3), .H_BP(2), .V_ACTIVE(4), .V_FP(1), .V_SYNC(2), .V_BP(1),
             .CE_DIV(2), .NAME("small")) u_small (.clk, .done(done_small));
  vt_check #(.NAME("vesa")) u_vesa (.clk, .done(done_vesa));

  initial begin
    wait (done_small && done_vesa);
    tb_done("tb_video_timing");
  end

  initial begin
    #100ms;
    $display("FAIL: timed out");
    $fatal(1, "timeout");
  end
endmodule
