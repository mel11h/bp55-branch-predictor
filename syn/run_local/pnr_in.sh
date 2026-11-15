#!/bin/bash
# Netlist clean-up: synthesis netlist -> place-and-route input (bp55_pnr_in.v).
#
# usage: pnr_in.sh <synth netlist .v or .v.gz> <output .v>
#
# What it does, and why:
#   - reads the mapped netlist with the standard cells as black boxes (read_liberty -lib);
#   - opt_clean -purge removes wires that drive nothing, including the public debug
#     wires that synthesis keeps (u_fi1.o, u_fthr.h, ...), many of them assigned 1'hx,
#     and the TIELO cells whose only load was such a wire;
#   - setundef -zero ties any remaining x bit to 0 (none is expected on a used net;
#     the log line "setundef" reports the count);
#   - write_verilog -noattr -noexpr writes plain structural Verilog for OpenROAD.
# The TIELO cells that drive output ports (f_ras_top[1:0], f_target[1:0], always 0
# because targets are 4-byte aligned) are kept.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
: "${BP55_ROOT:=$(cd "$here/../.." && pwd)}"
in=$1; out=$2
LIB="$BP55_ROOT/pdk/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR/liberty/ics55_LLSC_H7CR_typ_tt_1p2_25_nldm.lib"
tmp=$(mktemp --suffix=.v)
case $in in *.gz) zcat "$in" > "$tmp" ;; *) cp "$in" "$tmp" ;; esac
yosys -q -l "${out%.v}.log" -p "read_liberty -lib $LIB; read_verilog $tmp; hierarchy -top bp55; opt_clean -purge; setundef -zero; stat -liberty $LIB; write_verilog -noattr -noexpr $out" >/dev/null
rm -f "$tmp"
sed -i -e "s#$BP55_ROOT/##g" -e "s#$tmp#<input>#g" "${out%.v}.log"
echo "$out: $(grep -E 'Chip area' ${out%.v}.log | tail -1); TIELO $(grep -c '^ *TIELOH7R' $out); assigns $(grep -c '^ *assign' $out)"
