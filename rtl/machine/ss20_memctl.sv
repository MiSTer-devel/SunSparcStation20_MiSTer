// SPDX-License-Identifier: GPL-2.0-or-later
//
// ss20_memctl: the slave side of the interconnect (docs/arch/bus.md,
// mem_pkg) for one master: main memory and the boot PROM in DDR3, and
// everything else through the I/O bridge (ss20_iobridge). Every write is
// broadcast on the snoop port in its ack cycle (the module's I-cache keeps
// its own module's stores coherent that way: t_selfmod).
//
// The DDR3 layout (core byte addresses; ss20_pkg::ddr_word):
//   0x0000_0000 .. RAM size   main memory, PA 0 up (at most 464 MB)
//   0x1D00_0000 .. +512 KB    the boot PROM image (ss20_loader writes it)
// The core's 512 MB sit in the MiSTer's FPGA window (ARM physical
// 0x2000_0000-0x3FFF_FFFF) upside down by megabyte: address bits 28:20 are
// inverted, so main memory starts at the top of the window and the bottom
// of it — where the framework's video scaler keeps its frame buffer — holds
// only core addresses above 0x1D80_0000, which nothing uses. (With main
// memory at the bottom, the scaler overwrote the runtime's data on the
// board while the simulation, which has no scaler, ran clean.)
// A doubleword is stored big-endian in its DDR word, as the interconnect
// carries it: byte offset 0 in bits 63:56, so data and byte enables pass
// straight through.
//
// Decoding (docs/arch/memory-map.md):
//   PA[35:32] = 0, below the RAM size   main memory; line reads as 4-beat
//                                       Avalon bursts in address order
//   PA[35:32] = 0, above it             reads 0, writes ignored (DEC-3)
//   0xF_F0xx_xxxx                       the PROM, 512 KB mirrored through the
//                                       16 MB; writes ignored
//   anything else                       the I/O bridge (which answers err for
//                                       empty slots and unassigned spaces)
// One request at a time; a request whose last ack has been given is not
// looked at again in the next cycle (the master drops it then).

module ss20_memctl
  import mem_pkg::*;
#(
  parameter logic [28:0] DDR_BASE  = 29'h0400_0000,   // word address of ARM 0x2000_0000
  parameter logic [31:0] PROM_BASE = 32'h1D00_0000,   // core byte address of the PROM image
  parameter int          PROM_WAIT = 36               // cycles before a boot-mode PROM read (below)
)(
  input  logic        clk,
  input  logic        rst,

  input  logic [9:0]  ram_mb_i,           // installed memory, MB (the OSD's option)
  input  logic [3:0]  mid_i,              // the master's module ID (snoop source)
  input  logic        boot_mode_i,        // that master is a CPU in boot mode (its MCNTL.BM)

  input  mem_req_t    req_i,
  output mem_rsp_t    rsp_o,
  output snoop_t      snoop_o,
  input  logic        snoop_hold_i,       // the module's snoop queue is nearly full: no write now

  // the I/O bridge: single beats only
  output mem_req_t    io_req_o,
  input  mem_rsp_t    io_rsp_i,

  // DDR3 (Avalon-MM master)
  input  logic        ddr_wait_i,
  output logic [7:0]  ddr_burstcnt_o,
  output logic [28:0] ddr_addr_o,
  output logic        ddr_rd_o,
  output logic        ddr_we_o,
  output logic [63:0] ddr_din_o,
  output logic [7:0]  ddr_be_o,
  input  logic [63:0] ddr_dout_i,
  input  logic        ddr_dout_ready_i,

  output logic        ram_acc_o,         // a main-memory access is accepted (req_i is it): the EMC's ECC model
  input  logic [3:0]      fix_v_i,       // ... and its corrections of that read: flip data bit
  input  logic [3:0][5:0] fix_bit_i,     //     fix_bit_i[j] of beat j when fix_v_i[j]
  output logic [2:0]  state_o            // (bring-up)
);

  // the Avalon word of a core byte address (the layout above)
  /* verilator lint_off UNUSEDSIGNAL */   // (a[2:0]: the byte within the word)
  function automatic logic [28:0] ddr_word(input logic [28:0] base, input logic [28:0] a);
    return base | {3'b000, ~a[28:20], a[19:3]};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  typedef enum logic [2:0] {S_IDLE, S_RD_CMD, S_RD_DATA, S_WR_CMD, S_IO, S_GAP} st_t;
  st_t st;

  // ---------------------------------------------------------------- decode
  logic is_ram, is_low_empty, is_prom;
  always_comb begin
    // SIMM slot 7 (PA 0x1C00_0000-0x1FFF_FFFF) holds 16 MB at most (the DDR
    // above it is the PROM, the VRAM and the scaler's): with more than
    // 448 MB it is a 16 MB SIMM repeating every 16 MB (t_mem_slot7)
    is_ram       = req_i.pa[35:32] == 4'h0 &&
                   (req_i.pa[31:26] == 6'b000111 ? ram_mb_i > 10'd448
                                                 : {2'b00, req_i.pa[31:20]} < {4'd0, ram_mb_i});
    is_low_empty = req_i.pa[35:32] == 4'h0 && !is_ram;
    is_prom      = req_i.pa[35:24] == 12'hFF0;
  end

  logic [28:0] word_now;
  assign word_now = is_prom ? ddr_word(DDR_BASE, PROM_BASE[28:0] | {10'd0, req_i.pa[18:0]})
                            : ddr_word(DDR_BASE, req_i.pa[28:26] == 3'b111 ? {3'b111, 2'b00, req_i.pa[23:0]}
                                                                           : req_i.pa[28:0]);

  // ------------------------------------------------- reads in flight
  // DDR returns a read's beats however the machine is reset meanwhile, so
  // the beats owed are counted apart from rst: a reset in the middle of a
  // read (nvram_sd's ready drops when Main mounts the NVRAM image after the
  // machine started; a software reset) must not leave the next read
  // taking the old one's data, or waiting for beats already gone (the
  // board's first fetch hung so). A read is issued only when none is owed.
  /* verilator lint_off PROCASSINIT */
  logic [3:0] owed = 4'd0;             // (a power-up value: never reset)
  /* verilator lint_on PROCASSINIT */
  // A read the DDR port accepted but never answers (seen on the board for
  // the first fetch after a core load: the framework's DDR bridge was still
  // in its reset handling, which passes waitrequest through but drops the
  // command) is forgotten after 2^16 cycles (~1.2 ms, far beyond any real
  // latency) and issued again.
  logic [15:0] rd_wait;
  logic        forget;
  assign forget = &rd_wait;
  always_ff @(posedge clk) begin
    if (forget) owed <= 4'd0;
    else owed <= owed + ((ddr_rd_o && !ddr_wait_i) ? 4'(ddr_burstcnt_o) : 4'd0) - {3'd0, ddr_dout_ready_i};
    if (owed == 4'd0 || ddr_dout_ready_i || forget) rd_wait <= '0;
    else rd_wait <= rd_wait + 16'd1;
  end

  // ------------------------------------------------------------- the FSM
  logic [28:0] a_q;
  logic [2:0]  beats_left;
  logic        burst_q;
  logic        ram_q;                     // the request is main memory (the EMC's corrections apply)

  // A boot-PROM read by a CPU in boot mode waits PROM_WAIT cycles first:
  // the real machine's byte-wide EPROM takes about 0.7 us an instruction,
  // and OBP 2.25's POST, which runs in boot mode, times its counter/timer
  // test with instruction loops (post-tests.md "PROCn Counter/Timer
  // Test": a 2.1 s count within 0x80000 loop passes). Out of boot mode
  // (OBP after the POST, an OS's PROM calls) the PROM is read at full
  // speed. Simulation: +prom_wait=N replaces PROM_WAIT (0: no wait).
  logic [7:0]  prom_wait, pw_cnt;
`ifndef SYNTHESIS
  initial begin
    logic [7:0] n;
    if (!$value$plusargs("prom_wait=%d", n)) n = 8'(PROM_WAIT);
    prom_wait = n;
  end
`else
  assign prom_wait = 8'(PROM_WAIT);
`endif
  // the beat a read is at (a burst's in address order), for the EMC's
  // corrections
  logic [1:0] beat;
  assign beat = burst_q ? 2'(3'd4 - beats_left) : 2'd0;


  // A DDR command, once presented, is held unchanged until the port takes
  // it, whatever rst does (Avalon; a command withdrawn or changed while
  // waitrequest is up wedged the board's DDR port): rst is taken outside
  // the command states only, and the write's data and enables are
  // registered (the CPU's request changes when it is reset).
  logic [63:0] wd_q;
  logic [7:0]  be_q;

  always_ff @(posedge clk) begin
    rsp_o <= '0;
    snoop_o <= '0;
    if (rst && st != S_RD_CMD && st != S_WR_CMD) begin
      st <= S_IDLE;
      a_q <= '0; beats_left <= '0; burst_q <= 1'b0; ram_q <= 1'b0; pw_cnt <= '0;
    end else begin
      case (st)
        S_IDLE: begin
          if (req_i.valid) begin
            a_q <= word_now;
            ram_q <= is_ram;
            burst_q <= req_i.burst;
            if (is_ram && !req_i.write) begin
              beats_left <= req_i.burst ? 3'd4 : 3'd1;
              st <= S_RD_CMD;
            end else if (is_prom && !req_i.write) begin
              beats_left <= req_i.burst ? 3'd4 : 3'd1;
              pw_cnt <= boot_mode_i ? prom_wait : 8'd0;
              st <= S_RD_CMD;
            end else if (is_ram && req_i.write) begin
              wd_q <= req_i.wdata;
              be_q <= req_i.be;
              if (!snoop_hold_i) st <= S_WR_CMD;
            end else if (is_low_empty || is_prom) begin
              // reads 0 (a burst gives four zero beats), writes are ignored
              if (!(req_i.write && snoop_hold_i)) begin
                rsp_o.ack <= 1'b1;
                if (req_i.write) begin
                  snoop_o.valid <= 1'b1; snoop_o.line <= req_i.pa[35:5]; snoop_o.mid <= mid_i;
                end
                if (req_i.burst && !req_i.write) begin
                  beats_left <= 3'd3;
                  st <= S_RD_DATA;          // three more zero beats, below
                end else begin
                  st <= S_GAP;
                end
              end
            end else begin
              if (!(req_i.write && snoop_hold_i)) st <= S_IO;
            end
          end
        end
        S_RD_CMD: if (pw_cnt != 8'd0) pw_cnt <= pw_cnt - 8'd1;
                  else if (!ddr_wait_i && owed == 4'd0) st <= rst ? S_IDLE : S_RD_DATA;   // (in reset: its beats are only counted)
        S_RD_DATA: begin
          if (is_low_empty) begin
            // the zero beats of a burst beyond the memory
            rsp_o.ack <= 1'b1;
            beats_left <= beats_left - 3'd1;
            if (beats_left == 3'd1) st <= S_GAP;
          end else if (ddr_dout_ready_i) begin
            rsp_o.ack <= 1'b1;
            rsp_o.rdata <= ddr_dout_i ^ (ram_q && fix_v_i[beat] ? 64'd1 << fix_bit_i[beat] : 64'd0);
            beats_left <= beats_left - 3'd1;
            if (beats_left == 3'd1) st <= S_GAP;
          end else if (forget) begin
            st <= S_RD_CMD;               // the read was lost: again, for the beats still owed
          end
        end
        S_WR_CMD: begin
          if (!ddr_wait_i) begin
            rsp_o.ack <= !rst;
            snoop_o.valid <= !rst; snoop_o.line <= req_i.pa[35:5]; snoop_o.mid <= mid_i;
            st <= rst ? S_IDLE : S_GAP;
          end
        end
        S_IO: begin
          if (io_rsp_i.ack || io_rsp_i.err) begin
            rsp_o <= io_rsp_i;
            rsp_o.ack <= 1'b1;            // err comes with ack (bus.md)
            if (req_i.write && !io_rsp_i.err) begin
              snoop_o.valid <= 1'b1; snoop_o.line <= req_i.pa[35:5]; snoop_o.mid <= mid_i;
            end
            st <= S_GAP;
          end
        end
        default: st <= S_IDLE;            // S_GAP: the master drops the finished request
      endcase
    end
  end

  assign state_o = st;
  assign ram_acc_o = st == S_IDLE && req_i.valid && is_ram && !(req_i.write && snoop_hold_i);

  // ---------------------------------------------------------- the ports
  always_comb begin
    ddr_burstcnt_o = burst_q ? 8'd4 : 8'd1;
    ddr_addr_o     = a_q;
    ddr_rd_o       = st == S_RD_CMD && owed == 4'd0 && pw_cnt == 8'd0;   // the old read's beats first
    ddr_we_o       = st == S_WR_CMD;
    ddr_din_o      = wd_q;
    ddr_be_o       = be_q;
    io_req_o       = req_i;
    io_req_o.valid = st == S_IO;
  end

`ifndef SYNTHESIS
  // +promlog: every 10M cycles, the memory requests each master started
  // (MID 8 + n = CPU n), how many were boot-PROM reads and how many of
  // those waited (boot mode), and how busy this controller was
  // (simulation)
  logic        promlog;
  int unsigned pl_cyc, pl_busy, pl_rd [16], pl_wt [16], pl_all [16], pl_wr [16], pl_ln [16];
  initial begin
    promlog = $test$plusargs("promlog");
    pl_cyc = 0; pl_busy = 0;
    for (int i = 0; i < 16; i++) begin pl_rd[i] = 0; pl_wt[i] = 0; pl_all[i] = 0; pl_wr[i] = 0; pl_ln[i] = 0; end
  end
  /* verilator lint_off BLKSEQ */
  always_ff @(posedge clk) begin
    if (promlog) begin
      if (st != S_IDLE) pl_busy = pl_busy + 1;
      if (st == S_IDLE && req_i.valid) begin
        pl_all[mid_i] = pl_all[mid_i] + 1;
        if (req_i.write) pl_wr[mid_i] = pl_wr[mid_i] + 1;
        else if (req_i.burst) pl_ln[mid_i] = pl_ln[mid_i] + 1;
        if (is_prom && !req_i.write) begin
          pl_rd[mid_i] = pl_rd[mid_i] + 1;
          if (boot_mode_i) pl_wt[mid_i] = pl_wt[mid_i] + 1;
        end
      end
      pl_cyc = pl_cyc + 1;
      if (pl_cyc % 10000000 == 0) begin
        $display("promlog %0dM: requests cpu0 %0d (%0d writes, %0d line reads) cpu1 %0d (%0d, %0d) dvma %0d; PROM reads cpu0 %0d (%0d waited), cpu1 %0d (%0d waited); memctl busy %0d%% (%0d cycles a request)",
                 pl_cyc / 1000000, pl_all[8], pl_wr[8], pl_ln[8], pl_all[9], pl_wr[9], pl_ln[9], pl_all[0],
                 pl_rd[8], pl_wt[8], pl_rd[9], pl_wt[9], pl_busy / 100000,
                 (pl_all[8] + pl_all[9] + pl_all[0]) != 0 ? pl_busy / (pl_all[8] + pl_all[9] + pl_all[0]) : 0);
        pl_busy = 0;
        for (int i = 0; i < 16; i++) begin pl_rd[i] = 0; pl_wt[i] = 0; pl_all[i] = 0; pl_wr[i] = 0; pl_ln[i] = 0; end
      end
    end
  end
  /* verilator lint_on BLKSEQ */
`endif

endmodule
