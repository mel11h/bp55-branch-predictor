#!/bin/bash
# verif/run.sh : RTL regression for rtl/bp55.sv. Exits non-zero if any step fails.
#   1. verilator --lint-only -Wall           (no warnings; waivers are in the source with reasons)
#   2. yosys proc; check -assert             (no undriven / multiply-driven / comb loops)
#   3. iverilog -g2012 on the unmodified source (Icarus 12 elaboration, no warnings)
#   4. directed tests under Verilator        (tb_bp55_directed.sv: "DONE: 0 failure(s)")
#   5. directed tests under Icarus           (same testbench, 4-state)
#   6. X-propagation test under Icarus       (tb_bp55_xprop.sv: "XPROP: 0 failure(s)")
#   7. optional: COSIM=<records> runs sim/cosim.sh <records> (0 = full traces) as a smoke test
# Logs are written next to this script (*.log); build products go to a temp dir that is removed.
set -u
cd "$(dirname "$0")"
export PATH=~/.local/bin:$PATH
RTL=../rtl/bp55.sv
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
step() { # name status
  if [ "$2" = 0 ]; then printf '  %-48s PASS\n' "$1"; else printf '  %-48s FAIL\n' "$1"; fail=1; fi
}
echo "BP55 RTL regression"

verilator --lint-only -Wall --top-module bp55 $RTL > lint.log 2>&1
st=$?; grep -q '%Warning\|%Error' lint.log && st=1
step "verilator --lint-only -Wall" $st

yosys -q -p "read_verilog -sv $RTL; hierarchy -check -top bp55; proc; check -assert" > yosys_check.log 2>&1
step "yosys proc; check -assert" $?

iverilog -g2012 -o "$W/elab.vvp" $RTL > icarus_elab.log 2>&1
st=$?; [ -s icarus_elab.log ] && st=1
step "iverilog -g2012 elaboration (no warnings)" $st

verilator --binary -MAKEFLAGS "CXX=g++ LINK=g++ AR=ar" --timing -Wno-fatal -Wno-lint -Wno-TIMESCALEMOD -sv \
  --top-module tb -Mdir "$W/vl" $RTL tb_bp55_directed.sv -o tb > "$W/vl_build.log" 2>&1 \
  && "$W/vl/tb" > directed_verilator.log 2>&1
st=$?; grep -q '^DONE: 0 failure' directed_verilator.log 2>/dev/null || st=1
[ $st = 0 ] || tail -20 "$W/vl_build.log"
step "directed tests (Verilator)" $st

iverilog -g2012 -o "$W/dir.vvp" $RTL tb_bp55_directed.sv > "$W/iv_build.log" 2>&1 \
  && vvp -n "$W/dir.vvp" > directed_icarus.log 2>&1
st=$?; grep -q '^DONE: 0 failure' directed_icarus.log 2>/dev/null || st=1
[ $st = 0 ] || cat "$W/iv_build.log"
step "directed tests (Icarus)" $st

iverilog -g2012 -o "$W/x.vvp" $RTL tb_bp55_xprop.sv > "$W/ix_build.log" 2>&1 \
  && vvp -n "$W/x.vvp" > xprop.log 2>&1
st=$?; grep -q '^XPROP: 0 failure' xprop.log 2>/dev/null || st=1
[ $st = 0 ] || cat "$W/ix_build.log"
step "X-propagation / post-reset clear (Icarus)" $st

grep -h 'KNOWN-OPEN' directed_verilator.log | sed 's/^ */  /'

if [ -n "${COSIM:-}" ]; then
  ../sim/cosim.sh "$COSIM" 0 1 0 > cosim_smoke.log 2>&1
  st=$?; step "cosim smoke ($COSIM records/trace)" $st; tail -1 cosim_smoke.log
fi

[ $fail = 0 ] && echo "REGRESSION PASS" || echo "REGRESSION FAIL"
exit $fail
