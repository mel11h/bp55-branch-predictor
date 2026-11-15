#!/bin/bash
# cosim.sh [max_records (0 = full traces)] [delay] [nonbranch 0/1] [remap 0/1]
#   RTL (Yosys CXXRTL) vs bp_model.h co-simulation (see the header of cosim.cc for what is checked).
#   One cosim process per trace, JOBS in parallel (default 8). Stimulus knobs (env):
#   STALL (permille of lookups held 1-3 cycles, default 100), MISS (permille of BTB-missing
#   non-branches that get a u_isbr=0 message, default 1000), FLUSH (flushes per 100k lookups,
#   default 50), SEED (default 1). Prints one TRACE line per trace and a COSIM summary line;
#   exits non-zero on any mismatch.
# Uses the yosys binary on PATH (override YOSYS=...); the pass sequence is the one given in
# README step 4. CXXRTL runtime headers: $CXXRTL_INC, else `yosys-config --datdir` (YOSYS_CONFIG=...).
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
if [ -z "${NOBUILD:-}" ]; then
  "$YOSYS" -q -p "read_verilog -sv $R/rtl/bp55.sv; hierarchy -top bp55; proc; flatten; opt; memory -nomap; opt; write_cxxrtl bp55_rtl.cc"
  g++ -O2 -std=c++17 -I"$CXXRTL_INC" -o cosim cosim.cc
fi
MAXR=${1:-0}; DELAY=${2:-0}; NB=${3:-1}; RM=${4:-0}
OPTS="-n $MAXR -d $DELAY -b $NB -r $RM -s ${STALL:-100} -m ${MISS:-1000} -f ${FLUSH:-50} -S ${SEED:-1}"
tmp=$(mktemp -d)
rc=0
ls "$T"/*.trc | xargs -P"${JOBS:-8}" -I{} sh -c "./cosim $OPTS {} > $tmp/\$(basename {}).out 2> $tmp/\$(basename {}).err || true"
cat "$tmp"/*.out
cat "$tmp"/*.err >&2
awk -v d="$DELAY" -v nb="$NB" -v rm="$RM" -v n="$(ls "$T"/*.trc | wc -l)" '
  /^TRACE/ { k++; for (i = 3; i <= NF; i++) { split($i, a, "="); s[a[1]] += a[2]; if (i > 2 && !(a[1] in ord)) { ord[a[1]] = ++no; nm[no] = a[1] } } }
  END { line = sprintf("COSIM delay=%d nonbranch=%d remap=%d traces=%d/%d", d, nb, rm, k, n);
        for (j = 1; j <= no; j++) line = line sprintf(" %s=%.0f", nm[j], s[nm[j]]);
        ok = (k == n && s["mismatches"] == 0); print line " => " (ok ? "PASS" : "FAIL"); exit(ok ? 0 : 1) }' "$tmp"/*.out || rc=1
rm -rf "$tmp"
exit $rc
