/* ISS twin of link_wally.ld for the RELAX=1 build: a jump to _start at 0 (stub_iss.S), the
   program at 0x10000 so that linker relaxation treats it as it treats the 0x80000000 image. */
ENTRY(_start)
SECTIONS {
  . = 0;
  .stub : { *(.text.stub) }
  . = 0x10000;
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
