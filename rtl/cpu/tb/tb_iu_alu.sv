// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_iu_alu: every single-cycle op against a reference written from V8
// Appendix C and §B (the same rules as tests/cpu/gen_alu.py), on corner
// cases and random operands.

module tb_iu_alu;
  import cpu_pkg::*;
  import tb_pkg::*;

  logic [5:0]  op3;
  logic [31:0] a, b, y;
  logic [3:0]  icc;
  logic [31:0] r, yo;
  logic [3:0]  icc_o;
  logic        cc, wy, tag_trap;

  iu_alu dut (.op3_i(op3), .a_i(a), .b_i(b), .y_i(y), .icc_i(icc),
              .r_o(r), .icc_o(icc_o), .cc_o(cc), .y_o(yo), .wy_o(wy), .tag_trap_o(tag_trap));

  // ---- the reference ----
  function automatic logic [1:0] add_flags(input logic [31:0] x, input logic [31:0] z, input logic [31:0] s);
    return {(x[31] & z[31] & ~s[31]) | (~x[31] & ~z[31] & s[31]),
            (x[31] & z[31]) | (~s[31] & (x[31] | z[31]))};
  endfunction
  function automatic logic [1:0] sub_flags(input logic [31:0] x, input logic [31:0] z, input logic [31:0] s);
    return {(x[31] & ~z[31] & ~s[31]) | (~x[31] & z[31] & s[31]),
            (~x[31] & z[31]) | (~(x[31] ^ z[31]) & s[31])};
  endfunction

  typedef struct { logic [31:0] r; logic [3:0] icc; logic cc; logic [31:0] y; logic wy; logic trap; } ref_t;

  function automatic ref_t model(input logic [5:0] op, input logic [31:0] x, input logic [31:0] z,
                                 input logic [31:0] yi, input logic [3:0] ic);
    ref_t m;
    logic [31:0] s, o1, o2;
    logic v, c, cin;
    m.r = 'x; m.icc = ic; m.cc = 0; m.y = yi; m.wy = 0; m.trap = 0;
    v = 0; c = 0; cin = ic[0];
    case (op)
      6'h00, 6'h10: begin s = x + z; {v, c} = add_flags(x, z, s); m.r = s; end
      6'h08, 6'h18: begin s = x + z + 32'(cin); {v, c} = add_flags(x, z, s); m.r = s; end
      6'h04, 6'h14: begin s = x - z; {v, c} = sub_flags(x, z, s); m.r = s; end
      6'h0C, 6'h1C: begin s = x - z - 32'(cin); {v, c} = sub_flags(x, z, s); m.r = s; end
      6'h01, 6'h11: m.r = x & z;
      6'h02, 6'h12: m.r = x | z;
      6'h03, 6'h13: m.r = x ^ z;
      6'h05, 6'h15: m.r = x & ~z;
      6'h06, 6'h16: m.r = x | ~z;
      6'h07, 6'h17: m.r = ~(x ^ z);
      6'h25: m.r = x << z[4:0];
      6'h26: m.r = x >> z[4:0];
      6'h27: m.r = $signed(x) >>> z[4:0];
      6'h20, 6'h22: begin s = x + z; {v, c} = add_flags(x, z, s); if (|x[1:0] || |z[1:0]) v = 1; m.r = s; end
      6'h21, 6'h23: begin s = x - z; {v, c} = sub_flags(x, z, s); if (|x[1:0] || |z[1:0]) v = 1; m.r = s; end
      6'h24: begin
        o1 = {ic[3] ^ ic[1], x[31:1]};
        o2 = yi[0] ? z : 32'd0;
        s = o1 + o2; {v, c} = add_flags(o1, o2, s); m.r = s;
        m.y = {x[0], yi[31:1]}; m.wy = 1;
      end
      default: m.r = x + z;
    endcase
    if (op[4] && !op[5]) m.cc = 1;                         // 0x10-0x1F
    if (op >= 6'h20 && op <= 6'h24) m.cc = 1;
    if ((op == 6'h22 || op == 6'h23) && v) begin
      m.trap = 1; m.cc = 0; m.r = x;
    end
    if (m.cc) m.icc = {m.r[31], m.r == 32'd0, v, c};
    return m;
  endfunction

  task automatic run(input logic [5:0] op, input logic [31:0] x, input logic [31:0] z, input logic [31:0] yi, input logic [3:0] ic);
    ref_t m;
    op3 = op; a = x; b = z; y = yi; icc = ic;
    #1;
    m = model(op, x, z, yi, ic);
    check(r === m.r || (m.trap && tag_trap), $sformatf("op3 %02x a=%08x b=%08x: r %08x exp %08x", op, x, z, r, m.r));
    check(cc == m.cc, $sformatf("op3 %02x a=%08x b=%08x: cc %0d exp %0d", op, x, z, cc, m.cc));
    if (m.cc) check(icc_o == m.icc, $sformatf("op3 %02x a=%08x b=%08x y=%08x icc_in=%x: icc %x exp %x", op, x, z, yi, ic, icc_o, m.icc));
    check(tag_trap == m.trap, $sformatf("op3 %02x a=%08x b=%08x: tag trap %0d exp %0d", op, x, z, tag_trap, m.trap));
    check(wy == m.wy && (!m.wy || yo == m.y), $sformatf("op3 %02x: Y %08x exp %08x (wy %0d)", op, yo, m.y, wy));
  endtask

  localparam logic [5:0] OPS [0:30] = '{6'h00, 6'h01, 6'h02, 6'h03, 6'h04, 6'h05, 6'h06, 6'h07, 6'h08, 6'h0C,
                                        6'h10, 6'h11, 6'h12, 6'h13, 6'h14, 6'h15, 6'h16, 6'h17, 6'h18, 6'h1C,
                                        6'h20, 6'h21, 6'h22, 6'h23, 6'h24, 6'h25, 6'h26, 6'h27, 6'h3C, 6'h38, 6'h0E};
  localparam logic [31:0] CORNERS [0:9] = '{32'h0, 32'h1, 32'hFFFF_FFFF, 32'h7FFF_FFFF, 32'h8000_0000, 32'h8000_0001,
                                            32'h0000_0003, 32'hFFFF_FFFC, 32'h1234_5678, 32'h0000_001F};

  initial begin
    for (int i = 0; i < 31; i++)
      for (int j = 0; j < 10; j++)
        for (int k = 0; k < 10; k++)
          for (int c = 0; c < 2; c++)
            run(OPS[i], CORNERS[j], CORNERS[k], c == 1 ? 32'hA5A5_A5A5 : 32'h5A5A_5A5A, c == 1 ? 4'b1001 : 4'b0100);
    for (int n = 0; n < 20000; n++)
      run(OPS[$urandom_range(0, 30)], $urandom, $urandom, $urandom, 4'($urandom));
    tb_done("tb_iu_alu");
  end
endmodule
