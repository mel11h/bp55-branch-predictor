#!/bin/bash
# Local re-run of syn/synth.sh with the yosys binary instead of pyosys (syn/y.py).
# The pass sequence is the one in syn/synth.sh, unchanged; only the driver differs.
#
# usage: synth_local.sh <name> <corner tt|ss> <period_ps> <clockgate 0/1>
# input: $RTL (default bp55_v1.sv in this directory; git show <rev>:rtl/bp55.sv > bp55_v1.sv)
# output directory: $OUTDIR (default this directory)
# output: <name>.v, <name>.log (full yosys log incl. ABC), <name>.sta.log (OpenSTA, see sta_syn.tcl)
set -e
here="$(cd "$(dirname "$0")" && pwd)"
: "${BP55_ROOT:=$(cd "$here/../.." && pwd)}"
n=$1; corner=$2; D=$3; cg=$4
LIBD="$BP55_ROOT/pdk/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR/liberty"
case $corner in
  tt) lib="$LIBD/ics55_LLSC_H7CR_typ_tt_1p2_25_nldm.lib" ;;
  ss) lib="$LIBD/ics55_LLSC_H7CR_ss_rcworst_1p08_125_nldm.lib" ;;
  *) echo "corner must be tt or ss"; exit 1 ;;
esac
rtl="$(cd "$(dirname "${RTL:-$here/bp55_v1.sv}")" && pwd)/$(basename "${RTL:-bp55_v1.sv}")"
cd "${OUTDIR:-$here}"
CG=""; [ "$cg" = 1 ] && CG="clockgate -pos ICGX2H7R E:CK:ECK -min_net_size ${MINCG:-4};"
yosys -q -l "$n.log" -p "read_verilog -sv $rtl; synth -top bp55 -flatten; opt -full; $CG dfflibmap -liberty $lib; abc -liberty $lib -constr $here/../c.constr -D $D -script $here/../abc.script; opt_clean; hilomap -hicell TIEHIH7R Z -locell TIELOH7R Z; stat -liberty $lib; write_verilog -noattr $n.v" >/dev/null
sed -i -E -e "s#$BP55_ROOT/##g" -e "s#$rtl#$(basename $rtl)#g" -e "s#/[^ ']*/share/yosys/#<yosys-share>/#g" "$n.log"
echo "done $n: $(grep -E 'Chip area' $n.log | tail -1) $(grep -aE 'Delay =' $n.log | tail -1)"
