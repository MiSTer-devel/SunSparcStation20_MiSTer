// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_slavio_timer: the counter/timers against Sun-4M §5.3 and NCR89C105 §6.
// CLK_HZ is 8 MHz here so a 500 ns tick is exactly 4 clocks.

module tb_slavio_timer;
  import iobus_pkg::*;
  import tb_pkg::*;

  localparam int NCPU = 2;
  localparam int CLK_HZ = 8_000_000;
  localparam int TICK = 4;                       // clocks per tick

  localparam logic [19:0] SYS = 20'h10000;
  localparam logic [19:0] CPU0 = 20'h00000;
  localparam logic [19:0] CPU1 = 20'h01000;
  localparam logic [19:0] LIMIT = 20'h0, COUNT = 20'h4, LIMIT_NR = 20'h8, RUN = 20'hC, CFG = 20'h10;

  logic clk, rst, swr;
  initial begin clk = 0; rst = 1; swr = 0; end
  always #5 clk = ~clk;

  iob_req_t req = IOB_REQ_IDLE;
  iob_rsp_t rsp;
  logic            irq_sys;
  logic [NCPU-1:0] irq_cpu;

  slavio_timer #(.NCPU(NCPU), .CLK_HZ(CLK_HZ)) dut (
    .clk, .rst, .swr_i(swr), .bus_i(req), .bus_o(rsp), .irq_sys, .irq_cpu);

  // ---- bus functional model ------------------------------------------
  task automatic cycles(input int n);
    repeat (n) @(posedge clk);
    #1;
  endtask

  task automatic bus_write(input logic [19:0] a, input logic [31:0] d);
    req.req = 1; req.we = 1; req.addr = 28'(a); req.be = '1; req.wdata = d; req.pair = 0;
    do cycles(1); while (!rsp.ack);
    check(!rsp.err, "write: no error");
    req.req = 0; req.we = 0;
  endtask

  task automatic bus_read(input logic [19:0] a, output logic [31:0] d, input bit pair = 0);
    req.req = 1; req.we = 0; req.addr = 28'(a); req.be = '1; req.pair = pair;
    do cycles(1); while (!rsp.ack);
    check(!rsp.err, "read: no error");
    d = rsp.rdata;
    req.req = 0; req.pair = 0;
  endtask

  task automatic bus_read64(input logic [19:0] a, output logic [63:0] d, input int gap = 0);
    logic [31:0] hi, lo;
    bus_read(a, hi, 1);
    if (gap > 0) cycles(gap);
    bus_read(a + 20'd4, lo, 1);
    d = {hi, lo};
  endtask

  // Wait for an interrupt to rise, with a bound; returns the clocks it took.
  task automatic wait_sys(input int bound, output int took);
    took = 0;
    while (!irq_sys && took < bound) begin cycles(1); took++; end
  endtask
  task automatic wait_cpu(input int n, input int bound, output int took);
    took = 0;
    while (!irq_cpu[n] && took < bound) begin cycles(1); took++; end
  endtask

  logic [31:0] v, v2;
  logic [63:0] q;
  int took, t1, t2;

  initial begin
    cycles(3);
    rst = 0;
    cycles(2);

    // ---- reset state (§12, NCR: all count and limit registers 0) ----
    bus_read(SYS + LIMIT, v);  check32(v, 32'h0, "sys limit after reset");
    bus_read(SYS + CFG, v);    check32(v, 32'h0, "config after reset");
    bus_write(SYS + CFG, 32'hFFFF_FFFF);
    bus_read(SYS + CFG, v);    check32(v, 32'hF, "config: four bits whatever NCPU (POST)");
    bus_write(SYS + CFG, 32'h0);
    bus_read(CPU0 + RUN, v);   check32(v, 32'h0, "cpu0 run after reset");
    check(irq_sys == 0 && irq_cpu == '0, "no interrupts after reset");

    // ---- the counter runs at 500 ns in bit 9 (free-run, limit 0) ----
    bus_read(SYS + COUNT, v);
    cycles(10 * TICK);
    bus_read(SYS + COUNT, v2);
    // 40 clocks plus the two accesses (one clock each side): 10 or 11 ticks
    check(((v2 - v) >> 9) == 10 || ((v2 - v) >> 9) == 11, "sys counter advanced ~10 ticks in 40 clocks");
    check((v & 32'h1FF) == 0, "counter bits 8:0 read as 0");

    // ---- limit: period is limit-1 ticks, count resets to 0x200 ----
    bus_write(SYS + LIMIT, 32'd5 << 9);
    bus_read(SYS + COUNT, v);
    check((v >> 9) <= 2 && v[31] == 0, "count restarted at 0x200 after a limit write");
    wait_sys(10 * TICK, took);
    check(irq_sys, "level-10 interrupt after reaching the limit");
    // Period between two interrupts: 4 ticks
    bus_read(SYS + LIMIT, v);              // clears L and the interrupt
    check32(v, 32'h8000_0A00, "limit read shows L and the limit");
    check(!irq_sys, "reading the limit clears the interrupt");
    bus_read(SYS + LIMIT, v);
    check32(v, 32'h0000_0A00, "second limit read: L clear");
    wait_sys(10 * TICK, t1);
    bus_read(SYS + LIMIT, v);
    wait_sys(10 * TICK, t2);
    check(irq_sys, "interrupt again");
    // t2 counts from just after the clearing read; the whole period is 4 ticks
    // and the read itself took 2 clocks, so t2 + 2 clocks is one period.
    check(t2 + 2 >= 4 * TICK - 1 && t2 + 2 <= 4 * TICK + 1, "period is (limit - 1) ticks");
    bus_read(SYS + COUNT, v);
    check(v[31] == 1, "counter read shows L");
    check(irq_sys, "counter read does not clear the interrupt");
    bus_read(SYS + COUNT, v2);
    check(v2[31] == 1 && irq_sys, "counter read leaves L set");
    bus_read(SYS + LIMIT, v);

    // ---- limit through the non-resetting port keeps the count ----
    bus_write(SYS + LIMIT, 32'd100 << 9);
    cycles(20 * TICK);
    bus_read(SYS + COUNT, v);
    check((v >> 9) >= 20, "count advanced before the non-resetting write");
    bus_write(SYS + LIMIT_NR, 32'd40 << 9);
    bus_read(SYS + COUNT, v2);
    check((v2 >> 9) >= (v >> 9), "non-resetting limit write did not reset the count");
    bus_read(SYS + LIMIT, v);
    check32(v, 32'd40 << 9, "limit updated through the non-resetting port");
    wait_sys(25 * TICK, took);
    check(irq_sys, "alarm from the new limit");
    bus_read(SYS + LIMIT, v);

    // ---- a count already past the new limit wraps round first ----
    bus_write(SYS + LIMIT, 32'd0);           // free-run, restart
    cycles(50 * TICK);
    bus_write(SYS + LIMIT_NR, 32'd10 << 9);  // count ~50, limit 10
    cycles(20 * TICK);
    check(!irq_sys, "no interrupt until the counter wraps to the limit");
    bus_write(SYS + LIMIT, 32'd0);

    // ---- writes to the counter register are ignored in counter mode ----
    bus_read(SYS + COUNT, v);
    bus_write(SYS + COUNT, 32'hFFFF_FE00);
    bus_read(SYS + COUNT, v2);
    check((v2 >> 9) - (v >> 9) < 4, "counter register write ignored");
    bus_read(SYS + 20'hC, v);  check32(v, 32'h0, "reserved word reads 0");

    // ---- processor counters: level 14 to their own processor ----
    bus_write(CPU1 + LIMIT, 32'd3 << 9);
    wait_cpu(1, 10 * TICK, took);
    check(irq_cpu[1] && !irq_cpu[0] && !irq_sys, "cpu1 counter interrupts cpu1 only");
    bus_read(CPU0 + LIMIT, v);  check32(v, 32'h0, "cpu0 limit untouched");
    bus_read(CPU1 + LIMIT, v);  check32(v, 32'h8000_0600, "cpu1 limit read shows L");
    check(!irq_cpu[1], "cpu1 limit read clears the interrupt");
    bus_write(CPU1 + LIMIT, 32'd0);
    cycles(2);
    check(!irq_cpu[1], "free-running cpu1 counter: no interrupt");

    // ---- User Timer mode ----
    bus_write(CPU1 + LIMIT, 32'd3 << 9);
    wait_cpu(1, 10 * TICK, took);
    bus_write(SYS + CFG, 32'h2);             // cpu1 -> user timer
    bus_read(SYS + CFG, v);     check32(v, 32'h2, "config reads back");
    cycles(2);
    check(!irq_cpu[1], "user timer has no interrupt");
    bus_read(CPU1 + RUN, v);    check32(v, 32'h0, "user timer stopped at reset");
    bus_read64(CPU1 + LIMIT, q);
    cycles(10 * TICK);
    bus_read64(CPU1 + LIMIT, q);
    check(q == 64'h0, "a stopped user timer holds");
    bus_write(CPU1 + RUN, 32'h1);
    cycles(10 * TICK);
    bus_write(CPU1 + RUN, 32'h0);
    bus_read64(CPU1 + LIMIT, q);
    check((q >> 9) >= 10 && (q >> 9) <= 12 && q[63] == 0, "user timer counted ~10 ticks while running");
    check((q & 64'h1FF) == 0, "user timer bits 8:0 read as 0");
    bus_read(CPU1 + RUN, v);    check32(v, 32'h1 & 0, "run register reads back 0 after stop");
    // Load the 54-bit count just below its maximum: the next tick wraps it
    // and sets L (bit 63).
    bus_write(CPU1 + LIMIT, 32'h7FFF_FFFF);  // high word: count[53:23] all ones
    bus_write(CPU1 + COUNT, 32'hFFFF_FE00);  // low word: count[22:0] all ones
    bus_read64(CPU1 + LIMIT, q);
    check(q == 64'h7FFF_FFFF_FFFF_FE00, "user timer loaded through both words");
    bus_write(CPU1 + RUN, 32'h1);
    cycles(2 * TICK);
    bus_write(CPU1 + RUN, 32'h0);
    bus_read64(CPU1 + LIMIT, q);
    check(q[63] == 1 && (q[62:9]) <= 54'd3, "user timer wrapped: L set, count small");
    check(!irq_cpu[1], "wrap is not an interrupt");
    bus_write(CPU1 + COUNT, 32'h0000_0200); // any write clears L
    bus_read(CPU1 + LIMIT, v);
    check(v[31] == 0, "a write to the user timer clears L");
    // Low word carry into the high word
    bus_write(CPU1 + LIMIT, 32'h0);
    bus_write(CPU1 + COUNT, 32'hFFFF_FE00);
    bus_write(CPU1 + RUN, 32'h1);
    cycles(2 * TICK);
    bus_write(CPU1 + RUN, 32'h0);
    bus_read64(CPU1 + LIMIT, q);
    check(q[62:32] == 31'd1 && (q[31:9]) <= 23'd3, "low word carries into the high word");
    // 64-bit read consistency: the low word is snapshotted on the first beat
    bus_write(CPU1 + LIMIT, 32'h0);
    bus_write(CPU1 + COUNT, 32'h0);
    bus_write(CPU1 + RUN, 32'h1);
    bus_read64(CPU1 + LIMIT, q, 2 * TICK); // two ticks pass between the beats
    bus_read(CPU1 + COUNT, v);             // live low word, not paired
    check(((v >> 9) - 32'(q[31:9])) >= 2 && ((v >> 9) - 32'(q[31:9])) <= 4,
          "paired low word is the snapshot from the first beat");
    bus_write(CPU1 + RUN, 32'h0);
    // Back to counter/timer: counts again, interrupts again
    bus_write(SYS + CFG, 32'h0);
    bus_write(CPU1 + LIMIT, 32'd3 << 9);
    wait_cpu(1, 10 * TICK, took);
    check(irq_cpu[1], "back in counter mode the level-14 interrupt returns");
    bus_read(CPU1 + LIMIT, v);
    bus_write(CPU1 + LIMIT, 32'h0);

    // ---- a nonexistent processor set reads 0 and acks ----
    bus_read(20'h03000, v);  check32(v, 32'h0, "processor 3 absent: reads 0");

    // ---- free-run wrap of the 22-bit count: no L, no interrupt ----
    bus_write(SYS + LIMIT, 32'h0);
    bus_read(SYS + COUNT, v);
    check((v >> 9) <= 2, "count restarted");
    cycles((1 << 22) * TICK);
    bus_read(SYS + COUNT, v2);
    check((v2 >> 9) <= 6 && v2[31] == 0, "22-bit count wrapped without L");
    check(!irq_sys, "free-run wrap is not an interrupt");

    // ---- a software reset keeps RUN (OBP 2.25, then NeXTSTEP 3.3) ----
    // reset_power_on: processor 0's counter a running User Timer
    bus_write(SYS + CFG, 32'h1);
    bus_write(CPU0 + RUN, 32'h1);
    bus_write(CPU0 + LIMIT, 32'h0);
    bus_write(CPU0 + COUNT, 32'h0);
    cycles(5 * TICK);
    // obp_prep: SW_RST (the machine holds rst with swr for a few clocks)
    rst = 1; swr = 1; cycles(4); rst = 0; swr = 0; cycles(2);
    bus_read(SYS + CFG, v);    check32(v, 32'h0, "software reset: counter/timer mode again");
    bus_read(CPU0 + LIMIT, v); check32(v, 32'h0, "software reset: limit 0");
    bus_read(CPU0 + RUN, v);   check32(v, 32'h1, "software reset keeps RUN");
    // obp_start: processor 0 is OBP's level-14 tick
    bus_write(CPU0 + LIMIT, 32'h009c_4000);
    // the kernel: all four counters User Timers, processor 0's loaded,
    // then counted without a write to RUN
    bus_write(SYS + CFG, 32'hF);
    bus_write(CPU0 + COUNT, 32'h0);
    bus_write(CPU0 + LIMIT, 32'h4290_0000);
    bus_read(CPU0 + COUNT, v);
    cycles(20 * TICK);
    bus_read(CPU0 + COUNT, v2);
    check((v2 >> 9) - (v >> 9) >= 19 && (v2 >> 9) - (v >> 9) <= 21,
          "after SW_RST the User Timer counts without a RUN write");
    bus_read(CPU1 + RUN, v);   check32(v, 32'h0, "processor 1's RUN stays 0");
    // a power-on reset clears RUN
    bus_write(SYS + CFG, 32'h0);
    rst = 1; cycles(4); rst = 0; cycles(2);
    bus_read(CPU0 + RUN, v);   check32(v, 32'h0, "power-on reset clears RUN");

    tb_done("tb_slavio_timer");
  end

  initial begin
    #((1 << 22) * TICK * 10 + 2_000_000);
    $display("FAIL: timeout");
    $fatal(1, "timeout");
  end
endmodule
