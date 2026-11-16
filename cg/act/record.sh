#!/bin/bash
# record.sh <trace name> <records> <out .rec>
#   Runs the RTL co-simulation (sim/cosim.cc via mkrecorder.py, rtl/bp55.sv through Yosys
#   CXXRTL exactly as sim/cosim.sh builds it) on the first <records> branch records of
#   traces/<trace name>.trc, from an all-zero initial state, and records every cycle's inputs and
#   outputs into <out .rec> (format: mkrecorder.py). The co-simulation checks against the model are
#   all active; the TRACE line it prints must show mismatches=0.
#   Stimulus knobs as sim/cosim.sh: STALL (default 100), MISS (default 0 here: no u_isbr=0
#   training message for non-branches, so the training traffic is that of a real core), FLUSH
#   (default 50), SEED (default 1), DELAY (default 0).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
: "${BP55_ROOT:=$(cd "$here/../.." && pwd)}"
B="$here/build/recorder"; mkdir -p "$B"
if [ ! -x "$B/recorder" ]; then
  YC=${YOSYS_CONFIG:-$(command -v yosys-config)}
  CXXRTL_INC=${CXXRTL_INC:-$("$YC" --datdir)/include/backends/cxxrtl/runtime}
  ( cd "$B"
    yosys -q -p "read_verilog -sv $BP55_ROOT/rtl/bp55.sv; hierarchy -top bp55; proc; flatten; opt; memory -nomap; opt; write_cxxrtl bp55_rtl.cc"
    python3 -I "$here/mkrecorder.py" "$BP55_ROOT/sim/cosim.cc" recorder.cc
    cp "$BP55_ROOT/sim/bp_model.h" .
    g++ -O2 -std=c++17 -I"$CXXRTL_INC" -I. -o recorder recorder.cc && rm -f bp55_rtl.cc )
fi
REC_FILE="$3" REC_ZERO_INIT=1 "$B/recorder" -n "$2" -d "${DELAY:-0}" -b 1 -r 0 -s "${STALL:-100}" -m "${MISS:-0}" \
  -f "${FLUSH:-50}" -S "${SEED:-1}" "$BP55_ROOT/traces/$1.trc"
echo "recorded $(( $(stat -c %s "$3") / 96 )) cycles into $3"
