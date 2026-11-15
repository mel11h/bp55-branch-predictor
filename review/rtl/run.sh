#!/bin/bash
# Directed review testbench for rtl/bp55.sv (Verilator; Icarus 12 cannot elaborate bp55.sv line 126)
set -e
cd "$(dirname "$0")"
export PATH=~/.local/bin:$PATH
OBJ=${OBJ:-/tmp/bp55_review_obj}
verilator --binary -MAKEFLAGS "CXX=g++ LINK=g++ AR=ar" --timing -Wno-fatal -Wno-lint -Wno-TIMESCALEMOD -sv --top-module tb -Mdir "$OBJ" ../../rtl/bp55.sv tb_bp55_directed.sv -o tb >/dev/null
"$OBJ"/tb | tee directed.log
