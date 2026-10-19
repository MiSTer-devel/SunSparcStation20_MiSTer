// SPDX-License-Identifier: GPL-2.0-or-later
//
// ss20_mbus: the interconnect's arbiter (docs/arch/bus.md "The
// interconnect"): the CPU modules and the MSI's DVMA port (already
// translated to physical addresses) onto the one slave port of
// ss20_memctl. Master n < NCPU is CPU module MID 8 + n; master NCPU is DVMA.
//
// - A request is granted whole: a single beat until its ack, a line until
//   its fourth ack (or an err), a locked read until the owner's next write
//   completes (ldstub/swap and the table walker's R-bit update stay atomic
//   against the other masters).
// - The grant is combinational when the port is free, so an uncontended
//   request costs no cycle; after each finished request one cycle passes
//   with nothing presented (the finished master drops its request then,
//   and ss20_memctl ignores that cycle anyway).
// - Round robin among the masters that ask, starting after the last one
//   served. A CPU whose bit in park_i is set (the MSI's arbiter-enable
//   register clear for it, t_msi) is not granted.
// - ss20_memctl writes single beats only; the CPU's write-through caches
//   never write a line, but DMA does: a line write is passed on as four
//   single doubleword writes at its four addresses, the master's data for
//   each beat taken as it presents it after the previous ack.
// - mid_o is the granted master's module ID (the snoop's source, the MSI's
//   MID register): 8 + n for a CPU, 0 for DVMA.

module ss20_mbus
  import mem_pkg::*;
#(
  parameter int NCPU = 1                 // 1 to 4
)(
  input  logic      clk,
  input  logic      rst,

  input  mem_req_t  req_i [NCPU+1],      // CPU 0 .. NCPU-1, then DVMA
  output mem_rsp_t  rsp_o [NCPU+1],
  input  logic [NCPU-1:0] park_i,

  output mem_req_t  req_o,
  input  mem_rsp_t  rsp_i,
  output logic [3:0] mid_o
);

  localparam int NM = NCPU + 1;
  localparam int MW = $clog2(NM + 1);
  localparam logic [MW-1:0] NONE = MW'(NM);

  logic [MW-1:0] own;                     // the master holding the port, or NONE
  logic          gap;                     // the cycle after a finished request
  logic [MW-1:0] last;                    // the last master granted
  logic          locked;                  // the owner's locked read is done; hold until its write
  logic [1:0]    beat;                    // beats acked within a line

  logic [NM-1:0] want;
  always_comb
    for (int m = 0; m < NM; m++)
      want[m] = req_i[m].valid && !(m < NCPU && park_i[m < NCPU ? m : 0]);

  // the first master asking after `last`, or NONE. The modulo is taken on
  // the loop constants only: a modulo of the register itself was synthesised
  // as 32-bit dividers (~700 ALUTs, 2026-10-17).
  logic [MW-1:0] picked;
  always_comb begin
    picked = NONE;
    for (int l = 0; l < NM; l++)
      if (last == MW'(l))
        for (int k = NM; k >= 1; k--)
          if (want[(l + k) % NM]) picked = MW'((l + k) % NM);
  end

  // the master presented this cycle: the owner, or a new grant when free
  logic [MW-1:0] cur;
  assign cur = own != NONE ? own : gap ? NONE : picked;

  // the request of master i, or an idle one for NONE (an indexed read of the
  // array, one mux level; a priority chain over the masters cost a level
  // per master, 2026-10-17)
  localparam int IW = (NM > 1) ? $clog2(NM) : 1;   // the array index width
  function automatic mem_req_t sel_req(input logic [MW-1:0] i);
    if (i < MW'(NM)) return req_i[i[IW-1:0]];
    return '0;
  endfunction

  mem_req_t m_req;
  /* verilator lint_off UNUSEDSIGNAL */     // (of the owner's request only burst, lock and write)
  mem_req_t o_req;
  /* verilator lint_on UNUSEDSIGNAL */
  assign m_req = sel_req(cur);
  assign o_req = sel_req(own);            // (an ack only ever comes to the registered owner)
  always_comb begin
    req_o = m_req;
    if (m_req.burst && m_req.write) begin     // a line write: four single beats
      req_o.burst = 1'b0;
      req_o.pa    = {m_req.pa[35:5], beat, 3'b000};
    end
  end
  assign mid_o = (cur < MW'(NCPU)) ? 4'(8 + int'(cur)) : 4'd0;

  // the answer goes to the owner; the data goes to everyone (a master reads
  // it only with its ack), which saves gating 64 bits per master
  always_comb
    for (int m = 0; m < NM; m++) begin
      rsp_o[m] = '0;
      rsp_o[m].rdata = rsp_i.rdata;
      if (own == MW'(m)) begin rsp_o[m].ack = rsp_i.ack; rsp_o[m].err = rsp_i.err; end
    end

  // the owner's request's last ack
  logic active, done;
  assign active = own != NONE;
  always_comb begin
    done = 1'b0;
    if (rsp_i.ack && active) begin
      if (rsp_i.err)                       done = 1'b1;
      else if (o_req.burst)                done = beat == 2'd3;
      else if (o_req.lock && !o_req.write) done = 1'b0;   // a locked read: the write follows
      else                                 done = !locked || o_req.write;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      own <= NONE; gap <= 1'b0; last <= MW'(NM - 1); locked <= 1'b0; beat <= '0;
    end else begin
      gap <= 1'b0;
      if (own == NONE && cur != NONE) begin
        own  <= cur;
        last <= cur;
      end
      if (rsp_i.ack && active) begin
        beat <= o_req.burst && !rsp_i.err ? beat + 2'd1 : 2'd0;
        if (o_req.lock && !o_req.write && !rsp_i.err) locked <= 1'b1;
      end
      if (done) begin
        own <= NONE; gap <= 1'b1; locked <= 1'b0; beat <= '0;
      end
    end
  end

endmodule
