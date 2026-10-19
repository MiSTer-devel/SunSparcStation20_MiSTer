// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_iu_muldiv: umul/smul/udiv/sdiv against 64-bit arithmetic with the V8
// §B.9/§B.18 rules (saturation and V on overflow, divide by zero traps).

module tb_iu_muldiv;
  import tb_pkg::*;

  logic clk, rst;
  initial begin clk = 0; rst = 1; end
  always #5 clk = ~clk;

  logic        start = 0, div = 0, sgn = 0;
  logic [31:0] a = 0, b = 0, y = 0, r, yo;
  logic        busy, done, v, dz;

  iu_muldiv dut (.clk, .rst, .start_i(start), .kill_i(1'b0), .div_i(div), .signed_i(sgn), .a_i(a), .b_i(b), .y_i(y),
                 .busy_o(busy), .done_o(done), .r_o(r), .y_o(yo), .v_o(v), .div_zero_o(dz));

  task automatic cycles(input int n);
    repeat (n) @(posedge clk);
    #1;
  endtask

  task automatic go(input logic d, input logic s, input logic [31:0] x, input logic [31:0] z, input logic [31:0] yi, output int took);
    start = 1; div = d; sgn = s; a = x; b = z; y = yi;
    cycles(1);
    start = 0;
    took = 1;
    while (!done && took < 60) begin cycles(1); took++; end
    check(done, "done arrives");
  endtask

  int took;
  longint unsigned pu;
  longint ps;
  longint unsigned nu, qu;
  longint ns, qs;
  logic [31:0] exp_r, exp_y;
  logic exp_v;

  initial begin
    cycles(3);
    rst = 0;
    cycles(2);

    // ---- multiply ----
    for (int n = 0; n < 3000; n++) begin
      a = $urandom; b = $urandom;
      case (n)
        0: begin a = 32'hFFFF_FFFF; b = 32'hFFFF_FFFF; end
        1: begin a = 32'h8000_0000; b = 32'h8000_0000; end
        2: begin a = 32'h7FFF_FFFF; b = 32'h2; end
        3: begin a = 0; b = 32'h1234_5678; end
        default: ;
      endcase
      pu = longint'(a) * longint'(b);
      go(0, 0, a, b, 32'hDEAD_BEEF, took);
      check(r == pu[31:0] && yo == pu[63:32], $sformatf("umul %08x*%08x: %08x:%08x exp %016x", a, b, yo, r, pu));
      check(took == 4, $sformatf("umul takes 4 cycles (%0d)", took));
      ps = longint'($signed(a)) * longint'($signed(b));
      go(0, 1, a, b, 32'hDEAD_BEEF, took);
      check(r == ps[31:0] && yo == ps[63:32], $sformatf("smul %08x*%08x: %08x:%08x exp %016x", a, b, yo, r, ps));
    end

    // ---- divide ----
    for (int n = 0; n < 3000; n++) begin
      a = $urandom; b = $urandom; y = $urandom;
      case (n % 10)
        0: y = 0;                                   // small dividends
        1: begin y = 0; b = b >> 16; end
        2: begin y = y >> 16; b = b | 32'h8000_0000; end
        3: begin y = 32'hFFFF_FFFF; end             // signed: negative dividends
        4: begin y = 32'hFFFF_FFFF; b = 32'hFFFF_FFFF; end
        5: begin y = 32'h8000_0000; a = 0; b = 32'hFFFF_FFFF; end   // -2^63 / -1
        6: begin b = 1; end
        7: begin y = 0; a = 32'h8000_0000; b = 32'hFFFF_FFFF; end   // 2^31 / -1 = -2^31
        8: begin y = 32'hFFFF_FFFF; a = 32'h8000_0000; b = 1; end   // -2^31 / 1
        default: ;
      endcase
      if (n == 9) b = 0;

      // unsigned
      nu = {y, a};
      go(1, 0, a, b, y, took);
      if (b == 0) begin
        check(dz, "udiv by zero traps");
      end else begin
        qu = nu / longint'(b);
        exp_v = qu > 64'hFFFF_FFFF;
        exp_r = exp_v ? 32'hFFFF_FFFF : qu[31:0];
        check(!dz && r == exp_r && v == exp_v, $sformatf("udiv %08x%08x/%08x: %08x v%0d exp %08x v%0d", y, a, b, r, v, exp_r, exp_v));
        check(yo == y, "udiv leaves Y");
        check(took <= 36, $sformatf("udiv takes <= 36 cycles (%0d)", took));
      end
      // signed
      ns = {y, a};
      go(1, 1, a, b, y, took);
      if (b == 0) begin
        check(dz, "sdiv by zero traps");
      end else if (ns == 64'h8000_0000_0000_0000 && b == 32'hFFFF_FFFF) begin
        check(r == 32'h7FFF_FFFF && v, "sdiv -2^63 / -1 overflows to 7FFFFFFF");
      end else begin
        qs = ns / longint'($signed(b));            // SystemVerilog truncates toward zero
        if (qs > 64'sh7FFF_FFFF) begin exp_r = 32'h7FFF_FFFF; exp_v = 1; end
        else if (qs < -64'sh8000_0000) begin exp_r = 32'h8000_0000; exp_v = 1; end
        else begin exp_r = qs[31:0]; exp_v = 0; end
        check(!dz && r == exp_r && v == exp_v, $sformatf("sdiv %08x%08x/%08x: %08x v%0d exp %08x v%0d", y, a, b, r, v, exp_r, exp_v));
      end
    end
    tb_done("tb_iu_muldiv");
  end

  initial begin
    #20_000_000;
    $display("FAIL: timeout");
    $fatal(1, "timeout");
  end
endmodule
