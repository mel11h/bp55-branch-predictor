#!/bin/bash
# reextract_ref.sh <layout run dir> <out dir>
#   Routed-wire extraction (pnr/flow/def2spef.py, the version with the escaped-bus net-name fix)
#   and the final multi-corner STA (pnr/run_v2_cg/scripts/sta_routed.tcl) of a layout made by
#   someone else (the ungated reference pnr/run_v2_newsdc), written to <out dir> only: the
#   layout directory is read, never written. Upstream Liberty and LEF (ungated netlist).
set -e
here="$(cd "$(dirname "$0")" && pwd)"
: "${BP55_ROOT:=$(cd "$here/.." && pwd)}"; export BP55_ROOT
src="$(cd "$1" && pwd)"; out="$(mkdir -p "$2" && cd "$2" && pwd)"
SC="$BP55_ROOT/pdk/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR"
cd "$out"
zcat "$src/5_final.def.gz" > 5_final.def
python3 -I "$BP55_ROOT/pnr/flow/def2spef.py" "$BP55_ROOT/pdk/prtech/techLEF/N551P6M_ecos.lef" \
    "$SC/lef/ics55_LLSC_H7CR_ecos.lef" 5_final.def 5_final.spef > 5_extract.log
rm -f 5_final.def
zcat "$src/5_final.v.gz" > 5_final.v
export BP55_PERIOD=${BP55_PERIOD:-6.0} BP55_SDC="$BP55_ROOT/pnr/bp55.sdc"
STA_NETLIST="$out/5_final.v" STA_SPEF="$out/5_final.spef" IO_REF_FILE="$src/io_ref_pin.txt" \
systemd-run --user --collect -q --wait --pipe -p MemoryHigh=6G -p MemoryMax=8G -p MemorySwapMax=0 \
    --working-directory="$out" -E BP55_ROOT -E BP55_SDC -E BP55_PERIOD -E STA_NETLIST -E STA_SPEF -E IO_REF_FILE \
    openroad -threads 1 -no_init -exit "$BP55_ROOT/pnr/run_v2_cg/scripts/sta_routed.tcl" > 6_sta_routed.log 2>&1 || true
sed -i -e "s#$BP55_ROOT/##g" -e "s#$out/##g" 6_sta_routed.log 5_extract.log
rm -f 5_final.v; gzip -f -9 5_final.spef
grep -A3 "==== summary" 6_sta_routed.log
