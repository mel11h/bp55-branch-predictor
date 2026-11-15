#!/bin/bash
# Build all benchmarks for RV32IM and produce branch traces.
set -u
B=/home/user/bp55/bench; O=$B/build; T=/home/user/bp55/traces
CC="clang --target=riscv32-unknown-elf -march=rv32im -mabi=ilp32 -O2 -ffreestanding -fno-builtin -nostdinc -isystem $B/rt/include -isystem /usr/lib/llvm-18/lib/clang/18/include -mno-relax -w"
MAXI=${MAXI:-60000000}
link() { # name objs...
  n=$1; shift
  ld.lld -T $B/rt/link.ld -o $O/$n.elf "$@" 2> $O/$n.linkerr || { echo "LINKFAIL $n: $(head -2 $O/$n.linkerr | tr '\n' ' ')"; return 1; }
  llvm-objcopy -O binary $O/$n.elf $O/$n.bin
  /home/user/bp55/iss/rvsim $O/$n.bin $T/$n.trc $MAXI 2>&1 | tail -1 | sed "s/^/$n: /"
}
$CC -c $B/rt/crt.S -o $O/crt.o; $CC -c $B/rt/libc.c -o $O/libc.o; $CC -c $B/rt/board.c -o $O/board.o
# CoreMark
objs=""
for f in $B/coremark/core_*.c $B/cm_port/core_portme.c; do o=$O/cm_$(basename $f .c).o; $CC -I$B/coremark -I$B/cm_port -DITERATIONS=${CM_IT:-40} -DPERFORMANCE_RUN=1 -DFLAGS_STR=\"O2\" -c $f -o $o || exit 1; objs="$objs $o"; done
link coremark $O/crt.o $objs $O/libc.o
# Embench
E=$B/embench-iot
$CC -I$E/support -c $E/support/beebsc.c -o $O/beebsc.o; $CC -I$E/support -DWARMUP_HEAT=0 -c $E/support/main.c -o $O/emain.o
for d in $E/src/*/; do n=$(basename $d); objs=""; ok=1
  for f in $d*.c; do o=$O/${n}_$(basename $f .c).o; $CC -I$E/support -I$d -DGLOBAL_SCALE_FACTOR=${GSF:-1} -DWARMUP_HEAT=0 -c $f -o $o 2>$O/$n.cerr || { echo "CCFAIL $n"; ok=0; }; objs="$objs $o"; done
  [ $ok = 1 ] && link $n $O/crt.o $O/emain.o $objs $O/beebsc.o $O/board.o $O/libc.o
done
for n in interp recurse; do $CC -c $B/custom/$n.c -o $O/$n.o && link $n $O/crt.o $O/$n.o $O/libc.o; done
