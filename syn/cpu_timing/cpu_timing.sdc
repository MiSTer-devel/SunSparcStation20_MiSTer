# The machine's clock: 55 MHz
create_clock -name clk -period 18.181 [get_ports clk]
derive_clock_uncertainty
