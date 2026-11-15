# Console and exit for CORE-V Wally's testbench (no ecall, no trap handler).
# The testbench watches stores to the symbol "tohost" (HTIF convention):
#   - upper word (tohost+4) = 0x01010000, then a store of the character to tohost
#     prints the character (HTIF device 1, command 1: console putchar);
#   - any other store word to tohost ends the test with result (code << 1) | 1,
#     where 1 means pass.
# Instruction counts are matched one for one by io_iss.S:
#   putchar 6 instructions, exit 6 instructions up to and including the
#   reporting store.
.section .text
.globl putchar
putchar:                    # int putchar(int c): returns c in a0
  la   t0, tohost           # 2 (auipc + addi)
  lui  t1, 0x1010           # 1 (0x01010000: device 1, command 1)
  sw   t1, 4(t0)            # 1
  sw   a0, 0(t0)            # 1
  ret                       # 1

.globl exit
exit:                       # void exit(int code)
  la   t0, tohost           # 2
  sw   zero, 4(t0)          # 1 clear the upper word left by putchar
  slli a0, a0, 1            # 1
  ori  a0, a0, 1            # 1
  sw   a0, 0(t0)            # 1 the testbench ends the test here
1: j 1b

.section .tohost, "aw", @progbits
.balign 64
.globl tohost
tohost:   .dword 0
.globl fromhost
fromhost: .dword 0
