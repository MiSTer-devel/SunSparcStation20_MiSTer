// SPDX-License-Identifier: GPL-2.0-or-later
//
// tb_slavio_misc: the LED, Aux 0, power and System Control registers
// against Sun-4M §5.1.1, §5.4.1, §9.8, §9.9 and §12.

module tb_slavio_misc;
  import iobus_pkg::*;
  import tb_pkg::*;

  localparam logic [23:0] LEDS = 24'h600000, AUX0 = 24'h800000, POWER = 24'hA01000, SYSCTL = 24'hF00000;

  logic clk, rst;
  initial begin clk = 0; rst = 1; end
  always #5 clk = ~clk;

  iob_req_t req = IOB_REQ_IDLE;
  iob_rsp_t rsp;
  logic rst_swr = 0, rst_switch = 0;
  logic [15:0] leds;
  logic led, fd_tc, power_off, pwr_irq, sw_reset;
  logic fd_density = 0, pwr_fail = 0, diag_sw = 0;

  slavio_misc dut (
    .clk, .rst, .rst_swr_i(rst_swr), .rst_switch_i(rst_switch), .wd_i(1'b0), .bus_i(req), .bus_o(rsp),
    .leds_o(leds), .led_o(led), .fd_tc_o(fd_tc), .fd_density_i(fd_density),
    .power_off_o(power_off), .pwr_fail_i(pwr_fail), .pwr_irq_o(pwr_irq),
    .diag_sw_i(diag_sw), .cfg_cg3_i(1'b1), .cfg_noautoboot_i(1'b0), .cfg_serial_i(1'b0), .cfg_ram_mb_i(10'd464),
    .sw_reset_o(sw_reset));

  task automatic cycles(input int n);
    repeat (n) @(posedge clk);
    #1;
  endtask

  task automatic bus_write(input logic [23:0] a, input logic [3:0] be, input logic [31:0] d);
    req.req = 1; req.we = 1; req.addr = 28'(a); req.be = be; req.wdata = d;
    do cycles(1); while (!rsp.ack);
    req.req = 0; req.we = 0;
  endtask

  task automatic bus_read(input logic [23:0] a, output logic [31:0] d);
    req.req = 1; req.we = 0; req.addr = 28'(a); req.be = '1;
    do cycles(1); while (!rsp.ack);
    d = rsp.rdata;
    req.req = 0;
  endtask

  task automatic wr8(input logic [23:0] a, input logic [7:0] d);
    bus_write(a, 4'b1000 >> a[1:0], {4{d}});
  endtask

  task automatic rd8(input logic [23:0] a, output logic [7:0] d);
    logic [31:0] w;
    bus_read(a, w);
    d = w[8 * (3 - int'(a[1:0])) +: 8];
  endtask

  logic [7:0] b;
  logic [31:0] v;
  int seen;

  initial begin
    cycles(3);
    rst = 0;
    cycles(2);

    // ---- after a power-on reset ----
    check(leds == 16'h0000, "LEDs all lit at reset");
    bus_read(SYSCTL, v);  check32(v, 32'h0, "system control: no status bits after POR");
    rd8(AUX0, b);         check(b == 8'hC0, "Aux 0: bits 7:6 read 1, the rest 0");
    rd8(POWER, b);        check(b == 8'h00, "power register clear");
    bus_read(AUX0, v);        check32(v, 32'hC012_0044, "config word 0: HWCONF 0x12, video present, CG3");
    bus_read(AUX0 + 8, v);    check32(v, 32'd55_000_000, "config +8: the CPU clock");
    bus_read(AUX0 + 'h1C, v); check32(v, 32'h5A00_01D0, "config +0x1C: 0x5A and 464 MB");
    bus_read(AUX0 + 'h18, v); check32(v, 32'h0, "config +0x18: no Direct SD");
    check(!power_off && !pwr_irq && !led, "outputs quiet");

    // ---- LEDs: 16-bit write-only register ----
    bus_write(LEDS, 4'b1100, 32'hA5C3_0000);
    check(leds == 16'hA5C3, "LEDs take the high half-word");
    bus_write(LEDS, 4'b0011, 32'h0000_FFFF);
    check(leds == 16'hA5C3, "a write to the low half-word is not the LEDs");

    // ---- Aux 0 ----
    wr8(AUX0, 8'h01);
    check(led == 1, "Aux 0 bit 0 drives the LED");
    rd8(AUX0, b);         check(b == 8'hC1, "Aux 0 reads back with bits 7:6 set");
    fd_density = 1;
    rd8(AUX0, b);         check(b == 8'hE1, "bit 5 is the floppy density input");
    seen = 0;
    fork
      begin
        wr8(AUX0, 8'h03);
      end
      begin
        repeat (6) begin cycles(1); if (fd_tc) seen++; end
      end
    join
    check(seen == 1, $sformatf("terminal count is a one-cycle pulse (%0d)", seen));
    rd8(AUX0, b);         check(b[1] == 0, "terminal count bit reads 0");
    wr8(AUX0, 8'h1C);
    rd8(AUX0, b);         check(b == 8'hFC, "reserved bits 4:2 store; LED off");

    // ---- power ----
    pwr_fail = 1; cycles(1); pwr_fail = 0; cycles(1);
    check(pwr_irq, "power fail latched into an interrupt");
    rd8(POWER, b);        check(b[5] == 1, "power fail visible in bit 5");
    wr8(POWER, 8'h02);
    check(!pwr_irq, "bit 1 clears it");
    rd8(POWER, b);        check(b == 8'h00, "cleared");
    wr8(POWER, 8'h01);
    check(power_off, "bit 0 powers off");
    rd8(POWER, b);        check(b[0] == 1, "and reads back");

    // ---- system control: software reset and the status bits ----
    diag_sw = 1;
    bus_read(SYSCTL, v);  check32(v, 32'h4, "DIAG.SW reads in bit 2");
    seen = 0;
    fork
      bus_write(SYSCTL, 4'b1111, 32'h1);
      begin repeat (6) begin cycles(1); if (sw_reset) seen++; end end
    join
    check(seen == 1, "SW_RST is a pulse to the reset logic");
    // the reset that follows, as a software reset
    rst_swr = 1; rst = 1; cycles(2); rst = 0; rst_swr = 0; cycles(1);
    bus_read(SYSCTL, v);  check32(v, 32'h6, "after a software reset: SW_RST_STAT (and DIAG.SW)");
    check(!power_off && leds == '0, "the reset cleared the other registers");
    bus_write(SYSCTL, 4'b1111, 32'h0000_000C);   // 0 in bit 1 clears it; the 1 in bit 3 does nothing
    bus_read(SYSCTL, v);  check32(v, 32'h4, "SW_RST_STAT cleared by writing 0");
    rst_switch = 1; rst = 1; cycles(2); rst = 0; rst_switch = 0; cycles(1);
    bus_read(SYSCTL, v);  check32(v, 32'hC, "after the reset switch: RST.SW");
    bus_write(SYSCTL, 4'b1111, 32'h0000_0006);   // 0 in bit 3 clears it
    bus_read(SYSCTL, v);  check32(v, 32'h4, "RST.SW cleared by writing 0");
    rst = 1; cycles(2); rst = 0; cycles(1);
    bus_read(SYSCTL, v);  check32(v, 32'h4, "POR: both status bits clear");

    tb_done("tb_slavio_misc");
  end

  initial begin
    #1_000_000;
    $display("FAIL: timeout");
    $fatal(1, "timeout");
  end
endmodule
