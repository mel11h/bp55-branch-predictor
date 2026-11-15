.section .text.init
.globl _start
_start:
  la gp, __global_pointer$
  la sp, _stack_top
  li a0, 0
  li a1, 0
  call main
  li a7, 93
  ecall
1: j 1b
