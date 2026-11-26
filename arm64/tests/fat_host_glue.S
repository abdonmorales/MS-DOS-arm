// SPDX-License-Identifier: MIT
// Links src/fat.S into a Linux AArch64 test program (run under qemu-aarch64).
// Supplies the few runtime symbols the driver uses from the rest of the kernel.
.macro frame
    stp x29, x30, [sp, #-16]!
    mov x29, sp
.endm
.macro unframe
    ldp x29, x30, [sp], #16
    ret
.endm
.macro address reg, name
    adrp \reg, \name
    add \reg, \reg, :lo12:\name
.endm
.global fat_mount, fat_unmount, root_directory
.section .text
// Fixed clock: 2026-11-25 12:34:56.
dos_get_date:
    mov x0, #2026
    mov x2, #11
    mov x3, #25
    mov x1, #0
    ret
dos_get_time:
    mov x0, #12
    mov x2, #34
    mov x3, #56
    mov x1, #0
    ret
puts:
    ret
// The host test always uses the Block I/O path (platform_native stays 0).
vio_rw:
    mov x0, #7
    orr x0, x0, #0x8000000000000000
    ret
// Copy of pack_efi_time from src/search.S (that file needs the whole kernel).
pack_efi_time:
    ldrh w2, [x0]
    sub w2, w2, #1980
    cmp w2, #127
    b.hi 1f
    ldrb w3, [x0, #2]
    ldrb w4, [x0, #3]
    lsl w2, w2, #9
    orr w2, w2, w3, lsl #5
    orr w2, w2, w4
    ldrb w3, [x0, #4]
    ldrb w4, [x0, #5]
    ldrb w5, [x0, #6]
    lsl w1, w3, #11
    orr w1, w1, w4, lsl #5
    lsr w5, w5, #1
    orr w1, w1, w5
    mov w0, w2
    ret
1:
    mov x0, #0
    mov x1, #0
    ret
.include "src/fat.S"
.section .rodata
.balign 8
.global file_info_guid, loaded_image_guid
file_info_guid:
    .long 0x09576e92
    .short 0x6d3f, 0x11d2
    .byte 0x8e,0x39,0x00,0xa0,0xc9,0x69,0x72,0x3b
loaded_image_guid:
    .long 0x5b1b31a1
    .short 0x9562, 0x11d2
    .byte 0x8e,0x3f,0x00,0xa0,0xc9,0x69,0x72,0x3b
.section .bss
.balign 8
.global boot_services, image_handle, protocol_result
boot_services: .skip 8
image_handle: .skip 8
protocol_result: .skip 8
root_directory: .skip 8
platform_native: .skip 8
