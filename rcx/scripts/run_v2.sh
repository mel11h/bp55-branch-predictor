#!/bin/bash
# v2 (hardened RTL) layout of pnr/run_v2_newsdc: extraction + STA (new SDC, 6.0 ns) with the
# estimate for comparison, and the grounded-fill upper bound of its filled layout.
set -e
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
R=rcx/results; P=pnr/run_v2_newsdc
BP55_PERIOD=6.0 ESTIMATE=1 IO_REF_FILE=$root/$P/io_ref_pin.txt rcx/run_rcx.sh $P/5_final.odb $P/5_final.v.gz pnr/bp55.sdc $R/v2_newsdc
if [ ! -s $R/v2_newsdc_fillgnd/bp55_rcbest.spef.gz ]; then
  mkdir -p rcx/work
  while [ "$(awk '/MemAvailable/ {print int($2/1048576)}' /proc/meminfo)" -lt ${MEM_MIN_GB:-4} ]; do sleep 30; done
  [ -s rcx/work/v2_fill_gnd.odb ] || systemd-run --user --collect -q --wait --pipe -p MemoryHigh=${MEM_HIGH:-5G} -p MemoryMax=${MEM_MAX:-7G} \
    --working-directory="$root" -E FILL_IN="$root/$P/8_fill.odb" -E FILL_OUT="$root/rcx/work/v2_fill_gnd.odb" -E PATH \
    openroad -threads 1 -no_init -exit rcx/scripts/fill_to_ground.tcl > rcx/work/v2_fill_to_ground.log 2>&1
fi
BP55_PERIOD=6.0 IO_REF_FILE=$root/$P/io_ref_pin.txt rcx/run_rcx.sh rcx/work/v2_fill_gnd.odb $P/5_final.v.gz pnr/bp55.sdc $R/v2_newsdc_fillgnd
rm -f rcx/work/v2_fill_gnd.odb
