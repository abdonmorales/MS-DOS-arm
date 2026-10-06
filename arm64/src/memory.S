// SPDX-License-Identifier: MIT
// Owned firmware arenas. Reserve 64 KiB granules so native 4Ah can resize in
// place; an arena never moves behind a caller's pointer. Maximum request 16 MiB.
.section .text
memory_init:
    address x0, image_handle
    ldr x0, [x0]
    address x1, active_owner
    str x0, [x1]
    ret
dos_allocate:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    cbz x19, arena_no_memory
    mov x2, #0x1000000
    cmp x19, x2
    b.hi arena_no_memory
    address x20, arena_table
    mov x9, #64
1:
    ldr x2, [x20]
    cbz x2, 2f
    add x20, x20, #32
    subs x9, x9, #1
    b.ne 1b
    b arena_no_memory
2:
    mov x21, #65535
    add x21, x19, x21
    and x21, x21, #0xffffffffffff0000
    mov x1, x21
    mov x0, #2
    mov x2, x20
    address x3, boot_services
    ldr x3, [x3]
    ldr x3, [x3, #64]
    blr x3
    cbnz x0, arena_no_memory
    str x19, [x20, #8]
    str x21, [x20, #16]
    address x2, active_owner
    ldr x2, [x2]
    str x2, [x20, #24]
    ldr x0, [x20]
    mov x1, #0
    b arena_allocate_return
arena_no_memory:
    mov x0, #8
    mov x1, #1
    mov x2, #0x1000000
arena_allocate_return:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

arena_lookup:
    cbz x0, 3f
    address x2, arena_table
    mov x3, #64
    address x4, active_owner
    ldr x4, [x4]
1:
    ldr x5, [x2]
    cmp x5, x0
    b.ne 2f
    ldr x5, [x2, #24]
    cmp x4, x5
    b.eq 4f
    b 3f
2:
    add x2, x2, #32
    subs x3, x3, #1
    b.ne 1b
3:
    mov x2, #0
4:
    ret

dos_free:
    frame
    str x19, [sp, #-16]!
    bl arena_lookup
    cbz x2, arena_invalid
    mov x19, x2
    address x3, boot_services
    ldr x3, [x3]
    ldr x3, [x3, #72]
    blr x3
    cbnz x0, arena_invalid
    stp xzr, xzr, [x19]
    stp xzr, xzr, [x19, #16]
    mov x0, #0
    mov x1, #0
    b arena_free_return
arena_invalid:
    mov x0, #9
    mov x1, #1
arena_free_return:
    ldr x19, [sp], #16
    unframe

dos_resize:
    frame
    bl arena_lookup
    cbz x2, resize_arena_invalid
    cbz x1, resize_arena_invalid
    ldr x3, [x2, #16]
    cmp x1, x3
    b.hi resize_arena_full
    str x1, [x2, #8]
    mov x1, #0
    unframe
resize_arena_full:
    mov x2, x3
    mov x0, #8
    mov x1, #1
    unframe
resize_arena_invalid:
    mov x0, #9
    mov x1, #1
    unframe

// Release only the current process's allocations after StartImage returns.
arena_release_owner:
    frame
    stp x19, x20, [sp, #-16]!
    address x19, arena_table
    mov x20, #64
1:
    ldr x0, [x19]
    cbz x0, 2f
    address x1, active_owner
    ldr x1, [x1]
    ldr x2, [x19, #24]
    cmp x1, x2
    b.ne 2f
    bl dos_free
2:
    add x19, x19, #32
    subs x20, x20, #1
    b.ne 1b
    ldp x19, x20, [sp], #16
    unframe
.section .bss
.balign 16
active_owner: .skip 8
arena_table: .skip 2048
