#!/bin/bash
# build_vl.sh <netlist .v|.v.gz> <tag>
#   Verilator build of a gate netlist with the PDK cell models (gls/mkcells.py output, flops with
#   non-blocking updates, ICG latch level-sensitive) and the replay harness cg/act/replay.cpp,
#   with SAIF tracing of every net (--trace-saif --trace-underscore, all-zero initial state).
#   Verilator 5 schedules clocks derived through ICGs and clock buffers with IEEE semantics
#   (the gated flops sample before any non-blocking update of the same edge).
#   Output: cg/act/build/<tag>/replay
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
: "${BP55_ROOT:=$(cd "$here/../.." && pwd)}"
net="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; tag=$2
B="$here/build/$tag"; mkdir -p "$B"; cd "$B"
PDKV="$BP55_ROOT/pdk/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR/verilog/ics55_LLSC_H7CR.v"
case $net in *.gz) zcat "$net" > design.v ;; *) cp "$net" design.v ;; esac
# physical-only cells of a routed netlist (fillers, well taps: no ports, no Verilog model) are dropped
sed -i -E '/^ *(FILLER[0-9]+H7R|FILLTAPH7R) +[A-Za-z0-9_]+ *\(\);$/d' design.v
cells=cells_gl.v   # only the cells this netlist uses
python3 -I "$BP55_ROOT/gls/mkcells.py" "$PDKV" "$cells" --used design.v
verilator --cc --exe --build -j "${JOBS:-4}" --top-module bp55 -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN \
  --x-initial 0 --x-assign 0 --trace-saif --trace-underscore --no-timing -O3 \
  -CFLAGS "${OPT:--O1}" -MAKEFLAGS "CXX=${CXX:-g++} LINK=${CXX:-g++} AR=ar" --Mdir obj "$cells" design.v "$here/replay.cpp" -o replay > build.log 2>&1
cp obj/replay replay && rm -f design.v   # obj/ is kept for quick harness rebuilds; delete when done
echo "built $B/replay"
