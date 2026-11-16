#!/bin/bash
# finalize.sh : print the co-simulation summaries and, once no gate-level run is active, remove the
# build products (gls/build) and the netlist snapshot (gls/net) so that only scripts, logs and results stay.
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
for d in v1rtl v2syn v2rt v1syn v1rt; do
  printf '%-6s ' "$d"
  if [ -f logs/$d/summary.txt ]; then tail -1 logs/$d/summary.txt; head -1 logs/$d/summary.txt | sed 's/^/       /'
  else echo "running: $(ls logs/$d/*.out 2>/dev/null | xargs -r grep -l 'TRACE\|COSIM' | wc -l)/21 traces finished, $(grep -h MISMATCH logs/$d/*.err 2>/dev/null | wc -l) mismatch lines"; fi
done
if pgrep -f "$here/build/.*/cosim" > /dev/null; then echo "runs still active: build/ kept"; exit 1; fi
sed -i "s#$(cd "$here/.." && pwd)/##g" logs/*/*.err logs/*.txt 2>/dev/null
rm -rf build net
echo "build/ and net/ removed"
