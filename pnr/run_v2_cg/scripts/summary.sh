#!/bin/bash
# Print the headline numbers of one run directory from its logs and reports.
# usage: pnr/flow/summary.sh <run_dir>
r="$1"
p() { printf '%-34s %s\n' "$1" "$2"; }
p "die (um)"            "$(grep -m1 'IFP-0100\|Die BBox\|DieBBox' $r/1_place.log | sed 's/.*BBox: *//')"
p "core area / util"    "$(grep -m1 'GPL-0016\|CoreArea' $r/1_place.log | awk '{print $NF}') um2 / $(grep 'Design area' $r/3_route.log | tail -1)"
p "netlist cells in"    "$(grep -m1 'GPL-0006\|NumInstances\|Number of instances' $r/1_place.log | awk '{print $NF}')"
echo "-- cell usage (final, 3_route.log)"
awk '/Cell type report/{f=1;n++} f&&n>=1{print} /Total/{if(f){f=0}}' $r/3_route.log | tail -12
echo "-- CTS"
grep -E "CTS-0018|CTS-0012|CTS-0013" $r/2_cts.log
grep -E "clock arrival at" $r/2_cts.log
echo "-- timing repair (setup buffers, hold endpoints, hold buffers)"
for f in 2_cts 3_route; do echo "  $f:"; grep -E "RSZ-0094|RSZ-0040|RSZ-0041|RSZ-0049|RSZ-0046|RSZ-0032|RSZ-0033" $r/$f.log | sed 's/^/    /'; done
echo "-- routing"
grep -E "DRT-0199" $r/3_route.log | tail -1
grep -E "^Total wire length =|Total number of vias" $r/3_route.log | tail -2
p "4_drt_drc.rpt bytes" "$(stat -c %s $r/4_drt_drc.rpt 2>/dev/null || echo missing)"
p "antenna.rpt bytes"  "$(stat -c %s $r/antenna.rpt 2>/dev/null || echo missing)"
grep -E "ANT-|antenna" $r/3_route.log | tail -3
echo "-- in-session STA, global-route parasitics (3_route.log)"
grep -E "^corner (ss|tt|ff): worst" $r/3_route.log | tail -3
echo "-- final STA, routed-wire parasitics (6_sta_routed.log)"
grep -A3 "==== summary" $r/6_sta_routed.log | tail -3
grep -E "endpoints with hold slack" $r/6_sta_routed.log
grep -E "^Total " $r/6_sta_routed.log | tail -1
