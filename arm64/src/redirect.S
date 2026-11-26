// SPDX-License-Identifier: MIT
// Scoped <, > and >> redirection. Restore the parent descriptors on every
// return path, including nested batch execution and program termination.
.section .text
redirect_begin:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    str xzr, [x20, #40]
    address x0, handles
    ldp x1, x2, [x0]
    stp x1, x2, [x20, #8]
    ldr x1, [x0, #16]
    str x1, [x20, #24]
    address x0, handle_modes
    ldrh w1, [x0]
    strh w1, [x20, #32]
    ldrb w1, [x0, #2]
    strb w1, [x20, #34]
redirect_scan_start:
    mov x21, x19
    mov x22, #0
redirect_scan:
    ldrb w2, [x21]
    cbz w2, redirect_success
    cmp w2, #'"'
    b.ne 1f
    eor x22, x22, #1
    b redirect_advance
1:
    cbnz x22, redirect_advance
    cmp w2, #'|'
    b.eq redirect_invalid
    cmp w2, #'&'
    b.eq redirect_invalid
    mov x23, #0
    cmp w2, #'<'
    b.eq redirect_found
    mov x23, #1
    cmp w2, #'>'
    b.eq redirect_found
redirect_advance:
    add x21, x21, #1
    b redirect_scan
redirect_found:
    ldr x0, [x20, #40]
    cmp x0, #8
    b.hs redirect_invalid
    add x0, x21, #1
    cbz x23, 1f
    ldrb w2, [x0]
    cmp w2, #'>'
    b.ne 1f
    mov x23, #2
    add x0, x0, #1
1:
    bl next_word
    mov x24, x1                 // remaining command tail
    ldrb w2, [x0]
    cbz w2, redirect_invalid
    cbz x23, redirect_input
    cmp x23, #2
    b.eq redirect_append
    mov x1, #0
    bl dos_create
    b redirect_install
redirect_append:
    mov x22, x0
    mov x1, #1
    bl dos_open
    cbz x1, redirect_append_seek
    cmp x0, #2
    b.ne redirect_return
    mov x0, x22
    mov x1, #0
    bl dos_create
    cbnz x1, redirect_return
redirect_append_seek:
    cbnz x1, redirect_return
    mov x22, x0
    mov x1, #0
    mov x2, #2
    bl dos_seek
    cbz x1, 1f
    mov x0, x22
    bl dos_close
    b redirect_invalid
1:
    mov x0, x22
    b redirect_install
redirect_input:
    mov x1, #0
    bl dos_open
redirect_install:
    cbnz x1, redirect_return
    ldr x2, [x20, #40]
    add x3, x20, #48
    str x0, [x3, x2, lsl #3]
    add x2, x2, #1
    str x2, [x20, #40]
    // Keep the open handle as the owning reference until redirect_end.
    address x3, handles
    ldr x4, [x3, x0, lsl #3]
    cmp x23, #0
    cset x23, ne                // standard input 0 or output 1
    str x4, [x3, x23, lsl #3]
    address x3, handle_modes
    ldrb w4, [x3, x0]
    strb w4, [x3, x23]
    // Remove operator and filename, preserving arguments after redirection.
    mov x0, x24
    mov x1, x21
    bl copy_cstring
    b redirect_scan_start
redirect_invalid:
    mov x0, #1
    mov x1, #1
    b redirect_return
redirect_success:
    mov x0, #0
    mov x1, #0
redirect_return:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

redirect_end:
    frame
    stp x19, x20, [sp, #-16]!
    str x21, [sp, #-16]!
    mov x19, x0
    address x0, handles
    ldp x1, x2, [x19, #8]
    stp x1, x2, [x0]
    ldr x1, [x19, #24]
    str x1, [x0, #16]
    address x0, handle_modes
    ldrh w1, [x19, #32]
    strh w1, [x0]
    ldrb w1, [x19, #34]
    strb w1, [x0, #2]
    mov x20, #0
    ldr x21, [x19, #40]
1:
    cmp x20, x21
    b.hs 2f
    add x2, x19, #48
    ldr x0, [x2, x20, lsl #3]
    bl dos_close
    add x20, x20, #1
    b 1b
2:
    ldr x21, [sp], #16
    ldp x19, x20, [sp], #16
    unframe
