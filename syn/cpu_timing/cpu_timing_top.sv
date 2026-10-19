// SPDX-License-Identifier: GPL-2.0-or-later
//
// cpu_timing_top: cpu_module alone for a Quartus timing fit at the
// machine's clock (syn/cpu_timing/run.sh). Every input comes from a
// register of a serial chain and every output goes to a register folded
// into one pin, so all of the module's paths are register to register and
// none is trimmed. The debug outputs are left open, as in a real build.

module cpu_timing_top
  import mem_pkg::*;
(
  input  logic clk,
  input  logic si,
  output logic so
);
  localparam int NRSP = $bits(mem_rsp_t);
  localparam int NSN  = $bits(snoop_t);
  localparam int NI   = 1 + 4 + 4 + 1 + NRSP + NSN;
  localparam int NO   = $bits(mem_req_t) + 4;

  logic [NI-1:0] in_q;
  always_ff @(posedge clk) in_q <= {in_q[NI-2:0], si};

  logic        rst, cache_en;
  logic [3:0]  mid, irl;
  mem_rsp_t    rsp;
  snoop_t      sn;
  assign {rst, mid, irl, cache_en, rsp, sn} = in_q;

  mem_req_t    req;
  logic        hold, wd, sir, halt;

  /* verilator lint_off PINCONNECTEMPTY */
  cpu_module u_cpu (
    .clk, .rst, .mid_i(mid), .irl_i(irl), .cache_en_i(cache_en), .ram_mb_i(12'd464),
    .mem_req_o(req), .mem_rsp_i(rsp), .snoop_i(sn), .snoop_hold_o(hold),
    .wd_reset_o(wd), .si_reset_o(sir), .halt_o(halt),
    .dbg_commit_o(), .dbg_trap_o(), .dbg_tt_o(), .dbg_pc_o(), .dbg_psr_o(), .dbg_w_o());
  /* verilator lint_on PINCONNECTEMPTY */

  logic [NO-1:0] out_q;
  always_ff @(posedge clk) begin
    out_q <= {req, hold, wd, sir, halt};
    so <= ^out_q;
  end
endmodule
