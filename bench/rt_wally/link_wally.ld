/* CORE-V Wally image: RAM at 0x80000000 (RESET_VECTOR), 128 MB in rv32gc.
   Layout identical to link_iss.ld except for the base address and stack top,
   which keep the same offset from the base (64 MB - 16, as bench/rt/link.ld). */
ENTRY(_start)
SECTIONS {
  . = 0x80000000;
  .text : { *(.text.init) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) }
  .data : { *(.data .data.*) __global_pointer$ = . + 0x800; *(.sdata .sdata.*) }
  .bss : { *(.sbss .sbss.*) *(.bss .bss.*) *(COMMON) }
  _end = .;
  /* After .bss, so that .data and .bss stay adjacent as in bench/rt/link.ld:
     bench/custom/interp.c reads below its static array `stack` (into libc's
     `rs` and `brk`), and its control flow depends on what lies there. */
  .tohost : { *(.tohost) }
  _stack_top = 0x83fffff0;
}
