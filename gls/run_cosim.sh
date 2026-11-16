#!/bin/bash
# run_cosim.sh <tag> <v1|v2> [max_records (0 = full)] : run gls/build/<tag>/cosim on every trace in traces/,
#   JOBS (default 3) traces in parallel, one process per trace, inside one memory-limited scope (lim.sh).
#   v2 options are those of sim/cosim.sh (delay DELAY=0, nonbranch 1, remap REMAP=0, STALL 100, MISS 1000,
#   FLUSH 50, SEED 1); v1 runs the unchanged 8ff8f15 harness: cosim <max_records> <delay> 1 <trace>.
#   Per-trace output and wall time go to gls/logs/<tag>[_<suffix>]/; prints the summary line.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
: "${BP55_ROOT:=$(cd "$here/.." && pwd)}"
tag=$1; h=$2; MAXR=${3:-0}; T=${TRACES:-$BP55_ROOT/traces}
L="$here/logs/$tag${LOGSUFFIX:+_$LOGSUFFIX}"; mkdir -p "$L"
B="$here/build/$tag/cosim"
if [ "$h" = v2 ]; then
  OPTS="-n $MAXR -d ${DELAY:-0} -b 1 -r ${REMAP:-0} -s ${STALL:-100} -m ${MISS:-1000} -f ${FLUSH:-50} -S ${SEED:-1}"
else
  [ "$MAXR" = 0 ] && MAXR=4000000000
  OPTS="$MAXR ${DELAY:-0} 1"
fi
start=$(date +%s)
ls "$T"/*.trc | grep -E "${TRACELIST:-.}" | "$here/lim.sh" xargs -P"${JOBS:-3}" -I{} sh -c \
  "s=\$(date +%s); $B $OPTS {} > $L/\$(basename {}).out 2> $L/\$(basename {}).err; echo rc=\$? wall=\$((\$(date +%s)-s))s >> $L/\$(basename {}).err"
echo "wall=$(( $(date +%s) - start ))s opts=$OPTS" > "$L/summary.txt"
if [ "$h" = v2 ]; then
  awk '/^TRACE/ { k++; for (i = 3; i <= NF; i++) { split($i, a, "="); s[a[1]] += a[2]; if (!(a[1] in ord)) { ord[a[1]] = ++no; nm[no] = a[1] } } }
    END { line = sprintf("GLCOSIM traces=%d", k); for (j = 1; j <= no; j++) line = line sprintf(" %s=%.0f", nm[j], s[nm[j]]);
          print line " => " ((k > 0 && s["mismatches"] == 0) ? "PASS" : "FAIL") }' "$L"/*.out >> "$L/summary.txt"
else
  awk '/^COSIM/ { k++; for (i = 4; i <= NF; i++) { split($i, a, "="); if (a[2] != "") s[a[1]] += a[2] } }
    END { printf "GLCOSIM-v1 traces=%d lookups=%.0f repairs=%.0f phantom=%.0f cycles=%.0f mismatches=%.0f => %s\n", k, s["lookups"], s["repairs"], s["phantom"], s["cycles"], s["mismatches"], (k > 0 && s["mismatches"] == 0) ? "PASS" : "FAIL" }' "$L"/*.out >> "$L/summary.txt"
fi
grep -h MISMATCH "$L"/*.err | head -5
cat "$L/summary.txt"
