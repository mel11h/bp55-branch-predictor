#!/bin/bash
# Clock-gating synthesis sweep of the hardened RTL (rtl/bp55.sv).
# Pass sequence = syn/synth.sh and syn/run_local/synth_local.sh (same ABC script, same
# constraints, same tie cells); only the clock-gating step and the Liberty differ:
#
#   MINCG=0          no clockgate pass (ungated reference)
#   MINCG=<n>        clockgate -pos ICGX2H7R E:CK:ECK -min_net_size <n>   (as syn/synth.sh)
#   CGLIB=1          clockgate -liberty <patched lib> -min_net_size <n>   (cell chosen from the
#                    Liberty clock-gating attributes; works only with the patched Liberty)
#   COARSE=<m>       per-table gating: coarse_gate.py rewrites every table with >= m enable
#                    flops to one table-level enable (row enable kept as a D-side mux), then
#                    clockgate -pos ICGX2H7R E:CK:ECK -min_net_size m (one ICG per table)
#   LIBDIR           Liberty directory (default cg/lib, the patched copies; the patch only
#                    touches the ten ICG cells, so mapping of everything else is unchanged)
#
# usage: synth_cg.sh <name> <corner tt|ss> <period_ps>
# output (this directory): <name>.v (git-ignored), <name>.v.gz, <name>.log, <name>.stat.txt
set -e
here="$(cd "$(dirname "$0")" && pwd)"
: "${BP55_ROOT:=$(cd "$here/../.." && pwd)}"
n=$1; corner=$2; D=$3
LIBD="${LIBDIR:-$BP55_ROOT/cg/lib}"
case $corner in
  tt) lib="$LIBD/ics55_LLSC_H7CR_typ_tt_1p2_25_nldm.lib" ;;
  ss) lib="$LIBD/ics55_LLSC_H7CR_ss_rcworst_1p08_125_nldm.lib" ;;
  *) echo "corner must be tt or ss"; exit 1 ;;
esac
[ -f "$lib" ] || lib="$lib.gz"   # the patched copies are kept gzipped
rtl="$BP55_ROOT/rtl/bp55.sv"
CG=""
if [ "${MINCG:-0}" -gt 0 ]; then
  if [ "${CGLIB:-0}" = 1 ]; then CG="clockgate -liberty $lib -min_net_size $MINCG;"
  else CG="clockgate -pos ICGX2H7R E:CK:ECK -min_net_size $MINCG;"; fi
fi
cd "$here"
FRONT="read_verilog -sv $rtl; synth -top bp55 -flatten; opt -full;"
if [ -n "${COARSE:-}" ]; then
  yosys -q -l "$n.pre.log" -p "$FRONT write_json $n.pre.json" >/dev/null
  python3 -I "$here/coarse_gate.py" "$n.pre.json" "$n.cg.json" "$COARSE" | tee "$n.coarse.txt"
  rm -f "$n.pre.json"
  FRONT="read_json $n.cg.json; techmap; opt_clean;"   # techmap: the inserted $reduce_or trees to gates
  CG="clockgate -pos ICGX2H7R E:CK:ECK -min_net_size $COARSE;"
fi
yosys -q -l "$n.log" -p "$FRONT $CG dfflibmap -liberty $lib; abc -liberty $lib -constr $BP55_ROOT/syn/c.constr -D $D -script $BP55_ROOT/syn/abc.script; opt_clean; hilomap -hicell TIEHIH7R Z -locell TIELOH7R Z; stat -liberty $lib; write_verilog -noattr $n.v" >/dev/null
[ -n "${COARSE:-}" ] && { cat "$n.pre.log" "$n.log" > "$n.log.tmp"; mv "$n.log.tmp" "$n.log"; rm -f "$n.pre.log" "$n.cg.json"; }
sed -i -E -e "s#$BP55_ROOT/##g" -e "s#/[^ ']*/share/yosys/#<yosys-share>/#g" "$n.log"
# summary: cells, ICGs, flops behind an ICG
python3 -I "$here/cgstat.py" "$n.v" > "$n.stat.txt"
sed -i -e "s#$BP55_ROOT/##g" "$n.v"   # no machine paths in the debug wire names
gzip -9 -k -f "$n.v"
echo "done $n: $(grep -E 'Chip area' $n.log | tail -1) $(grep -aE 'Delay =' $n.log | tail -1 | sed 's/.*Delay = *//;s/ps.*/ps/')"
cat "$n.stat.txt"
