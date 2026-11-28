// SPDX-License-Identifier: MIT
// Bare-metal check of the framebuffer console's Raspberry Pi path on QEMU's
// raspi3b model, run by `make fb-test`: allocate a framebuffer through the
// VideoCore mailbox (fbcon_mailbox), start the console and draw text, then
// report on the PL011 so tools/fb_test.py can read the screen back. The
// MMU is off, so every access is Device memory: this also shows the console
// makes no unaligned framebuffer accesses.
.macro address reg, name
    adrp \reg, \name
    add \reg, \reg, :lo12:\name
.endm
.macro frame
    stp x29, x30, [sp, #-16]!
    mov x29, sp
.endm
.macro unframe
    ldp x29, x30, [sp], #16
    ret
.endm
.macro ldv reg, sym
    adrp \reg, \sym
    ldr \reg, [\reg, :lo12:\sym]
.endm
.macro enter
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
.endm
.macro leave
    ldp x19, x20, [sp, #16]
    ldp x21, x22, [sp, #32]
    ldp x23, x24, [sp, #48]
    ldp x25, x26, [sp, #64]
    ldp x27, x28, [sp, #80]
    ldp x29, x30, [sp], #96
    ret
.endm
.equ PL011, 0x3f201000

.section .text.boot
.global _start
_start:
    mrs x0, mpidr_el1
    and x0, x0, #3
    cbnz x0, halt
    mov x0, #0x80000
    mov sp, x0
    movz x1, #(PL011 & 0xffff)
    movk x1, #(PL011 >> 16), lsl #16
    str wzr, [x1, #0x30]
    mov w2, #0x70
    str w2, [x1, #0x2c]
    mov w2, #0x301
    str w2, [x1, #0x30]
    address x0, msg_start
    bl print
    movz x0, #0x3f00, lsl #16   // Pi 3 peripheral base
    bl fbcon_mailbox
    cbnz x0, 1f
    bl fbcon_setup
    address x0, screen_text
    bl fb_print
    address x0, msg_ready
    bl print
    b halt
1:
    address x0, msg_fail
    bl print
halt:
    wfe
    b halt

// x0 = string to the screen.
fb_print:
    stp x29, x30, [sp, #-32]!
    str x19, [sp, #16]
    mov x19, x0
1:
    ldrb w0, [x19], #1
    cbz w0, 2f
    bl fbcon_putc
    b 1b
2:
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// x0 = string to the PL011.
print:
    movz x1, #(PL011 & 0xffff)
    movk x1, #(PL011 >> 16), lsl #16
1:
    ldrb w2, [x0], #1
    cbz w2, 3f
2:
    ldr w3, [x1, #0x18]
    tbnz w3, #5, 2b
    str w2, [x1]
    b 1b
3:
    ret

// Symbols src/fbcon.S refers to for the kernel's UEFI and dispatch paths.
plat_putc_uart:
dos_call_invalid:
    ret

.section .rodata
msg_start: .asciz "FBTEST start\r\n"
msg_ready: .asciz "FBTEST READY\r\n"
msg_fail: .asciz "FBTEST FAIL mailbox\r\n"
// 30 numbered lines scroll the first ones away; then colours, a cursor
// move and an erase. tools/fb_test.py expects exactly this screen.
screen_text:
    .ascii "Line 01\r\nLine 02\r\nLine 03\r\nLine 04\r\nLine 05\r\nLine 06\r\n"
    .ascii "Line 07\r\nLine 08\r\nLine 09\r\nLine 10\r\nLine 11\r\nLine 12\r\n"
    .ascii "Line 13\r\nLine 14\r\nLine 15\r\nLine 16\r\nLine 17\r\nLine 18\r\n"
    .ascii "Line 19\r\nLine 20\r\nLine 21\r\nLine 22\r\nLine 23\r\nLine 24\r\n"
    .ascii "Line 25\r\nLine 26\r\nLine 27\r\nLine 28\r\nLine 29\r\nLine 30\r\n"
    .ascii "Pi mailbox \x1b[1;32mGREEN\x1b[0m \x1b[44;37mBLUE\x1b[0m\r\n"
    .ascii "erase me\x1b[5D\x1b[K\x1b[3;20Hmoved\x1b[24;1H"
    .asciz "Raspberry\tPi\x07 3"

.section .bss
.balign 16
boot_services: .skip 8
plat_uart: .skip 8

.section .text
mmu_map_normal_nc:              // the MMU is off here: nothing to map
    ret

.include "src/fbcon.S"
