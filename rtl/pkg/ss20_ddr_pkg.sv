// SPDX-License-Identifier: GPL-2.0-or-later
//
// ss20_ddr_pkg: where the machine keeps things in the MiSTer's DDR3, for
// every block with an Avalon master on it (ss20_memctl, ss20_loader, the
// TCX's VRAM and scan-out).
//
// Core byte addresses (29 bits, 512 MB) sit in the FPGA window (ARM
// physical 0x2000_0000-0x3FFF_FFFF) upside down by megabyte: address bits
// 28:20 are inverted, so main memory starts at the top of the window and
// the bottom — the framework's video scaler buffer, ARM 0x2000_0000 up —
// only holds core addresses at 0x1D80_0000 and above, which nothing uses.
//
//   0x0000_0000 .. RAM size    main memory, PA 0 up (464 MB at most)
//   0x1D00_0000 .. +512 KB     the boot PROM image
//   0x1D10_0000 .. +1 MB       the TCX's VRAM (8 bits a pixel, 1024 x 768 used)
//   0x1D80_0000 ..             unused: the scaler's buffer
//
// A doubleword is stored big-endian in its DDR word: byte offset 0 in
// bits 63:56 (byte enable 7).

package ss20_ddr_pkg;

  localparam logic [28:0] DDR_BASE  = 29'h0400_0000;   // Avalon word address of ARM 0x2000_0000
  localparam logic [28:0] PROM_BASE = 29'h1D00_0000;
  localparam logic [28:0] VRAM_BASE = 29'h1D10_0000;

  // the Avalon word address of a core byte address
  /* verilator lint_off UNUSEDSIGNAL */   // (a[2:0]: the byte within the word)
  function automatic logic [28:0] ddr_word(input logic [28:0] a);
    return DDR_BASE | {3'b000, ~a[28:20], a[19:3]};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

endpackage
