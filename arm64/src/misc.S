// SPDX-License-Identifier: MIT
.section .text
dos_get_drive:
    mov x0, #0
    mov x1, #0
    ret
dos_set_drive:
    cbnz x0, 1f
    mov x0, #1                 // one configured drive, A:
    mov x1, #0
    ret
1:
    mov x0, #15
    mov x1, #1
    ret
dos_disk_reset:
    frame
    stp x19, x20, [sp, #-16]!
    address x19, handles
    mov x20, #0
1:
    ldr x0, [x19, x20, lsl #3]
    cbz x0, 2f
    address x3, handle_modes    // firmware refuses to flush read-only opens,
    ldrb w3, [x3, x20]          // and they hold nothing to write back
    tst w3, #3                  // access bits only (bit 7 is no-inherit)
    b.eq 2f
    ldr x3, [x0, #80]
    blr x3
    cbnz x0, 3f
2:
    add x20, x20, #1
    cmp x20, #32
    b.lo 1b
    mov x0, #0
    mov x1, #0
    b 4f
3:
    bl efi_error_to_dos
    mov x1, #1
4:
    ldp x19, x20, [sp], #16
    unframe
dos_free_space:
    frame
    sub sp, sp, #16
    cmp x0, #1                 // 0=default, 1=A:
    b.hi free_space_drive_error
    address x0, root_directory
    ldr x0, [x0]
    cbz x0, free_space_drive_error
    mov x2, #1024
    str x2, [sp]
    mov x2, sp
    address x1, file_system_info_guid
    address x3, file_info_buffer
    ldr x4, [x0, #64]
    blr x4
    cbnz x0, free_space_efi_error
    address x4, file_info_buffer
    ldr w0, [x4, #32]          // bytes per firmware allocation unit
    cbz x0, free_space_drive_error
    ldr x2, [x4, #24]
    ldr x3, [x4, #16]
    udiv x2, x2, x0
    udiv x3, x3, x0
    mov x1, #0
    b free_space_return
free_space_drive_error:
    mov x0, #15
    mov x1, #1
    b free_space_return
free_space_efi_error:
    bl efi_error_to_dos
    mov x1, #1
free_space_return:
    add sp, sp, #16
    unframe

dos_file_time:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x20, x1
    mov x21, x2
    mov x22, x3
    cmp x20, #1
    b.hi file_time_invalid
    bl file_handle
    cbz x0, file_time_bad_handle
    mov x19, x0
    bl get_file_info
    cbnz x0, file_time_efi_error
    cbnz x20, file_time_set
    add x0, x1, #56
    bl pack_efi_time
    mov x2, x0
    mov x3, x1
    mov x0, #0
    mov x1, #0
    b file_time_return
file_time_set:
    ubfx x0, x21, #9, #7
    add x0, x0, #1980
    ubfx x1, x21, #5, #4
    and x2, x21, #31
    bl validate_date
    cbnz x0, file_time_invalid
    ubfx x0, x22, #11, #5
    cmp x0, #23
    b.hi file_time_invalid
    ubfx x0, x22, #5, #6
    cmp x0, #59
    b.hi file_time_invalid
    and x0, x22, #31
    cmp x0, #29
    b.hi file_time_invalid
    address x3, file_info_buffer
    ubfx x0, x21, #9, #7
    add x0, x0, #1980
    strh w0, [x3, #56]
    ubfx x0, x21, #5, #4
    strb w0, [x3, #58]
    and x0, x21, #31
    strb w0, [x3, #59]
    ubfx x0, x22, #11, #5
    strb w0, [x3, #60]
    ubfx x0, x22, #5, #6
    strb w0, [x3, #61]
    and x0, x22, #31
    lsl x0, x0, #1
    strb w0, [x3, #62]
    str wzr, [x3, #64]
    ldr x2, [x3]
    address x1, file_info_guid
    mov x0, x19
    ldr x4, [x0, #72]
    blr x4
    cbnz x0, file_time_efi_error
    mov x1, #0
    b file_time_return
file_time_bad_handle:
    mov x0, #6
    b file_time_error
file_time_invalid:
    mov x0, #1
    b file_time_error
file_time_efi_error:
    bl efi_error_to_dos
file_time_error:
    mov x1, #1
file_time_return:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

dos_create_new:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x1, #1
    mov x2, #0
    bl open_path_object
    cbnz x1, 1f
    ldr x3, [x0, #16]
    blr x3
    mov x0, #80
    mov x1, #1
    b create_new_return
1:
    cmp x0, #2
    b.ne create_new_return
    mov x0, x19
    mov x1, x20
    bl dos_create
create_new_return:
    ldp x19, x20, [sp], #16
    unframe
.section .rodata
.balign 8
file_system_info_guid:
    .long 0x09576e93
    .short 0x6d3f, 0x11d2
    .byte 0x8e,0x39,0x00,0xa0,0xc9,0x69,0x72,0x3b
