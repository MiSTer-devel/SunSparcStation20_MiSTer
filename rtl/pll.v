// SPDX-License-Identifier: GPL-2.0-or-later
//
// pll: the core's clocks from the 50 MHz board clock. The altera_pll
// wrapper of Template_MiSTer (rtl/pll.v, rtl/pll/pll_0002.v), given a
// second output; Quartus picks the counters from the frequencies.
//
//   outclk_0  55 MHz  clk_sys: the machine, hps_io, DDR3 (plan §1.3: >= 55)
//   outclk_1  65 MHz  clk_vid: the pixel clock, 1024x768 at 60 Hz (VESA)
//   outclk_2  55 MHz  clk_sdram: clk_sys + 270 degrees (13.636 ns, 78 steps
//                     of the 715 MHz VCO's eighth), the SDRAM's clock
//                     (sdram64; SDRAM_CLK through a DDIO register)
//
// The instance in emu must stay named "pll" with "pll_inst" inside:
// sys/sys_top.sdc and SunSparcStation.sdc find the clocks by that path.

`timescale 1 ps / 1 ps
module pll (
		input  wire  refclk,
		input  wire  rst,
		output wire  outclk_0,
		output wire  outclk_1,
		output wire  outclk_2,
		output wire  locked
	);

	pll_0002 pll_inst (
		.refclk   (refclk),
		.rst      (rst),
		.outclk_0 (outclk_0),
		.outclk_1 (outclk_1),
		.outclk_2 (outclk_2),
		.locked   (locked)
	);

endmodule
