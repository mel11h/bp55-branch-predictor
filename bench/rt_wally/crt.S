# Start-up code for the CORE-V Wally benchmark build (bench/build_wally.sh).
# Shared by both link variants: the Wally image (linked at 0x80000000) and its
# ISS twin (linked at 0, run on iss/rvsim for the instruction-count cross-check).
# Only io_wally.S / io_iss.S differ between the variants, and they are written
# so that both execute the same number of instructions.
.section .text.init
.globl _start
_start:
  .option push
  .option norelax      # gp itself must not be relaxed into a gp-relative address (RELAX=1 builds)
  la gp, __global_pointer$
  .option pop
  la sp, _stack_top
  li a0, 0
  li a1, 0
  call main
  j exit          # exit(main's return value), a0 is already the code
