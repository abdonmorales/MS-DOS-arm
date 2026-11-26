// SPDX-License-Identifier: MIT
// Flat AArch64 DTA: attributes:u64, size:u64, time:u16, date:u16,
// reserved:u32, ASCII filename[256]. Searches retain state per DTA (16 slots).
.section .text
search_init:
    address x0, default_dta
    address x1, current_dta
    str x0, [x1]
    address x0, current_dta_capacity
    mov x1, #280
    str x1, [x0]
    ret
dos_set_dta:
    cbz x0, dta_invalid
    cbz x1, dta_invalid
    address x2, current_dta
    str x0, [x2]
    address x2, current_dta_capacity
    str x1, [x2]
    mov x1, #0
    ret
dta_invalid:
    mov x0, #1
    mov x1, #1
    ret
dos_get_dta:
    address x0, current_dta
    ldr x0, [x0]
    mov x1, #0
    address x2, current_dta_capacity
    ldr x2, [x2]
    ret

dos_find_first:
    address x2, current_dta_capacity
    ldr x2, [x2]
    cmp x2, #280
    b.lo dta_invalid
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x20, x1
    address x1, canonical_buffer
    bl canonicalize_path
    cbnz x1, find_first_return
    mov x21, x0
    address x0, current_dta
    ldr x22, [x0]
    address x19, search_slots
    mov x9, #16
    mov x10, #0
1:
    ldr x0, [x19]
    cmp x0, x22
    b.eq find_slot_selected
    cbnz x0, 2f
    mov x10, x19
2:
    add x19, x19, #288
    subs x9, x9, #1
    b.ne 1b
    mov x19, x10
    cbz x19, find_slots_full
    b find_slot_install
find_slot_selected:
    ldr x0, [x19, #8]
    cbz x0, find_slot_install
    ldr x3, [x0, #16]
    blr x3
find_slot_install:
    str xzr, [x19]
    str xzr, [x19, #8]
    str x20, [x19, #16]
    address x0, active_owner
    ldr x0, [x0]
    str x0, [x19, #280]
    // Separate last component from the already normalized absolute parent.
    mov x9, x21
    mov x20, x21
1:
    ldrb w2, [x9], #1
    cbz w2, 2f
    cmp w2, #'\\'
    b.ne 1b
    sub x20, x9, #1
    b 1b
2:
    add x0, x20, #1
    ldrb w2, [x0]
    cbnz w2, 3f
    address x0, search_all
3:
    add x1, x19, #24
    bl copy_cstring
    cmp x20, x21
    b.ne 4f
    add x20, x20, #1
4:
    strb wzr, [x20]
    // canonicalize_path's source and destination must not overlap.
    mov x0, x21
    address x1, search_path
    bl copy_cstring
    address x0, search_path
    mov x1, #1
    mov x2, #0
    bl open_path_object
    cbnz x1, find_first_return
    str x0, [x19, #8]
    str x22, [x19]
    bl get_file_info
    cbnz x0, find_not_directory
    ldr x2, [x1, #72]
    tbz x2, #4, find_not_directory
    mov x0, x19
    bl search_next_slot
    b find_first_return
find_not_directory:
    mov x0, x19
    bl search_close_slot
    mov x0, #3
    mov x1, #1
    b find_first_return
find_slots_full:
    mov x0, #4
    mov x1, #1
find_first_return:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

dos_find_next:
    address x2, current_dta_capacity
    ldr x2, [x2]
    cmp x2, #280
    b.lo dta_invalid
    address x0, current_dta
    ldr x0, [x0]
    address x2, search_slots
    mov x3, #16
1:
    ldr x4, [x2]
    cmp x0, x4
    b.eq 2f
    add x2, x2, #288
    subs x3, x3, #1
    b.ne 1b
    mov x0, #18
    mov x1, #1
    ret
2:
    mov x0, x2
    b search_next_slot

search_next_slot:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    sub sp, sp, #16
    mov x19, x0
    ldr x20, [x19]
search_read_entry:
    ldr x0, [x19, #8]
    mov x1, #1024
    str x1, [sp]
    mov x1, sp
    address x2, file_info_buffer
    ldr x3, [x0, #32]
    blr x3
    cbnz x0, search_read_error
    ldr x0, [sp]
    cbz x0, search_exhausted
    address x21, file_info_buffer
    ldr x22, [x21, #72]
    mov x2, #0x16              // hidden/system/directory require selection
    and x2, x22, x2
    ldr x3, [x19, #16]
    bic x2, x2, x3
    cbnz x2, search_read_entry
    add x0, x21, #80
    address x1, search_name
    bl utf16_to_ascii
    cbnz x0, search_read_entry  // current ABI supports ASCII filenames
    add x0, x19, #24
    address x1, search_name
    bl wildcard_match
    cbz x0, search_read_entry
    str x22, [x20]
    ldr x2, [x21, #8]
    str x2, [x20, #8]
    add x0, x21, #56
    bl pack_efi_time
    strh w0, [x20, #18]
    strh w1, [x20, #16]
    str wzr, [x20, #20]
    address x0, search_name
    add x1, x20, #24
    bl copy_cstring
    mov x0, #0
    mov x1, #0
    b search_next_return
search_read_error:
    bl efi_error_to_dos
    mov x22, x0
    mov x0, x19
    bl search_close_slot
    mov x0, x22
    b search_next_error
search_exhausted:
    mov x0, x19
    bl search_close_slot
    mov x0, #18
search_next_error:
    mov x1, #1
search_next_return:
    add sp, sp, #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

search_close_slot:
    frame
    str x19, [sp, #-16]!
    mov x19, x0
    ldr x0, [x19, #8]
    cbz x0, 1f
    ldr x3, [x0, #16]
    blr x3
1:
    str xzr, [x19]
    str xzr, [x19, #8]
    ldr x19, [sp], #16
    unframe

search_release_owner:
    frame
    stp x19, x20, [sp, #-16]!
    address x19, search_slots
    mov x20, #16
1:
    ldr x0, [x19]
    cbz x0, 2f
    address x1, active_owner
    ldr x1, [x1]
    ldr x2, [x19, #280]
    cmp x1, x2
    b.ne 2f
    mov x0, x19
    bl search_close_slot
2:
    add x19, x19, #288
    subs x20, x20, #1
    b.ne 1b
    ldp x19, x20, [sp], #16
    unframe

utf16_to_ascii:
    mov x2, #0
1:
    ldrh w3, [x0], #2
    cmp w3, #127
    b.hi 2f
    strb w3, [x1, x2]
    cbz w3, 3f
    add x2, x2, #1
    cmp x2, #255
    b.lo 1b
2:
    mov x0, #1
    ret
3:
    mov x0, #0
    ret

// Case-insensitive glob with star backtracking. DOS *.* includes no extension.
wildcard_match:
    ldrb w2, [x0]
    cmp w2, #'*'
    b.ne wildcard_start
    ldrb w2, [x0, #1]
    cmp w2, #'.'
    b.ne wildcard_start
    ldrb w2, [x0, #2]
    cmp w2, #'*'
    b.ne wildcard_start
    ldrb w2, [x0, #3]
    cbnz w2, wildcard_start
    mov x0, #1
    ret
wildcard_start:
    mov x4, #0
    mov x5, #0
1:
    ldrb w2, [x0]
    ldrb w3, [x1]
    cmp w2, #'*'
    b.eq 4f
    cbz w3, 5f
    cmp w2, #'?'
    b.eq 3f
    cmp w2, #'a'
    b.lo 2f
    cmp w2, #'z'
    b.hi 2f
    sub w2, w2, #32
2:
    cmp w3, #'a'
    b.lo 6f
    cmp w3, #'z'
    b.hi 6f
    sub w3, w3, #32
6:
    cmp w2, w3
    b.ne 7f
3:
    add x0, x0, #1
    add x1, x1, #1
    b 1b
4:
    add x0, x0, #1
    mov x4, x0
    mov x5, x1
    b 1b
5:
    cbnz w2, 8f
    mov x0, #1
    ret
7:
    cbz x4, 8f
    add x5, x5, #1
    mov x1, x5
    mov x0, x4
    b 1b
8:
    mov x0, #0
    ret

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
.section .rodata
search_all: .asciz "*"
.section .bss
.balign 16
current_dta: .skip 8
current_dta_capacity: .skip 8
default_dta: .skip 280
search_slots: .skip 4608
search_name: .skip 256
search_path: .skip 256
