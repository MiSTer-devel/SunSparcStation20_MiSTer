// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_l1cache: the D-cache (l1cache ICACHE = 0, FAST_HIT as in cpu_module)
// against a memory model: line fills, write-through stores through the
// write buffer, and the case of the 2026-10-18 review: a store that missed
// waits in S_WRITE_WAIT (the write buffer full) while idx_i moves to
// another set whose tags hold a line with the store's tag bits. Only the
// tags of the accept cycle may decide the store's line update; a later
// match would write the store's bytes into the wrong line (here line C,
// whose data is then checked).
//
// The CPU side as cpu_module drives it: the request held until done_o and
// dropped in done_o's cycle (req_i = held & !done_o); idx_i the request's
// VA[11:3] (the page offset, = the PA's here).

/* verilator lint_off PROCASSINIT */   // a bench: its variables start at their declared values
/* verilator lint_off BLKSEQ */        // (the memory model updates its array at once)
module tb_l1cache;
  import tb_pkg::*;
  import mem_pkg::*;

  logic clk, rst;
  initial begin clk = 0; rst = 1; end
  always #5 clk = ~clk;

  logic        req_q, we, cacheable;
  logic [35:0] pa;
  logic [8:0]  idx;
  logic [7:0]  be;
  logic [63:0] wdata;
  logic        req, taken, done, fast, err;
  logic [63:0] rdata;
  mem_req_t    mreq;
  mem_rsp_t    mrsp;
  logic        wb_empty, snoop_hold, flash_busy, diag_done;
  logic [63:0] diag_rdata;
  logic [7:0]  dbg;
  snoop_t      snoop;
  initial begin req_q = 0; we = 0; cacheable = 1; pa = '0; idx = '0; be = '1; wdata = '0; snoop = '0; end
  assign req = req_q & ~done;

  l1cache #(.ICACHE(1'b0), .FAST_HIT(1'b1)) dut (
    .clk, .rst, .enable_i(1'b1), .mid_i(4'd8),
    .req_i(req), .freq_i(1'b0), .we_i(we), .atomic_i(1'b0), .cacheable_i(cacheable), .pa_i(pa), .idx_i(idx),
    .be_i(be), .wdata_i(wdata), .taken_o(taken), .done_o(done), .fast_o(fast), .rdata_o(rdata), .err_o(err),
    .inval_i(1'b0), .inval_line_i('0), .snoop_i(snoop), .snoop_hold_o(snoop_hold),
    .flash_v_i(1'b0), .flash_l_i(1'b0), .flash_busy_o(flash_busy),
    .diag_req_i(1'b0), .diag_we_i(1'b0), .diag_tag_i(1'b0), .diag_va_i('0), .diag_wdata_i('0),
    .diag_done_o(diag_done), .diag_rdata_o(diag_rdata),
    .mem_req_o(mreq), .mem_rsp_i(mrsp), .wb_empty_o(wb_empty), .dbg_o(dbg));

  // memory: a doubleword's initial value is a pattern of its address; reads
  // and bursts answer a beat a cycle after two cycles; writes are acked
  // unless held (hold_w), so the write buffer can be filled
  logic [63:0] mem [int];
  function automatic logic [63:0] mrd(input logic [35:3] dw);
    return mem.exists(int'(dw)) ? mem[int'(dw)] : {28'hA5A5A5A, dw[34:3], 4'h5};
  endfunction
  bit hold_w = 0;
  int wait_n = 0, beat = 0;
  always @(posedge clk) begin
    mrsp <= '0;
    if (!mreq.valid) begin wait_n <= 0; beat <= 0; end
    else if (mrsp.ack && !mreq.burst) begin wait_n <= 0; end   // a single beat done: the next request
    else if (mreq.write) begin
      if (!hold_w && wait_n >= 1 && !mrsp.ack) begin
        logic [63:0] m;
        m = mrd(mreq.pa[35:3]);
        for (int b = 0; b < 8; b++) if (mreq.be[b]) m[8*b +: 8] = mreq.wdata[8*b +: 8];
        mem[int'(mreq.pa[35:3])] = m;
        mrsp.ack <= 1'b1;
      end else wait_n <= wait_n + 1;
    end else if (wait_n >= 2 && !(mrsp.ack && !mreq.burst)) begin
      mrsp.ack <= 1'b1;
      mrsp.rdata <= mrd(mreq.burst ? {mreq.pa[35:5], 2'(beat)} : mreq.pa[35:3]);
      beat <= beat + 1;
    end else wait_n <= wait_n + 1;
  end

  // the CPU side: one access; returns the read data
  task automatic access(input logic w, input logic [35:0] a, input logic [63:0] d, output logic [63:0] q);
    @(negedge clk);
    we = w; pa = a; idx = a[11:3]; be = '1; wdata = d; req_q = 1;
    do @(negedge clk); while (!done);
    q = rdata;
    @(posedge clk); #1;
    req_q = 0;
  endtask

  localparam logic [35:0] A = 36'h0_0000_1200;   // tag 1, set 0x10
  localparam logic [35:0] C = 36'h0_0000_2400;   // tag 2, set 0x20
  localparam logic [35:0] B = 36'h0_0000_1408;   // tag 1, set 0x20: misses (C holds that set's way 0)

  initial begin
    logic [63:0] q;
    repeat (4) @(negedge clk);
    rst = 0;
    repeat (300) @(negedge clk);              // the reset sweeps
    // C, then A: each filled into way 0 of its set
    access(0, C, '0, q); check32(q[31:0], mrd(C[35:3])[31:0], "load C (fill)");
    access(0, A, '0, q); check32(q[31:0], mrd(A[35:3])[31:0], "load A (fill)");
    access(0, C, '0, q); check(q === mrd(C[35:3]), "load C again (hit)");
    // fill the write buffer with four stores the memory does not take yet
    hold_w = 1;
    for (int i = 0; i < 4; i++) access(1, 36'h0_0000_3000 + 36'(i * 32), 64'hDEAD_0000_0000_0000 | 64'(i), q);
    // the store to B misses and waits in S_WRITE_WAIT; meanwhile idx_i
    // moves to A's set, whose way 0 holds tag 1
    @(negedge clk);
    we = 1; pa = B; idx = B[11:3]; wdata = 64'h0BAD_0BAD_0BAD_0BAD; req_q = 1;
    repeat (3) @(negedge clk);
    check(!done, "the store to B waits (the write buffer is full)");
    idx = A[11:3];
    repeat (12) @(negedge clk);
    hold_w = 0;
    while (!done) @(negedge clk);
    @(posedge clk); #1;
    req_q = 0; idx = '0;
    repeat (40) @(negedge clk);               // the buffer drains
    check(wb_empty, "the write buffer drained");
    check(mrd(B[35:3]) === 64'h0BAD_0BAD_0BAD_0BAD, "the store reached memory");
    // C's line must be untouched, A's too
    access(0, C, '0, q); check(q === mrd(C[35:3]), $sformatf("load C after the store: %016x, wanted %016x", q, mrd(C[35:3])));
    access(0, C + 36'd8, '0, q); check(q === mrd(C[35:3] + 33'd1), $sformatf("load C+8 after the store: %016x, wanted %016x", q, mrd(C[35:3] + 33'd1)));
    access(0, A + 36'd8, '0, q); check(q === mrd(A[35:3] + 33'd1), "load A+8 after the store");
    access(0, B, '0, q); check(q === 64'h0BAD_0BAD_0BAD_0BAD, "load B (a fill from memory)");
    tb_done("tb_l1cache");
  end

endmodule
