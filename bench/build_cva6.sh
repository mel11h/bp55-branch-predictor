#!/bin/bash
# Build the 21 benchmark programs for CVA6 (cva6/cva6.sh runs them).
#
# The CVA6 harness uses exactly the images of the CORE-V Wally flow: RV32IM
# (-march=rv32im, so no compressed instruction exists in any program), linked
# at 0x80000000 with a 64 MB footprint, console and exit through stores to the
# symbol "tohost" (bench/rt_wally/io_wally.S), plus an ISS twin of every program
# for the instruction-count cross-check on iss/rvsim. So this script only runs
# bench/build_wally.sh with a separate output directory (bench/build/cva6 by
# default, CVA6_BENCH_OUT to override), so that a Wally rebuild never changes
# binaries a CVA6 sweep is reading, and then checks two things:
#   - the program objects are byte-identical to the ones bench/build.sh made
#     for the BP55 traces (when bench/build holds a build), as build_wally.sh
#     checks for its default output directory;
#   - no ELF contains a 16-bit (compressed) instruction encoding.
#
# Toolchain: clang, ld.lld, llvm-objcopy, llvm-objdump from PATH (source tools/env.sh).
# Settings: GSF and CM_IT as in build.sh; the project uses GSF=4 CM_IT=60.
set -u
R=${BP55_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
B=$R/bench
O=${CVA6_BENCH_OUT:-$B/build/cva6}
WALLY_BENCH_OUT=$O "$B/build_wally.sh" || exit 1

fail=0
if [ -d "$B/build" ]; then
  same=0; diff=0; diffs=""
  for o in "$O"/obj/*.o; do b=$(basename "$o")
    case $b in crt.o|io_*.o|libc.o|cm_core_portme_wally.o) continue;; esac
    [ -f "$B/build/$b" ] || continue
    if cmp -s "$o" "$B/build/$b"; then same=$((same+1)); else diff=$((diff+1)); diffs="$diffs $b"; fi
  done
  echo "object check against bench/build: $same identical, $diff different${diffs:+ ($diffs)}"
fi

# Every instruction must be 32 bits wide: llvm-objdump prints the raw encoding
# as 4-byte groups for 32-bit and as one 2-byte group for 16-bit instructions.
for e in "$O"/*.elf; do
  n=$(llvm-objdump -d --section=.text "$e" | awk -F'\t' '/^ *[0-9a-f]+: / { b = $1; sub(/^ *[0-9a-f]+: /, "", b); gsub(/ /, "", b); if (length(b) != 8) c++ } END { print c+0 }')
  if [ "$n" != 0 ]; then echo "COMPRESSED $(basename "$e"): $n instructions are not 32-bit"; fail=1; fi
done
[ $fail = 0 ] && echo "no compressed instructions in $(ls "$O"/*.elf | wc -l) programs"
exit $fail
