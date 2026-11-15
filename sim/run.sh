#!/bin/bash
# run.sh out.csv < list-of-configs ("name key=val ...")   -> runs all configs in parallel
out=$1; tmp=$(mktemp -d)
i=0; while read -r line; do [ -z "$line" ] && continue; i=$((i+1)); echo "./bpsim $line -- /home/user/bp55/traces/*.trc > $tmp/$(printf %04d $i).csv"; done | xargs -P4 -I{} sh -c "{}"
cat $tmp/*.csv > $out; rm -rf $tmp
