#!/bin/bash
# CoreMark self-check. The traced build (build.sh) uses a port whose ee_printf is
# a no-op and whose main() always returns 0, so its exit=0 says nothing about
# correctness. This builds the same sources with a printing ee_printf
# (cm_check/core_portme_check.c) and checks CoreMark's own CRC verdict.
set -u
R=${BP55_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
B=$R/bench; O=$B/build/cm_check; mkdir -p "$O"
CLANG_INC=${BP55_CLANG_INC:-$(clang -print-resource-dir)/include}
CC="clang --target=riscv32-unknown-elf -march=rv32im -mabi=ilp32 -O2 -ffreestanding -fno-builtin -nostdinc -isystem $B/rt/include -isystem $CLANG_INC -mno-relax -w"
objs=""
$CC -c $B/rt/crt.S -o $O/crt.o; $CC -c $B/rt/libc.c -o $O/libc.o
for f in $B/coremark/core_*.c $B/cm_check/core_portme_check.c; do o=$O/$(basename $f .c).o
  $CC -I$B/coremark -I$B/cm_port -DITERATIONS=${CM_IT:-40} -DPERFORMANCE_RUN=1 -DFLAGS_STR=\"O2\" -c $f -o $o || exit 1; objs="$objs $o"; done
ld.lld -T $B/rt/link.ld -o $O/coremark_check.elf $O/crt.o $objs $O/libc.o || exit 1
llvm-objcopy -O binary $O/coremark_check.elf $O/coremark_check.bin
out=$("$R/iss/rvsim" $O/coremark_check.bin /dev/null ${MAXI:-60000000} 2>&1)
# There is no timer (get_time() returns 0), so CoreMark always adds one error for
# "Must execute for at least 10 secs". That one is expected and ignored; any CRC
# or datatype error, or an unrecognised seed set, fails the check.
echo "$out" | grep -E 'run parameters|ERROR|Errors detected|Cannot validate|exit='
if echo "$out" | grep -q 'performance run parameters' && ! echo "$out" | grep -E 'ERROR! (list|matrix|state) crc|ERROR: |Cannot validate' >/dev/null; then
  echo "coremark: self-check PASS (CRCs match the 2K performance-run reference; timing error expected)"; exit 0
fi
echo "coremark: self-check FAIL"; exit 1
