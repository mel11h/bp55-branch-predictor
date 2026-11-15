/* ISS twin of link_wally.ld for iss/rvsim (memory from address 0, 64 MB). */
ENTRY(_start)
SECTIONS {
  . = 0;
  .text : { *(.text.init) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) }
  .data : { *(.data .data.*) __global_pointer$ = . + 0x800; *(.sdata .sdata.*) }
  .bss : { *(.sbss .sbss.*) *(.bss .bss.*) *(COMMON) }
  _end = .;
  /* After .bss, so that .data and .bss stay adjacent as in bench/rt/link.ld:
     bench/custom/interp.c reads below its static array `stack` (into libc's
     `rs` and `brk`), and its control flow depends on what lies there. */
  .tohost : { *(.tohost) }
  _stack_top = 0x3fffff0;
}
