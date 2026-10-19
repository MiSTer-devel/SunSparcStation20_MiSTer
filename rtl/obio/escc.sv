// SPDX-License-Identifier: GPL-2.0-or-later
//
// escc: a Z85C30 / Am85C30 SCC as a Sun wires it ("zs"): two channels,
// byte registers at offsets 0 (B control), 2 (B data), 4 (A control) and
// 6 (A data), a 4.9152 MHz PCLK that also feeds the RTxC inputs, one INT.
// The SS20 has two: keyboard (A) and mouse (B) at PA 0xF_F100_0000, ttya (A)
// and ttyb (B) at 0xF_F110_0000 (Sun-4M §3.2.2.2.1, §9.1).
//
// From: AMD Am8530H/Am85C30 Technical Manual: §3.4 the register pointer
//   (one set for both channels, reset to 0 after every control access),
//   §3.5.2 Interrupt Without Acknowledge (the RR2 read in channel B returns
//   the status of the highest priority interrupt pending), §6.2.3 WR2,
//   §6.2.10 WR9 (resets, MIE, status high/low, Table 6-4 vector
//   modification), §6.3.3 RR2, §6.3.4 RR3, §6.2.1 Reset Highest IUS.
//   The Sun register offsets and the clock: QEMU hw/char/escc.c and
//   hw/sparc/sun4m.c (ESCC_CLOCK 4915200), Linux sunzilog.h.
//
// Interrupt priority, highest first: Rx A, Tx A, Ext/Status A, Rx B, Tx B,
// Ext/Status B. INT is asserted while any enabled IP is set and no IUS of
// equal or higher priority is set. An IUS is only ever set by the software
// acknowledge of WR9 bit 5 (an RR2 read in channel B), which the Sun
// drivers do not use; Reset Highest IUS clears it.
//
// Left out: the INTACK pin and the daisy chain (IEI/IEO), the DLC and NV
// bits (stored only), everything escc_chan.sv leaves out.

module escc
  import iobus_pkg::*;
#(
  parameter int CLK_HZ  = 80_000_000,
  parameter int PCLK_HZ = 4_915_200
)(
  input  logic     clk,
  input  logic     rst,

  input  iob_req_t bus_i,               // addr[2:1] select the register
  output iob_rsp_t bus_o,

  // Channel A pins (asserted = 1)
  output logic     txd_a_o,
  input  logic     rxd_a_i,
  input  logic     dcd_a_i,
  input  logic     cts_a_i,
  output logic     rts_a_o,
  output logic     dtr_a_o,
  // Channel B pins
  output logic     txd_b_o,
  input  logic     rxd_b_i,
  input  logic     dcd_b_i,
  input  logic     cts_b_i,
  output logic     rts_b_o,
  output logic     dtr_b_o,

  // Byte-level taps of each channel (escc_chan: characters the transmitter
  // starts; bytes to receive), for a host that moves whole characters
  output logic [7:0] tx_byte_a_o,
  output logic       tx_byte_valid_a_o,
  input  logic [7:0] rx_byte_a_i,
  input  logic       rx_byte_valid_a_i,
  output logic       rx_byte_ready_a_o,
  output logic [7:0] tx_byte_b_o,
  output logic       tx_byte_valid_b_o,
  input  logic [7:0] rx_byte_b_i,
  input  logic       rx_byte_valid_b_i,
  output logic       rx_byte_ready_b_o,

  output logic     irq_o                // INT, asserted high
);

  // ---------------------------------------------------------------------
  // PCLK as a clock enable
  // ---------------------------------------------------------------------
  localparam int ACC_W = $clog2(CLK_HZ) + 1;
  logic [ACC_W-1:0] acc;
  logic [ACC_W:0]   acc_next;
  logic             pclk_en;
  assign acc_next = {1'b0, acc} + (ACC_W + 1)'(PCLK_HZ);
  always_ff @(posedge clk) begin
    if (rst) begin
      acc <= '0;
      pclk_en <= 1'b0;
    end else if (acc_next >= (ACC_W + 1)'(CLK_HZ)) begin
      acc <= ACC_W'(acc_next - (ACC_W + 1)'(CLK_HZ));
      pclk_en <= 1'b1;
    end else begin
      acc <= acc_next[ACC_W-1:0];
      pclk_en <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------
  // Bus decode: a byte at offsets 0, 2, 4, 6
  // ---------------------------------------------------------------------
  logic       access, is_a, is_data;
  logic [7:0] wbyte;

  assign access  = bus_i.req & ~bus_o.ack;
  assign is_a    = bus_i.addr[2];
  assign is_data = bus_i.addr[1];
  assign wbyte   = bus_i.wdata[8 * (3 - int'(bus_i.addr[1:0])) +: 8];

  logic ctl_wr_a, ctl_rd_a, dat_wr_a, dat_rd_a;
  logic ctl_wr_b, ctl_rd_b, dat_wr_b, dat_rd_b;
  assign ctl_wr_a = access &  bus_i.we &  is_a & ~is_data;
  assign ctl_rd_a = access & ~bus_i.we &  is_a & ~is_data;
  assign dat_wr_a = access &  bus_i.we &  is_a &  is_data;
  assign dat_rd_a = access & ~bus_i.we &  is_a &  is_data;
  assign ctl_wr_b = access &  bus_i.we & ~is_a & ~is_data;
  assign ctl_rd_b = access & ~bus_i.we & ~is_a & ~is_data;
  assign dat_wr_b = access &  bus_i.we & ~is_a &  is_data;
  assign dat_rd_b = access & ~bus_i.we & ~is_a &  is_data;

  logic ctl_wr, ctl_rd;
  assign ctl_wr = ctl_wr_a | ctl_wr_b;
  assign ctl_rd = ctl_rd_a | ctl_rd_b;

  // ---------------------------------------------------------------------
  // The shared registers: pointer, WR2, WR9
  // ---------------------------------------------------------------------
  logic [3:0] ptr;
  logic [7:0] wr2;
  logic [5:0] wr9;              // bits 5:0; 7:6 are the reset command
  logic       hw_rst, chn_rst_a, chn_rst_b;

  always_comb begin
    hw_rst    = rst | (ctl_wr && ptr == 4'd9 && wbyte[7:6] == 2'b11);
    chn_rst_a = ctl_wr && ptr == 4'd9 && wbyte[7:6] == 2'b10;
    chn_rst_b = ctl_wr && ptr == 4'd9 && wbyte[7:6] == 2'b01;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      ptr <= '0;
      wr2 <= '0;
      wr9 <= '0;
    end else begin
      if (ctl_wr && ptr == 4'd0)
        ptr <= {wbyte[5:3] == 3'b001, wbyte[2:0]};   // Point High adds eight
      else if (ctl_wr || ctl_rd)
        ptr <= '0;                                   // back to 0 after the access

      if (ctl_wr && ptr == 4'd2) wr2 <= wbyte;
      if (ctl_wr && ptr == 4'd9) wr9 <= wbyte[5:0];   // with Force Hardware Reset too: "take the programmed values"
    end
  end

  logic mie, status_high, soft_iack;
  assign mie         = wr9[3];
  assign status_high = wr9[4];
  assign soft_iack   = wr9[5];

  // ---------------------------------------------------------------------
  // The channels
  // ---------------------------------------------------------------------
  logic [7:0] rdata_a, rdata_b;
  logic rx_cond_a, rx_spec_a, tx_ip_a, ext_ip_a;
  logic rx_cond_b, rx_spec_b, tx_ip_b, ext_ip_b;

  escc_chan chan_a (
    .clk, .hw_rst, .chn_rst(chn_rst_a),
    .ctl_wr(ctl_wr_a), .ctl_rd(ctl_rd_a), .dat_wr(dat_wr_a), .dat_rd(dat_rd_a),
    .ptr, .wdata(wbyte), .rdata(rdata_a),
    .pclk_en, .trxc_en(pclk_en),
    .txd_o(txd_a_o), .rxd_i(rxd_a_i), .dcd_i(dcd_a_i), .cts_i(cts_a_i), .rts_o(rts_a_o), .dtr_o(dtr_a_o),
    .tx_byte_o(tx_byte_a_o), .tx_byte_valid_o(tx_byte_valid_a_o),
    .rx_byte_i(rx_byte_a_i), .rx_byte_valid_i(rx_byte_valid_a_i), .rx_byte_ready_o(rx_byte_ready_a_o),
    .rx_cond(rx_cond_a), .rx_special(rx_spec_a), .tx_ip(tx_ip_a), .ext_ip(ext_ip_a));

  escc_chan chan_b (
    .clk, .hw_rst, .chn_rst(chn_rst_b),
    .ctl_wr(ctl_wr_b), .ctl_rd(ctl_rd_b), .dat_wr(dat_wr_b), .dat_rd(dat_rd_b),
    .ptr, .wdata(wbyte), .rdata(rdata_b),
    .pclk_en, .trxc_en(pclk_en),
    .txd_o(txd_b_o), .rxd_i(rxd_b_i), .dcd_i(dcd_b_i), .cts_i(cts_b_i), .rts_o(rts_b_o), .dtr_o(dtr_b_o),
    .tx_byte_o(tx_byte_b_o), .tx_byte_valid_o(tx_byte_valid_b_o),
    .rx_byte_i(rx_byte_b_i), .rx_byte_valid_i(rx_byte_valid_b_i), .rx_byte_ready_o(rx_byte_ready_b_o),
    .rx_cond(rx_cond_b), .rx_special(rx_spec_b), .tx_ip(tx_ip_b), .ext_ip(ext_ip_b));

  // ---------------------------------------------------------------------
  // Interrupts: IP, IUS, INT, RR3 and the modified vector
  // ---------------------------------------------------------------------
  // Bit 5 Rx A, 4 Tx A, 3 Ext A, 2 Rx B, 1 Tx B, 0 Ext B (RR3's layout)
  logic [5:0] ip, ius;
  assign ip = {rx_cond_a, tx_ip_a, ext_ip_a, rx_cond_b, tx_ip_b, ext_ip_b};

  // The highest priority IP, and the IPs not masked by an IUS
  logic [5:0] unmasked;
  logic [2:0] top_idx;          // 5..0, valid when any IP
  logic       any_ip;
  always_comb begin
    unmasked = '0;
    for (int i = 0; i < 6; i++) begin
      logic blocked;
      blocked = 1'b0;
      for (int j = i; j < 6; j++) if (ius[j]) blocked = 1'b1;
      unmasked[i] = ip[i] & ~blocked;
    end
    any_ip  = ip != '0;
    top_idx = 3'd0;
    for (int i = 0; i < 6; i++) if (ip[i]) top_idx = 3'(i);
  end

  assign irq_o = mie && (unmasked != '0);

  // Software acknowledge (WR9 bit 5): an RR2 read in channel B sets the IUS
  // of the highest IP. Reset Highest IUS (WR0 command 111) clears it.
  logic cmd_reset_ius;
  assign cmd_reset_ius = ctl_wr && ptr == 4'd0 && wbyte[5:3] == 3'b111;
  always_ff @(posedge clk) begin
    if (hw_rst) ius <= '0;
    else begin
      if (chn_rst_a) ius[5:3] <= '0;
      if (chn_rst_b) ius[2:0] <= '0;
      if (soft_iack && ctl_rd_b && ptr == 4'd2 && any_ip)
        ius[top_idx] <= 1'b1;
      if (cmd_reset_ius) begin
        for (int i = 5; i >= 0; i--) begin
          if (ius[i]) begin
            ius[i] <= 1'b0;
            break;
          end
        end
      end
    end
  end

  // Table 6-4 status for the highest IP; 011 when none
  logic [2:0] code;
  always_comb begin
    code = 3'b011;
    if (any_ip) begin
      case (top_idx)
        3'd5: code = rx_spec_a ? 3'b111 : 3'b110;
        3'd4: code = 3'b100;
        3'd3: code = 3'b101;
        3'd2: code = rx_spec_b ? 3'b011 : 3'b010;
        3'd1: code = 3'b000;
        default: code = 3'b001;
      endcase
    end
  end

  logic [7:0] vector_b;
  assign vector_b = status_high ? {wr2[7], code[0], code[1], code[2], wr2[3:0]}
                                : {wr2[7:4], code, wr2[0]};

  // ---------------------------------------------------------------------
  // Read data and the response
  // ---------------------------------------------------------------------
  logic [7:0] rbyte;
  always_comb begin
    if (is_data)            rbyte = is_a ? rdata_a : rdata_b;
    else if (ptr == 4'd2)   rbyte = is_a ? wr2 : vector_b;
    else if (ptr == 4'd3)   rbyte = is_a ? {2'b00, ip} : 8'h00;
    else                    rbyte = is_a ? rdata_a : rdata_b;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      bus_o <= IOB_RSP_IDLE;
    end else begin
      bus_o.ack   <= access;
      bus_o.err   <= 1'b0;
      bus_o.rdata <= {4{rbyte}};
    end
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, bus_i.be, bus_i.pair, bus_i.addr[IOB_AW-1:3], bus_i.addr[0], wr9[2:0]};

endmodule
