#!/bin/bash
# Build the 21 benchmark programs for CORE-V Wally (wally/wally.sh runs them).
# Separate from build.sh (the trace flow), which it does not touch: output goes
# to bench/build/wally (override with WALLY_BENCH_OUT).
#
# Every program is compiled exactly as build.sh compiles it (same compiler
# flags, defines, GSF and CM_IT) and linked twice from the same objects:
#   $O/<name>.elf      for Wally: linked at 0x80000000, console and exit
#                      through stores to "tohost" (rt_wally/io_wally.S)
#   $O/iss/<name>.bin  ISS twin: linked at 0, console and exit through ecall
#                      (rt_wally/io_iss.S), for iss/rvsim
# The two differ only in base address and in the I/O routines, which execute
# the same number of instructions, so Wally's minstret must equal rvsim's
# instruction count of the twin. rvsim is run on every twin; its counts are
# written to $O/iss/counts.csv and its console output to $O/iss/<name>.console.
#
# Differences from the traced binaries of build.sh: start-up (rt_wally/crt.S:
# exit through a function instead of an inline ecall), putchar/exit as separate
# routines (libc.c is compiled without its two ecall functions), and CoreMark
# uses rt_wally/core_portme_wally.c, whose ee_printf prints (the traced port is
# silent), so CoreMark's CRCs can be checked on Wally.
#
# Toolchain: clang, ld.lld, llvm-objcopy from PATH (source tools/env.sh).
# Settings: GSF (default 1) and CM_IT (default 40) as in build.sh; the project
# uses GSF=4 CM_IT=60.
set -u
R=${BP55_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
B=$R/bench; W=$B/rt_wally; O=${WALLY_BENCH_OUT:-$B/build/wally}
mkdir -p "$O/obj" "$O/iss"
CLANG_INC=${BP55_CLANG_INC:-$(clang -print-resource-dir)/include}
# Identical to CC in build.sh.
CC="clang --target=riscv32-unknown-elf -march=rv32im -mabi=ilp32 -O2 -ffreestanding -fno-builtin -nostdinc -isystem $B/rt/include -isystem $CLANG_INC -mno-relax -w"
MAXI=${MAXI:-60000000}
J=$O/obj
fail=0
echo "program,exit,instr,branches" > "$O/iss/counts.csv"

link() { # name objs...
  n=$1; shift
  if ! ld.lld -T $W/link_wally.ld -o $O/$n.elf $J/crt.o $J/io_wally.o "$@" 2> $O/$n.linkerr; then
    echo "LINKFAIL $n: $(head -2 $O/$n.linkerr | tr '\n' ' ')"; fail=1; return 1; fi
  if ! ld.lld -T $W/link_iss.ld -o $O/iss/$n.elf $J/crt.o $J/io_iss.o "$@" 2> $O/iss/$n.linkerr; then
    echo "LINKFAIL iss/$n"; fail=1; return 1; fi
  llvm-objcopy -O binary $O/iss/$n.elf $O/iss/$n.bin
  # rvsim prints "[rvsim] exit=<rc> instr=<n> branches=<n>" on its last line.
  # rvsim writes the program's console output and then its summary to stderr.
  $R/iss/rvsim $O/iss/$n.bin /dev/null $MAXI 2> $O/iss/$n.out
  line=$(tail -1 $O/iss/$n.out)
  head -n -2 $O/iss/$n.out > $O/iss/$n.console   # drop the "\n[rvsim] ..." summary
  echo "$n: $line"
  echo "$line" | sed -E "s/.*exit=(-?[0-9]+) instr=([0-9]+) branches=([0-9]+).*/$n,\1,\2,\3/" >> "$O/iss/counts.csv"
}

# Runtime. libc.c minus its two ecall routines (putchar, exit), which come from
# io_wally.S / io_iss.S instead. Both are one-line definitions in libc.c.
sed -E '/^int putchar\(int c\)\{/d; /^void exit\(int c\)\{/d' $B/rt/libc.c > $J/libc_noio.c
if [ $(( $(wc -l < $B/rt/libc.c) - $(wc -l < $J/libc_noio.c) )) -ne 2 ]; then
  echo "build_wally.sh: expected to remove exactly putchar and exit from rt/libc.c"; exit 1; fi
{ echo 'int putchar(int c); void exit(int c) __attribute__((noreturn));'; cat $J/libc_noio.c; } > $J/libc_wally.c
$CC -c $W/crt.S -o $J/crt.o && $CC -c $W/io_wally.S -o $J/io_wally.o && $CC -c $W/io_iss.S -o $J/io_iss.o \
  && $CC -c $J/libc_wally.c -o $J/libc.o && $CC -c $B/rt/board.c -o $J/board.o || exit 1

# CoreMark: same objects as build.sh except the port file.
objs=""
for f in $B/coremark/core_*.c $W/core_portme_wally.c; do o=$J/cm_$(basename $f .c).o
  $CC -I$B/coremark -I$B/cm_port -DITERATIONS=${CM_IT:-40} -DPERFORMANCE_RUN=1 -DFLAGS_STR=\"O2\" -c $f -o $o || exit 1; objs="$objs $o"; done
link coremark $objs $J/libc.o

# Embench, as in build.sh.
E=$B/embench-iot
$CC -I$E/support -c $E/support/beebsc.c -o $J/beebsc.o; $CC -I$E/support -DWARMUP_HEAT=0 -c $E/support/main.c -o $J/emain.o
for d in $E/src/*/; do n=$(basename $d); objs=""; ok=1
  for f in $d*.c; do o=$J/${n}_$(basename $f .c).o; $CC -I$E/support -I$d -DGLOBAL_SCALE_FACTOR=${GSF:-1} -DWARMUP_HEAT=0 -c $f -o $o 2>$J/$n.cerr || { echo "CCFAIL $n"; ok=0; }; objs="$objs $o"; done
  [ $ok = 1 ] && link $n $J/emain.o $objs $J/beebsc.o $J/board.o $J/libc.o
done
for n in interp recurse; do $CC -c $B/custom/$n.c -o $J/$n.o && link $n $J/$n.o $J/libc.o; done

# The program objects must be byte-identical to the ones build.sh compiled for
# the traces (when bench/build holds a build with the same GSF/CM_IT).
if [ -d $B/build ] && [ -z "${WALLY_BENCH_OUT:-}" ]; then
  same=0; diff=0; diffs=""
  for o in $J/*.o; do b=$(basename $o)
    case $b in crt.o|io_*.o|libc.o|cm_core_portme_wally.o) continue;; esac
    [ -f $B/build/$b ] || continue
    if cmp -s $o $B/build/$b; then same=$((same+1)); else diff=$((diff+1)); diffs="$diffs $b"; fi
  done
  echo "object check against bench/build: $same identical, $diff different${diffs:+ ($diffs)}"
fi
exit $fail
