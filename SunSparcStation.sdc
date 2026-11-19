# SunSparcStation: the core's clocks (sys/sys_top.sdc has the framework's).
#
#   pll general[0]  60 MHz  clk_sys  the machine, hps_io, DDR3
#   pll general[1]  65 MHz  clk_vid  the pixel clock
#
# The two are unrelated: everything that crosses between them goes through
# a synchroniser (the reset in ss20_machine today; the TCX scan-out's FIFO
# later), so they are cut from each other. A crossing added without a
# synchroniser must come with its own constraint here.

derive_pll_clocks
derive_clock_uncertainty

set clk_sys [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set clk_vid [get_clocks {*|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
if {[get_collection_size $clk_sys] != 1 || [get_collection_size $clk_vid] != 1} {
	post_message -type error "SunSparcStation.sdc: the core PLL's clocks did not resolve"
}

set_clock_groups -asynchronous -group $clk_sys -group $clk_vid

# No multicycle exception for scsi_targets' command bytes (cdb). One was
# here from 2026-11-14 to 2026-11-18 (two cycles from cdb, because its
# first reader, S_EXEC, comes two cycles after the last byte). It was
# wrong: st and the result registers have no clock enable, so they also
# sample their inputs in the cycle between, while the 20 ns decode behind
# cdb is still settling, and what a LUT network puts out for a branch
# that is "not selected" is then not guaranteed. Fits that left those
# paths over one period (the 61.9 MHz build, seed 2 of ab37e16 and
# 254f184) passed the analysis and panicked in the Sun PROM's disk reads
# on the board; fits that happened to keep them under a period worked.
# At 60 MHz the decode fits in one cycle and is analysed as one.
