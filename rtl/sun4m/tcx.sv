// SPDX-License-Identifier: GPL-2.0-or-later
//
// tcx: the Sun TCX 8-bit frame buffer, as the card in SBus slot 2 (PA
// 0xE_2000_0000 on the SS20) that OpenBIOS's drivers/tcx.fs, its fast
// console (libopenbios/video_common.c) and the NetBSD/Solaris/Linux tcx
// drivers program: 1024x768, 8 bits a pixel, a Bt458-style DAC, the THC's
// 32x32 hardware cursor, and the stippler and blitter spaces.
//
// From: QEMU hw/display/tcx.c and hw/sparc/sun4m.c tcx_init (the regions
//   and their behaviour); OpenBIOS drivers/tcx.fs (the same offsets, as the
//   "reg" property) and libopenbios/video_common.c (the blit-space console
//   scroll and fills); NetBSD sys/dev/sbus/tcxreg.h (THC_MISC bits); Linux
//   drivers/video/fbdev/tcx.c (the DAC control writes); the Bt458 data
//   sheet (Brooktree 1991 databook).
//
// The slot (iob addr = byte offset in the 256 MB slot):
//   0x0000000  FCode PROM, 64 KB window (tcx_fcode: QEMU,tcx.bin, 2 KB;
//              the rest reads 0)
//   0x0200000  DAC, 16 bytes; data in bits 31:24:
//              +0 address; +4 colour map (R, G, B in turn, the entry written
//              on B and the address incremented, as the Bt458 does); +8 the
//              control register the address selects (4 read mask, reset
//              0xFF, ANDed with each pixel; 5-7 held, no effect); +C the
//              overlay colours (entry address & 3: 2 and 3 are the cursor's)
//   0x0300000  THC: +0x818 MISC (bit 10 VIDEN blanks the picture when 0;
//              bit 5 INTEN; bit 4 INTR, set at each vertical retrace,
//              written 1 to clear; the rest held; reads OR in 0x02000000
//              as QEMU does); +0x8FC cursor x (31:16), y (15:0); +0x900 the
//              32 rows of the cursor mask, +0x980 of its bits (write-only)
//   0x0800000  the 8-bit frame buffer, 1 MB (VRAM in DDR3), byte/half/word
//   0x4000000, 0xC000000  stippler (raw: the same on an 8-bit TCX)
//   0x6000000, 0xE000000  blitter (raw: the same)
//   everything else (DHC, ALT, TEC, THC24, the 24-bit and control planes)
//   reads 0 and ignores writes (QEMU's dummies).
//
// Stippler and blitter (tcx.c tcx_stip_writel/tcx_blit_writel): a store at
// offset with bit 2 clear sets the colour/fill word; one with bit 2 set
// starts an operation at pixel p = offset[22:3] (a 64-bit store does both,
// colour first). Stipple: data bit 31-i set paints pixel p+i (i < 32) with
// the colour's low byte. Blit: n = data[28:24] + 1 pixels from p; if
// data[23:16] is 0xFF they are filled with the colour's low byte (OpenBIOS
// sends 0xFFFFFF, as QEMU tests), otherwise copied from pixel data[19:0].
// A copy reads all its source before writing, so any overlap is a memmove.
// Operations are posted: the store is acked at once and any later access to
// the frame buffer or the engine waits until the operation is over.
//
// VRAM master (vram_*): CPU accesses and the engine, one doubleword at a
// time with byte enables (DDR3 has them, so no read-modify-write); a copy
// pipelines its up to 5 source reads, then writes up to 5 doublewords.
// Scan-out master (scan_*): tcx_scan's read bursts. Both are Avalon-MM in
// clk: a command presented while waitrequest is high is held unchanged
// until taken; reads return in order. Addresses are DDR word addresses
// (ss20_ddr_pkg::ddr_word of VRAM_BASE + offset).
//
// irq_o: THC_MISC INTEN and INTR (the vertical retrace interrupt the real
// THC has; QEMU wires the line but never raises it).
//
// Reset: palette and overlay colours 0 except entries 255, 256 and 258
// white (QEMU tcx_reset; loaded in the first 512 cycles, during which the
// slot holds its accesses), cursor at 0xF000,0xF000 (off screen), read
// mask 0xFF, THC_MISC = VIDEN only. QEMU always displays and resets
// THC_MISC to 0; nothing in OpenBIOS enables the video, so VIDEN starts set.

module tcx
  import iobus_pkg::*, ss20_ddr_pkg::*;
#(
  parameter int BURST = 32               // scan read burst length
)(
  input  logic        clk,
  input  logic        rst,

  /* verilator lint_off UNUSEDSIGNAL */  // (pair: no 64-bit registers here)
  input  iob_req_t    bus_i,             // addr = offset in the slot
  /* verilator lint_on UNUSEDSIGNAL */
  output iob_rsp_t    bus_o,
  output logic        irq_o,

  // VRAM: CPU and engine accesses (Avalon-MM, clk)
  output logic [28:0] vram_address,
  output logic [7:0]  vram_burstcount,
  output logic        vram_read,
  output logic        vram_write,
  output logic [63:0] vram_writedata,
  output logic [7:0]  vram_byteenable,
  input  logic        vram_waitrequest,
  input  logic [63:0] vram_readdata,
  input  logic        vram_readdatavalid,

  // scan-out (Avalon-MM read bursts, clk)
  output logic [28:0] scan_address,
  output logic [7:0]  scan_burstcount,
  output logic        scan_read,
  input  logic        scan_waitrequest,
  input  logic [63:0] scan_readdata,
  input  logic        scan_readdatavalid,

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

  wire [27:0] a = bus_i.addr;

  wire r_rom  = a[27:16] == 12'h000;
  wire r_dac  = a[27:4]  == 24'h020000;
  wire r_thc  = a[27:12] == 16'h0300;
  wire r_vram = a[27:20] == 8'h08;
  wire r_stip = a[26:23] == 4'b1000;     // 0x4000000 and 0xC000000
  wire r_blit = a[26:23] == 4'b1100;     // 0x6000000 and 0xE000000

  // ---------------------------------------------------------- the engine
  typedef enum logic [2:0] {OP_CW, OP_CR, OP_STIP, OP_FILL, OP_COPY} op_t;
  typedef enum logic [2:0] {E_IDLE, E_CW, E_CRW, E_SRC, E_DST} est_t;

  logic        eng_start;
  op_t         eng_op;
  logic [19:0] eng_dst, eng_src;
  logic [31:0] eng_mask, eng_wdata;
  logic [7:0]  eng_color;
  logic [3:0]  eng_be;
  logic        eng_busy, eng_rdone;
  logic [63:0] eng_rdata;

  est_t        est;
  logic [19:0] e_dst, e_src;
  logic [31:0] e_mask;
  logic [7:0]  e_color;
  logic        e_copy;
  logic [2:0]  e_k, e_nis, e_nret;
  // the copy's source doublewords, rb[0..4]: in MLAB (asynchronous reads),
  // one copy per read port (the destination word k takes rb[k-1] and
  // rb[k], shifted); in flops with their 5:1 muxes they cost ~250 ALMs
  (* ramstyle = "MLAB, no_rw_check" *) logic [63:0] rb_lo_m [8];
  (* ramstyle = "MLAB, no_rw_check" *) logic [63:0] rb_hi_m [8];

  function automatic logic [28:0] vword(input logic [16:0] w);
    return ddr_word(VRAM_BASE + {9'd0, w, 3'd0});
  endfunction

  // destination doubleword k of an operation: its byte enables (pixel
  // e_dst + i is bit 31 - i of the mask) and, for a copy, its data
  logic [39:0] e_ben;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [39:0] e_benk;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [7:0]  be_k;
  logic [63:0] data_k, cp_lo, cp_hi;
  logic [2:0]  sh;
  logic        adj;
  logic [3:0]  m;

  // rb[-1] and rb[5] are 0
  logic [3:0] m1;
  assign m1    = m + 4'd1;
  assign e_ben = {e_mask, 8'd0} >> e_dst[2:0];
  assign e_benk = e_ben << (8 * e_k);
  assign be_k  = e_benk[39:32];
  assign sh    = e_src[2:0] - e_dst[2:0];
  assign adj   = e_src[2:0] < e_dst[2:0];
  assign m     = {1'b0, e_k} - {3'd0, adj};                       // 4'hF for k = 0, adj = 1
  assign cp_lo = (m  < 4'd5) ? rb_lo_m[m[2:0]]  : 64'd0;
  assign cp_hi = (m1 < 4'd5) ? rb_hi_m[m1[2:0]] : 64'd0;
  always_ff @(posedge clk)
    if (est == E_SRC && vram_readdatavalid) begin
      rb_lo_m[e_nret] <= vram_readdata;
      rb_hi_m[e_nret] <= vram_readdata;
    end
  /* verilator lint_off UNUSEDSIGNAL */
  logic [127:0] cp_sh;
  /* verilator lint_on UNUSEDSIGNAL */
  assign cp_sh  = {cp_lo, cp_hi} << (8 * sh);
  assign data_k = e_copy ? cp_sh[127:64] : {8{e_color}};

  wire slot_free = !(vram_read || vram_write) || !vram_waitrequest;
  assign eng_busy = est != E_IDLE;
  assign vram_burstcount = 8'd1;

  always_ff @(posedge clk) begin
    eng_rdone <= 1'b0;
    if (rst) begin
      est <= E_IDLE;
      vram_read <= 1'b0;
      vram_write <= 1'b0;
      vram_address <= '0;
      vram_writedata <= '0;
      vram_byteenable <= '0;
      e_dst <= '0; e_src <= '0; e_mask <= '0; e_color <= '0; e_copy <= 1'b0;
      e_k <= '0; e_nis <= '0; e_nret <= '0;
      eng_rdata <= '0;
    end else begin
      if (slot_free) begin
        vram_read <= 1'b0;
        vram_write <= 1'b0;
      end
      case (est)
        E_IDLE:
          if (eng_start) begin
            e_dst <= eng_dst;
            e_src <= eng_src;
            e_mask <= eng_mask;
            e_color <= eng_color;
            e_copy <= eng_op == OP_COPY;
            e_k <= '0;
            e_nis <= '0;
            e_nret <= '0;
            case (eng_op)
              OP_CW: begin
                vram_write <= 1'b1;
                vram_address <= vword(eng_dst[19:3]);
                vram_writedata <= {eng_wdata, eng_wdata};
                vram_byteenable <= eng_dst[2] ? {4'd0, eng_be} : {eng_be, 4'd0};
                est <= E_CW;
              end
              OP_CR: begin
                vram_read <= 1'b1;
                vram_address <= vword(eng_dst[19:3]);
                est <= E_CRW;
              end
              OP_COPY: est <= E_SRC;
              default: est <= E_DST;
            endcase
          end
        E_CW:
          if (slot_free) est <= E_IDLE;
        E_CRW:
          if (vram_readdatavalid) begin
            eng_rdata <= vram_readdata;
            eng_rdone <= 1'b1;
            est <= E_IDLE;
          end
        E_SRC: begin
          if (slot_free && e_nis < 3'd5) begin
            vram_read <= 1'b1;
            vram_address <= vword(e_src[19:3] + 17'(e_nis));
            e_nis <= e_nis + 3'd1;
          end
          if (vram_readdatavalid) begin       // (the word goes into rb_*_m above)
            e_nret <= e_nret + 3'd1;
            if (e_nret == 3'd4) est <= E_DST;
          end
        end
        E_DST:
          if (slot_free) begin
            if (e_k < 3'd5) begin
              if (be_k != 8'd0) begin
                vram_write <= 1'b1;
                vram_address <= vword(e_dst[19:3] + 17'(e_k));
                vram_writedata <= data_k;
                vram_byteenable <= be_k;
              end
              e_k <= e_k + 3'd1;
            end else begin
              est <= E_IDLE;
            end
          end
        default: est <= E_IDLE;
      endcase
    end
  end

  // ------------------------------------------------- the slave registers
  typedef enum logic [2:0] {F_IDLE, F_ROM, F_DACR, F_VRAM, F_VREAD} fst_t;
  fst_t        fst;

  logic [7:0]  dac_index;
  logic [1:0]  dac_state;
  logic [7:0]  dac_ctl [4];              // Bt458 control registers 4-7
  logic [7:0]  lat_r, lat_g;
  logic [31:0] thc_misc;
  logic [15:0] cursx, cursy;
  logic [7:0]  tmpblit;                  // the colour word (only its low byte matters at 8 bits)

  logic        pal_we;
  logic [8:0]  pal_idx;
  logic [23:0] pal_rgb;
  logic        cur_we, cur_plane;
  logic [4:0]  cur_row;
  logic [31:0] cur_data;
  logic        vblank;

  logic [9:0]  init_cnt;                 // the palette's reset load
  wire         init_busy = !init_cnt[9];

  logic [31:0] rom_q;
  logic [23:0] prb_q;                    // palette read-back
  wire  [8:0]  prb_addr = a[3] ? {7'b1000000, dac_index[1:0]} : {1'b0, dac_index};  // this access's entry

  wire new_req = bus_i.req && !bus_o.ack && fst == F_IDLE && !init_busy;
  wire [7:0] d8 = bus_i.wdata[31:24];

  always_ff @(posedge clk) begin
    bus_o <= IOB_RSP_IDLE;
    eng_start <= 1'b0;
    pal_we <= 1'b0;
    cur_we <= 1'b0;
    if (rst) begin
      fst <= F_IDLE;
      dac_index <= '0;
      dac_state <= '0;
      dac_ctl[0] <= 8'hFF;
      dac_ctl[1] <= 8'h00;
      dac_ctl[2] <= 8'h00;
      dac_ctl[3] <= 8'h00;
      lat_r <= '0;
      lat_g <= '0;
      thc_misc <= 32'h0000_0400;
      cursx <= 16'hF000;
      cursy <= 16'hF000;
      tmpblit <= '0;
      init_cnt <= '0;
      pal_idx <= '0;
      pal_rgb <= '0;
      cur_plane <= 1'b0;
      cur_row <= '0;
      cur_data <= '0;
      eng_op <= OP_CW;
      eng_dst <= '0; eng_src <= '0; eng_mask <= '0; eng_wdata <= '0;
      eng_color <= '0; eng_be <= '0;
    end else begin
      if (init_busy) begin
        init_cnt <= init_cnt + 10'd1;
        pal_we <= 1'b1;
        pal_idx <= init_cnt[8:0];
        pal_rgb <= (init_cnt[8:0] == 9'd255 || init_cnt[8:0] == 9'd256 || init_cnt[8:0] == 9'd258)
                   ? 24'hFFFFFF : 24'h000000;
      end

      if (vblank) thc_misc[4] <= 1'b1;

      case (fst)
        F_IDLE:
          if (new_req) begin
            if (r_rom) begin
              if (bus_i.we) bus_o.ack <= 1'b1;
              else fst <= F_ROM;
            end else if (r_dac) begin
              if (bus_i.we) begin
                bus_o.ack <= 1'b1;
                case (a[3:2])
                  2'd0: begin dac_index <= d8; dac_state <= '0; end
                  2'd2: if (dac_index[7:2] == 6'd1) dac_ctl[dac_index[1:0]] <= d8;
                  default:                                      // colour map, overlay
                    case (dac_state)
                      2'd0: begin lat_r <= d8; dac_state <= 2'd1; end
                      2'd1: begin lat_g <= d8; dac_state <= 2'd2; end
                      default: begin
                        pal_we <= 1'b1;
                        pal_idx <= prb_addr;
                        pal_rgb <= {lat_r, lat_g, d8};
                        dac_index <= dac_index + 8'd1;
                        dac_state <= '0;
                      end
                    endcase
                endcase
              end else begin
                case (a[3:2])
                  2'd0: begin bus_o.ack <= 1'b1; bus_o.rdata <= {dac_index, 24'd0}; end
                  2'd2: begin
                    bus_o.ack <= 1'b1;
                    bus_o.rdata <= {dac_index[7:2] == 6'd1 ? dac_ctl[dac_index[1:0]] : 8'd0, 24'd0};
                  end
                  default: fst <= F_DACR;
                endcase
              end
            end else if (r_thc) begin
              bus_o.ack <= 1'b1;
              if (bus_i.we) begin
                if (a[11:2] == 10'h206) begin                    // 0x818 MISC
                  thc_misc <= {bus_i.wdata[31:5], thc_misc[4] && !bus_i.wdata[4], bus_i.wdata[3:0]};
                  if (vblank) thc_misc[4] <= 1'b1;
                end else if (a[11:2] == 10'h23F) begin           // 0x8FC cursor position
                  cursx <= bus_i.wdata[31:16];
                  cursy <= bus_i.wdata[15:0];
                end else if (a[11:8] == 4'h9) begin              // 0x900 mask, 0x980 bits
                  cur_we <= 1'b1;
                  cur_plane <= a[7];
                  cur_row <= a[6:2];
                  cur_data <= bus_i.wdata;
                end
              end else if (a[11:2] == 10'h206) begin
                bus_o.rdata <= thc_misc | 32'h0200_0000;
              end
            end else if ((r_stip || r_blit) && (!bus_i.we || !a[2])) begin
              bus_o.ack <= 1'b1;                                 // reads 0
              if (bus_i.we) tmpblit <= bus_i.wdata[7:0];
            end else if (r_vram || r_stip || r_blit) begin
              fst <= F_VRAM;
            end else begin
              bus_o.ack <= 1'b1;                                 // DHC, ALT, TEC, ...: 0
            end
          end
        F_ROM: begin
          bus_o.ack <= 1'b1;
          bus_o.rdata <= a[15:11] == 5'd0 ? rom_q : 32'd0;
          fst <= F_IDLE;
        end
        F_DACR: begin
          bus_o.ack <= 1'b1;
          case (dac_state)
            2'd0: bus_o.rdata <= {prb_q[23:16], 24'd0};
            2'd1: bus_o.rdata <= {prb_q[15:8], 24'd0};
            default: bus_o.rdata <= {prb_q[7:0], 24'd0};
          endcase
          if (dac_state >= 2'd2) begin
            dac_state <= '0;
            dac_index <= dac_index + 8'd1;
          end else begin
            dac_state <= dac_state + 2'd1;
          end
          fst <= F_IDLE;
        end
        F_VRAM:
          if (!eng_busy && !eng_start) begin
            eng_start <= 1'b1;
            eng_dst <= r_vram ? a[19:0] : a[22:3];
            eng_wdata <= bus_i.wdata;
            eng_be <= bus_i.be;
            eng_color <= tmpblit;
            if (r_vram) begin
              eng_op <= bus_i.we ? OP_CW : OP_CR;
            end else if (r_stip) begin
              eng_op <= OP_STIP;
              eng_mask <= bus_i.wdata;
            end else begin
              eng_op <= bus_i.wdata[23:16] == 8'hFF ? OP_FILL : OP_COPY;
              eng_src <= bus_i.wdata[19:0];
              eng_mask <= ~(32'hFFFF_FFFF >> ({1'b0, bus_i.wdata[28:24]} + 6'd1));
            end
            if (r_vram && !bus_i.we) begin
              fst <= F_VREAD;
            end else begin
              bus_o.ack <= 1'b1;
              fst <= F_IDLE;
            end
          end
        F_VREAD:
          if (eng_rdone) begin
            bus_o.ack <= 1'b1;
            bus_o.rdata <= a[2] ? eng_rdata[31:0] : eng_rdata[63:32];
            fst <= F_IDLE;
          end
        default: fst <= F_IDLE;
      endcase
    end
  end

  assign irq_o = thc_misc[5] && thc_misc[4];

  // ------------------------------------------------------------ the rest
  tcx_fcode u_fcode (.clk, .addr(a[10:2]), .q(rom_q));

  tcx_dcram #(.AW(9), .DW(24)) u_prb (
    .wclk(clk), .we(pal_we), .waddr(pal_idx), .wdata(pal_rgb),
    .rclk(clk), .raddr(prb_addr), .rdata(prb_q));

  tcx_scan #(.BURST(BURST)) u_scan (
    .clk, .rst,
    .scan_address, .scan_burstcount, .scan_read, .scan_waitrequest,
    .scan_readdata, .scan_readdatavalid,
    .pal_we, .pal_idx, .pal_rgb,
    .cur_we, .cur_plane, .cur_row, .cur_data,
    .cursx, .cursy, .readmask(dac_ctl[0]), .viden(thc_misc[10]),
    .vblank_o(vblank),
    .clk_vid, .vid_ce_o, .vid_r_o, .vid_g_o, .vid_b_o, .vid_hs_o, .vid_vs_o, .vid_de_o);

endmodule
