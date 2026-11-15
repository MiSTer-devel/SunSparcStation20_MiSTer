# SunSparcStation: the core's clocks (sys/sys_top.sdc has the framework's).
#
#   pll general[0]  65 MHz  clk_sys  the machine, hps_io, DDR3
#   pll general[1]  65 MHz  clk_vid  the pixel clock (a phase apart, so that the PLL keeps two counters)
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

# scsi_targets: the command bytes (cdb) are written only in S_CMD, and first
# read in S_EXEC, which is entered a cycle after the last byte at the
# earliest; every later reader is further away still. So whatever starts at
# cdb has two cycles (the command decode -- LBA, counts, the MSF arithmetic,
# the range checks -- into st and the result registers was the design's
# longest path at 65 MHz).
set cdb [get_registers {*scsi_targets:*|cdb[*][*]}]
if {[get_collection_size $cdb] == 0} { error "SunSparcStation.sdc: scsi_targets' cdb registers not found" }
set_multicycle_path -from $cdb -setup 2
set_multicycle_path -from $cdb -hold 1
