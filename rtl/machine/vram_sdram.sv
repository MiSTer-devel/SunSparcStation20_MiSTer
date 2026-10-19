// SPDX-License-Identifier: GPL-2.0-or-later
//
// vram_sdram: the TCX's two Avalon-MM masters onto the SDRAM controller
// (rtl/mister/sdram64.sv), which holds the frame buffer: 1 MB at SDRAM
// byte 0 (the rest of the module is free for a deeper frame buffer).
//
// - s_*: tcx_scan's scan-out, read bursts of a multiple of 4 beats from a
//   32-byte-aligned address; each burst becomes line reads (4 doublewords
//   each, in order: the critical doubleword of an aligned line is the
//   first). It goes first: the line buffer must not run dry.
// - v_*: the TCX's VRAM master, one doubleword at a time: a read, or a
//   write with byte enables. A write of the whole doubleword is one
//   write; a partial one is read, merged and written whole: the SDRAM's
//   DQM byte masks cannot be relied on (on the board, 2026-10-19, the
//   bytes a partial write masked were written anyway: the TCX's text came
//   out smeared while its fills were right; the HP 9000/715 core saw the
//   same with DQM in its write bursts). A write is taken when the
//   controller has its data and needs nothing more from here.
//
// Addresses are the masters' DDR word addresses (ss20_ddr_pkg::ddr_word of
// VRAM_BASE + offset): within the 1 MB VRAM, bits 16:0 are the offset's
// doubleword (VRAM_BASE is 1 MB-aligned, so ddr_word passes offset[19:3]
// through). One access at a time; waitrequest is high while busy.

module vram_sdram (
  input  logic        clk,
  input  logic        rst,
  // the scan-out master
  input  logic [28:0] s_address,
  input  logic [7:0]  s_burstcount,
  input  logic        s_read,
  output logic        s_waitrequest,
  output logic [63:0] s_readdata,
  output logic        s_readdatavalid,
  // the VRAM master (burst count 1)
  input  logic [28:0] v_address,
  input  logic        v_read,
  input  logic        v_write,
  input  logic [63:0] v_writedata,
  input  logic [7:0]  v_byteenable,
  output logic        v_waitrequest,
  output logic [63:0] v_readdata,
  output logic        v_readdatavalid,
  // sdram64's port
  output logic        ram_req,
  output logic        ram_we,
  output logic        ram_line,
  output logic [26:0] ram_addr,
  output logic [7:0]  ram_be,
  output logic [63:0] ram_wdata,
  input  logic        ram_ack,
  input  logic        ram_wready,
  input  logic        ram_rvalid,
  input  logic [63:0] ram_rdata
);

  typedef enum logic [1:0] {A_IDLE, A_SCAN, A_VRAM, A_MERGE} astate_t;
  astate_t     st;
  logic        req_pend;          // ram_req: up until the controller acks it
  logic [14:0] line;              // the scan's 32-byte line in the VRAM
  logic [5:0]  lines_left;        // after this one
  logic [1:0]  beat;              // the line's doublewords received
  logic [16:0] v_dw;
  logic        v_we;
  logic [7:0]  v_be;
  logic [63:0] v_wd;

  logic s_take, v_take;
  assign s_take = st == A_IDLE && s_read;
  assign v_take = st == A_IDLE && !s_read && (v_read || v_write);
  assign s_waitrequest = !s_take;
  assign v_waitrequest = !v_take;

  assign ram_req   = req_pend;
  assign ram_line  = st == A_SCAN;
  assign ram_we    = st == A_VRAM && v_we;   // (A_MERGE reads the doubleword first)
  assign ram_addr  = st == A_SCAN ? {7'd0, line, 5'd0} : {7'd0, v_dw, 3'd0};
  assign ram_be    = v_be;
  assign ram_wdata = v_wd;

  assign s_readdata      = ram_rdata;
  assign s_readdatavalid = st == A_SCAN && ram_rvalid;
  assign v_readdata      = ram_rdata;
  assign v_readdatavalid = st == A_VRAM && !v_we && ram_rvalid;

  always_ff @(posedge clk) begin
    if (rst) begin
      st <= A_IDLE; req_pend <= 1'b0;
      line <= '0; lines_left <= '0; beat <= '0;
      v_dw <= '0; v_we <= 1'b0; v_be <= '0; v_wd <= '0;
    end else begin
      if (ram_ack) req_pend <= 1'b0;
      case (st)
        A_IDLE: begin
          if (s_take) begin
            line <= s_address[16:2];
            lines_left <= 6'(s_burstcount[7:2] - 6'd1);
            beat <= '0;
            req_pend <= 1'b1;
            st <= A_SCAN;
          end else if (v_take) begin
            v_dw <= v_address[16:0];
            v_we <= v_write;
            v_be <= v_byteenable;
            v_wd <= v_writedata;
            req_pend <= 1'b1;
            st <= (v_write && v_byteenable != 8'hFF) ? A_MERGE : A_VRAM;
          end
        end
        A_SCAN: if (ram_rvalid) begin
          beat <= beat + 2'd1;
          if (beat == 2'd3) begin
            if (lines_left == '0) st <= A_IDLE;
            else begin
              line <= line + 15'd1;
              lines_left <= lines_left - 6'd1;
              req_pend <= 1'b1;      // the controller takes it when it is idle again
            end
          end
        end
        A_VRAM: if (v_we ? ram_wready : ram_rvalid) st <= A_IDLE;
        // a partial write: the doubleword read, the write's bytes merged
        // in, then written whole (A_VRAM)
        A_MERGE: if (ram_rvalid) begin
          for (int b = 0; b < 8; b++) if (!v_be[b]) v_wd[8*b +: 8] <= ram_rdata[8*b +: 8];
          v_be <= 8'hFF;
          req_pend <= 1'b1;
          st <= A_VRAM;
        end
        default: st <= A_IDLE;
      endcase
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_addr = ^{s_address[28:17], s_address[1:0], s_burstcount[1:0], v_address[28:17]};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
