#!/bin/bash
# replay_icarus.sh <netlist .v|.v.gz> <tag> <record .rec[.gz]>
#   Icarus replay (tb_replay.sv) of a recorded stimulus on a gate netlist with the behavioural
#   cell models of gls/mkcells.py (race-free for gated clocks: non-blocking flops). The record is
#   streamed through a FIFO, nothing large is written to disk. Log: cg/act/build/<tag>/replay_<rec>.log
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
: "${BP55_ROOT:=$(cd "$here/../.." && pwd)}"
net="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; tag=$2
rec="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"; rn=$(basename "$rec"); rn=${rn%%.*}
B="$here/build/$tag"; mkdir -p "$B"; cd "$B"
PDKV="$BP55_ROOT/pdk/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR/verilog/ics55_LLSC_H7CR.v"
case $net in *.gz) zcat "$net" > rdesign_$rn.v ;; *) cp "$net" rdesign_$rn.v ;; esac
python3 -I "$BP55_ROOT/gls/mkcells.py" "$PDKV" rcells_$rn.v --used rdesign_$rn.v
iverilog -g2012 -o r_$rn.vvp rcells_$rn.v rdesign_$rn.v "$here/tb_replay.sv"
rm -f rdesign_$rn.v rec_$rn.fifo; mkfifo rec_$rn.fifo
python3 -I "$here/rec2hex.py" "$rec" rec_$rn.fifo &
vvp -n r_$rn.vvp +rec=rec_$rn.fifo > replay_$rn.log 2>&1 || true
wait; rm -f rec_$rn.fifo r_$rn.vvp rcells_$rn.v
tail -12 replay_$rn.log
grep -q "=> PASS" replay_$rn.log
