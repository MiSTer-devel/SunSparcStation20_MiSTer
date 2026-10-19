// SPDX-License-Identifier: GPL-2.0-or-later
// snoop_queue — cpu_sim's snoop broadcast: the module's own accepted write
// beats and the harness's DMA write beats, queued, one delivered per CPU
// cycle in the register the CPU reads (loaded when ld_i is high).
//
// Written from docs/arch/bus.md (snoop_t). Simulation only.
//
// Two pushes may come in one cycle (own and DMA); consecutive beats of one
// line fold into the entry pushed last. The queue never drops a DMA snoop
// as long as DMA writes arrive slower than one line per two bus cycles (a
// DMA master writes a line in eight beats); the harness holds its own write
// beats while full_o is high, so the module's stores cannot starve the DMA
// snoops (a polling loop that stores every iteration did, and the cached
// copy of a DMA buffer went stale). While the module holds (hold_i: its
// caches' queues are nearly full) nothing is delivered; the queue absorbs
// the DMA beats meanwhile.
//
// A DMA write is snooped when the I/O bus accepts it, but it reaches the
// memory later; a line fill the module issues in between can read the old
// data after the snoop has passed and keep it. With RESNOOP set, every DMA
// line is snooped a second time RESNOOP cycles later (in a cycle without a
// DMA push), which drops any such copy before software can see the
// transfer complete.

module snoop_queue
  import mem_pkg::*;
#(
  parameter int         DEPTH = 16,
  parameter logic [3:0] OWN_MID = 4'd8,
  parameter logic [3:0] DMA_MID = 4'd0,
  parameter int         RESNOOP = 0,      // bus cycles after which each DMA line is snooped again (0: never)
  parameter int         RW      = 16      // its FIFO: at least RESNOOP / (bus cycles a DMA line)
)(
  input  logic        clk,
  input  logic        rst,
  input  logic        ld_i,            // the cycle whose end loads the register the CPU sees
  input  logic        hold_i,          // the module's caches cannot take a snoop: deliver none

  input  logic        own_valid_i,
  input  logic [30:0] own_line_i,
  input  logic        dma_valid_i,
  input  logic [30:0] dma_line_i,

  output logic        full_o,          // fewer than four free slots: hold the module's writes
  output snoop_t      snoop_o          // the register the CPU reads
);
  localparam int AW = $clog2(DEPTH);
  logic [30:0] q_line [0:DEPTH-1];
  logic [3:0]  q_mid  [0:DEPTH-1];
  logic [AW-1:0] wp, rp;
  logic [AW:0]   n;
  logic [30:0]   last_line;
  logic [3:0]    last_mid;

  // The delayed second snoops: a FIFO of (line, due cycle)
  logic [30:0] r_line [0:RW-1];
  logic [15:0] r_due  [0:RW-1];
  localparam int RAW = $clog2(RW);
  logic [RAW-1:0] r_wp, r_rp;
  logic [RAW:0]   r_n;
  logic [15:0] now;
  logic        r_push, r_pop, re_go;
  logic [30:0] r_last;
  assign r_push = RESNOOP != 0 && dma_valid_i && !(r_n != '0 && r_last == dma_line_i);
  logic [15:0] r_age;
  assign r_age  = now - r_due[r_rp];      // wraps: due when the difference is "non-negative"
  assign re_go  = RESNOOP != 0 && r_n != '0 && !r_age[15];
  assign r_pop  = re_go && !dma_valid_i && !full_o;   // the DMA slot when free, and room in the queue (later is harmless)

  // Which of this cycle's pushes go in: a beat of the line pushed last folds
  logic        push_dma, push_own;
  logic        d_valid;
  logic [30:0] d_line;
  assign d_valid  = dma_valid_i || r_pop;
  assign d_line   = dma_valid_i ? dma_line_i : r_line[r_rp];
  assign push_dma = d_valid && n != DEPTH[AW:0] &&
                    !(n != '0 && last_line == d_line && last_mid == DMA_MID);
  assign push_own = own_valid_i && (n + {{AW{1'b0}}, push_dma}) != DEPTH[AW:0] &&
                    !(n != '0 && last_line == own_line_i && last_mid == OWN_MID && !push_dma);
  assign full_o   = n > DEPTH[AW:0] - 4;

  logic pop;
  assign pop = ld_i && n != '0 && !hold_i;

  always_ff @(posedge clk) begin
    if (rst) begin
      wp <= '0; rp <= '0; n <= '0; last_line <= '0; last_mid <= '0;
      snoop_o <= '0;
      r_wp <= '0; r_rp <= '0; r_n <= '0; now <= '0; r_last <= '0;
    end else begin
      if (push_dma) begin
        q_line[wp] <= d_line; q_mid[wp] <= DMA_MID;
        last_line <= d_line; last_mid <= DMA_MID;
      end
      if (push_own) begin
        q_line[wp + {{AW-1{1'b0}}, push_dma}] <= own_line_i;
        q_mid [wp + {{AW-1{1'b0}}, push_dma}] <= OWN_MID;
        last_line <= own_line_i; last_mid <= OWN_MID;
      end
      wp <= wp + {{AW-1{1'b0}}, push_dma} + {{AW-1{1'b0}}, push_own};
      if (pop) rp <= rp + 1'b1;
      n <= n + {{AW{1'b0}}, push_dma} + {{AW{1'b0}}, push_own} - {{AW{1'b0}}, pop};
      now <= now + 16'd1;
      if (r_push) begin
        r_line[r_wp] <= dma_line_i; r_due[r_wp] <= now + 16'(RESNOOP); r_last <= dma_line_i;
        r_wp <= r_wp + 1'b1;
      end
      if (r_pop) r_rp <= r_rp + 1'b1;
      r_n <= r_n + {{RAW{1'b0}}, r_push} - {{RAW{1'b0}}, r_pop};
`ifndef SYNTHESIS
      if (RESNOOP != 0 && r_push && !r_pop && r_n == (RAW+1)'(RW))
        $error("snoop_queue: the delayed-snoop FIFO overflowed");
      if (d_valid && n == DEPTH[AW:0] && !(n != '0 && last_line == d_line && last_mid == DMA_MID))
        $error("snoop_queue: a DMA snoop was dropped (queue full): n=%0d dma=%0d resnoop=%0d own=%0d hold=%0d RESNOOP=%0d", n, dma_valid_i, r_pop, own_valid_i, hold_i, RESNOOP);
`endif
      if (ld_i) begin
        snoop_o.valid <= pop;
        snoop_o.line  <= q_line[rp];
        snoop_o.mid   <= q_mid[rp];
      end
    end
  end
endmodule
