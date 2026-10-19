// SPDX-License-Identifier: GPL-2.0-or-later
//
// slavio_timer: the sun4m counter/timers (the SLAVIO's timer section).
//
// One system counter (level-10 interrupt) and one counter per processor
// (level-14, directed to that processor, or a 64-bit User Timer with no
// interrupt). Occupies the 1 MB at PA 0xF_F130_0000: processor N's
// registers at N*0x1000, the system counter's at 0x10000.
//
// From: Sun-4M System Architecture, 950-1373-01 Rev 50, §3.2.2.2.2 (the
//   address map), §5.3 Counter-Timer Registers and User Timers, §12 (reset);
//   NCR89C105 (SLAVIO) specification, "Counter-Timers" (figures 6-14 to
//   6-18). Cross-checked with QEMU hw/timer/slavio_timer.c and NetBSD
//   sys/arch/sparc/sparc/timerreg.h (tmr_ustolim4m: limit = 2*us + 1).
//
// Registers (word offsets within a set):
//   +0  Limit (RW): bits 30:9 the limit, bit 31 L (limit reached). Writing
//       sets the count to 0x200 (one tick) and clears L. Reading clears L
//       and the interrupt. Limit 0 lets the counter free-run (no match, no
//       interrupt). User Timer mode: the count's high word (bits 62:32 of
//       the 64-bit count, with L at 63); writing clears L.
//   +4  Counter (R): bit 31 L, bits 30:9 the count; reading does not clear
//       L. User Timer mode: the count's low word, writable.
//   +8  Limit, non-resetting (W): loads the limit without touching the
//       count; an alarm-clock write. L is left as it is.
//   +C  User Timer start/stop (RW, processor sets only): bit 0 RUN. No
//       effect on a counter/timer (those always run).
//   +10 Timer configuration (RW, system set only): bit N = 1 makes
//       processor N's counter a User Timer. All four bits are kept.
//
// The counters tick every 500 ns in bit 9. A counter/timer counts up from
// 0x200; when the next tick would make the 22-bit count equal the limit,
// the count goes back to 0x200 instead, L is set and the interrupt is
// raised, so the period is (limit - 1) ticks: limit = 2*us + 1 for a tick
// every us microseconds. A User Timer counts 54 bits (62:9); L is set when
// it wraps and is cleared by any write to it.
//
// A 64-bit read of a User Timer (the recommended access) arrives as two
// word beats with `pair` set, the high word first: the low word is
// snapshotted on the first beat and returned on the second, so the pair
// is consistent.
//
// Reset (§12 and NCR §6): all counts and limits 0, counter/timer mode,
// RUN bits 0. The count is 0 (not 0x200) at reset and takes one tick to
// show 0x200. A software reset (swr_i: the System Control register's
// SW_RST) resets the same state but keeps the RUN bits. OBP 2.25 sets
// processor 0's RUN at power-on (reset_power_on: user timer for its
// keyboard time-outs), then issues SW_RST and never writes RUN again
// (obp_start); NeXTSTEP 3.3's kernel later makes the processor counters
// User Timers (configuration 0xF), loads processor 0's and calibrates its
// delay loop on that count without writing RUN: with RUN cleared by the
// software reset the count stays 0 and the calibration never ends. NeXTSTEP
// boots under OBP on a real SS20, so RUN must survive SW_RST there (QEMU
// resets RUN to 1 on every reset; the Sun-4M spec, §5.3.4 and §12, gives
// no reset value).
//
// Left out: nothing from the specification. Reserved bits read as 0;
// writes to read-only registers and reserved words are ignored (acked).

module slavio_timer
  import iobus_pkg::*;
#(
  parameter int NCPU   = 2,            // processor sets (1 to 4)
  parameter int CLK_HZ = 80_000_000    // the bus clock; ticks are 2 MHz
)(
  input  logic     clk,
  input  logic     rst,
  input  logic     swr_i,              // with rst: a software reset (RUN kept)

  input  iob_req_t bus_i,              // addr[19:0] within the timer space
  output iob_rsp_t bus_o,

  output logic            irq_sys,     // level-10 source (SI_T)
  output logic [NCPU-1:0] irq_cpu      // level-14, one per processor
);

  // ---------------------------------------------------------------------
  // The 2 MHz tick: a phase accumulator, exact on average for any CLK_HZ.
  // ---------------------------------------------------------------------
  localparam int TICK_HZ = 2_000_000;
  localparam int ACC_W = $clog2(CLK_HZ) + 1;

  logic [ACC_W-1:0] acc;
  logic [ACC_W:0]   acc_next;
  logic             tick;

  assign acc_next = {1'b0, acc} + (ACC_W + 1)'(TICK_HZ);

  always_ff @(posedge clk) begin
    if (rst) begin
      acc  <= '0;
      tick <= 1'b0;
    end else if (acc_next >= (ACC_W + 1)'(CLK_HZ)) begin
      acc  <= ACC_W'(acc_next - (ACC_W + 1)'(CLK_HZ));
      tick <= 1'b1;
    end else begin
      acc  <= acc_next[ACC_W-1:0];
      tick <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------
  // Access decode
  // ---------------------------------------------------------------------
  localparam int SW = (NCPU > 1) ? $clog2(NCPU) : 1;   // processor index width

  logic          access;      // this cycle performs the held request
  logic          is_sys;      // the system set at 0x10000
  logic [1:0]    cpu_sel;     // processor set 0..3
  logic [SW-1:0] idx;         // the same, as an index into the arrays
  logic          cpu_valid;   // a processor set that exists
  logic [2:0]    word;        // register index within the set

  assign access    = bus_i.req & ~bus_o.ack;
  assign is_sys    = bus_i.addr[19:12] == 8'h10;
  assign cpu_sel   = bus_i.addr[13:12];
  assign idx       = cpu_sel[SW-1:0];
  assign cpu_valid = (bus_i.addr[19:14] == '0) && (32'(cpu_sel) < NCPU);
  assign word      = bus_i.addr[4:2];

  // Word-wide registers: the byte enables are not looked at.
  logic unused_ok;
  assign unused_ok = &{1'b0, bus_i.be, bus_i.addr[IOB_AW-1:20], bus_i.addr[1:0], bus_i.addr[11:5]};

  // ---------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------
  // Counter/timer state: count[21:0] is bits 30:9 of the register.
  // The processor counters double as User Timers: the 54-bit user count
  // is {ucnt_hi[31:0], count[21:0]}, i.e. bits 62:9.
  logic [21:0]      sys_count, sys_limit;
  logic             sys_l;
  logic [21:0]      cpu_count [NCPU];
  logic [21:0]      cpu_limit [NCPU];
  logic [31:0]      ucnt_hi   [NCPU];
  logic             cpu_l     [NCPU];
  logic             run       [NCPU];
  logic [NCPU-1:0]  user_mode;
  logic [31:0]      pair_lo;           // low word snapshot for 64-bit reads

  // Per-register strobes (the access cycle)
  logic wr_sys_limit, wr_sys_limit_nr, rd_sys_limit;
  logic wr_cfg;

  assign wr_sys_limit    = access & bus_i.we & is_sys & (word == 3'd0);
  assign wr_sys_limit_nr = access & bus_i.we & is_sys & (word == 3'd2);
  assign rd_sys_limit    = access & ~bus_i.we & is_sys & (word == 3'd0);
  assign wr_cfg          = access & bus_i.we & is_sys & (word == 3'd4);

  // System counter
  always_ff @(posedge clk) begin
    if (rst) begin
      sys_count <= '0;
      sys_limit <= '0;
      sys_l     <= 1'b0;
    end else begin
      if (tick) begin
        if (sys_limit != '0 && sys_count + 22'd1 == sys_limit) begin
          sys_count <= 22'd1;
          sys_l     <= 1'b1;
        end else begin
          sys_count <= sys_count + 22'd1;   // wraps 0x3FFFFF -> 0: free-run
        end
      end
      if (wr_sys_limit) begin
        sys_limit <= bus_i.wdata[30:9];
        sys_count <= 22'd1;
        sys_l     <= 1'b0;
      end
      if (wr_sys_limit_nr)
        sys_limit <= bus_i.wdata[30:9];
      if (rd_sys_limit)
        sys_l <= 1'b0;
    end
  end

  assign irq_sys = sys_l;

  // Timer configuration: four bits whatever NCPU (OBP 2.25's POST "PROCn
  // User Timer Test" writes all ones and expects 0xF back); bits beyond the
  // processors fitted do nothing
  logic [3:0] cfg;
  always_ff @(posedge clk) begin
    if (rst)
      cfg <= '0;
    else if (wr_cfg)
      cfg <= bus_i.wdata[3:0];
  end
  assign user_mode = cfg[NCPU-1:0];

  // Processor counters
  genvar n;
  generate
  for (n = 0; n < NCPU; n = n + 1) begin : g_cpu
    logic sel, wr0, wr1, wr2, wr3, rd0;
    logic mode_change;

    assign sel = access & cpu_valid & (32'(cpu_sel) == n);
    assign wr0 = sel & bus_i.we & (word == 3'd0);
    assign wr1 = sel & bus_i.we & (word == 3'd1);
    assign wr2 = sel & bus_i.we & (word == 3'd2);
    assign wr3 = sel & bus_i.we & (word == 3'd3);
    assign rd0 = sel & ~bus_i.we & (word == 3'd0);
    // The value after a mode change is unspecified (§5.3.1): start clean.
    assign mode_change = wr_cfg & (bus_i.wdata[n] != user_mode[n]);

    always_ff @(posedge clk) begin
      if (rst) begin
        cpu_count[n] <= '0;
        cpu_limit[n] <= '0;
        ucnt_hi[n]   <= '0;
        cpu_l[n]     <= 1'b0;
        if (!swr_i)
          run[n]     <= 1'b0;
      end else begin
        if (tick) begin
          if (user_mode[n]) begin
            if (run[n]) begin : inc              // 54-bit count; L sticks once set
              logic [54:0] sum;
              sum = {1'b0, ucnt_hi[n], cpu_count[n]} + 55'd1;
              {ucnt_hi[n], cpu_count[n]} <= sum[53:0];
              cpu_l[n] <= cpu_l[n] | sum[54];
            end
          end else if (cpu_limit[n] != '0 && cpu_count[n] + 22'd1 == cpu_limit[n]) begin
            cpu_count[n] <= 22'd1;
            cpu_l[n]     <= 1'b1;
          end else begin
            cpu_count[n] <= cpu_count[n] + 22'd1;
          end
        end

        if (user_mode[n]) begin
          // The 64-bit User Timer is {L, count[53:0], 9'b0}: its high word
          // is {L, count[53:23]}, its low word {count[22:0], 9'b0}. Here
          // count[53:22] is ucnt_hi and count[21:0] is cpu_count.
          if (wr0) begin                         // high word: count[53:23], clears L
            ucnt_hi[n][31:1] <= bus_i.wdata[30:0];
            cpu_l[n]         <= 1'b0;
          end
          if (wr1) begin                         // low word: count[22:0], clears L
            ucnt_hi[n][0] <= bus_i.wdata[31];
            cpu_count[n]  <= bus_i.wdata[30:9];
            cpu_l[n]      <= 1'b0;
          end
          if (wr3)
            run[n] <= bus_i.wdata[0];
        end else begin
          if (wr0) begin
            cpu_limit[n] <= bus_i.wdata[30:9];
            cpu_count[n] <= 22'd1;
            cpu_l[n]     <= 1'b0;
          end
          if (wr2)
            cpu_limit[n] <= bus_i.wdata[30:9];
          if (rd0)
            cpu_l[n] <= 1'b0;
          if (wr3)
            run[n] <= bus_i.wdata[0];            // kept, takes effect in user mode
        end

        if (mode_change) begin
          cpu_count[n] <= '0;
          ucnt_hi[n]   <= '0;
          cpu_l[n]     <= 1'b0;
        end
      end
    end

    assign irq_cpu[n] = cpu_l[n] & ~user_mode[n];
  end
  endgenerate

  // ---------------------------------------------------------------------
  // Read data and the response
  // ---------------------------------------------------------------------
  // The User Timer's words: low {count[22:0], 9'b0} = {ucnt_hi[0], cpu_count, 9'b0},
  // high {L, count[53:23]} = {L, ucnt_hi[31:1]}.
  logic [31:0] rdata;
  logic [31:0] ulo, uhi;

  always_comb begin
    rdata = '0;
    ulo   = '0;
    uhi   = '0;
    if (is_sys) begin
      case (word)
        3'd0:    rdata = {sys_l, sys_limit, 9'd0};
        3'd1:    rdata = {sys_l, sys_count, 9'd0};
        3'd4:    rdata = {28'd0, cfg};
        default: rdata = '0;
      endcase
    end else if (cpu_valid) begin
      ulo = {ucnt_hi[idx][0], cpu_count[idx], 9'd0};
      uhi = {cpu_l[idx], ucnt_hi[idx][31:1]};
      case (word)
        3'd0: rdata = user_mode[idx] ? uhi : {cpu_l[idx], cpu_limit[idx], 9'd0};
        3'd1: rdata = user_mode[idx] ? (bus_i.pair ? pair_lo : ulo)   // second beat of a pair
                                         : {cpu_l[idx], cpu_count[idx], 9'd0};
        3'd3: rdata = 32'(run[idx]);
        default: rdata = '0;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      bus_o   <= IOB_RSP_IDLE;
      pair_lo <= '0;
    end else begin
      bus_o.ack   <= access;
      bus_o.err   <= 1'b0;
      bus_o.rdata <= rdata;
      // First beat of a 64-bit User Timer read: keep the low word for the
      // second beat.
      if (access && !bus_i.we && cpu_valid && word == 3'd0 && bus_i.pair)
        pair_lo <= ulo;
    end
  end

endmodule
