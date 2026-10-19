// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_m48t08: the TOD/NVRAM against the M48T08 datasheet §3 and Table 5.
// CLK_HZ is 1000 here: one second is 1000 clocks.

module tb_m48t08;
  import iobus_pkg::*;
  import tb_pkg::*;

  localparam int CLK_HZ = 1000;
  localparam int SEC = CLK_HZ;

  localparam logic [12:0] CTRL = 13'h1FF8, SECS = 13'h1FF9, MINS = 13'h1FFA, HOURS = 13'h1FFB,
                          DAY = 13'h1FFC, DATE = 13'h1FFD, MONTH = 13'h1FFE, YEAR = 13'h1FFF;
  localparam logic [7:0] W = 8'h80, R = 8'h40;

  logic clk, rst;
  initial begin clk = 0; rst = 1; end
  always #5 clk = ~clk;

  iob_req_t req = IOB_REQ_IDLE;
  iob_rsp_t rsp;
  logic        img_we = 0;
  logic [10:0] img_addr = 0;
  logic [3:0]  img_be = 0;
  logic [31:0] img_wdata = 0, img_rdata;
  logic        seed_valid = 0;
  logic [7:0]  s_sec = 0, s_min = 0, s_hour = 0, s_day = 0, s_date = 0, s_month = 0, s_year = 0;

  m48t08 #(.CLK_HZ(CLK_HZ)) dut (
    .clk, .rst, .bus_i(req), .bus_o(rsp),
    .img_we, .img_addr, .img_be, .img_wdata, .img_rdata,
    .seed_valid, .seed_sec(s_sec), .seed_min(s_min), .seed_hour(s_hour), .seed_day(s_day),
    .seed_date(s_date), .seed_month(s_month), .seed_year(s_year));

  task automatic cycles(input int n);
    repeat (n) @(posedge clk);
    #1;
  endtask

  task automatic bus_write(input logic [12:0] a, input logic [3:0] be, input logic [31:0] d);
    req.req = 1; req.we = 1; req.addr = 28'(a); req.be = be; req.wdata = d;
    do cycles(1); while (!rsp.ack);
    req.req = 0; req.we = 0;
  endtask

  task automatic bus_read(input logic [12:0] a, output logic [31:0] d);
    req.req = 1; req.we = 0; req.addr = 28'(a); req.be = '1;
    do cycles(1); while (!rsp.ack);
    d = rsp.rdata;
    req.req = 0;
  endtask

  // Byte accesses: lane 3 is byte offset 0.
  task automatic wr8(input logic [12:0] a, input logic [7:0] d);
    bus_write(a, 4'b1000 >> a[1:0], {4{d}});
  endtask

  task automatic rd8(input logic [12:0] a, output logic [7:0] d);
    logic [31:0] w;
    bus_read(a, w);
    d = w[8 * (3 - int'(a[1:0])) +: 8];
  endtask

  task automatic set_time(input logic [7:0] sec, min, hour, day, date, month, year);
    wr8(CTRL, W);
    wr8(SECS, sec); wr8(MINS, min); wr8(HOURS, hour); wr8(DAY, day);
    wr8(DATE, date); wr8(MONTH, month); wr8(YEAR, year);
    wr8(CTRL, 8'h00);
  endtask

  task automatic read_time(output logic [7:0] sec, min, hour, day, date, month, year);
    wr8(CTRL, R);
    rd8(SECS, sec); rd8(MINS, min); rd8(HOURS, hour); rd8(DAY, day);
    rd8(DATE, date); rd8(MONTH, month); rd8(YEAR, year);
    wr8(CTRL, 8'h00);
  endtask

  task automatic expect_time(input string what, input logic [7:0] sec, min, hour, day, date, month, year);
    logic [7:0] gs, gm, gh, gd, gdt, gmo, gy;
    read_time(gs, gm, gh, gd, gdt, gmo, gy);
    check({gs, gm, gh, gd, gdt, gmo, gy} == {sec, min, hour, day, date, month, year},
          $sformatf("%s: %02x:%02x:%02x day %0d %02x/%02x/%02x", what, gh, gm, gs, gd, gdt, gmo, gy));
  endtask

  logic [7:0] b, b2;
  logic [31:0] v;

  initial begin
    cycles(3);
    rst = 0;
    cycles(2);

    // ---- the RAM: bytes, lanes, words ----
    wr8(13'h0000, 8'h11); wr8(13'h0001, 8'h22); wr8(13'h0002, 8'h33); wr8(13'h0003, 8'h44);
    bus_read(13'h0000, v);  check32(v, 32'h1122_3344, "bytes land in big-endian lanes");
    rd8(13'h0001, b);       check(b == 8'h22, "byte read picks its lane");
    bus_write(13'h0004, 4'b0110, 32'hAABB_CCDD);
    bus_read(13'h0004, v);  check(v[23:8] == 16'hBBCC, "partial word write touches only its lanes");
    bus_write(13'h1FD8, 4'b1111, 32'h0172_0800);  // an IDPROM header: format 1, type 0x72
    bus_read(13'h1FD8, v);  check32(v, 32'h0172_0800, "IDPROM bytes are plain RAM");
    wr8(13'h1FF7, 8'h5A);
    rd8(13'h1FF7, b);       check(b == 8'h5A, "last RAM byte before the clock");

    // ---- the image port sees the same RAM ----
    cycles(1);
    img_addr = 11'h000; cycles(1);  // registered output
    check32(img_rdata, 32'h1122_3344, "image port reads what the bus wrote");
    img_addr = 11'h100; img_be = 4'b1111; img_wdata = 32'hDEAD_BEEF; img_we = 1; cycles(1); img_we = 0;
    bus_read(13'h0400, v);  check32(v, 32'hDEAD_BEEF, "bus reads what the image port wrote");
    img_addr = 11'h7FE; img_be = 4'b1111; img_wdata = 32'hFFFF_FFFF; img_we = 1; cycles(1); img_we = 0;
    rd8(CTRL, b);           check(b == 8'h00, "image writes to the clock bytes are ignored");

    // ---- the clock counts seconds, in BCD ----
    set_time(8'h58, 8'h59, 8'h23, 8'h07, 8'h31, 8'h12, 8'h99);
    expect_time("set", 8'h58, 8'h59, 8'h23, 8'h07, 8'h31, 8'h12, 8'h99);
    cycles(SEC);
    expect_time("+1 s", 8'h59, 8'h59, 8'h23, 8'h07, 8'h31, 8'h12, 8'h99);
    cycles(SEC);
    expect_time("new century", 8'h00, 8'h00, 8'h00, 8'h01, 8'h01, 8'h01, 8'h00);

    // ---- month lengths and leap years ----
    set_time(8'h59, 8'h59, 8'h23, 8'h01, 8'h28, 8'h02, 8'h00);   // 2000 is a leap year
    cycles(SEC);
    expect_time("Feb 28 -> 29 in a leap year", 8'h00, 8'h00, 8'h00, 8'h02, 8'h29, 8'h02, 8'h00);
    set_time(8'h59, 8'h59, 8'h23, 8'h01, 8'h28, 8'h02, 8'h99);
    cycles(SEC);
    expect_time("Feb 28 -> Mar 1 otherwise", 8'h00, 8'h00, 8'h00, 8'h02, 8'h01, 8'h03, 8'h99);
    set_time(8'h59, 8'h59, 8'h23, 8'h01, 8'h29, 8'h02, 8'h96);
    cycles(SEC);
    expect_time("Feb 29 -> Mar 1 in 1996", 8'h00, 8'h00, 8'h00, 8'h02, 8'h01, 8'h03, 8'h96);
    set_time(8'h59, 8'h59, 8'h23, 8'h01, 8'h30, 8'h04, 8'h26);
    cycles(SEC);
    expect_time("Apr 30 -> May 1", 8'h00, 8'h00, 8'h00, 8'h02, 8'h01, 8'h05, 8'h26);
    set_time(8'h59, 8'h59, 8'h23, 8'h01, 8'h30, 8'h05, 8'h26);
    cycles(SEC);
    expect_time("May 30 -> 31", 8'h00, 8'h00, 8'h00, 8'h02, 8'h31, 8'h05, 8'h26);
    set_time(8'h59, 8'h59, 8'h23, 8'h01, 8'h09, 8'h10, 8'h26);
    cycles(SEC);
    expect_time("BCD date carry 09 -> 10", 8'h00, 8'h00, 8'h00, 8'h02, 8'h10, 8'h10, 8'h26);
    set_time(8'h59, 8'h09, 8'h09, 8'h01, 8'h01, 8'h01, 8'h26);
    cycles(SEC);
    expect_time("BCD minute/hour carries", 8'h00, 8'h10, 8'h09, 8'h01, 8'h01, 8'h01, 8'h26);

    // ---- R freezes the registers, not the clock (§3.1) ----
    set_time(8'h00, 8'h00, 8'h12, 8'h03, 8'h15, 8'h06, 8'h26);
    wr8(CTRL, R);
    rd8(SECS, b);
    cycles(2 * SEC);
    rd8(SECS, b2);
    check(b == b2, "with R set the seconds register holds");
    wr8(CTRL, 8'h00);
    cycles(2);
    rd8(SECS, b2);
    check(b2 == 8'h02, "the clock ran on behind the frozen registers");

    // ---- ST stops the oscillator (§3.3) ----
    wr8(CTRL, W);
    wr8(SECS, 8'h80 | 8'h30);           // ST, 30 s
    wr8(CTRL, 8'h00);
    cycles(2 * SEC);
    rd8(SECS, b);
    check(b == 8'hB0, "stopped: ST reads back and the seconds hold");
    wr8(CTRL, W);
    wr8(SECS, 8'h30);
    wr8(CTRL, 8'h00);
    cycles(SEC);
    rd8(SECS, b);
    check(b == 8'h31, "ST cleared: counting again");

    // ---- control and FT bits store; zero bits read 0 ----
    wr8(CTRL, W | 8'h3F);               // W, S and all calibration bits
    rd8(CTRL, b);                       check(b == 8'hBF, "control reads back");
    wr8(DAY, 8'hFF);
    rd8(DAY, b);                        check(b == 8'h47, "day: FT and the three day bits only");
    wr8(MONTH, 8'hFF);  rd8(MONTH, b);  check(b == 8'h1F, "month: five bits");
    wr8(DATE, 8'hFF);   rd8(DATE, b);   check(b == 8'h3F, "date: six bits");
    wr8(HOURS, 8'hFF);  rd8(HOURS, b);  check(b == 8'h3F, "hours: six bits");
    wr8(MINS, 8'hFF);   rd8(MINS, b);   check(b == 8'h7F, "minutes: seven bits");
    wr8(CTRL, 8'h00);
    cycles(2);
    rd8(CTRL, b);                       check(b == 8'h00, "control cleared");

    // ---- a word read of the clock bytes ----
    set_time(8'h05, 8'h04, 8'h03, 8'h02, 8'h01, 8'h11, 8'h26);
    wr8(CTRL, R);
    bus_read(13'h1FF8, v);  check32(v, 32'h4005_0403, "word at 1FF8: ctrl, sec, min, hour");
    bus_read(13'h1FFC, v);  check32(v, 32'h0201_1126, "word at 1FFC: day, date, month, year");
    img_addr = 11'h7FF; cycles(1);
    check32(img_rdata, 32'h0201_1126, "the image port reads the clock bytes too");
    wr8(CTRL, 8'h00);

    // ---- the host seed loads the time ----
    s_sec = 8'h45; s_min = 8'h30; s_hour = 8'h21; s_day = 8'h05; s_date = 8'h24; s_month = 8'h12; s_year = 8'h25;
    seed_valid = 1; cycles(1); seed_valid = 0;
    expect_time("seeded", 8'h45, 8'h30, 8'h21, 8'h05, 8'h24, 8'h12, 8'h25);
    cycles(SEC);
    expect_time("seeded and running", 8'h46, 8'h30, 8'h21, 8'h05, 8'h24, 8'h12, 8'h25);

    tb_done("tb_m48t08");
  end

  initial begin
    #(100 * SEC * 10 + 1_000_000);
    $display("FAIL: timeout");
    $fatal(1, "timeout");
  end
endmodule
