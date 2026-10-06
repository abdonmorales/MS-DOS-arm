// SPDX-License-Identifier: MIT
// Native PE32+ AArch64 process ABI. Firmware performs verified image loading;
// children receive an ARMDOS64 descriptor via LoadedImage.LoadOptions.
.equ PROCESS_FRAME_SIZE, 704
.section .text
dos_exec:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    sub sp, sp, #PROCESS_FRAME_SIZE
    mov x26, sp
    mov x20, x1                 // stable caller-owned command tail
    mov x1, #0
    bl dos_open
    cbnz x1, exec_return
    mov x19, x0
    bl file_handle
    bl get_file_info
    cbnz x0, exec_close_bad_format
    ldr x21, [x1, #8]
    cmp x21, #512
    b.lo exec_close_bad_format
    mov x0, x21
    bl dos_allocate
    cbnz x1, exec_close_error
    mov x22, x0
    mov x23, #0
exec_read_image:
    mov x0, x19
    add x1, x22, x23
    sub x2, x21, x23
    bl dos_read
    cbnz x1, exec_free_close_error
    cbz x0, exec_free_close_bad_format
    add x23, x23, x0
    cmp x23, x21
    b.lo exec_read_image
    mov x0, x19
    bl dos_close
    cbnz x1, exec_free_bad_format
    // Reject x86 MZ/PE and malformed headers before firmware receives them.
    ldrh w2, [x22]
    mov w3, #0x5a4d
    cmp w2, w3
    b.ne exec_free_bad_format
    ldr w2, [x22, #60]
    add x3, x2, #26
    cmp x3, x21
    b.hi exec_free_bad_format
    add x2, x22, x2
    ldr w3, [x2]
    mov w4, #0x4550
    cmp w3, w4
    b.ne exec_free_bad_format
    ldrh w3, [x2, #4]
    mov w4, #0xaa64
    cmp w3, w4
    b.ne exec_free_bad_format
    ldrh w3, [x2, #24]
    cmp w3, #0x20b
    b.ne exec_free_bad_format
    mov x0, #0
    address x1, active_owner
    ldr x1, [x1]
    mov x2, #0
    mov x3, x22
    mov x4, x21
    add x5, x26, #32
    address x27, boot_services
    ldr x27, [x27]
    ldr x6, [x27, #200]         // LoadImage
    blr x6
    mov x23, x0
    mov x0, x22
    bl dos_free
    cbnz x23, exec_bad_format
    ldr x19, [x26, #32]
    mov x0, x19
    address x1, loaded_image_guid
    address x2, protocol_result
    ldr x3, [x27, #152]
    blr x3
    cbnz x0, exec_unload_bad_format
    address x0, protocol_result
    ldr x0, [x0]
    mov w1, #64
    str w1, [x0, #48]
    add x28, x26, #328
    str x28, [x0, #56]
    // All descriptor pointers are installed at runtime: no absolute fixups.
    address x1, process_signature
    ldr x1, [x1]
    str x1, [x28]
    mov x1, #1
    str x1, [x28, #8]
    mov x1, #64
    str x1, [x28, #16]
    address x1, dos_call
    str x1, [x28, #24]
    str x20, [x28, #32]
    address x1, process_environment
    str x1, [x28, #40]
    address x1, current_directory
    str x1, [x28, #48]
    str x19, [x28, #56]
    address x0, process_frames
    ldr x1, [x0]
    str x1, [x26]
    str x26, [x0]
    address x0, active_owner
    ldr x1, [x0]
    str x1, [x26, #8]
    str x19, [x0]
    address x0, current_dta
    ldr x1, [x0]
    str x1, [x26, #16]
    add x1, x26, #392
    str x1, [x0]
    address x0, current_dta_capacity
    ldr x1, [x0]
    str x1, [x26, #672]
    mov x1, #280
    str x1, [x0]
    address x0, process_exit_code
    ldr x1, [x0]
    str x1, [x26, #24]
    str xzr, [x0]
    address x0, handles
    add x1, x26, #40
    mov x2, #288
    bl copy_bytes
    str xzr, [x26, #680]
    str xzr, [x26, #688]
    mov x0, x19
    add x1, x26, #680
    add x2, x26, #688
    ldr x3, [x27, #208]         // StartImage
    blr x3
    mov x24, x0
    ldr x0, [x26, #688]
    cbz x0, 1f
    ldr x3, [x27, #72]          // optional firmware ExitData
    blr x3
1:
    bl arena_release_owner
    bl search_release_owner
    mov x25, #0
2:
    mov x0, x25
    bl dos_close
    add x25, x25, #1
    cmp x25, #32
    b.lo 2b
    add x0, x26, #40
    address x1, handles
    mov x2, #288
    bl copy_bytes
    address x0, active_owner
    ldr x1, [x26, #8]
    str x1, [x0]
    address x0, current_dta
    ldr x1, [x26, #16]
    str x1, [x0]
    address x0, current_dta_capacity
    ldr x1, [x26, #672]
    str x1, [x0]
    address x0, process_exit_code
    ldr x23, [x0]
    ldr x1, [x26, #24]
    str x1, [x0]
    address x0, process_frames
    ldr x1, [x26]
    str x1, [x0]
    address x0, last_exit_code
    // Returning EFI errors count as abnormal termination (DOS termination 2).
    cbz x24, 3f
    mov x23, #0x0201
3:
    str x23, [x0]
    mov x0, #0
    mov x1, #0
    b exec_return              // StartImage unloads applications on return/Exit
exec_free_close_error:
    mov x23, x0
    mov x0, x22
    bl dos_free
    mov x0, x19
    bl dos_close
    mov x0, x23
    mov x1, #1
    b exec_return
exec_free_close_bad_format:
    mov x0, x19
    bl dos_close
exec_free_bad_format:
    mov x0, x22
    bl dos_free
    b exec_bad_format
exec_close_bad_format:
    mov x0, x19
    bl dos_close
    b exec_bad_format
exec_close_error:
    mov x23, x0
    mov x0, x19
    bl dos_close
    mov x0, x23
    mov x1, #1
    b exec_return
exec_unload_bad_format:
    mov x0, x19
    ldr x3, [x27, #224]
    blr x3
exec_bad_format:
    mov x0, #11                // invalid executable format
    mov x1, #1
exec_return:
    add sp, sp, #PROCESS_FRAME_SIZE
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

dos_terminate:
    frame
    address x2, process_frames
    ldr x2, [x2]
    cbz x2, terminate_no_process
    and x0, x0, #255
    address x2, process_exit_code
    str x0, [x2]
    address x0, active_owner
    ldr x0, [x0]
    mov x1, #0
    mov x2, #0
    mov x3, #0
    address x4, boot_services
    ldr x4, [x4]
    ldr x4, [x4, #216]          // Exit unwinds only this child's StartImage
    blr x4
terminate_no_process:
    mov x0, #1
    mov x1, #1
    unframe
dos_get_exit_code:
    address x2, last_exit_code
    ldr x0, [x2]
    str xzr, [x2]
    mov x1, #0
    ret

// Parent snapshots keep EFI objects alive even if a child closes every copy.
parent_references_file:
    address x2, process_frames
    ldr x2, [x2]
1:
    cbz x2, 4f
    add x3, x2, #40
    mov x4, #0
2:
    ldr x5, [x3, x4, lsl #3]
    cmp x5, x0
    b.eq 3f
    add x4, x4, #1
    cmp x4, #32
    b.lo 2b
    ldr x2, [x2]
    b 1b
3:
    mov x1, #1
    ret
4:
    mov x1, #0
    ret
copy_bytes:
    cbz x2, 2f
1:
    ldrb w3, [x0], #1
    strb w3, [x1], #1
    subs x2, x2, #1
    b.ne 1b
2:
    ret
.section .rodata
process_signature: .ascii "ARMDOS64"
process_environment: .asciz "COMSPEC=A:\\EFI\\BOOT\\BOOTAA64.EFI"
    .asciz "PATH=A:\\"
    .byte 0
.section .bss
.balign 16
process_frames: .skip 8
process_exit_code: .skip 8
last_exit_code: .skip 8
