#!/bin/bash
# equiv.sh <netlist .v|.v.gz> <tag> [rtl file, default rtl/bp55.sv] : Yosys formal equivalence RTL vs gate netlist.
#   gold: RTL, proc; flatten; memory -nomap; memory_map (tables become registers bim[0] .. as in the netlist)
#   gate: netlist + gls/build/cells_gl.v (PDK cell models, UDPs replaced; see mkcells.py), proc; flatten
#   both: async2sync (async reset modelled as sync for the proof, same on both sides); internal names
#   containing '.' (bp_fold instances, flattened cell internals) are hidden so only ports, state and
#   top-level nets are matched; nets that synthesis assigned x (debug wires such as ctr_alloc[1:0])
#   are blacklisted. Then equiv_make; equiv_simple -seq 1; equiv_induct; equiv_status.
#   Log: gls/logs/equiv_<tag>.log
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
: "${BP55_ROOT:=$(cd "$here/.." && pwd)}"
net=$1; tag=$2; rtl=${3:-$BP55_ROOT/rtl/bp55.sv}
W="$here/build/eq_$tag"; mkdir -p "$W"
case $net in *.gz) zcat "$net" > "$W/net.v" ;; *) cp "$net" "$W/net.v" ;; esac
cp "$rtl" "$W/rtl.sv"
PDKV="$BP55_ROOT/pdk/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR/verilog/ics55_LLSC_H7CR.v"
python3 "$here/mkcells.py" "$PDKV" "$W/cells_gl.v" --used "$W/net.v"
# nets assigned (partly) x by synthesis
grep -E "^\s*assign .*'h[0-9a-f]*x" "$W/net.v" | sed -E 's/^\s*assign\s+(\\\S+|\w+).*/\1/; s/^\\//' | sort -u > "$W/blacklist.txt"
cd "$W"
cat > eq.ys <<EOS
read_verilog -sv rtl.sv
hierarchy -top bp55
proc; flatten; memory -nomap; memory_map; opt_clean; async2sync
rename -hide w:*.*
rename bp55 gold
design -stash gold
read_verilog cells_gl.v
read_verilog net.v
hierarchy -top bp55
proc; flatten; opt_clean; async2sync
rename -hide w:*.*
rename bp55 gate
design -stash gate
design -copy-from gold -as gold gold
design -copy-from gate -as gate gate
equiv_make -blacklist blacklist.txt gold gate equiv
hierarchy -top equiv
opt_clean
equiv_status
equiv_simple -seq 1
equiv_status
equiv_induct -seq 1
equiv_status
EOS
yosys -l "$here/logs/equiv_$tag.log" -q eq.ys > /dev/null || true
sed -i -e "s#$BP55_ROOT/##g" -e "s#$here/#gls/#g" "$here/logs/equiv_$tag.log"
grep -E 'Found [0-9]+ \$equiv cells|Of those cells|unproven|Equivalence successfully proven' "$here/logs/equiv_$tag.log" | tail -6
