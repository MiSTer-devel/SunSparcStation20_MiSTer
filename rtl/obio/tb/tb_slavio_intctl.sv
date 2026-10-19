// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_slavio_intctl: the interrupt controller against Sun-4M §5.7 and §6.

module tb_slavio_intctl;
  import iobus_pkg::*;
  import sun4m_pkg::*;
  import tb_pkg::*;

  localparam int NCPU = 2;
  localparam logic [19:0] SYS = 20'h10000;
  localparam logic [19:0] CPU0 = 20'h00000, CPU1 = 20'h01000;
  localparam logic [19:0] PEND = 20'h0, CLR = 20'h4, SET = 20'h8;         // processor
  localparam logic [19:0] SPEND = 20'h0, MASK = 20'h4, MCLR = 20'h8, MSET = 20'hC, TARGET = 20'h10;

  localparam logic [31:0] MA = 32'd1 << SI_MA;
  localparam logic [31:0] ALL = 32'hF87F_FFFF;   // every mask bit that exists (VME's too)

  logic clk, rst;
  initial begin clk = 0; rst = 1; end
  always #5 clk = ~clk;

  iob_req_t req = IOB_REQ_IDLE;
  iob_rsp_t rsp;
  logic [31:0]      src = '0;
  logic [NCPU-1:0]  tmr = '0;
  logic [NCPU-1:0][3:0] irl;

  slavio_intctl #(.NCPU(NCPU)) dut (
    .clk, .rst, .bus_i(req), .bus_o(rsp), .src_i(src), .timer_cpu_i(tmr), .irl_o(irl));

  task automatic cycles(input int n);
    repeat (n) @(posedge clk);
    #1;
  endtask

  task automatic bus_write(input logic [19:0] a, input logic [31:0] d);
    req.req = 1; req.we = 1; req.addr = 28'(a); req.be = '1; req.wdata = d;
    do cycles(1); while (!rsp.ack);
    req.req = 0; req.we = 0;
    cycles(2);                                   // let the IRL settle
  endtask

  task automatic bus_read(input logic [19:0] a, output logic [31:0] d);
    req.req = 1; req.we = 0; req.addr = 28'(a); req.be = '1;
    do cycles(1); while (!rsp.ack);
    d = rsp.rdata;
    req.req = 0;
  endtask

  function automatic logic [31:0] sw(input int level);
    return 32'd1 << (16 + level);
  endfunction
  function automatic logic [31:0] hw(input int level);
    return 32'd1 << level;
  endfunction

  logic [31:0] v;

  initial begin
    cycles(3);
    rst = 0;
    cycles(2);

    // ---- reset: all masks set, target 0, nothing pending (§12) ----
    bus_read(SYS + MASK, v);    check32(v, ALL, "mask: every mask bit and MA set");
    bus_read(SYS + TARGET, v);  check32(v, 32'h0, "target 0");
    bus_read(SYS + SPEND, v);   check32(v, 32'h0, "nothing pending");
    bus_read(CPU0 + PEND, v);   check32(v, 32'h0, "cpu0 nothing pending");
    check(irl == '0, "IRL 0 on both");

    // ---- a masked source shows in the pending register but raises nothing ----
    src[SI_T] = 1;
    cycles(3);
    bus_read(SYS + SPEND, v);   check32(v, 32'd1 << SI_T, "system pending shows the timer");
    check(irl == '0, "masked: no IRL");
    bus_read(CPU0 + PEND, v);   check32(v, 32'h0, "masked: cpu0 shows nothing");

    // ---- unmask it (and MA): the target gets level 10 ----
    bus_write(SYS + MCLR, (32'd1 << SI_T) | MA);
    bus_read(SYS + MASK, v);    check32(v, ALL & ~((32'd1 << SI_T) | MA), "mask bits cleared");
    check(irl[0] == 4'd10 && irl[1] == 4'd0, "cpu0 (the target) gets IRL 10");
    bus_read(CPU0 + PEND, v);   check32(v, hw(10), "cpu0 pending HARD_INT<10>");
    bus_read(CPU1 + PEND, v);   check32(v, 32'h0, "cpu1 sees nothing");

    // ---- the target moves ----
    bus_write(SYS + TARGET, 32'h1);
    bus_read(SYS + TARGET, v);  check32(v, 32'h1, "target 1");
    check(irl[0] == 4'd0 && irl[1] == 4'd10, "cpu1 now gets IRL 10");
    bus_read(CPU1 + PEND, v);   check32(v, hw(10), "cpu1 pending HARD_INT<10>");

    // ---- mask-all stops the undirected interrupts, not the pending view ----
    bus_write(SYS + MSET, MA);
    check(irl == '0, "MA: no IRL");
    bus_read(SYS + SPEND, v);   check32(v, 32'd1 << SI_T, "MA: system pending unchanged");
    bus_write(SYS + MCLR, MA);
    check(irl[1] == 4'd10, "MA cleared: IRL back");

    // ---- soft interrupts are per processor and directed ----
    bus_write(CPU0 + SET, sw(3));
    check(irl[0] == 4'd3 && irl[1] == 4'd10, "cpu0 soft 3");
    bus_read(CPU0 + PEND, v);   check32(v, sw(3), "cpu0 pending SOFTINT<3>");
    bus_write(CPU0 + SET, sw(13));
    check(irl[0] == 4'd13, "the highest level wins");
    bus_read(CPU0 + PEND, v);   check32(v, sw(3) | sw(13), "both soft bits");
    bus_write(CPU0 + CLR, sw(13));
    check(irl[0] == 4'd3, "clear 13 leaves 3");
    bus_write(CPU0 + CLR, sw(3));
    check(irl[0] == 4'd0, "clear 3");
    bus_write(CPU0 + CLR, sw(1));           // clearing a clear bit: no effect
    bus_read(CPU0 + PEND, v);   check32(v, 32'h0, "cpu0 clean");

    // ---- hard and soft priority on the target ----
    bus_write(SYS + TARGET, 32'h0);
    bus_write(CPU0 + SET, sw(12));
    check(irl[0] == 4'd12, "soft 12 over hard 10");
    bus_write(CPU0 + SET, sw(9));
    check(irl[0] == 4'd12, "still 12");
    bus_write(CPU0 + CLR, sw(12));
    check(irl[0] == 4'd10, "hard 10 over soft 9");
    bus_write(CPU0 + CLR, sw(9));

    // ---- level assignment (§6.3) of each source ----
    src = '0; cycles(3);
    bus_write(SYS + MCLR, SI_IMPLEMENTED & ~32'h7800_0000);  // everything but level 15
    begin
      int exp_lvl [int];
      exp_lvl[SI_SBUS_LSB + 0] = 2;  exp_lvl[SI_SBUS_LSB + 1] = 3;  exp_lvl[SI_SBUS_LSB + 2] = 5;
      exp_lvl[SI_SBUS_LSB + 3] = 7;  exp_lvl[SI_SBUS_LSB + 4] = 9;  exp_lvl[SI_SBUS_LSB + 5] = 11;
      exp_lvl[SI_SBUS_LSB + 6] = 13;
      exp_lvl[SI_K] = 12; exp_lvl[SI_S] = 12; exp_lvl[SI_E] = 6; exp_lvl[SI_A] = 13;
      exp_lvl[SI_SC] = 4; exp_lvl[SI_T] = 10; exp_lvl[SI_VI] = 8; exp_lvl[SI_MI] = 9; exp_lvl[SI_FL] = 11;
      foreach (exp_lvl[b]) begin
        src = 32'd1 << b; cycles(3);
        check(irl[0] == 4'(exp_lvl[b]), $sformatf("source bit %0d is level %0d (got %0d)", b, exp_lvl[b], irl[0]));
        bus_read(CPU0 + PEND, v);
        check32(v, hw(exp_lvl[b]), $sformatf("cpu0 pending for bit %0d", b));
      end
      src = '0; cycles(3);
    end
    // VME bits and reserved bits are not sources here
    src = 32'h0000_007F | 32'h0780_0000; cycles(3);
    bus_read(SYS + SPEND, v);   check32(v, 32'h0, "VME and reserved bits read 0");
    check(irl == '0, "and raise nothing");
    src = '0; cycles(3);
    bus_write(SYS + MCLR, 32'h0000_007F);
    bus_read(SYS + MASK, v);    check32(v, 32'h7800_0000, "VME mask bits cleared; only level 15 still masked");
    bus_write(SYS + MSET, 32'hFFFF_FFFF);
    bus_read(SYS + MASK, v);    check32(v, 32'hF87F_FFFF, "mask set: bits 26:23 read 0 (POST System Interrupt Regs)");
    bus_write(SYS + MCLR, 32'hF87F_FFFF);
    bus_read(SYS + MASK, v);    check32(v, 32'h0, "mask clear: all 0");
    bus_write(SYS + MSET, 32'h7800_0000);

    // ---- the per-processor timer: level 14, directed, not steered ----
    bus_write(SYS + TARGET, 32'h0);
    tmr[1] = 1; cycles(3);
    check(irl[1] == 4'd14 && irl[0] == 4'd0, "cpu1 timer -> cpu1 level 14");
    bus_read(CPU1 + PEND, v);   check32(v, hw(14), "cpu1 pending HARD_INT<14>");
    bus_write(SYS + MSET, MA);
    check(irl[1] == 4'd14, "MA does not mask the processor's timer (5.7.4)");
    bus_write(SYS + MCLR, MA);
    tmr[1] = 0; cycles(3);
    check(irl[1] == 4'd0, "timer released");

    // ---- level 15: a broadcast latched in every processor ----
    src[SI_M] = 1; cycles(3);                // masked: nothing
    check(irl == '0, "masked level-15 source: no broadcast");
    bus_read(SYS + SPEND, v);   check32(v, 32'd1 << SI_M, "but visible in the system pending");
    bus_write(SYS + MCLR, 32'd1 << SI_M);    // unmask while asserted: the event
    check(irl[0] == 4'd15 && irl[1] == 4'd15, "level 15 on every processor");
    bus_read(CPU0 + PEND, v);   check32(v, hw(15), "cpu0 HARD_INT<15>");
    bus_read(CPU1 + PEND, v);   check32(v, hw(15), "cpu1 HARD_INT<15>");
    bus_write(CPU0 + CLR, hw(15));         // cpu0 acknowledges its copy
    check(irl[0] == 4'd0 && irl[1] == 4'd15, "cpu0 cleared, cpu1 still pending");
    src[SI_M] = 0; cycles(3);                // the source is serviced
    check(irl[1] == 4'd15, "cpu1's copy stays until it clears it");
    bus_write(CPU1 + CLR, hw(15));
    check(irl == '0, "all clear");
    src[SI_ME] = 1; cycles(3);               // another source, already unmasked? no: ME is still masked
    check(irl == '0, "ME masked: nothing");
    bus_write(SYS + MCLR, 32'd1 << SI_ME);
    check(irl[0] == 4'd15 && irl[1] == 4'd15, "ME unmasked: broadcast");
    bus_write(CPU0 + CLR, hw(15));
    bus_write(CPU1 + CLR, hw(15));
    src[SI_ME] = 0; cycles(3);
    src[SI_ME] = 1; cycles(3);               // a new assertion is a new event
    check(irl[0] == 4'd15 && irl[1] == 4'd15, "re-asserted: broadcast again");
    bus_write(CPU0 + CLR, hw(15) | sw(15));
    bus_write(CPU1 + CLR, hw(15));
    src = '0; cycles(3);
    check(irl == '0, "quiet");

    // ---- absent processor set and reserved words ----
    bus_read(20'h02000, v);     check32(v, 32'h0, "processor 2 absent: reads 0");
    bus_read(SYS + 20'h14, v);  check32(v, 32'h0, "reserved word reads 0");
    bus_read(CPU0 + 20'hC, v);  check32(v, 32'h0, "reserved processor word reads 0");

    tb_done("tb_slavio_intctl");
  end

  initial begin
    #2_000_000;
    $display("FAIL: timeout");
    $fatal(1, "timeout");
  end
endmodule
