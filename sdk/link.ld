/* SPDX-License-Identifier: MIT */
/*
 * ARM DOS C programs. Linked at RVA 0x1000 with image base 0 (the same
 * layout as the assembly programs' link.ld) and with --emit-relocs, so that
 * tools/elf2pe.py can turn every remaining absolute pointer (R_AARCH64_ABS64)
 * into a PE IMAGE_REL_BASED_DIR64 fixup for the kernel's loader. Code uses
 * ADRP/ADD, which only needs the 64 KiB-aligned load to keep page offsets.
 */
ENTRY(_start)
PHDRS {
  code PT_LOAD FLAGS(5);
  data PT_LOAD FLAGS(6);
}
SECTIONS {
  . = 0x1000;
  .text : { *(.text.start) *(.text .text.*) } :code
  . = ALIGN(16);
  .rodata : { *(.rodata .rodata.*) } :code
  . = ALIGN(4096);
  __data_start = .;
  .data : { *(.data .data.*) *(.data.rel.ro .data.rel.ro.*) *(.got .got.plt) } :data
  __file_end = .;
  . = ALIGN(16);
  __bss_start = .;
  .bss (NOLOAD) : { *(.bss .bss.*) *(COMMON) . = ALIGN(16); } :data
  __bss_end = .;
  __image_end = .;
  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.interp) *(.dynamic) }
}
