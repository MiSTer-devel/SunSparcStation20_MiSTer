// SPDX-License-Identifier: GPL-2.0-or-later
//
// m48t08: the TOD/NVRAM, an ST (Mostek) M48T08 TIMEKEEPER SRAM: 8 KB of
// battery-backed RAM whose top eight bytes are the clock. The sun4m maps it
// byte-wide at PA 0xF_F120_0000 (Sun-4M §9.3); the IDPROM is the 32 bytes
// at 0x1FD8 of the RAM, plain data this module does not interpret.
//
// From: ST M48T08/M48T08Y/M48T18 datasheet, Doc ID 2411 Rev 10, §3 Clock
//   operations (reading, setting, stopping the oscillator, calibration) and
//   Table 5, the register map; Sun-4M System Architecture §9.3 TOD/NVRAM
//   and §9.3.1 NVRAM/IDPROM. Cross-checked with QEMU hw/rtc/m48t59.c and
//   NetBSD sys/dev/ic/mk48txxreg.h.
//
// The clock registers, BCD (Table 5):
//   1FF8  control: W (bit 7), R (6), S sign (5), calibration (4:0)
//   1FF9  seconds 00-59; ST (bit 7) stops the oscillator
//   1FFA  minutes 00-59
//   1FFB  hours 00-23
//   1FFC  day 01-07; FT (bit 6) frequency test
//   1FFD  date 01-31
//   1FFE  month 01-12
//   1FFF  year 00-99
// Setting R or W halts the updates of the eight registers so they can be
// read consistently; with W set they can be written, and clearing W loads
// the counters from them (§3.1, §3.2). The counters correct for 28/29/30/31
// day months and leap years (every fourth year, so until 2100). ST stops
// the counting (§3.3). The bits Table 5 marks 0 read as 0.
//
// Beyond the chip: an image port, through which the NVRAM's contents are
// loaded from and saved to the image file on the SD card (the battery, in
// effect), and a `seed` of the time of day from the MiSTer's host clock,
// loaded once at start-up by the top level. Writes to the clock bytes
// through the image port are ignored; reads of them return the clock, so a
// saved image carries the time.
//
// Left out: the calibration bits and FT are stored and read back but do
// not alter the rate or the seconds bit.

module m48t08
  import iobus_pkg::*;
#(
  parameter int CLK_HZ = 80_000_000
)(
  input  logic     clk,
  input  logic     rst,

  input  iob_req_t bus_i,                 // addr[12:0] within the 8 KB
  output iob_rsp_t bus_o,

  // Image port: 32-bit words, byte enables, data the next cycle.
  input  logic        img_we,
  input  logic [10:0] img_addr,
  input  logic [3:0]  img_be,
  input  logic [31:0] img_wdata,
  output logic [31:0] img_rdata,

  // Time of day from the host, BCD as in the registers; loaded on seed_valid.
  input  logic        seed_valid,
  input  logic [7:0]  seed_sec, seed_min, seed_hour, seed_day,
  input  logic [7:0]  seed_date, seed_month, seed_year
);

  // ---------------------------------------------------------------------
  // The one-second tick
  // ---------------------------------------------------------------------
  localparam int ACC_W = $clog2(CLK_HZ) + 1;
  logic [ACC_W-1:0] acc;
  logic             tick;

  always_ff @(posedge clk) begin
    if (rst) begin
      acc  <= '0;
      tick <= 1'b0;
    end else if (acc == ACC_W'(CLK_HZ - 1)) begin
      acc  <= '0;
      tick <= 1'b1;
    end else begin
      acc  <= acc + 1'b1;
      tick <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------
  // The counters (BCD) and the registers the bus sees
  // ---------------------------------------------------------------------
  // c_*: the TIMEKEEPER counters. r_*: the eight registers; they follow the
  // counters unless W or R holds them, and are what W loads into the
  // counters when it is cleared.
  logic [6:0] c_sec,  r_sec;       // {tens[2:0], ones[3:0]}
  logic [6:0] c_min,  r_min;
  logic [5:0] c_hour, r_hour;      // {tens[1:0], ones[3:0]}
  logic [2:0] c_day,  r_day;       // 1-7
  logic [5:0] c_date, r_date;      // {tens[1:0], ones[3:0]}
  logic [4:0] c_month, r_month;    // {tens, ones[3:0]}
  logic [7:0] c_year, r_year;
  logic       c_stop, r_stop;      // ST
  logic       r_ft;                // FT, stored only
  logic [7:0] ctrl;                // W, R, S, calibration

  logic hold, w_bit, w_bit_q;
  assign w_bit = ctrl[7];
  assign hold  = ctrl[7] | ctrl[6];

  // BCD helpers
  function automatic logic [7:0] bcd_inc(input logic [7:0] v);
    if (v[3:0] == 4'd9) return {v[7:4] + 4'd1, 4'd0};
    else                return {v[7:4], v[3:0] + 4'd1};
  endfunction

  function automatic logic is_leap(input logic tens_lsb, input logic [1:0] ones);
    // (10*tens + ones) mod 4 == (2*tens + ones) mod 4: only the low bit of
    // the tens digit and the low two bits of the ones digit matter.
    logic [1:0] m;
    m = {tens_lsb, 1'b0} + ones;
    return m == 2'b00;
  endfunction

  function automatic logic [5:0] month_last(input logic [4:0] month, input logic leap);
    case (month)
      5'h02: return leap ? 6'h29 : 6'h28;
      5'h04, 5'h06, 5'h09, 5'h11: return 6'h30;
      default: return 6'h31;
    endcase
  endfunction

  // Access decode: byte lanes of the two clock words at 0x1FF8 and 0x1FFC
  logic        access;
  logic        clk_word;           // addr in 0x1FF8..0x1FFF
  logic        clk_hi;             // the 0x1FFC word
  logic [3:0]  lane;               // the bytes this access touches

  assign access   = bus_i.req & ~bus_o.ack;
  assign clk_word = bus_i.addr[12:3] == 10'h3FF;
  assign clk_hi   = bus_i.addr[2];
  assign lane     = bus_i.be;

  logic wr_clk;
  assign wr_clk = access & bus_i.we & clk_word;

  // The counters
  always_ff @(posedge clk) begin
    if (rst) begin
      // Only the oscillator state: the chip keeps its time across a reset.
      w_bit_q <= 1'b0;
    end else begin
      w_bit_q <= w_bit;
    end
  end

  always_ff @(posedge clk) begin
    if (seed_valid) begin
      c_sec   <= seed_sec[6:0];
      c_min   <= seed_min[6:0];
      c_hour  <= seed_hour[5:0];
      c_day   <= seed_day[2:0];
      c_date  <= seed_date[5:0];
      c_month <= seed_month[4:0];
      c_year  <= seed_year;
      c_stop  <= 1'b0;
    end else if (w_bit_q && !w_bit) begin
      // W cleared: the registers become the time (§3.2)
      c_sec   <= r_sec;
      c_min   <= r_min;
      c_hour  <= r_hour;
      c_day   <= r_day;
      c_date  <= r_date;
      c_month <= r_month;
      c_year  <= r_year;
      c_stop  <= r_stop;
    end else if (tick && !c_stop) begin
      if (c_sec != 7'h59) c_sec <= 7'(bcd_inc({1'b0, c_sec}));
      else begin
        c_sec <= '0;
        if (c_min != 7'h59) c_min <= 7'(bcd_inc({1'b0, c_min}));
        else begin
          c_min <= '0;
          if (c_hour != 6'h23) c_hour <= 6'(bcd_inc({2'b0, c_hour}));
          else begin
            c_hour <= '0;
            c_day  <= (c_day == 3'd7) ? 3'd1 : c_day + 3'd1;
            if (c_date != month_last(c_month, is_leap(c_year[4], c_year[1:0])))
              c_date <= 6'(bcd_inc({2'b0, c_date}));
            else begin
              c_date <= 6'h01;
              if (c_month != 5'h12) c_month <= 5'(bcd_inc({3'b0, c_month}));
              else begin
                c_month <= 5'h01;
                c_year  <= (c_year == 8'h99) ? 8'h00 : bcd_inc(c_year);
              end
            end
          end
        end
      end
    end
  end

  // The registers and the control byte
  always_ff @(posedge clk) begin
    if (rst) begin
      ctrl <= '0;
      r_ft <= 1'b0;
    end else begin
      if (!hold) begin
        r_sec <= c_sec; r_min <= c_min; r_hour <= c_hour; r_day <= c_day;
        r_date <= c_date; r_month <= c_month; r_year <= c_year; r_stop <= c_stop;
      end
      if (seed_valid && !hold) begin
        r_sec <= seed_sec[6:0]; r_min <= seed_min[6:0]; r_hour <= seed_hour[5:0];
        r_day <= seed_day[2:0]; r_date <= seed_date[5:0]; r_month <= seed_month[4:0];
        r_year <= seed_year; r_stop <= 1'b0;
      end
      if (wr_clk && !clk_hi) begin
        if (lane[3]) ctrl <= bus_i.wdata[31:24];                    // 1FF8
        if (lane[2]) {r_stop, r_sec} <= {bus_i.wdata[23], bus_i.wdata[22:16]};  // 1FF9
        if (lane[1]) r_min  <= bus_i.wdata[14:8];                   // 1FFA
        if (lane[0]) r_hour <= bus_i.wdata[5:0];                    // 1FFB
      end
      if (wr_clk && clk_hi) begin
        if (lane[3]) {r_ft, r_day} <= {bus_i.wdata[30], bus_i.wdata[26:24]};  // 1FFC
        if (lane[2]) r_date  <= bus_i.wdata[21:16];                 // 1FFD
        if (lane[1]) r_month <= bus_i.wdata[12:8];                  // 1FFE
        if (lane[0]) r_year  <= bus_i.wdata[7:0];                   // 1FFF
      end
    end
  end

  logic [31:0] clk_word_lo, clk_word_hi;
  assign clk_word_lo = {ctrl, r_stop, r_sec, 1'b0, r_min, 2'b0, r_hour};
  assign clk_word_hi = {1'b0, r_ft, 3'b0, r_day, 2'b0, r_date, 3'b0, r_month, r_year};

  // ---------------------------------------------------------------------
  // The RAM: port A the bus, port B the image
  // ---------------------------------------------------------------------
  logic [31:0] ram_a_q, ram_b_q;

  ram_tdp_be #(.AW(11)) ram (
    .clk,
    .a_addr (bus_i.addr[12:2]),
    .a_we   (access & bus_i.we & ~clk_word),
    .a_be   (bus_i.be),
    .a_wdata(bus_i.wdata),
    .a_rdata(ram_a_q),
    .b_addr (img_addr),
    .b_we   (img_we & (img_addr[10:1] != 10'h3FF)),
    .b_be   (img_be),
    .b_wdata(img_wdata),
    .b_rdata(ram_b_q)
  );

  // Registered selects for the read data (the RAM's data is a cycle late
  // too, so both arrive in the ack cycle).
  logic sel_clk_q, sel_hi_q;
  logic img_clk_q, img_hi_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      bus_o.ack <= 1'b0;
      bus_o.err <= 1'b0;
      sel_clk_q <= 1'b0;
      sel_hi_q  <= 1'b0;
    end else begin
      bus_o.ack <= access;
      bus_o.err <= 1'b0;
      sel_clk_q <= clk_word;
      sel_hi_q  <= clk_hi;
    end
    img_clk_q <= img_addr[10:1] == 10'h3FF;
    img_hi_q  <= img_addr[0];
  end

  assign bus_o.rdata = sel_clk_q ? (sel_hi_q ? clk_word_hi : clk_word_lo) : ram_a_q;
  assign img_rdata   = img_clk_q ? (img_hi_q ? clk_word_hi : clk_word_lo) : ram_b_q;

  logic unused_ok;
  assign unused_ok = &{1'b0, bus_i.pair, bus_i.addr[IOB_AW-1:13], bus_i.addr[1:0],
                       seed_sec[7], seed_min[7], seed_hour[7:6], seed_day[7:3],
                       seed_date[7:6], seed_month[7:5]};

endmodule
