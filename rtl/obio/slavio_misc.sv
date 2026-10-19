// SPDX-License-Identifier: GPL-2.0-or-later
//
// slavio_misc: the small system-space registers of a sun4m: the diagnostic
// LEDs, Auxiliary I/O register 0, the power control register (Auxiliary I/O
// register 1 of the Campus2/SS20 appendix), and the System Control/Status
// register. One slave for the 0xF_F1xx_xxxx pages 0x6, 0x8, 0xA and 0xF;
// addr[23:0] is the offset within the system control space.
//
// From: Sun-4M System Architecture, 950-1373-01 Rev 50: §5.1.1 System
//   Control/Status Register (PA 0xFF1F00000), §5.4.1 Diagnostic LEDs
//   (0xFF1600000), §9.8 Auxiliary I/O register 0 (0xFF1800000), §9.9 Generic
//   I/O and Auxiliary I/O register 1 (0xFF1A01000, the power control
//   register), §12 Resets (the status bits after each kind of reset).
//   The power register's bits (off, interrupt clear, power fail) from QEMU
//   hw/misc/slavio_misc.c and Linux arch/sparc/include/asm/auxio_32.h.
//
// Registers:
//   0x600000  LEDs (16-bit, W): a 0 lights the LED; 0 at reset (all lit).
//   0x800000  Aux 0 (byte): bits 7:6 read 1; bit 5 D floppy density (R);
//             bit 1 T floppy terminal count (W, a pulse); bit 0 L the LED (W).
//   0xA01000  Power (byte): bit 0 power off (W), bit 1 clears the power-fail
//             interrupt (W), bit 5 power fail pending (R).
//   0xF00000  System Control/Status (32-bit): bit 0 SW_RST (W, 1 resets the
//             machine), bit 1 SW_RST_STAT (R, set by a software reset), bit 2
//             DIAG.SW (R), bit 3 RST.SW (R, set by a reset-switch reset),
//             bit 4 WD (R, set by a processor's watchdog reset: Sun-4M §12
//             "local-watchdog" in the reset search order; wdtest).
//             Writing a 0 to a status bit clears it; a 1 has no effect.
//
// The Aux 0 page is also a private configuration block, which the OpenBIOS
// build in bios/ (CONFIG_TACUS) reads as 32-bit words (bios/openbios
// arch/sparc32/openbios.c, entry.S TACUS_RAMSIZE, libopenbios/video_common.c):
//   +0x00     bits 31:24 the Sun Aux 0 byte above; 23:16 HWCONF (0x12, the
//             MiSTer: no Direct SD probe, no video-encoder setup); bit 6
//             video present (0 with the OSD's serial console: OpenBIOS's
//             nographic); bit 3 AutoBoot off (OSD); bit 2 CG3 (OSD)
//   +0x08     the CPU clock in Hz (the cpu node's clock-frequency)
//   +0x1C     0x5A in bits 31:24, the OSD's memory size in MB in 11:0
//   others    0 (+0x04 an I2C bus, +0x18 a Direct SD controller: neither here)
//
// `rst` is every reset (POR, SW_RST, the reset switch); rst_swr_i and
// rst_switch_i, sampled during rst, say which kind it was, for the status
// bits (§12: SWR_STAT is 1 after SWR only, RST.SW after the switch only).

module slavio_misc
  import iobus_pkg::*;
#(
  parameter int CLK_HZ = 55_000_000
)(
  input  logic     clk,
  input  logic     rst,
  input  logic     rst_swr_i,         // this reset is a software reset
  input  logic     rst_switch_i,      // this reset is the reset switch
  input  logic     wd_i,              // pulse: a processor took a watchdog reset

  input  iob_req_t bus_i,             // addr[23:0] within the system control space
  output iob_rsp_t bus_o,

  output logic [15:0] leds_o,         // as written: 0 = lit
  output logic        led_o,          // Aux 0 bit 0
  output logic        fd_tc_o,        // floppy terminal count pulse
  input  logic        fd_density_i,
  output logic        power_off_o,    // level, once software powers off
  input  logic        pwr_fail_i,     // sets the power-fail interrupt
  output logic        pwr_irq_o,      // the power-fail interrupt (level 15 source)
  input  logic        diag_sw_i,
  input  logic        cfg_cg3_i,       // OpenBIOS configuration (OSD)
  input  logic        cfg_noautoboot_i,
  input  logic        cfg_serial_i,    // console on ttya: "no video" to OpenBIOS
  input  logic [9:0]  cfg_ram_mb_i,
  output logic        sw_reset_o      // pulse: software reset requested
);

  logic access;
  assign access = bus_i.req & ~bus_o.ack;

  logic sel_leds, sel_aux0, sel_power, sel_sysctl;
  assign sel_leds   = bus_i.addr[23:20] == 4'h6;
  assign sel_aux0   = bus_i.addr[23:20] == 4'h8;
  assign sel_power  = bus_i.addr[23:20] == 4'hA && bus_i.addr[12];
  assign sel_sysctl = bus_i.addr[23:20] == 4'hF;

  // The byte at the access address (all four registers are at offset 0 of
  // their page; the LEDs take the high half-word)
  logic [7:0] wbyte;
  assign wbyte = bus_i.wdata[8 * (3 - int'(bus_i.addr[1:0])) +: 8];

  logic [2:0] aux0_rsvd;
  logic       pwr_fail;
  logic       swr_stat, rstsw_stat, wd_stat;

  always_ff @(posedge clk) begin
    fd_tc_o    <= 1'b0;
    sw_reset_o <= 1'b0;
    if (rst) begin
      leds_o      <= '0;
      led_o       <= 1'b0;
      aux0_rsvd   <= '0;
      power_off_o <= 1'b0;
      pwr_fail    <= 1'b0;
      swr_stat    <= rst_swr_i;
      wd_stat     <= 1'b0;
      rstsw_stat  <= rst_switch_i;
    end else begin
      if (pwr_fail_i) pwr_fail <= 1'b1;
      if (wd_i) wd_stat <= 1'b1;
      if (access && bus_i.we) begin
        if (sel_leds && (bus_i.be[3] | bus_i.be[2]))
          leds_o <= bus_i.wdata[31:16];
        if (sel_aux0 && bus_i.addr[4:2] == 3'd0 && bus_i.be[3]) begin
          led_o     <= wbyte[0];
          fd_tc_o   <= wbyte[1];
          aux0_rsvd <= wbyte[4:2];
        end
        if (sel_power) begin
          if (wbyte[0]) power_off_o <= 1'b1;
          if (wbyte[1]) pwr_fail <= 1'b0;
        end
        if (sel_sysctl) begin
          if (bus_i.wdata[0]) sw_reset_o <= 1'b1;        // a 32-bit register: bit 0
          // bits 1 and 3: write 0 to clear
          if (bus_i.wdata[1] == 1'b0) swr_stat <= 1'b0;
          if (bus_i.wdata[3] == 1'b0) rstsw_stat <= 1'b0;
          if (bus_i.wdata[4] == 1'b0) wd_stat <= 1'b0;
        end
      end
    end
  end

  assign pwr_irq_o = pwr_fail;

  logic [31:0] rdata;
  always_comb begin
    rdata = '0;
    if (sel_leds)   rdata = {leds_o, 16'h0};
    if (sel_aux0)
      case (bus_i.addr[4:2])
        3'd0:    rdata = {2'b11, fd_density_i, aux0_rsvd, 1'b0, led_o, 8'h12, 8'h00,
                          1'b0, !cfg_serial_i, 2'b00, cfg_noautoboot_i, cfg_cg3_i, 2'b00};
        3'd2:    rdata = CLK_HZ;
        3'd7:    rdata = {8'h5A, 14'h0, cfg_ram_mb_i};
        default: rdata = '0;
      endcase
    if (sel_power)  rdata = {4{2'b00, pwr_fail, 4'b0000, power_off_o}};
    if (sel_sysctl) rdata = {27'h0, wd_stat, rstsw_stat, diag_sw_i, swr_stat, 1'b0};
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      bus_o <= IOB_RSP_IDLE;
    end else begin
      bus_o.ack   <= access;
      bus_o.err   <= 1'b0;
      bus_o.rdata <= rdata;
    end
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, bus_i.pair, bus_i.be[1:0], bus_i.addr[IOB_AW-1:24], wbyte[7:5],
                       bus_i.addr[19:13], bus_i.addr[11:5]};

endmodule
