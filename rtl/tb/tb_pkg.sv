// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_pkg: the self-checking helpers shared by the block testbenches.
// A testbench calls check()/check32() and ends with tb_done(), which prints
// the summary and exits non-zero on any failure (core/tb/run.sh looks for
// the PASS line and the exit code).

package tb_pkg;

  int unsigned tb_checks = 0;
  int unsigned tb_errors = 0;

  task automatic check(input bit cond, input string what);
    tb_checks++;
    if (!cond) begin
      tb_errors++;
      $display("FAIL @%0t: %s", $time, what);
    end
  endtask

  task automatic check32(input logic [31:0] got, input logic [31:0] exp, input string what);
    tb_checks++;
    if (got !== exp) begin
      tb_errors++;
      $display("FAIL @%0t: %s: got %08x, expected %08x", $time, what, got, exp);
    end
  endtask

  task automatic tb_done(input string name);
    if (tb_errors == 0) begin
      $display("PASS %s: %0d checks", name, tb_checks);
      $finish;
    end else begin
      $display("FAIL %s: %0d of %0d checks failed", name, tb_errors, tb_checks);
      $fatal(1, "testbench failed");
    end
  endtask

endpackage
