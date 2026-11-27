/* Raw kernel8.img for QEMU raspi3b: loaded and entered at 0x80000. */
ENTRY(_start)
SECTIONS {
  . = 0x80000;
  .text : { *(.text.boot) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.*) }
  .data : { *(.data .data.*) }
  . = ALIGN(16);
  .bss (NOLOAD) : { *(.bss .bss.*) *(COMMON) }
  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
