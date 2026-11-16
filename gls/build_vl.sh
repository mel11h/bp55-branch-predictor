#!/bin/bash
# build_vl.sh <netlist .v|.v.gz> <tag> <harness v1|v2>
#   Verilator route for the gate-level co-simulation (the CXXRTL route, build_gl.sh, needs more than
#   7.5 GB and several hours of g++ per flattened netlist on this machine). Builds gls/build/<tag>/cosim:
#     netlist + gls/build/cells_gl.v (PDK cell models, UDPs replaced, gls/mkcells.py)
#     -> verilator --cc (flop/latch state and RTL-named nets made public by gls/vl/gl.vlt)
#     -> bp55_rtl.cc = CXXRTL-compatible facade over the Verilated model (gls/mkshim.py)
#     -> the same harness source as build_gl.sh (v2: mkharness.py on sim/cosim.cc; v1: 8ff8f15
#        cosim.cc with the gl_rd accessor change), compiled and linked against the model.
#   Env: OPT (g++ level for the model, default -O1), JOBS (make -j, default 2).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
: "${BP55_ROOT:=$(cd "$here/.." && pwd)}"
net="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; tag=$2; h=$3
B="$here/build/$tag"; rm -rf "$B"; mkdir -p "$B"; cd "$B"
PDKV="$BP55_ROOT/pdk/IP/STD_cell/ics55_LLSC_H7C_V1p10C100/ics55_LLSC_H7CR/verilog/ics55_LLSC_H7CR.v"
case $net in *.gz) zcat "$net" > design.v ;; *) cp "$net" design.v ;; esac
python3 "$here/mkcells.py" "$PDKV" cells_gl.v --used design.v
case $h in
  v2) python3 "$here/mkharness.py" "$BP55_ROOT/sim/cosim.cc" cosim.cc; cp "$BP55_ROOT/sim/bp_model.h" . ;;
  v1) git -C "$BP55_ROOT" show 8ff8f15:sim/cosim.cc > cosim.cc; git -C "$BP55_ROOT" show 8ff8f15:sim/bp_model.h > bp_model.h
      sed -i -e 's/t\.p_f__meta\.curr\.data\[i\]/gl_rd(t.p_f__meta)[i]/' \
             -e 's/^using Top = cxxrtl_design::p_bp55;/&\ntemplate <size_t N> static const uint32_t *gl_rd(const cxxrtl::value<N> \&v) { return v.data; }\ntemplate <size_t N> static const uint32_t *gl_rd(const cxxrtl::wire<N> \&w) { return w.curr.data; }/' cosim.cc
      grep -q 'gl_rd(t.p_f__meta)' cosim.cc ;;
  *) echo "harness must be v1 or v2"; exit 2 ;;
esac
verilator --cc -O3 --x-assign unique --x-initial unique -Wno-fatal -Wno-lint -Wno-style -Wno-UNOPTFLAT \
  -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD --top-module bp55 --output-split 20000 --output-split-cfuncs 2000 \
  -Mdir obj --exe "$B/cosim.cc" -CFLAGS "-I$B -std=c++17" "$here/vl/gl.vlt" cells_gl.v design.v > verilate.log 2>&1
python3 "$here/mkshim.py" design.v obj bp55_rtl.cc
make -s -C obj -f Vbp55.mk -j"${JOBS:-2}" OPT_FAST="${OPT:--O1}" OPT_SLOW=-O0 OPT_GLOBAL=-O1 CXX=g++ LINK=g++ AR=ar > make.log 2>&1 \
  || { tail -30 make.log; exit 1; }
cp obj/Vbp55 cosim
rm -rf obj design.v
sed -i -e "s#$BP55_ROOT/##g" verilate.log
echo "built $B/cosim"
