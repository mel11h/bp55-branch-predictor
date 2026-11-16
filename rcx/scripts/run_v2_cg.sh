#!/bin/bash
# Clock-gated, hold-repaired v2 layout (pnr/run_v2_cg/gated_cg2_eco): coupled extraction + STA
# (new SDC, 6.0 ns, completed ICG Liberty from cg/setup.sh), and the grounded-fill upper bound
# of its filled layout (8_fill.odb).
set -e
root="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$root"
source cg/env.sh
R=rcx/results; P=pnr/run_v2_cg/gated_cg2_eco
BP55_PERIOD=6.0 IO_REF_FILE=$root/$P/io_ref_pin.txt rcx/run_rcx.sh $P/5_final.odb $P/5_final.v.gz pnr/bp55.sdc $R/v2_cg2_eco
if [ ! -s $R/v2_cg2_eco_fillgnd/bp55_rcbest.spef.gz ]; then
  mkdir -p rcx/work
  systemd-run --user --collect -q --wait --pipe -p MemoryHigh=${MEM_HIGH:-5G} -p MemoryMax=${MEM_MAX:-7G} \
    --working-directory="$root" -E FILL_IN="$root/$P/8_fill.odb" -E FILL_OUT="$root/rcx/work/v2_cg_fill_gnd.odb" -E PATH \
    openroad -threads 1 -no_init -exit rcx/scripts/fill_to_ground.tcl > rcx/work/v2_cg_fill_to_ground.log 2>&1
fi
BP55_PERIOD=6.0 IO_REF_FILE=$root/$P/io_ref_pin.txt rcx/run_rcx.sh rcx/work/v2_cg_fill_gnd.odb $P/5_final.v.gz pnr/bp55.sdc $R/v2_cg2_eco_fillgnd
rm -f rcx/work/v2_cg_fill_gnd.odb
