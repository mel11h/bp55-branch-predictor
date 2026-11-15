#!/bin/bash
# run.sh out.csv < list-of-configs ("name key=val ...")   -> runs all configs in parallel
# Traces are read from $TRACES (default: <repo>/traces); JOBS sets parallelism (default 4).
cd "$(dirname "$0")"
out=$1; tmp=$(mktemp -d)
T=${TRACES:-$(cd .. && pwd)/traces}
i=0; while read -r line; do [ -z "$line" ] && continue; i=$((i+1)); echo "./bpsim $line -- $T/*.trc > $tmp/$(printf %04d $i).csv"; done | xargs -P${JOBS:-4} -I{} sh -c "{}"
cat $tmp/*.csv > $out; rm -rf $tmp
