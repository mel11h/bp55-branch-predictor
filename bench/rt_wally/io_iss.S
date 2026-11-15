# ISS twin of io_wally.S for iss/rvsim (ecall 64 = putchar, ecall 93 = exit).
# Padded with nops so that every routine executes exactly as many instructions
# as its io_wally.S counterpart; rvsim counts the final ecall, Wally counts the
# reporting store, so whole-program counts must agree exactly.
.section .text
.globl putchar
putchar:
  li   a7, 64               # 1
  ecall                     # 1
  nop                       # 1
  nop                       # 1
  nop                       # 1
  ret                       # 1

.globl exit
exit:
  nop                       # 1
  nop                       # 1
  nop                       # 1
  nop                       # 1
  li   a7, 93               # 1
  ecall                     # 1 rvsim stops here
1: j 1b

# Same section and size as in io_wally.S, so both variants have the same layout.
.section .tohost, "aw", @progbits
.balign 64
.globl tohost
tohost:   .dword 0
.globl fromhost
fromhost: .dword 0
