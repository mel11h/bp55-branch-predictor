#!/bin/bash
# sweep_replay.sh <replay binary> <records per trace> <log> [trace ...]
#   For every trace (default: all traces/*.trc): record the RTL co-simulation (record.sh, model
#   checks active) and replay the record on the Verilated gate netlist (replay binary from
#   build_vl.sh); one line per trace in <log>, the record is deleted afterwards.
#   Env as record.sh (STALL, MISS, FLUSH, SEED, DELAY).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
: "${BP55_ROOT:=$(cd "$here/../.." && pwd)}"
bin=$1; n=$2; log=$3; shift 3
traces=("$@"); [ ${#traces[@]} = 0 ] && traces=($(cd "$BP55_ROOT/traces" && ls *.trc | sed 's/\.trc$//'))
tmp="$here/build/sweep_$$.rec"
echo "# replay sweep: $(basename "$(dirname "$bin")"), $n records per trace, STALL=${STALL:-100} MISS=${MISS:-0} FLUSH=${FLUSH:-50} SEED=${SEED:-1} DELAY=${DELAY:-0}" >> "$log"
for t in "${traces[@]}"; do
  r=$("$here/record.sh" "$t" "$n" "$tmp" 2>&1 | grep '^TRACE' | sed 's/.* cycles=\([0-9]*\) mismatches=\([0-9]*\)/rtl_cycles=\1 rtl_vs_model_mismatches=\2/')
  p=$("$bin" "$tmp" 2>/dev/null | grep '^REPLAY' | sed 's/^REPLAY //')
  echo "$t $r | $p" >> "$log"
  rm -f "$tmp"
done
