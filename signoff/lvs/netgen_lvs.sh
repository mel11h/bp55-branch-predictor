#!/bin/bash
# Compare a KLayout-extracted netlist (icsprout55_lvs.lvs -rd compare=0 -rd netlist_out=...) with the
# schematic using netgen. usage: netgen_lvs.sh LAYOUT.cir SCHEMATIC.sp TOP OUTDIR
set -eu
here=$(cd "$(dirname "$0")" && pwd)
lay=$1; sch=$2; top=$3; out=$4; mkdir -p "$out"
python3 "$here/../tools/lvs_netgen_prep.py" "$lay" "$sch" "$out/layout_ng.cir" "$out/schematic_ng.sp"
NG=${NETGEN:-$(command -v netgen || echo "$HOME/.local/bin/netgen")}
"$NG" -batch lvs "$out/layout_ng.cir $top" "$out/schematic_ng.sp $top" "$here/netgen_setup.tcl" "$out/netgen_lvs.out" > "$out/netgen.log" 2>&1 || true
grep -E "Netlists match|Netlists do not match|Final result|Result:" "$out/netgen_lvs.out" | tail -5
