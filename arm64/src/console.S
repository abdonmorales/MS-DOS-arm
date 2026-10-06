// SPDX-License-Identifier: MIT
.section .text
dos_console_input:
    frame
    str x19, [sp, #-16]!
    bl read_key
    mov x19, x0
    bl stdout_putc
    mov x0, x19
    mov x1, #0
    ldr x19, [sp], #16
    unframe
dos_console_noecho:
    frame
    bl read_key
    mov x1, #0
    unframe
dos_console_direct:
    cmp x0, #255
    b.ne dos_console_out
    frame
    address x0, handles
    ldr x0, [x0]
    cbz x0, direct_console_poll
    mov x0, #0
    mov x1, #6
    bl dos_ioctl
    cbz x0, 1f
    bl read_key
    mov x2, #0
    b 2f
direct_console_poll:
    bl poll_key
    cbz x0, 1f
    address x2, pending_key
    str xzr, [x2]
    mov x2, #0                 // native replacement for DOS ZF=0
    b 2f
1:
    mov x2, #1                 // ZF=1: no key available
2:
    mov x1, #0
    unframe
dos_console_status:
    frame
    address x0, handles
    ldr x0, [x0]
    cbz x0, console_status_poll
    mov x0, #0
    mov x1, #6
    bl dos_ioctl
    unframe
console_status_poll:
    bl poll_key
    cmp x0, #0
    mov x2, #255
    csel x0, x2, xzr, ne
    mov x1, #0
    unframe
dos_console_buffer:
    frame
    str x19, [sp, #-16]!
    mov x19, x0
    ldrb w1, [x19]
    cbz w1, 1f
    sub x1, x1, #1
    add x0, x19, #2
    bl read_line
    strb w0, [x19, #1]
    add x2, x19, #2
    mov w3, #13
    strb w3, [x2, x0]
    b 2f
1:
    strb wzr, [x19, #1]
    mov x0, #0
2:
    mov x1, #0
    ldr x19, [sp], #16
    unframe
dos_console_flush:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    address x0, pending_key
    str xzr, [x0]
    address x0, system_table
    ldr x0, [x0]
    ldr x0, [x0, #48]
    ldr x3, [x0]
    mov x1, #0
    blr x3
    mov w8, w19
    mov x0, x20
    cmp w8, #1
    b.eq 1f
    cmp w8, #6
    b.eq 1f
    cmp w8, #7
    b.eq 1f
    cmp w8, #8
    b.eq 1f
    cmp w8, #10
    b.eq 1f
    mov x0, #0
    mov x1, #0
    b 2f
1:
    bl dos_call
2:
    ldp x19, x20, [sp], #16
    unframe

// Polling retains a character, so status queries never consume user input.
poll_key:
    frame
    sub sp, sp, #16
    address x0, pending_key
    ldr x0, [x0]
    cbnz x0, 2f
1:
    address x0, system_table
    ldr x0, [x0]
    ldr x0, [x0, #48]
    mov x1, sp
    ldr x3, [x0, #8]
    blr x3
    cbnz x0, 3f
    ldrh w0, [sp, #2]
    cbz w0, 1b                 // scan-only keys unsupported by ASCII ABI
    address x2, pending_key
    str x0, [x2]
2:
    add sp, sp, #16
    unframe
3:
    mov x0, #0
    b 2b

read_console_handle:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x1
    mov x20, x2
    cbz x20, 3f
    address x0, stdin_buffer
    mov x1, #253
    cmp x20, x1
    csel x1, x20, x1, lo
    bl read_line
    cbnz x2, 3f
    mov x21, x0
    address x0, stdin_buffer
    ldrb w2, [x0]
    cmp w2, #26                // DOS text EOF
    b.eq 3f
    cmp x21, x20
    b.hs 1f
    mov w2, #13
    strb w2, [x0, x21]
    add x21, x21, #1
    cmp x21, x20
    b.hs 1f
    mov w2, #10
    strb w2, [x0, x21]
    add x21, x21, #1
1:
    mov x1, x19
    mov x2, x21
    bl copy_bytes
    mov x0, x21
    b 4f
3:
    mov x0, #0
4:
    mov x1, #0
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe
.section .bss
.balign 16
pending_key: .skip 8
stdin_buffer: .skip 256
