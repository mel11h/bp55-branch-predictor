# RELAX=1 ISS twin only (bench/build_wally.sh): rvsim starts at address 0, the relaxed twin
# is linked at 0x10000 (link_iss_relax.ld). One jump, counted by rvsim but not by Wally.
.section .text.stub, "ax"
.globl _iss_stub
_iss_stub:
  j _start
