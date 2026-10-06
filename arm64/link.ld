/* Position-independent UEFI application, with RVA 0x1000. */
ENTRY(efi_main)
PHDRS {
  code PT_LOAD FLAGS(5);
  data PT_LOAD FLAGS(6);
}
SECTIONS {
  . = 0x1000;
  .text : { *(.text .text.*) } :code
  . = ALIGN(16);
  .rodata : { *(.rodata .rodata.*) } :code
  . = ALIGN(4096);
  __data_start = .;
  .data : { QUAD(0); *(.data .data.*) } :data
  __file_end = .;
  . = ALIGN(16);
  .bss (NOLOAD) : { *(.bss .bss.*) *(COMMON) } :data
  __image_end = .;
  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
