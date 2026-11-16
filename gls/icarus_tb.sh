#!/bin/bash
# icarus_tb.sh <netlist .v|.v.gz> <tag> [<spef .gz> <io_ref_pin.txt>]
#   4-state gate-level runs of verif/tb_bp55_directed.sv and verif/tb_bp55_xprop.sv in Icarus 12 with the
#   unmodified PDK cell models (UDPs; flops start as X). Testbenches: gls/mktb.py (hierarchical
#   references mapped to netlist nets). Clock-gated netlists use the Icarus copy of the cell file with
#   the ICG delayed nets tied (mkcells.py --icarus); fillers / tap cells get empty stubs.
#   With a SPEF: additionally writes a slow-corner SDF with OpenSTA (gls/sdf.tcl, at BP55_PERIOD, default
#   6.0 ns), converts it for Icarus (gls/sdffix.py, max and min) and runs the directed test SDF-annotated
#   with -gspecify at the testbench timing of gls/sdf_tb.py (low 3.2 ns, high 3.7 ns, sample 5.7 ns;
#   see the report for why 6.0 ns back-to-back is not usable with this testbench).
#   Logs: gls/logs/tb_<tag>/. Needs about 3 GB for the SDF runs. STA_LD: LD_LIBRARY_PATH for sta.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
: "${BP55_ROOT:=$(cd "$here/.." && pwd)}"
net="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; tag=$2; spef=${3:-}; ioref=${4:-}
B="$here/build/tb_$tag"; L="$here/logs/tb_$tag"; mkdir -p "$B" "$L"; cd "$B"
PDKV="$BP55_ROOT/pdk/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR/verilog/ics55_LLSC_H7CR.v"
case $net in *.gz) zcat "$net" > net.v ;; *) cp "$net" net.v ;; esac
python3 "$here/mkcells.py" "$PDKV" cells_icarus.v --icarus
python3 "$here/mkcells.py" "$PDKV" phys_stubs.v --stubs-only --used net.v
python3 "$here/mktb.py" net.v "$BP55_ROOT/verif" .
for t in directed xprop; do
  iverilog -g2012 -o $t.vvp gl_tb_bp55_$t.sv net.v cells_icarus.v phys_stubs.v > iverilog_$t.log 2>&1
  vvp -n $t.vvp > $t.log 2>&1 || true; rm -f $t.vvp; cp $t.log "$L/"
done
grep -h -E '^DONE|^XPROP' directed.log xprop.log
if [ -n "$spef" ]; then
  zcat "$spef" | sed -E 's/^(\*D_NET \S*\\\[[0-9]+\\\])\\\[([0-9]+)\\\]/\1[\2]/' > net.spef   # see report: SPEF bus-bit names
  BP55_ROOT="$BP55_ROOT" SDF_NETLIST=net.v SDF_SPEF=net.spef SDF_OUT=ss.sdf IO_REF_FILE="$ioref" \
    LD_LIBRARY_PATH="${STA_LD:-}" sta -no_init -exit "$here/sdf.tcl" > sta_sdf.log 2>&1
  cp sta_sdf.log "$L/"
  for m in max min; do
    python3 "$here/sdffix.py" ss.sdf ss_$m.sdf $m
    python3 "$here/sdf_tb.py" gl_tb_bp55_directed.sv ss_$m.sdf sdf_${m}_directed.sv 3.2 3.7 5.7
    iverilog -gspecify -g2012 -o sdf_$m.vvp sdf_${m}_directed.sv net.v cells_icarus.v phys_stubs.v > iverilog_sdf_$m.log 2>&1
    vvp -n sdf_$m.vvp > sdf_${m}_directed.log 2>&1 || true; rm -f sdf_$m.vvp ss_$m.sdf; cp sdf_${m}_directed.log "$L/"
    grep -h '^DONE' sdf_${m}_directed.log
  done
  rm -f ss.sdf net.spef
fi
rm -f net.v
