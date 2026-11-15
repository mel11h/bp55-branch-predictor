#!/bin/bash
# Device-level LVS of individual standard cells against their own CDL subcircuit.
# usage: run_cell_lvs.sh CELLS.sp(flattened CDL) LIB.gds OUTDIR CELL [CELL ...]
set -u
here=$(cd "$(dirname "$0")" && pwd)
sp=$1; gds=$2; out=$3; shift 3
mkdir -p "$out"
for c in "$@"; do
  awk -v c="$c" '$1==".SUBCKT" && $2==c {p=1} p{print} p && $1==".ENDS"{p=0}' "$sp" > "$out/$c.sp"
  res=$(klayout -b -r "$here/icsprout55_lvs.lvs" -rd gds="$gds" -rd top="$c" -rd schematic="$out/$c.sp" \
        -rd report="$out/$c.lvsdb" -rd threads=1 -rd tie=1 2>&1)
  r=$(echo "$res" | grep -o "LVS RESULT: [A-Z]*" | head -1)
  nd=$(grep -c "^M" "$out/$c.sp")
  echo -e "$c\t${r:-ERROR}\tschematic_devices=$nd\t$(echo "$res" | grep 'well-tie' | sed 's/well-tie //' | tr '\n' ';')"
  [ -z "$r" ] && echo "$res" | tail -5 | sed 's/^/    /'
done
true
