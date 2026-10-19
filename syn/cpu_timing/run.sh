#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# syn/cpu_timing/run.sh [TAG] - a Quartus fit of cpu_module alone at 55 MHz
# (cpu_timing_top.sv: registered inputs and outputs), on the build machine
# (scripts/local.env: BUILD_HOST, default misterubuntu). Prints the worst
# slack and the 40 worst paths, into scratch/cpu_timing/TAG.txt as well.
# A fit takes ~10-20 minutes; much quicker than a full build for
# iterating on the CPU's paths.
set -euo pipefail
cd "$(dirname "$0")/../.."
TAG=${1:-run}
H=${BUILD_HOST:-misterubuntu}
R=mister/cpu_timing
ssh "$H" "mkdir -p $R/src" < /dev/null
rsync -a --delete rtl/pkg rtl/lib rtl/cpu syn/cpu_timing/cpu_timing_top.sv "$H:$R/src/" --exclude tb
{
  echo 'set_global_assignment -name FAMILY "Cyclone V"'
  echo 'set_global_assignment -name DEVICE 5CSEBA6U23I7'
  echo 'set_global_assignment -name TOP_LEVEL_ENTITY cpu_timing_top'
  echo 'set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files'
  echo 'set_global_assignment -name SDC_FILE cpu_timing.sdc'
  echo 'set_global_assignment -name OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"'
  echo 'set_global_assignment -name VERILOG_MACRO "SYNTHESIS=1"'
  for f in rtl/pkg/cpu_pkg.sv rtl/pkg/fpu_pkg.sv rtl/pkg/mmu_pkg.sv rtl/pkg/mem_pkg.sv rtl/lib/*.sv rtl/cpu/*.sv; do
    echo "set_global_assignment -name SYSTEMVERILOG_FILE src/${f#rtl/}"
  done
  echo 'set_global_assignment -name SYSTEMVERILOG_FILE src/cpu_timing_top.sv'
} > /tmp/cpu_timing.qsf.$$
scp -q /tmp/cpu_timing.qsf.$$ "$H:$R/cpu_timing.qsf"; rm -f /tmp/cpu_timing.qsf.$$
scp -q syn/cpu_timing/cpu_timing.sdc "$H:$R/"
mkdir -p scratch/cpu_timing
ssh "$H" "cd $R && printf 'QUARTUS_VERSION = \"17.0\"\nPROJECT_REVISION = \"cpu_timing\"\n' > cpu_timing.qpf &&
  Q=\$HOME/intelFPGA_lite/17.0/quartus/bin && \$Q/quartus_sh --flow compile cpu_timing > flow.log 2>&1;
  grep -E 'Logic utilization|Total registers|Total block memory|DSP' output_files/cpu_timing.fit.summary;
  cat > paths.tcl <<'T'
project_open cpu_timing
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -setup -npaths 40 -detail summary -file paths.txt
T
  \$Q/quartus_sta -t paths.tcl > sta.log 2>&1; grep -A3 \"Setup 'clk'\" output_files/cpu_timing.sta.summary | head -4;
  grep -E '^; -?[0-9]' paths.txt | awk -F';' '{print \$2, \$3, \$4}' | sed -e 's/cpu_module:u_cpu|//g' | cut -c1-230" < /dev/null | tee "scratch/cpu_timing/$TAG.txt"
