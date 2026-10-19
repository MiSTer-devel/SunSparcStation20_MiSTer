// SPDX-License-Identifier: GPL-2.0-or-later
//
// tcx_scan: the TCX's scan-out. Reads the 8-bit frame buffer from DDR3 a
// line ahead of the raster, looks each pixel up in the palette, lays the
// THC's hardware cursor over it and drives the video outputs at 1024x768,
// 60 Hz (rtl/video/video_timing.sv's raster).
//
// From: QEMU hw/display/tcx.c (tcx_draw_line32, tcx_draw_cursor32: a 32x32
//   cursor of two planes, mask and bits; mask 1 shows overlay colour 3
//   where bits is 1 and 2 where it is 0, i.e. palette[259]/[258]; rows
//   y - cursy, the leftmost pixel in bit 31); the Bt458 data sheet
//   (Brooktree 1991 databook: the read mask ANDed with the pixel before
//   the colour lookup); NetBSD sys/dev/sbus/tcxreg.h (THC_MISC_VIDEN).
//
// Two clocks. clk (the machine) fetches: line n of VRAM (1024 bytes, 128
// doublewords at VRAM_BASE + n*1024) goes into slot n mod 2 of a dual-clock
// line buffer, in read bursts of BURST beats issued back to back on the
// scan_* Avalon master (address, burstcount and read held while
// waitrequest; every burst is taken to its last beat; data in order).
// clk_vid (the pixel clock) displays: at the start of line n's horizontal
// sync it asks for line n+2 (whose slot line n has just finished reading),
// so a fetch has 1640 pixel times (25 us, ~1380 clk cycles at 55 MHz) to
// land.
//
// Clock crossings (each a false path / max-delay for the SDC):
//  - line requests: a toggle (req_tog_v) through two clk flops; its line
//    number (req_line_v) changes in the same clk_vid edge as the toggle and
//    is sampled by clk only after the synchronised toggle has moved;
//  - frame snapshot: at vertical sync clk_vid toggles snap_tog_v; clk copies
//    the cursor position, read mask and video enable into xfer_c and
//    toggles ack_tog_c back; clk_vid loads its shadows from xfer_c when the
//    synchronised ack moves (xfer_c is still by then). So those controls
//    change between frames, never mid-picture. vblank_o pulses in clk then;
//  - the palette and the cursor bitmaps are dual-clock RAMs written in clk,
//    read in clk_vid: a write during the picture shows from that pixel on,
//    as on the real DAC;
//  - rst reaches clk_vid through two flops.
//
// Interface contract: pal_we writes palette entry pal_idx (0-255 the colour
// map, 256-259 the overlay/cursor colours) with {r, g, b}; cur_we writes
// row cur_row of cursor plane cur_plane (0 mask, 1 bits); cursx/cursy, the
// THC's 16-bit cursor position, readmask and viden are levels.

module tcx_scan
  import ss20_ddr_pkg::*;
#(
  parameter int BURST = 32               // beats per scan read burst (divides 128)
)(
  input  logic        clk,
  input  logic        rst,

  // the scan-out master (clk)
  output logic [28:0] scan_address,
  output logic [7:0]  scan_burstcount,
  output logic        scan_read,
  input  logic        scan_waitrequest,
  input  logic [63:0] scan_readdata,
  input  logic        scan_readdatavalid,

  // the DAC and THC state (clk)
  input  logic        pal_we,
  input  logic [8:0]  pal_idx,
  input  logic [23:0] pal_rgb,
  input  logic        cur_we,
  input  logic        cur_plane,
  input  logic [4:0]  cur_row,
  input  logic [31:0] cur_data,
  input  logic [15:0] cursx,
  input  logic [15:0] cursy,
  input  logic [7:0]  readmask,
  input  logic        viden,
  output logic        vblank_o,          // one clk cycle per frame, at vertical sync

  // video (clk_vid)
  input  logic        clk_vid,
  output logic        vid_ce_o,
  output logic [7:0]  vid_r_o,
  output logic [7:0]  vid_g_o,
  output logic [7:0]  vid_b_o,
  output logic        vid_hs_o,
  output logic        vid_vs_o,
  output logic        vid_de_o
);

  localparam int H_ACTIVE = 1024, H_FP = 24, H_SYNC = 136, H_BP = 160;
  localparam int V_ACTIVE = 768,  V_FP = 3,  V_SYNC = 6,   V_BP = 29;
  localparam int V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;
  localparam int NCMD     = 128 / BURST;

  // ======================================================== clk_vid side
  logic [1:0] rst_vid_s;
  always_ff @(posedge clk_vid) rst_vid_s <= {rst_vid_s[0], rst};
  wire rst_vid = rst_vid_s[1];

  logic [11:0] x;
  /* verilator lint_off UNUSEDSIGNAL */   // (y: only the slot bit; vl1/vl2 count the lines)
  logic [11:0] y;
  /* verilator lint_on UNUSEDSIGNAL */
  logic        de, hs, vs, frame;
  video_timing #(
    .H_ACTIVE(H_ACTIVE), .H_FP(H_FP), .H_SYNC(H_SYNC), .H_BP(H_BP),
    .V_ACTIVE(V_ACTIVE), .V_FP(V_FP), .V_SYNC(V_SYNC), .V_BP(V_BP)
  ) u_timing (
    .clk(clk_vid), .rst(rst_vid), .ce_i(1'b1),
    .x_o(x), .y_o(y), .de_o(de), .hs_o(hs), .vs_o(vs), .frame_o(frame));

  // the raster's next line and the one after (mod V_TOTAL), blanking
  // included (video_timing holds y_o in the blanking)
  logic [9:0] vl1, vl2;
  logic       hs_d, vs_d;
  wire hs_rise = hs && !hs_d;
  wire vs_rise = vs && !vs_d;

  function automatic logic [9:0] line_plus(input logic [9:0] l, input logic [1:0] k);
    logic [10:0] t;
    t = 11'(l) + {9'd0, k};
    if (t >= 11'(V_TOTAL)) t = t - 11'(V_TOTAL);
    return t[9:0];
  endfunction


  logic       req_tog_v, snap_tog_v;
  logic [9:0] req_line_v;

  // shadows of the clk-domain controls, loaded between frames
  logic [15:0] cx_s, cy_s;
  logic [7:0]  rm_s;
  logic        ven_s;
  logic [2:0]  ack_s;
  logic [40:0] xfer_c;                   // {cursx, cursy, readmask, viden}, clk

  // the cursor rows of the line about to be drawn
  logic        cf1, cf2, cl_on_n, cl_on;
  logic [4:0]  cr_addr;
  logic [31:0] cm_q, cb_q, cl_mask, cl_bits;

  always_ff @(posedge clk_vid) begin
    if (rst_vid) begin
      vl1 <= 10'd1;
      vl2 <= 10'd2;
      hs_d <= 1'b0;
      vs_d <= 1'b0;
      req_tog_v <= 1'b0;
      req_line_v <= '0;
      snap_tog_v <= 1'b0;
      ack_s <= '0;
      cx_s <= 16'hF000;
      cy_s <= 16'hF000;
      rm_s <= 8'hFF;
      ven_s <= 1'b0;
      cf1 <= 1'b0;
      cf2 <= 1'b0;
      cl_on_n <= 1'b0;
      cl_on <= 1'b0;
      cr_addr <= '0;
      cl_mask <= '0;
      cl_bits <= '0;
    end else begin
      hs_d <= hs;
      vs_d <= vs;
      if (frame) begin
        vl1 <= 10'd1;
        vl2 <= 10'd2;
      end else if (hs_rise) begin
        vl1 <= vl2;
        vl2 <= line_plus(vl2, 2'd1);
      end

      // ask for line vl2 (its slot is this line's, just drawn)
      if (hs_rise && vl2 < 10'(V_ACTIVE)) begin
        req_line_v <= vl2;
        req_tog_v <= ~req_tog_v;
      end

      // the cursor rows for line vl1, read in the horizontal blanking
      cf1 <= hs_rise;
      cf2 <= cf1;
      if (hs_rise) begin
        cl_on_n <= {6'd0, vl1} >= cy_s && {6'd0, vl1} - cy_s < 16'd32;
        cr_addr <= vl1[4:0] - cy_s[4:0];
      end
      if (cf2) begin
        cl_on <= cl_on_n;
        cl_mask <= cm_q;
        cl_bits <= cb_q;
      end

      if (vs_rise) snap_tog_v <= ~snap_tog_v;
      ack_s <= {ack_s[1:0], ack_tog_c};
      if (ack_s[2] != ack_s[1])
        {cx_s, cy_s, rm_s, ven_s} <= xfer_c;
    end
  end

  // ---- the pixel pipeline: S0 video_timing, S1 line buffer, S2 palette
  logic [63:0] lb_q;
  logic [23:0] pal_q;
  logic        c1_show, c1_bit;
  logic [2:0]  x1;
  logic [1:0]  de_p, hs_p, vs_p;
  logic [8:0]  pal_raddr;
  logic [16:0] dx;
  logic [7:0]  pix;

  assign dx = {5'd0, x} - {1'b0, cx_s};

  always_ff @(posedge clk_vid) begin
    c1_show <= de && cl_on && !dx[16] && dx[15:5] == '0 && cl_mask[~dx[4:0]];
    c1_bit  <= cl_bits[~dx[4:0]];
    x1      <= x[2:0];
    de_p    <= {de_p[0], de};
    hs_p    <= {hs_p[0], hs};
    vs_p    <= {vs_p[0], vs};
  end

  assign pix = lb_q[8 * (7 - x1) +: 8] & rm_s;
  assign pal_raddr = c1_show ? {7'b1000000, 1'b1, c1_bit} : {1'b0, pix};

  always_ff @(posedge clk_vid) begin
    vid_hs_o <= hs_p[1];
    vid_vs_o <= vs_p[1];
    vid_de_o <= de_p[1];
    if (de_p[1] && ven_s)
      {vid_r_o, vid_g_o, vid_b_o} <= pal_q;
    else
      {vid_r_o, vid_g_o, vid_b_o} <= '0;
  end
  assign vid_ce_o = 1'b1;

  // ============================================================ clk side
  logic [2:0] req_s, snap_s;
  logic       ack_tog_c;
  logic       pend, busy;
  logic [9:0] pend_line;
  logic       slot;                     // the line buffer slot being filled
  logic [$clog2(NCMD+1)-1:0] ncmd;
  logic [6:0] beat;

  always_ff @(posedge clk) begin
    vblank_o <= 1'b0;
    if (rst) begin
      req_s <= '0;
      snap_s <= '0;
      ack_tog_c <= 1'b0;
      xfer_c <= {16'hF000, 16'hF000, 8'hFF, 1'b0};
      pend <= 1'b0;
      pend_line <= '0;
      busy <= 1'b0;
      slot <= 1'b0;
      ncmd <= '0;
      beat <= '0;
      scan_read <= 1'b0;
      scan_address <= '0;
    end else begin
      req_s <= {req_s[1:0], req_tog_v};
      snap_s <= {snap_s[1:0], snap_tog_v};

      if (snap_s[2] != snap_s[1]) begin
        xfer_c <= {cursx, cursy, readmask, viden};
        ack_tog_c <= ~ack_tog_c;
        vblank_o <= 1'b1;
      end

      // a request while a fetch runs waits (the newest one wins)
      if (req_s[2] != req_s[1]) begin
        pend <= 1'b1;
        pend_line <= req_line_v;
      end

      if (scan_read && !scan_waitrequest) begin
        ncmd <= ncmd + 1'b1;
        scan_address <= scan_address + 29'(BURST);
        if (ncmd == $bits(ncmd)'(NCMD - 1)) scan_read <= 1'b0;
      end

      if (scan_readdatavalid) begin
        beat <= beat + 1'b1;
        if (beat == 7'd127) busy <= 1'b0;
      end

      if (!busy && pend && !(req_s[2] != req_s[1])) begin
        busy <= 1'b1;
        pend <= 1'b0;
        slot <= pend_line[0];
        ncmd <= '0;
        beat <= '0;
        scan_read <= 1'b1;
        scan_address <= ddr_word(VRAM_BASE + {9'd0, pend_line, 10'd0});
      end
    end
  end

  assign scan_burstcount = 8'(BURST);

  // ============================================================== RAMs
  tcx_dcram #(.AW(8), .DW(64)) u_line (
    .wclk(clk), .we(scan_readdatavalid), .waddr({slot, beat}), .wdata(scan_readdata),
    .rclk(clk_vid), .raddr({y[0], x[9:3]}), .rdata(lb_q));

  tcx_dcram #(.AW(9), .DW(24)) u_pal (
    .wclk(clk), .we(pal_we), .waddr(pal_idx), .wdata(pal_rgb),
    .rclk(clk_vid), .raddr(pal_raddr), .rdata(pal_q));

  tcx_dcram #(.AW(5), .DW(32)) u_cmask (
    .wclk(clk), .we(cur_we && !cur_plane), .waddr(cur_row), .wdata(cur_data),
    .rclk(clk_vid), .raddr(cr_addr), .rdata(cm_q));

  tcx_dcram #(.AW(5), .DW(32)) u_cbits (
    .wclk(clk), .we(cur_we && cur_plane), .waddr(cur_row), .wdata(cur_data),
    .rclk(clk_vid), .raddr(cr_addr), .rdata(cb_q));

endmodule
