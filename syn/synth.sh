#!/bin/bash
# synth.sh <name> <lib> <period_ps> <clockgate 0/1>
n=$1; lib=$2; D=$3; cg=$4
CG=""; [ "$cg" = 1 ] && CG="clockgate -pos ICGX2H7R E:CK:ECK -min_net_size ${MINCG:-4};"
python3 y.py "read_verilog -sv ../rtl/bp55.sv; synth -top bp55 -flatten; opt -full; $CG dfflibmap -liberty $lib; abc -liberty $lib -constr c.constr -D $D -script abc.script; opt_clean; hilomap -hicell TIEHIH7R Z -locell TIELOH7R Z; stat -liberty $lib; write_verilog -noattr $n.v" > $n.log 2>&1
echo "done $n: $(grep -E 'Chip area' $n.log | tail -1) $(grep -aE 'Delay =' $n.log | tail -1)"
