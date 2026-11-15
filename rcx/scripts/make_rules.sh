#!/bin/bash
# Build the three OpenRCX rules files: patterns (A), 2D field-solver reference SPEF (B),
# rules (C), and the self-check extraction of the patterns with the rules (D).
# usage: rcx/scripts/make_rules.sh [jobs]      (work files in rcx/work/patterns, rules in rcx/rules)
set -e
here="$(cd "$(dirname "$0")" && pwd)"
rcx="$(cd "$here/.." && pwd)"
export BP55_ROOT="${BP55_ROOT:-$(cd "$rcx/.." && pwd)}"
jobs="${1:-4}"   # the solver needs numpy + scipy: PYTHON (default /usr/bin/python3)
w="$rcx/work/patterns"; mkdir -p "$w" "$rcx/rules"
memwait() { while [ "$(awk '/MemAvailable/ {print int($2/1048576)}' /proc/meminfo)" -lt ${MEM_MIN_GB:-4} ]; do sleep 30; done; }
cap() { memwait; systemd-run --user --collect -q --wait --pipe -p MemoryHigh=${MEM_HIGH:-5G} -p MemoryMax=${MEM_MAX:-7G} -p MemorySwapMax=0 \
          --working-directory="$w" -E BP55_ROOT -E PATH "$@"; }
[ -f "$w/patterns.def" ] || cap openroad -threads 4 -no_init -exit "$here/gen_patterns.tcl" > "$w/gen_patterns.log" 2>&1
for c in typ rcworst rcbest; do
  [ -f "$w/patterns_$c.spef" ] || cap "${PYTHON:-/usr/bin/python3}" -I "$rcx/solver/patterns2spef.py" patterns.def $c patterns_$c.spef "$jobs" > "$w/solve_$c.log" 2>&1
  cap -E PAT_SPEF="patterns_$c.spef" -E RULES_OUT="$rcx/rules/bp55_$c.rules" \
      openroad -threads 4 -no_init -exit "$here/gen_rules.tcl" > "$w/gen_rules_$c.log" 2>&1
  rm -f "$w/rulesGen.log"
  cap -E RULES_OUT="$rcx/rules/bp55_$c.rules" -E EXT_SPEF="ext_$c.spef" \
      openroad -threads 4 -no_init -exit "$here/ext_patterns.tcl" > "$w/ext_patterns_$c.log" 2>&1
done
