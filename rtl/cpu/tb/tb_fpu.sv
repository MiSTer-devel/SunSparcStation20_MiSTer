// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_fpu: the FPU against the reference vectors of tests/fpu (an exact
// IEEE 754 model with the SPARC conventions, tests/fpu/README.md): every
// FPop in both precisions and all four rounding modes, result bits and
// the cexc flags. Then the state machine: a trapped exception (TEM), the
// FQ, the exception state, a sequence error, an unimplemented (quad) op.
//
// Run from the repository root (the vectors are opened by relative path):
//   rtl/tb/run.sh tb_fpu

module tb_fpu
  import fpu_pkg::*;
  import tb_pkg::*;
#(
  parameter string VEC = "tests/fpu/vectors"
);
  logic clk, rst;
  initial begin clk = 0; rst = 1; end
  always #5 clk = ~clk;

  fpu_req_t req;
  fpu_rsp_t rsp;
  fpu u_fpu (.clk, .rst, .req_i(req), .rsp_o(rsp));

  task automatic idle();
    req = '0;
  endtask

  task automatic wr_fsr(input logic [31:0] v);
    @(negedge clk); req = '0; req.fsr_wr = 1'b1; req.fsr_wdata = v;
    @(negedge clk); req = '0;
  endtask

  task automatic wr_reg(input logic [4:0] r, input logic dbl, input logic [63:0] v);
    @(negedge clk); req = '0; req.wr_valid = 1'b1; req.wr_addr = r; req.wr_dbl = dbl;
    req.wr_data = dbl ? v : {32'd0, v[31:0]};
    @(negedge clk); req = '0;
  endtask

  task automatic fpop(input logic [31:0] inst, input logic [31:0] pc);
    @(negedge clk); req = '0; req.fpop_valid = 1'b1; req.fpop_inst = inst; req.fpop_pc = pc;
    @(negedge clk); req = '0;
    while (rsp.busy) @(negedge clk);
  endtask

  function automatic logic [31:0] enc(input logic fpop2, input logic [4:0] rd, input logic [4:0] rs1,
                                       input logic [8:0] opf, input logic [4:0] rs2);
    return {2'b10, rd, fpop2 ? 6'h35 : 6'h34, rs1, opf, rs2};
  endfunction

  // the register read port is combinational: give it a moment
  task automatic rd_pair(input logic [4:0] r, output logic [63:0] v);
    req.rd_addr = r;
    #1;
    v = rsp.rd_data;
  endtask

  // ---- the vectors ----
  typedef struct {
    string      name;
    logic [8:0] opf;
    bit         fpop2;
    bit         two;       // two operands
    bit         src_dbl;   // operand width (int operands are single-width)
    bit         dst_dbl;
    bit         cmp;
  } vop_t;

  vop_t ops [24] = '{
    '{"fadds",  9'h041, 0, 1, 0, 0, 0}, '{"faddd",  9'h042, 0, 1, 1, 1, 0},
    '{"fsubs",  9'h045, 0, 1, 0, 0, 0}, '{"fsubd",  9'h046, 0, 1, 1, 1, 0},
    '{"fmuls",  9'h049, 0, 1, 0, 0, 0}, '{"fmuld",  9'h04A, 0, 1, 1, 1, 0},
    '{"fdivs",  9'h04D, 0, 1, 0, 0, 0}, '{"fdivd",  9'h04E, 0, 1, 1, 1, 0},
    '{"fsmuld", 9'h069, 0, 1, 0, 1, 0},
    '{"fsqrts", 9'h029, 0, 0, 0, 0, 0}, '{"fsqrtd", 9'h02A, 0, 0, 1, 1, 0},
    '{"fcmps",  9'h051, 1, 1, 0, 0, 1}, '{"fcmpd",  9'h052, 1, 1, 1, 1, 1},
    '{"fcmpes", 9'h055, 1, 1, 0, 0, 1}, '{"fcmped", 9'h056, 1, 1, 1, 1, 1},
    '{"fitos",  9'h0C4, 0, 0, 0, 0, 0}, '{"fitod",  9'h0C8, 0, 0, 0, 1, 0},
    '{"fstoi",  9'h0D1, 0, 0, 0, 0, 0}, '{"fdtoi",  9'h0D2, 0, 0, 1, 0, 0},
    '{"fstod",  9'h0C9, 0, 0, 0, 1, 0}, '{"fdtos",  9'h0C6, 0, 0, 1, 0, 0},
    '{"fmovs",  9'h001, 0, 0, 0, 0, 0}, '{"fnegs",  9'h005, 0, 0, 0, 0, 0},
    '{"fabss",  9'h009, 0, 0, 0, 0, 0}
  };

  int          fd;
  string       line;
  int          rm;
  logic [63:0] va, vb, vres, got;
  logic [4:0]  vflags;
  int          n, nfail, total;

  initial begin
    idle();
    repeat (3) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);

    total = 0;
    foreach (ops[k]) begin
      fd = $fopen({VEC, "/", ops[k].name, ".txt"}, "r");
      if (fd == 0) begin
        $display("FAIL: cannot open %s/%s.txt (run from the repository root)", VEC, ops[k].name);
        $fatal(1, "no vectors");
      end
      n = 0; nfail = 0;
      while ($fgets(line, fd) != 0) begin
        if (line.len() == 0 || line[0] == "#") continue;
        if ($sscanf(line, "%d %h %h %h %b", rm, va, vb, vres, vflags) != 5) continue;
        n++;
        wr_fsr({rm[1:0], 30'd0});
        // rs1 in f0, rs2 in f2; a one-operand op takes rs2 (f2), with
        // rs1 = f0 left holding something else so that a mix-up shows
        if (ops[k].two) begin
          wr_reg(5'd0, ops[k].src_dbl, va);
          wr_reg(5'd2, ops[k].src_dbl, vb);
        end else begin
          wr_reg(5'd0, 1'b1, 64'h4000_0000_0000_0000);
          wr_reg(5'd2, ops[k].src_dbl, va);
        end
        wr_reg(5'd4, 1'b1, 64'hDEAD_BEEF_DEAD_BEEF);      // the destination, to see a missing write
        fpop(enc(ops[k].fpop2, 5'd4, 5'd0, ops[k].opf, 5'd2), 32'h1000);
        @(negedge clk);
        if (ops[k].cmp) begin
          got = {62'd0, rsp.fsr[11:10]};
        end else begin
          rd_pair(5'd4, got);
          if (!ops[k].dst_dbl) got = {32'd0, got[63:32]};
        end
        tb_checks++;
        if (got !== vres || rsp.fsr[4:0] !== vflags) begin
          tb_errors++;
          if (nfail < 10)
            $display("FAIL %s rm=%0d a=%h b=%h: got %h flags %b, expected %h flags %b",
                     ops[k].name, rm, va, vb, got, rsp.fsr[4:0], vres, vflags);
          nfail++;
        end
      end
      $fclose(fd);
      $display("%-7s %6d vectors, %0d failed", ops[k].name, n, nfail);
      total += n;
    end
    $display("vectors: %0d", total);

    // ---- the state machine ----
    // A trapped exception: TEM.DZ, 1/0: no result, ftt 1, cexc DZ, the FQ
    // holds the op, exc_pending; then the trap: exc_state; stdfq ends it.
    wr_fsr(32'h0100_0000);
    wr_reg(5'd0, 1'b0, 64'h3F80_0000);
    wr_reg(5'd1, 1'b0, 64'h0);
    wr_reg(5'd2, 1'b0, 64'h1234_5678);
    fpop(enc(0, 5'd2, 5'd0, 9'h04D, 5'd1), 32'h2000);   // fdivs %f0, %f1, %f2
    @(negedge clk);
    check(rsp.exc_pending, "trapped: exc_pending");
    check(!rsp.exc_state, "trapped: not yet in fp_exception");
    check32(rsp.fsr, 32'h0100_6002, "trapped: FSR = TEM.DZ, ftt 1, qne, cexc DZ");
    rd_pair(5'd2, got);
    check(got[63:32] == 32'h1234_5678, "trapped: no result written");
    check(rsp.fq == {32'h2000, enc(0, 5'd2, 5'd0, 9'h04D, 5'd1)}, "FQ holds the op");
    @(negedge clk); req = '0; req.trap_taken = 1'b1;
    @(negedge clk); req = '0;
    check(rsp.exc_state && !rsp.exc_pending, "trap taken: fp_exception");
    @(negedge clk); req = '0; req.fq_pop = 1'b1;
    @(negedge clk); req = '0;
    check(!rsp.exc_state && !rsp.exc_pending, "stdfq: back to fp_execute");
    check32(rsp.fsr, 32'h0100_4002, "after stdfq: qne 0, ftt kept");
    // a sequence error reported by the IU (an stdfq on the empty queue): ftt 4
    @(negedge clk); req = '0; req.trap_taken = 1'b1;
    @(negedge clk); req = '0;
    check32(32'(rsp.fsr[16:14]), 32'd4, "sequence error: ftt 4");
    check(!rsp.exc_state && !rsp.exc_pending, "sequence error: state unchanged");
    // an FPop that completes clears ftt
    wr_fsr(32'h0);
    fpop(enc(0, 5'd3, 5'd0, 9'h001, 5'd0), 32'h2004);   // fmovs
    @(negedge clk);
    check32(rsp.fsr, 32'h0, "fmovs clears ftt and cexc");
    // an unimplemented op (faddq): ftt 3, pending
    fpop(enc(0, 5'd4, 5'd0, 9'h043, 5'd4), 32'h2008);
    @(negedge clk);
    check(rsp.exc_pending, "faddq: exc_pending");
    check32(32'(rsp.fsr[16:14]), 32'd3, "faddq: ftt 3");
    check(rsp.fq[63:32] == 32'h2008, "faddq: queued");
    // ldfsr does not touch ftt or qne
    wr_fsr(32'hC000_0000);
    check32(rsp.fsr, 32'hC000_E000, "ldfsr keeps ftt and qne");
    @(negedge clk); req = '0; req.trap_taken = 1'b1;
    @(negedge clk); req = '0; req.fq_pop = 1'b1;
    @(negedge clk); req = '0;
    // the untrapped underflow of t_fpu: FLT_MIN * FLT_MIN = +0, cexc UF|NX
    wr_fsr(32'h0);
    wr_reg(5'd1, 1'b0, 64'h0080_0000);
    fpop(enc(0, 5'd3, 5'd1, 9'h049, 5'd1), 32'h200C);
    @(negedge clk);
    rd_pair(5'd2, got);
    check32(got[31:0], 32'h0, "FLT_MIN^2 = +0");
    check32(rsp.fsr, 32'h0000_00A5, "FLT_MIN^2: aexc, cexc = UF|NX");
    // and trapped: TEM.UF
    wr_fsr(32'h0F80_0000);
    fpop(enc(0, 5'd3, 5'd1, 9'h049, 5'd1), 32'h2010);
    @(negedge clk);
    check(rsp.exc_pending, "FLT_MIN^2 trapped: pending");
    check32(rsp.fsr, 32'h0F80_6005, "FLT_MIN^2 trapped: ftt 1, qne, cexc UF|NX");

    tb_done("tb_fpu");
  end

endmodule
