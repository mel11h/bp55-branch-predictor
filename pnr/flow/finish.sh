#!/bin/bash
# After 3_route: routed-wire extraction, final multi-corner STA on it, GDS merge, and
# compression of the large outputs.
#
# usage: pnr/flow/finish.sh <run_dir>       env: BP55_SDC, BP55_PERIOD (as for run.sh)
set -e
here="$(cd "$(dirname "$0")" && pwd)"
export BP55_ROOT="${BP55_ROOT:-$(cd "$here/../.." && pwd)}"
run="$(cd "$1" && pwd)"
: "${BP55_PERIOD:=6.0}"; export BP55_PERIOD
export BP55_SDC="$(cd "$(dirname "${BP55_SDC:-$BP55_ROOT/pnr/bp55.sdc}")" && pwd)/$(basename "${BP55_SDC:-bp55.sdc}")"
SC="$BP55_ROOT/pdk/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR"
cd "$run"
[ -f 5_final.def ] || { [ -f 5_final.def.gz ] && gunzip -k 5_final.def.gz; }
[ -f 5_final.v ] || { [ -f 5_final.v.gz ] && gunzip -k 5_final.v.gz; }
echo "[$(date +%H:%M:%S)] extraction"
python3 -I "$here/def2spef.py" "$BP55_ROOT/pdk/prtech/techLEF/N551P6M_ecos.lef" \
    "${BP55_CELL_LEF:-$SC/lef/ics55_LLSC_H7CR_ecos.lef}" 5_final.def 5_final.spef | tee 5_extract.log
echo "[$(date +%H:%M:%S)] sta (routed wires)"
STA_NETLIST="$run/5_final.v" STA_SPEF="$run/5_final.spef" IO_REF_FILE="$run/io_ref_pin.txt" \
systemd-run --user --collect -q --wait --pipe -p MemoryHigh=6G -p MemoryMax=8G -p MemorySwapMax=0 \
    --working-directory="$run" -E BP55_ROOT -E BP55_SDC -E BP55_PERIOD -E BP55_LIBDIR="${BP55_LIBDIR:-}" -E BP55_CELL_LEF="${BP55_CELL_LEF:-}" -E STA_NETLIST -E STA_SPEF -E IO_REF_FILE \
    openroad -threads 1 -no_init -exit "$here/sta_routed.tcl" > 6_sta_routed.log 2>&1 || true
sed -i -e "s#$BP55_ROOT/##g" -e "s#$run/##g" 6_sta_routed.log
grep -A3 "==== summary" 6_sta_routed.log
echo "[$(date +%H:%M:%S)] gds"
BP55_ROOT="$BP55_ROOT" timeout 1800 klayout -b -r "$BP55_ROOT/pnr/def2gds.py" > 7_def2gds.log 2>&1 || echo "def2gds failed, see 7_def2gds.log"
sed -i -e "s#$BP55_ROOT/##g" 7_def2gds.log
tail -2 7_def2gds.log
# large outputs: compressed copies are kept, raw files and databases are removed
for f in 5_final.def 5_final.v 5_final.spef bp55.gds; do [ -f $f ] && gzip -f -9 $f; done
rm -f 1_place.odb 2_cts.odb 3_grt.odb
ls -la "$run"
