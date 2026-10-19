// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_iu_regfile: the window mapping against V8 §4.1: a window's outs are
// the next window's ins, globals are shared, %g0 is 0, writes forward.

module tb_iu_regfile;
  import cpu_pkg::*;
  import tb_pkg::*;

  logic clk;
  initial clk = 0;
  always #5 clk = ~clk;

  logic [4:0]  rs1 = 0, rs2 = 0, rs3 = 0, rs4 = 0, rd = 0;
  logic [2:0]  rcwp = 0, wcwp = 0;
  logic        we = 0;
  logic [31:0] wdata = 0, o1, o2, o3, o4;

  iu_regfile dut (.clk, .rs1_i(rs1), .rs2_i(rs2), .rs3_i(rs3), .rs4_i(rs4), .rcwp_i(rcwp), .rs1_o(o1), .rs2_o(o2), .rs3_o(o3), .rs4_o(o4),
                  .we_i(we), .rd_i(rd), .wcwp_i(wcwp), .wdata_i(wdata));

  task automatic cycles(input int n);
    repeat (n) @(posedge clk);
    #1;
  endtask

  task automatic write(input logic [2:0] cwp, input logic [4:0] r, input logic [31:0] d);
    we = 1; wcwp = cwp; rd = r; wdata = d;
    cycles(1);
    we = 0;
  endtask

  task automatic read(input logic [2:0] cwp, input logic [4:0] r, output logic [31:0] d);
    rcwp = cwp; rs1 = r;
    cycles(1);
    d = o1;
  endtask

  logic [31:0] v;

  initial begin
    cycles(2);
    // Fill every register of every window with a recognisable value:
    // window in the high byte, register in the low
    for (int w = 0; w < NWINDOWS; w++)
      for (int r = 8; r < 32; r++)
        write(3'(w), 5'(r), {8'(w), 16'h0, 8'(r)});
    for (int r = 1; r < 8; r++) write(0, 5'(r), 32'h1000_0000 + r);

    // Globals: the same from every window
    for (int w = 0; w < NWINDOWS; w++) begin
      read(3'(w), 5'd1, v); check(v == 32'h1000_0001, $sformatf("g1 from window %0d", w));
    end
    read(0, 5'd0, v); check(v == 0, "%g0 reads 0");
    write(0, 5'd0, 32'hFFFF_FFFF);
    read(0, 5'd0, v); check(v == 0, "%g0 stays 0 after a write");

    // Locals are private to the window; the last writer of overlapping
    // registers wins, so check the overlap rule by writing per window:
    // the outs of window w (r8-15) are the ins (r24-31) of window w-1.
    for (int w = 0; w < NWINDOWS; w++)
      for (int i = 0; i < 8; i++) begin
        write(3'(w), 5'(8 + i), {8'hA0 + 8'(w), 16'h0, 8'(i)});
      end
    for (int w = 0; w < NWINDOWS; w++)
      for (int i = 0; i < 8; i++) begin
        read(3'(w - 1), 5'(24 + i), v);
        check(v == {8'hA0 + 8'(w), 16'h0, 8'(i)}, $sformatf("outs of window %0d = ins of window %0d (i=%0d)", w, (w + 7) % 8, i));
      end
    // locals of window w: untouched by the outs writes
    for (int w = 0; w < NWINDOWS; w++) begin
      read(3'(w), 5'd16, v); check(v == {8'(w), 16'h0, 8'd16}, $sformatf("locals of window %0d private", w));
      read(3'(w), 5'd23, v); check(v == {8'(w), 16'h0, 8'd23}, $sformatf("locals of window %0d private (23)", w));
    end
    // Wrap-around: window 0's ins are window 7's outs? No: window 0's
    // ins (24-31) are the outs of window 1; window 7's ins are window 0's outs.
    read(3'd7, 5'd24, v); check(v == {8'hA0, 16'h0, 8'd0}, "window 7's ins are window 0's outs (wrap)");

    // Three read ports at once, and forwarding of a same-cycle write
    rcwp = 2; rs1 = 8; rs2 = 16; rs3 = 24; rs4 = 25;
    cycles(1);
    check(o1 == {8'hA2, 16'h0, 8'd0} && o2 == {8'd2, 16'h0, 8'd16} && o3 == {8'hA3, 16'h0, 8'd0} && o4 == {8'hA3, 16'h0, 8'd1}, "four ports");
    we = 1; wcwp = 2; rd = 16; wdata = 32'hCAFE_0016; rs2 = 16;
    cycles(1);
    we = 0;
    check(o2 == 32'hCAFE_0016, "a write forwards to a same-cycle read");
    cycles(1);
    check(o2 == 32'hCAFE_0016, "and is in the RAM after");

    tb_done("tb_iu_regfile");
  end

  initial begin
    #2_000_000;
    $display("FAIL: timeout");
    $fatal(1, "timeout");
  end
endmodule
