#!/bin/bash
# Every v1 extraction and STA run reported in rcx/README.md, in order (rerunnable: existing
# SPEFs are kept). Results: rcx/results/<layout>/. Memory: each OpenROAD call waits for
# MEM_MIN_GB (default 4) GB available and runs under MEM_HIGH/MEM_MAX (rcx/run_rcx.sh).
set -e
here="$(cd "$(dirname "$0")" && pwd)"
rcx="$(cd "$here/.." && pwd)"
root="$(cd "$rcx/.." && pwd)"
cd "$root"
R=rcx/results
# 1. committed v1 layout (pnr/5_final.*), both constraint sets at the published 6.2 ns.
#    ESTIMATE=1 also runs the published estimated-parasitics STA (independent of the rules).
BP55_PERIOD=6.2 ESTIMATE=${EST_COMMITTED:-1} rcx/run_rcx.sh pnr/5_final.def.gz pnr/5_final.v.gz pnr/bp55_legacy.sdc $R/v1_committed
BP55_PERIOD=6.2 ESTIMATE=${EST_COMMITTED:-1} rcx/run_rcx.sh pnr/5_final.def.gz pnr/5_final.v.gz pnr/bp55.sdc $R/v1_committed
# 2. colleague's v1 re-run with the new SDC (6.0 ns, its own IO reference pin)
P=pnr/run_v1_newsdc
BP55_PERIOD=6.0 ESTIMATE=${EST_RERUN:-1} IO_REF_FILE=$root/$P/io_ref_pin.txt rcx/run_rcx.sh $P/5_final.odb $P/5_final.v.gz pnr/bp55.sdc $R/v1_newsdc
# 2b. its filled layout (8_fill.odb): OpenRCX ignores dbFill shapes, the extraction is
#     identical to 2 (checked in the typical corner), so only the grounded-fill bound is run:
#     every fill shape turned into wiring of VSS (rcx/scripts/fill_to_ground.tcl)
if [ ! -s $R/v1_newsdc_fillgnd/bp55_rcbest.spef.gz ]; then
  mkdir -p rcx/work
  [ -s rcx/work/8_fill_gnd.odb ] || systemd-run --user --collect -q --wait --pipe -p MemoryHigh=${MEM_HIGH:-5G} -p MemoryMax=${MEM_MAX:-7G} \
    --working-directory="$root" -E FILL_IN="$root/$P/8_fill.odb" -E FILL_OUT="$root/rcx/work/8_fill_gnd.odb" -E PATH \
    openroad -threads 1 -no_init -exit rcx/scripts/fill_to_ground.tcl > rcx/work/fill_to_ground.log 2>&1
fi
BP55_PERIOD=6.0 IO_REF_FILE=$root/$P/io_ref_pin.txt rcx/run_rcx.sh rcx/work/8_fill_gnd.odb $P/5_final.v.gz pnr/bp55.sdc $R/v1_newsdc_fillgnd
rm -f rcx/work/8_fill_gnd.odb
# 3. colleague's v1 re-run with the legacy SDC (placed and checked at 5.0 ns)
P=pnr/run_v1_legacy
BP55_PERIOD=5.0 ESTIMATE=${EST_RERUN:-1} rcx/run_rcx.sh $P/5_final.def.gz $P/5_final.v.gz pnr/bp55_legacy.sdc $R/v1_legacy
# 4. sensitivity: all extracted C x0.8 and x1.2 (R unchanged)
BP55_PERIOD=6.2 rcx/scripts/sensitivity.sh $R/v1_committed pnr/5_final.v.gz pnr/bp55_legacy.sdc
BP55_PERIOD=6.0 IO_REF_FILE=$root/pnr/run_v1_newsdc/io_ref_pin.txt rcx/scripts/sensitivity.sh $R/v1_newsdc pnr/run_v1_newsdc/5_final.v.gz pnr/bp55.sdc
