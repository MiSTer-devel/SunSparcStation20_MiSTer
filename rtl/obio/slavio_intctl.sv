// SPDX-License-Identifier: GPL-2.0-or-later
//
// slavio_intctl: the sun4m interrupt controller (the SLAVIO's interrupt
// section, in its multiprocessor form).
//
// Occupies the 1 MB at PA 0xF_F140_0000: processor N's registers at
// N*0x1000, the system registers at 0x10000.
//
// From: Sun-4M System Architecture, 950-1373-01 Rev 50, §3.2.2.2.3 (the
//   address map), §5.7 Interrupt Related Registers, §6 Interrupts (the
//   level assignment, the directed / undirected / broadcast model), §12
//   (reset). Cross-checked with QEMU hw/intc/slavio_intctl.c and NetBSD
//   sys/arch/sparc/sparc/intreg.h.
//
// System registers (offset 0x10000):
//   +0  System Interrupt Pending (R): the level-sensitive sources as they
//       stand, in the SI_* bit positions of sun4m_pkg.
//   +4  Interrupt Target Mask (R), +8 mask clear (W), +C mask set (W):
//       a masked source does not reach the target; bit 31 (MA) masks all
//       of them (the system sources; not the processors' own counters
//       and soft interrupts, which bypass the mask: §5.7.4).
//       All mask bits are set at reset.
//   +10 Interrupt Target (RW): the processor that takes the undirected
//       interrupts, the "Current Interrupt Target".
// Processor registers (offset N*0x1000):
//   +0  Interrupt Pending (R): bits 31:17 SOFTINT<15:1>, bits 15:1
//       HARD_INT<15:1>. HARD_INT<13:1> show the unmasked system sources at
//       each level, only on the target processor; HARD_INT<14> is this
//       processor's counter/timer; HARD_INT<15> the level-15 broadcast.
//   +4  Clear pending (W): a 1 in bits 31:17 clears that soft interrupt, a
//       1 in bit 15 acknowledges this processor's level-15.
//   +8  Set soft interrupt (W): a 1 in bits 31:17 posts that level.
//
// Each processor's IRL is the highest level set in its pending register.
// A level-15 source (bits 30:27) that asserts while its mask bit is clear
// sets the level-15 bit of every processor (a broadcast); each processor
// clears its own copy. The mask stops the broadcast, not the pending bit.
//
// Left out: the VME interrupts (bits 6:0: an SS20 has no VMEbus) and the
// reserved bits read as 0 in the pending register; the VME mask bits are
// kept (the POST writes and reads them), the reserved ones read 0.

module slavio_intctl
  import iobus_pkg::*;
#(
  parameter int NCPU = 2                   // 1 to 4
)(
  input  logic             clk,
  input  logic             rst,

  input  iob_req_t         bus_i,          // addr[19:0] within the space
  output iob_rsp_t         bus_o,

  input  logic [31:0]      src_i,          // level-sensitive sources, SI_* positions
  input  logic [NCPU-1:0]  timer_cpu_i,    // each processor's level-14 counter

  output logic [NCPU-1:0][3:0] irl_o       // to each processor, 0 = none
);

  import sun4m_pkg::*;               // a second header import is not Quartus 17 syntax

  localparam int TW = (NCPU > 1) ? $clog2(NCPU) : 1;

  // ---------------------------------------------------------------------
  // Decode
  // ---------------------------------------------------------------------
  localparam int SW = (NCPU > 1) ? $clog2(NCPU) : 1;

  logic          access;
  logic          is_sys, cpu_valid;
  logic [1:0]    cpu_sel;
  logic [SW-1:0] idx;
  logic [2:0]    word;

  assign access    = bus_i.req & ~bus_o.ack;
  assign is_sys    = bus_i.addr[19:12] == 8'h10;
  assign cpu_sel   = bus_i.addr[13:12];
  assign idx       = cpu_sel[SW-1:0];
  assign cpu_valid = (bus_i.addr[19:14] == '0) && (32'(cpu_sel) < NCPU);
  assign word      = bus_i.addr[4:2];

  // Word-wide registers: the byte enables and `pair` are not looked at.
  logic unused_ok;
  assign unused_ok = &{1'b0, bus_i.be, bus_i.pair, bus_i.addr[IOB_AW-1:20],
                       bus_i.addr[1:0], bus_i.addr[11:5], hard_lvl[14]};

  // ---------------------------------------------------------------------
  // System state
  // ---------------------------------------------------------------------
  logic [31:0]   pending;       // the sources, as presented
  logic [31:0]   mask;          // Interrupt Target Mask, MA at 31
  // the mask bits that exist: MA, the level-15 sources, bits 22:0 (the VME
  // ones too, though nothing drives them: OBP 2.25's POST "System Interrupt
  // Regs Tests" sets and reads back 0xF87FFFFF); bits 26:23 read 0
  localparam logic [31:0] MASK_BITS = 32'hF87F_FFFF;
  logic [TW-1:0] target;

  assign pending = src_i & SI_IMPLEMENTED;

  always_ff @(posedge clk) begin
    if (rst) begin
      mask   <= MASK_BITS;
      target <= '0;
    end else if (access && bus_i.we && is_sys) begin
      case (word)
        3'd2: mask <= mask & ~(bus_i.wdata & MASK_BITS);
        3'd3: mask <= mask |  (bus_i.wdata & MASK_BITS);
        3'd4: target <= bus_i.wdata[TW-1:0];
        default: ;
      endcase
    end
  end

  // The unmasked sources, and their levels. Level 15 is handled as a
  // broadcast below; levels 1..13 go to the target.
  logic [31:0] active;
  logic [15:1] hard_lvl;        // bit L: some unmasked source at level L

  assign active = pending & ~mask & {32{~mask[SI_MA]}};

  always_comb begin
    hard_lvl = '0;
    for (int b = 0; b < 32; b++)
      if (active[b] && si_level(b) != 4'd0)
        hard_lvl[si_level(b)] = 1'b1;
  end

  // Level-15 broadcast: the rising edge of any unmasked level-15 source.
  logic l15_now, l15_q, l15_set;
  assign l15_now = hard_lvl[15];
  always_ff @(posedge clk) begin
    if (rst) l15_q <= 1'b0;
    else     l15_q <= l15_now;
  end
  assign l15_set = l15_now & ~l15_q;

  // ---------------------------------------------------------------------
  // Processor state
  // ---------------------------------------------------------------------
  logic [15:1] softint [NCPU];
  logic        l15     [NCPU];
  logic [31:0] cpu_pending [NCPU];

  genvar n;
  generate
  for (n = 0; n < NCPU; n = n + 1) begin : g_cpu
    logic sel, wr_clr, wr_set;
    logic is_target;
    logic [15:1] hard;

    assign sel    = access & cpu_valid & (32'(cpu_sel) == n);
    assign wr_clr = sel & bus_i.we & (word == 3'd1);
    assign wr_set = sel & bus_i.we & (word == 3'd2);
    assign is_target = (32'(target) == n);

    always_ff @(posedge clk) begin
      if (rst) begin
        softint[n] <= '0;
        l15[n]     <= 1'b0;
      end else begin
        if (wr_set) softint[n] <= softint[n] | bus_i.wdata[31:17];
        if (wr_clr) softint[n] <= softint[n] & ~bus_i.wdata[31:17];
        if (l15_set)                       l15[n] <= 1'b1;
        else if (wr_clr && bus_i.wdata[15]) l15[n] <= 1'b0;
      end
    end

    // HARD_INT<15:1>
    always_comb begin
      hard       = '0;
      hard[13:1] = is_target ? hard_lvl[13:1] : '0;
      // the processor's own counter goes straight into its pending register
      // (§5.7.4's flow: Timer N and Soft Int N bypass the system mask, MA
      // included); the OpenBIOS in bios/ leaves MA set and ticks at level 14
      hard[14]   = timer_cpu_i[n];
      hard[15]   = l15[n];
    end

    assign cpu_pending[n] = {softint[n], 1'b0, hard, 1'b0};

    // IRL: the highest level pending, registered.
    logic [15:1] lvls;
    assign lvls = softint[n] | hard;
    always_ff @(posedge clk) begin
      if (rst) irl_o[n] <= '0;
      else begin
        irl_o[n] <= '0;
        for (int l = 1; l < 16; l++)
          if (lvls[l]) irl_o[n] <= 4'(l);
      end
    end
  end
  endgenerate

  // ---------------------------------------------------------------------
  // Read data and the response
  // ---------------------------------------------------------------------
  logic [31:0] rdata;

  always_comb begin
    rdata = '0;
    if (is_sys) begin
      case (word)
        3'd0:    rdata = pending;
        3'd1:    rdata = mask;
        3'd4:    rdata = 32'(target);
        default: rdata = '0;
      endcase
    end else if (cpu_valid) begin
      rdata = (word == 3'd0) ? cpu_pending[idx] : '0;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      bus_o <= IOB_RSP_IDLE;
    end else begin
      bus_o.ack   <= access;
      bus_o.err   <= 1'b0;
      bus_o.rdata <= rdata;
    end
  end

endmodule
