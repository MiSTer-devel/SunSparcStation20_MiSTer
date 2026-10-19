// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_hang_dump: the hang reporter's two triggers and its text line, read
// back by an 8N1 receiver: a "C" line when commits stop (the last PC, the
// state words, the last sixteen PCs and eight traps oldest first), nothing
// for a spin without traps until an interrupt trap and user code have
// armed it, then a "T" line; a second C line after progress; the line only while act_o.

module tb_hang_dump;
  import tb_pkg::*;

  localparam int DIV = 4, CBITS = 8, TBITS = 10;

  logic clk, rst;
  initial begin clk = 0; rst = 1; end
  always #5 clk = ~clk;

  logic             commit = 0, trap = 0;
  logic [7:0]       tt = 0;
  logic [31:0]      pc = 0, psr = 32'h04400fc0, x = 32'hdeadbeef;
  logic [5:0][31:0] w;
  logic             txd, act;
  initial for (int k = 0; k < 6; k++) w[k] = 32'h11111111 * (k + 1);

  hang_dump #(.DIV(DIV), .CBITS(CBITS), .TBITS(TBITS)) dut (
    .clk, .rst, .commit_i(commit), .trap_i(trap), .tt_i(tt), .pc_i(pc), .psr_i(psr),
    .w_i(w), .x_i(x), .txd_o(txd), .act_o(act));

  task automatic cycles(input int n);
    repeat (n) @(posedge clk);
    #1;
  endtask

  // the receiver: characters into the current line; a line ends at "\n"
  string line = "", lines[$];
  int    bad_idle;
  initial begin
    logic [7:0] c;
    forever begin
      @(negedge txd);
      repeat (DIV / 2) @(posedge clk);
      for (int b = 0; b < 8; b++) begin
        repeat (DIV) @(posedge clk);
        c[b] = txd;
      end
      repeat (DIV) @(posedge clk);
      if (txd !== 1'b1) $display("FAIL: framing error");
      if (c == 8'h0a) begin
        if (line != "") lines.push_back(line);
        line = "";
      end else if (c != 8'h0d) begin
        line = {line, string'(c)};
      end
    end
  end
  always @(posedge clk) if (rst) bad_idle <= 0; else if (!act && txd !== 1'b1) bad_idle <= bad_idle + 1;

  task automatic wait_lines(input int n, input int max_cycles);
    for (int t = 0; t < max_cycles && lines.size() < n; t++) cycles(1);
  endtask

  function automatic string expect_c(input logic [31:0] last, input logic [31:0] first_ring,
                                     input logic [31:0] trap_pc0);
    string s = "#HANGC";
    s = {s, $sformatf(" %08x %08x", last, psr)};
    for (int k = 0; k < 6; k++) s = {s, $sformatf(" %08x", w[k])};
    s = {s, $sformatf(" %08x", x)};
    for (int k = 0; k < 16; k++) s = {s, $sformatf(" %08x", first_ring + 32'(4 * k))};
    for (int k = 0; k < 8; k++) s = {s, $sformatf(" %08x", trap_pc0 + 32'(4 * k))};
    s = {s, " 80818283 84858687"};
    return s;
  endfunction

  initial begin
    cycles(3); rst = 0; cycles(2);

    // eight traps that do not arm the T trigger, then 20 commits
    for (int k = 0; k < 8; k++) begin
      pc = 32'h2000 + 32'(4 * k); tt = 8'h80 + 8'(k); trap = 1; cycles(1); trap = 0;
    end
    for (int k = 0; k < 20; k++) begin
      pc = 32'h1000 + 32'(4 * k); commit = 1; cycles(1);
    end
    commit = 0;
    check(!act, "quiet while committing");

    // commits stop: one C line after 2^CBITS cycles
    cycles((1 << CBITS) - 20);
    check(!act, "no line before 2^CBITS cycles");
    wait_lines(1, 40000);
    check(lines.size() == 1, "a C line");
    if (lines.size() >= 1) begin
      check(lines[0] == expect_c(32'h104c, 32'h1010, 32'h2000), "the C line's fields");
      if (lines[0] != expect_c(32'h104c, 32'h1010, 32'h2000))
        $display("  got      %s\n  expected %s", lines[0], expect_c(32'h104c, 32'h1010, 32'h2000));
    end
    cycles(200);
    check(!act && lines.size() == 1, "once per stop");

    // a spin without traps before any interrupt: no T line
    commit = 1;
    cycles(3 << TBITS);
    check(lines.size() == 1, "the T trigger unarmed until an interrupt trap");

    // an interrupt trap alone (a PROM's POST): still no T line
    tt = 8'h1a; trap = 1; cycles(1); trap = 0;
    cycles(3 << TBITS);
    check(lines.size() == 1, "the T trigger unarmed until user code has run");

    // user-mode commits arm it; 2^TBITS cycles without a trap: a T line
    psr = 32'h04400f40; cycles(4); psr = 32'h04400fc0;
    wait_lines(2, 60000);
    check(lines.size() == 2, "a T line");
    if (lines.size() >= 2) check(lines[1].substr(0, 5) == "#HANGT", "the T line's kind");

    // progress, then commits stop again: a second C line
    commit = 0;
    wait_lines(3, 60000);
    check(lines.size() == 3, "a second C line after progress");
    if (lines.size() >= 3) check(lines[2].substr(0, 5) == "#HANGC", "the second line's kind");
    cycles(50);
    check(bad_idle == 0, "the line idle (1) while act_o is low");
    tb_done("tb_hang_dump");
  end
endmodule
