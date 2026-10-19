// SPDX-License-Identifier: GPL-2.0-or-later
//
// sun4m_pkg: the Sun-4M machine constants shared by the chipset blocks.
//
// From: Sun-4M System Architecture, 950-1373-01 Rev 50 (July 1991),
//   §3.2 Physical Address Space, §5.7 Interrupt Related Registers,
//   §6.3 Interrupt Level Assignment;
// cross-checked with QEMU hw/sparc/sun4m.c (the SS-20 hwdef) and
// hw/intc/slavio_intctl.c (intbit_to_level).

package sun4m_pkg;

  // 36-bit physical addresses. PA[35:32] selects a 4 GB space: 0 is main
  // memory, 0xE the SBus, 0xF the control space (§3.2.1).
  localparam int PA_W = 36;

  // System control space, PA[35:20] (§3.2.2.2.1)
  localparam logic [35:20] PA_KBDMS   = 16'hFF10;  // keyboard/mouse ESCC
  localparam logic [35:20] PA_SERIAL  = 16'hFF11;  // serial ports ESCC
  localparam logic [35:20] PA_NVRAM   = 16'hFF12;  // TOD/NVRAM (M48T08)
  localparam logic [35:20] PA_TIMER   = 16'hFF13;  // counter/timers
  localparam logic [35:20] PA_INTCTL  = 16'hFF14;  // interrupt registers
  localparam logic [35:20] PA_LEDS    = 16'hFF16;  // diagnostic LEDs
  localparam logic [35:20] PA_FDC     = 16'hFF17;  // floppy controller
  localparam logic [35:20] PA_AUX1    = 16'hFF18;  // auxiliary I/O register
  localparam logic [35:20] PA_AUX2    = 16'hFF1A;  // generic 8-bit device (power)
  localparam logic [35:20] PA_SYSCTL  = 16'hFF1F;  // system control/status

  // Within the timer space (§3.2.2.2.2): processor N at N*0x1000, the
  // system counter at 0x10000.
  localparam logic [19:0] TIMER_SYS_OFF = 20'h10000;
  localparam logic [19:0] TIMER_CPU_STRIDE = 20'h1000;

  // Within the interrupt space (§3.2.2.2.3): processor N at N*0x1000, the
  // system registers at 0x10000.
  localparam logic [19:0] INTCTL_SYS_OFF = 20'h10000;
  localparam logic [19:0] INTCTL_CPU_STRIDE = 20'h1000;

  // System Interrupt Pending / Interrupt Target Mask bits (§5.7.3.1)
  localparam int SI_VME_LSB = 0;   // VME interrupts 7:1 at bits 6:0 (not here)
  localparam int SI_SBUS_LSB = 7;  // SBus interrupts 7:1 at bits 13:7
  localparam int SI_K  = 14;  // keyboard/mouse SCC
  localparam int SI_S  = 15;  // serial ports SCC
  localparam int SI_E  = 16;  // on-board Ethernet
  localparam int SI_A  = 17;  // audio/ISDN
  localparam int SI_SC = 18;  // on-board SCSI
  localparam int SI_T  = 19;  // level-10 system counter/timer
  localparam int SI_VI = 20;  // on-board video
  localparam int SI_MI = 21;  // module interrupt
  localparam int SI_FL = 22;  // floppy
  localparam int SI_V  = 27;  // VME asynchronous error (level 15)
  localparam int SI_M  = 28;  // ECC memory error (level 15)
  localparam int SI_I  = 29;  // M-to-S write buffer error (level 15)
  localparam int SI_ME = 30;  // module error (level 15)
  localparam int SI_MA = 31;  // mask register only: mask all

  // The sources an SS20 has (the implemented mask bits): bits 22:7 and
  // 30:27. No VME (6:0); 26:23 and 31 are reserved in the pending register.
  localparam logic [31:0] SI_IMPLEMENTED = 32'h787F_FF80;

  // Interrupt level of each System Interrupt Pending bit (§6.3). 0: none.
  function automatic logic [3:0] si_level(input int unsigned bit_no);
    case (bit_no)
      0, 7:   return 4'd2;    // VME/SBus level 1
      1, 8:   return 4'd3;    // level 2
      2, 9:   return 4'd5;    // level 3
      3, 10:  return 4'd7;    // level 4
      4, 11:  return 4'd9;    // level 5
      5, 12:  return 4'd11;   // level 6
      6, 13:  return 4'd13;   // level 7
      SI_K, SI_S:  return 4'd12;
      SI_E:   return 4'd6;
      SI_A:   return 4'd13;
      SI_SC:  return 4'd4;
      SI_T:   return 4'd10;
      SI_VI:  return 4'd8;
      SI_MI:  return 4'd9;
      SI_FL:  return 4'd11;
      SI_V, SI_M, SI_I, SI_ME: return 4'd15;
      default: return 4'd0;
    endcase
  endfunction

endpackage
