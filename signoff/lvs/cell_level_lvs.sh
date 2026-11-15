#!/bin/bash
# Cell-level (black-box) LVS of the routing: the schematic top level is rebuilt from the routed
# Verilog, but every cell is described by its own extracted layout netlist, so netgen compares only
# how the cells are wired together (shorts, opens, swapped pins in the routing).
# usage: cell_level_lvs.sh LAYOUT.cir (from icsprout55_lvs.lvs -rd compare=0) NETLIST.v[.gz] TOP OUTDIR
set -eu
here=$(cd "$(dirname "$0")" && pwd)
lay=$1; vlog=$2; top=$3; out=$4; mkdir -p "$out"
python3 "$here/../tools/lvs_netgen_prep.py" "$lay" /dev/null "$out/layout_ng.cir" /dev/null
awk -v t="$top" '$1==".SUBCKT" && $2!=t {p=1} p{print} p && $1==".ENDS"{p=0}' "$out/layout_ng.cir" > "$out/cells_layout.sp"
python3 "$here/../tools/verilog2spice.py" "$vlog" "$out/cells_layout.sp" "$out/top.sp" --top "$top"
cat "$out/cells_layout.sp" "$out/top.sp" > "$out/schematic_cells.sp"
# the top level is built with the layout cells' pin lists; report cell pins of the CDL that the layout
# cells do not expose (such pins would silently drop Verilog connections from the comparison)
CDL=${CDL:-$here/../../pdk/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR/cdl/ics55_LLSC_H7CR.cdl}
python3 - "$out/cells_layout.sp" "$CDL" <<'PY'
import sys
def pins(fn):
    d = {}
    for l in open(fn, encoding="latin-1"):
        w = l.split()
        if w and w[0].upper() == ".SUBCKT": d[w[1]] = set(x for x in w[2:] if "=" not in x)
    return d
a, b = pins(sys.argv[1]), pins(sys.argv[2])
miss = {c: sorted(b[c] - a[c]) for c in a if c in b and b[c] - a[c]}
print("CDL pins not exposed by the layout cells: %d cells %s" % (len(miss), " ".join("%s:%s" % (c, ",".join(v)) for c, v in sorted(miss.items())[:20])))
PY
NG=${NETGEN:-$(command -v netgen || echo "$HOME/.local/bin/netgen")}
"$NG" -batch lvs "$out/layout_ng.cir $top" "$out/schematic_cells.sp $top" "$here/netgen_setup.tcl" "$out/netgen_cell_level.out" > "$out/netgen.log" 2>&1 || true
echo "top-level verdict: $(grep -E '^Netlists (match|do not)' "$out/netgen_cell_level.out" | tail -1)"
grep "Number of devices\|Number of nets" "$out/netgen_cell_level.out" | tail -2
echo "unmatched pins: $(grep -c '(no matching pin)' "$out/netgen_cell_level.out")"
