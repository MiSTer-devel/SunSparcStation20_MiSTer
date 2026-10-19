#!/bin/sh
# Benches for the DDRAM arbiter (iverilog):
#   tb_ddram_arb.sv          randomised, masters wait for their read data
#   tb_ddram_arb_pipe.sv     randomised, pipelined masters (Avalon bridges)
#   tb_ddram_arb_abandon.sv  a write burst abandoned mid-way is flushed
#   tb_ddram_arb_lat.sv      throughput vs DDR latency (report only)
# and, under Verilator through rtl/tb/run.sh (self-checking, tb_pkg):
#   tb_nvram_sd.sv           the NVRAM image on SD slot 3, with m48t08
#   tb_eth_hps.sv            the Ethernet mailbox to Main
set -e
here=$(cd "$(dirname "$0")" && pwd)
t=${TMPDIR:-/tmp}
for tb in tb_ddram_arb tb_ddram_arb_pipe tb_ddram_arb_abandon; do
  iverilog -g2012 -o "$t/$tb.vvp" "$here/../ddram_arb.sv" "$here/$tb.sv"
  echo "== $tb"; vvp -n "$t/$tb.vvp" | grep -v '\$finish'
done
for L in 10 20 30; do
  iverilog -g2012 -P tb.L=$L -o "$t/tb_lat.vvp" "$here/../ddram_arb.sv" "$here/tb_ddram_arb_lat.sv"
  vvp -n "$t/tb_lat.vvp" | grep -v '\$finish'
done
"$here/../../tb/run.sh" tb_nvram_sd tb_eth_hps
