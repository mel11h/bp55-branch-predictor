#!/bin/bash
# xprop_gl.sh <netlist .v|.v.gz> <tag> [models: gl|udp] [--reset-edge]
#   4-state post-reset clear check (verif/tb_bp55_xprop.sv, gate-level copy from
#   mk_tb_xprop_gl.py) on a gate netlist under Icarus. Cell models:
#     gl  (default) gls/mkcells.py output: flops update with non-blocking assignments, the ICG
#         latch and AND are level-sensitive, so a clock derived through an ICG (and through clock
#         buffers) is race-free in zero-delay simulation, like an RTL model with NBAs;
#     udp the PDK models with their UDP tables and specify blocks (gls/mkcells.py --icarus, which
#         only ties the dly_* timing-check nets that Icarus does not drive); X-pessimistic UDPs,
#         and the 1.0 ns placeholder path delays order the gated clock after the ungated one.
#   --reset-edge: rst_n starts high and falls at 0.1 ns (see mk_tb_xprop_gl.py). Needed with the
#         gl models when async-reset flops sit behind an ICG: their behavioural model applies the
#         reset only on a negedge of RN or on a clock edge, and the unmodified testbench starts
#         with rst_n = 0 (no edge) while the gated clock does not toggle.
#   Output: cg/gls/build/<tag>/xprop_<models>[_redge].log; exit 0 iff "XPROP: 0 failure(s)".
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
: "${BP55_ROOT:=$(cd "$here/../.." && pwd)}"
net="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; tag=$2; models=${3:-gl}; redge=${4:-}
sfx=$models; [ "$redge" = --reset-edge ] && sfx=${models}_redge
B="$here/build/$tag"; mkdir -p "$B"; cd "$B"
PDKV="$BP55_ROOT/pdk/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR/verilog/ics55_LLSC_H7CR.v"
case $net in *.gz) zcat "$net" > xdesign.v ;; *) cp "$net" xdesign.v ;; esac
sed -i -E '/^ *(FILLER[0-9]+H7R|FILLTAPH7R) +[A-Za-z0-9_]+ *\(\);$/d' xdesign.v   # physical-only cells
case $models in
  gl)  cells=cells_gl.v; python3 -I "$BP55_ROOT/gls/mkcells.py" "$PDKV" "$cells" --used xdesign.v ;;
  udp) cells=cells_icarus.v; python3 -I "$BP55_ROOT/gls/mkcells.py" "$PDKV" "$cells" --icarus ;;
  *) echo "models must be gl or udp"; exit 2 ;;
esac
python3 -I "$here/mk_tb_xprop_gl.py" "$BP55_ROOT/verif/tb_bp55_xprop.sv" xdesign.v tb_xprop_gl.sv $redge | tee "xprop_$sfx.log"
iverilog -g2012 -o x_$models.vvp "$cells" xdesign.v tb_xprop_gl.sv >> "xprop_$sfx.log" 2>&1
vvp -n x_$models.vvp >> "xprop_$sfx.log" 2>&1 || true
rm -f xdesign.v x_$models.vvp
sed -i -e "s#$BP55_ROOT/##g" "xprop_$sfx.log"
grep -E "PASS|FAIL|XPROP|clear finished|rows with X" "xprop_$sfx.log"
grep -q '^XPROP: 0 failure' "xprop_$sfx.log"
