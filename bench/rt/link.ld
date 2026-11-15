ENTRY(_start)
SECTIONS {
  . = 0;
  .text : { *(.text.init) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) }
  .data : { *(.data .data.*) __global_pointer$ = . + 0x800; *(.sdata .sdata.*) }
  .bss : { *(.sbss .sbss.*) *(.bss .bss.*) *(COMMON) }
  _end = .;
  _stack_top = 0x3fffff0;
}
