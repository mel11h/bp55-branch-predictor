#!/bin/bash
# cosim.sh [max_records] [delay] [nonbranch] : RTL (Yosys CXXRTL) vs bp_model.h co-simulation.
# Uses the yosys binary on PATH (override YOSYS=...) instead of syn/y.py (pyosys);
# the pass sequence is the one given in README step 4.
# CXXRTL runtime headers: $CXXRTL_INC, else `yosys-config --datdir` (YOSYS_CONFIG=...).
set -eu
cd "$(dirname "$0")"
R=$(cd .. && pwd); T=${TRACES:-$R/traces}
YOSYS=${YOSYS:-yosys}
if [ -z "${CXXRTL_INC:-}" ]; then
  YC=${YOSYS_CONFIG:-$(command -v yosys-config || true)}
  [ -n "$YC" ] || { echo "set CXXRTL_INC or YOSYS_CONFIG (yosys-config not on PATH)" >&2; exit 2; }
  CXXRTL_INC=$("$YC" --datdir)/include/backends/cxxrtl/runtime
fi
[ -f "$CXXRTL_INC/cxxrtl/cxxrtl.h" ] || { echo "no cxxrtl.h under $CXXRTL_INC" >&2; exit 2; }
"$YOSYS" -q -p "read_verilog -sv $R/rtl/bp55.sv; hierarchy -top bp55; proc; flatten; opt; memory -nomap; opt; write_cxxrtl bp55_rtl.cc"
g++ -O2 -std=c++17 -I"$CXXRTL_INC" -o cosim cosim.cc
./cosim "${1:-300000}" "${2:-0}" "${3:-1}" "$T"/*.trc
