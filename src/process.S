// SPDX-License-Identifier: MIT
// Native PE32+ AArch64 process ABI. The kernel loads and relocates images
// itself; a program's entry point receives x0 = ARMDOS64 process descriptor.
.equ PROCESS_FRAME_SIZE, 880    // +704: proc_call context, +816: saved state
.section .text

// 4Bh: x0 = path, x1 = command tail, x2 = mode.
//  0 load and execute.  1 load only: x0 = image base, x2 = entry, x3 = size
//  (the caller owns the block and frees it with 49h).  3 overlay: load at
//  x3 (4 KiB aligned) with x4 bytes available, relocated for that address;
//  returns the same registers as mode 1.
dos_exec_call:
    cbz x2, dos_exec
    cmp x2, #1
    b.eq 1f
    cmp x2, #3
    b.ne 2f
    mov x1, x3
    mov x2, x4
    tst x1, #0xfff
    b.ne 2f
    cbz x1, 2f
    b pe_load
1:
    mov x1, #0
    mov x2, #0
    b pe_load
2:
    mov x0, #1
    mov x1, #1
    ret

// x0 = path, x1 = destination (0 = allocate an owned block), x2 = capacity.
// Loads and relocates a native PE32+ image. Returns x0 = base, x2 = entry,
// x3 = image size, x1 = 0; or x1 = 1 with a DOS error in x0.
pe_load:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    sub sp, sp, #64
    mov x26, sp
    mov x27, x1                 // caller's destination
    mov x28, x2                 // and its capacity
    mov x1, #0
    bl dos_open
    cbnz x1, pe_return
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
    // Load the PE32+ image ourselves: sections, then DIR64 relocations.
    ldr w2, [x22, #60]
    add x2, x22, x2
    stp x2, xzr, [x26, #32]     // [32]=PE header, [40] reused below
    ldr w0, [x2, #80]           // SizeOfImage (optional header + 56)
    cmp x0, #0x1000
    b.lo exec_free_bad_format
    mov x1, #0x1000000
    cmp x0, x1
    b.hi exec_free_bad_format
    str x0, [x26, #24]          // image size
    cbz x27, 11f
    cmp x0, x28
    b.hi exec_free_too_big
    mov x23, x27                // overlay destination
    b 12f
11:
    bl dos_allocate
    cbnz x1, exec_free_error
    mov x23, x0                 // image base
12:
    ldr x1, [x26, #24]
    bl fat_zero_bytes
    ldr x2, [x26, #32]
    ldr w3, [x2, #84]           // SizeOfHeaders
    cmp x3, x21
    b.hi exec_unload_bad_format
    mov x0, x23
    mov x1, x22
    mov x2, x3
    bl fat_memcpy
    ldr x2, [x26, #32]
    ldrh w4, [x2, #6]           // NumberOfSections
    ldrh w5, [x2, #20]          // SizeOfOptionalHeader
    add x25, x2, #24
    add x25, x25, x5            // section table
    mov x24, x4
1:
    cbz x24, 2f
    ldr w0, [x25, #12]          // VirtualAddress
    ldr w1, [x25, #16]          // SizeOfRawData
    ldr w3, [x25, #20]          // PointerToRawData
    ldr w4, [x25, #8]           // VirtualSize
    cmp x1, x4
    csel x1, x1, x4, lo         // never copy past the section's size
    add x5, x3, x1
    cmp x5, x21
    b.hi exec_unload_bad_format
    add x5, x0, x1
    ldr x6, [x26, #24]
    cmp x5, x6
    b.hi exec_unload_bad_format
    mov x2, x1
    add x0, x23, x0
    add x1, x22, x3
    bl fat_memcpy
    add x25, x25, #40
    sub x24, x24, #1
    b 1b
2:
    ldr x2, [x26, #32]
    ldr x3, [x2, #48]           // ImageBase
    sub x24, x23, x3            // relocation delta
    ldr w4, [x2, #132]          // NumberOfRvaAndSizes (optional header + 108)
    cmp w4, #6
    b.lo 5f
    ldr w25, [x2, #176]         // base relocation directory RVA
    ldr w5, [x2, #180]          // and size
    cbz w5, 5f
    add x6, x25, x5
    ldr x7, [x26, #24]
    cmp x6, x7
    b.hi exec_unload_bad_format
    add x25, x23, x25
    add x6, x23, x6             // end of relocation data
3:
    add x7, x25, #8
    cmp x7, x6
    b.hi 5f
    ldr w8, [x25]               // page RVA
    ldr w9, [x25, #4]           // block size
    cmp w9, #8
    b.lo 5f
    add x10, x25, x9            // end of block
    cmp x10, x6
    b.hi exec_unload_bad_format
    add x11, x25, #8
4:
    cmp x11, x10
    b.hs 41f
    ldrh w12, [x11], #2
    lsr w13, w12, #12
    cbz w13, 4b                 // IMAGE_REL_BASED_ABSOLUTE (padding)
    cmp w13, #10                // IMAGE_REL_BASED_DIR64
    b.ne exec_unload_bad_format
    and w12, w12, #0xfff
    add x12, x12, x8
    add x13, x12, #8
    ldr x7, [x26, #24]
    cmp x13, x7
    b.hi exec_unload_bad_format
    add x12, x23, x12
    ldr x13, [x12]
    add x13, x13, x24
    str x13, [x12]
    b 4b
41:
    mov x25, x10
    b 3b
5:
    ldr x2, [x26, #32]
    ldr w25, [x2, #40]          // AddressOfEntryPoint
    ldr x7, [x26, #24]
    cmp x25, x7
    b.hs exec_unload_bad_format
    add x25, x23, x25
    mov x0, x23
    ldr x1, [x26, #24]
    bl plat_sync_code
    mov x0, x22
    bl dos_free
    mov x0, x23
    mov x2, x25
    ldr x3, [x26, #24]
    mov x1, #0
    b pe_return
exec_free_close_error:
    mov x23, x0
    mov x0, x22
    bl dos_free
    mov x0, x19
    bl dos_close
    mov x0, x23
    mov x1, #1
    b pe_return
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
    b pe_return
exec_unload_bad_format:
    cbnz x27, exec_free_bad_format   // never free the caller's overlay area
    mov x0, x23
    bl dos_free
    b exec_free_bad_format
exec_free_too_big:
    mov x0, x22
    bl dos_free
    mov x0, #8
    mov x1, #1
    b pe_return
exec_free_error:
    mov x23, x0
    mov x0, x22
    bl dos_free
    mov x0, x23
    mov x1, #1
    b pe_return
exec_bad_format:
    mov x0, #11                // invalid executable format
    mov x1, #1
pe_return:
    add sp, sp, #64
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// Frame: 0 parent frame, 8 parent owner, 16 parent DTA, 24 parent exit code,
// 40 parent handles+modes (288), 328 descriptor, 392 DTA, 672 DTA capacity,
// 704 context, 816 PSP override, 824 vectors 22h-24h, 848 TSR flag,
// 856 InDOS, 864 image base.
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
    mov x2, #0
    bl pe_load
    cbnz x1, exec_return
    mov x22, x0                 // loaded image
    mov x25, x2                 // entry point
    mov x19, x0                 // the image base is the process owner id
    str x0, [x26, #864]
    str xzr, [x26, #848]
    add x28, x26, #328
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
    address x1, env_block
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
    // Handles opened with the no-inherit bit (80h) stay with the parent.
    address x0, handles
    address x1, handle_modes
    mov x2, #0
4:
    ldrb w3, [x1, x2]
    tbz w3, #7, 5f
    str xzr, [x0, x2, lsl #3]
    strb wzr, [x1, x2]
5:
    add x2, x2, #1
    cmp x2, #32
    b.lo 4b
    // The PSP kept the terminate, Ctrl-C and critical-error vectors.
    address x0, dos_vectors
    ldr x1, [x0, #0x22 * 8]
    str x1, [x26, #824]
    ldr x1, [x0, #0x23 * 8]
    str x1, [x26, #832]
    ldr x1, [x0, #0x24 * 8]
    str x1, [x26, #840]
    address x0, dos_psp_override
    ldr x1, [x0]
    str x1, [x26, #816]
    str xzr, [x0]
    address x0, dos_sda
    ldrb w1, [x0, #SDA_INDOS]
    str x1, [x26, #856]
    strb wzr, [x0, #SDA_INDOS]  // the child runs outside DOS
    mov x0, x25
    mov x1, x28
    add x2, x26, #704
    bl proc_call
    mov x24, x0
    ldr x27, [x26, #848]        // 1 Ctrl-C, 3 stay resident
    cmp x27, #3
    b.eq 6f                     // 31h: the program and its memory stay
    bl arena_release_owner
6:
    mov x0, x19
    bl lock_release_owner
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
    address x0, dos_vectors
    ldr x1, [x26, #824]
    str x1, [x0, #0x22 * 8]
    ldr x1, [x26, #832]
    str x1, [x0, #0x23 * 8]
    ldr x1, [x26, #840]
    str x1, [x0, #0x24 * 8]
    address x0, dos_psp_override
    ldr x1, [x26, #816]
    str x1, [x0]
    address x0, dos_sda
    ldr x1, [x26, #856]
    strb w1, [x0, #SDA_INDOS]
    // Termination type in the high byte: 0 normal, 1 Ctrl-C, 2 CPU
    // exception or error return, 3 terminate and stay resident.
    and x23, x23, #255
    cmp x27, #3
    b.ne 7f
    orr x23, x23, #0x300
    b 3f
7:
    cmp x27, #1
    b.ne 8f
    mov x23, #0x0100
    b 3f
8:
    cbz x24, 3f
    mov x23, #0x0201
3:
    address x0, last_exit_code
    str x23, [x0]
    cmp x27, #3
    b.eq 9f
    mov x0, x22                 // unload the image (owned by the parent)
    bl dos_free
9:
    mov x0, #0
    mov x1, #0
    b exec_return
exec_return:
    add sp, sp, #PROCESS_FRAME_SIZE
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// 31h: x0 = exit code, x1 = bytes to keep (the whole image stays resident
// with every block the program allocated; open files are still closed).
dos_keep_process:
    frame
    address x2, process_frames
    ldr x2, [x2]
    cbz x2, terminate_no_process
    and x0, x0, #255
    address x3, process_exit_code
    str x0, [x3]
    mov x0, #3
    str x0, [x2, #848]
    mov x0, #0
    b proc_resume

dos_terminate:
    frame
    address x2, process_frames
    ldr x2, [x2]
    cbz x2, terminate_no_process
    and x0, x0, #255
    address x2, process_exit_code
    str x0, [x2]
    mov x0, #0
    b proc_resume               // unwind to this child's dos_exec
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

// x0 = entry, x1 = descriptor, x2 = 112-byte context. Calls the program;
// returns its x0, or the value given to proc_resume when it terminates early.
proc_call:
    stp x19, x20, [x2]
    stp x21, x22, [x2, #16]
    stp x23, x24, [x2, #32]
    stp x25, x26, [x2, #48]
    stp x27, x28, [x2, #64]
    stp x29, x30, [x2, #80]
    mov x3, sp
    str x3, [x2, #96]
    mov x19, x2                 // preserved by the callee (AAPCS64)
    mov x9, x0
    mov x0, x1
    mov x1, #0
    blr x9
    mov x2, x19
    b proc_restore

// x0 = value. Unwind the newest process to the end of its proc_call.
proc_resume:
    address x2, process_frames
    ldr x2, [x2]
    add x2, x2, #704
proc_restore:
    ldp x19, x20, [x2]
    ldp x21, x22, [x2, #16]
    ldp x23, x24, [x2, #32]
    ldp x25, x26, [x2, #48]
    ldp x27, x28, [x2, #64]
    ldp x29, x30, [x2, #80]
    ldr x3, [x2, #96]
    mov sp, x3
    ret

// CPU exception inside a program: terminate it abnormally.
proc_abort:
    mov x0, #1
    b proc_resume

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
