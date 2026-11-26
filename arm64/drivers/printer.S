// SPDX-License-Identifier: MIT
// PRINTER.SYS [/AUX | /NUL] (v4.0/src/DEV/PRINTER): the printer device. The
// supported boards have no parallel port, so PRN goes to the serial line
// (/AUX, the default, the same UART as the console and AUX) or nowhere
// (/NUL, as without the driver). Code page switching for IBM printers has
// no printer to drive here.
.macro address reg, name
    adrp \reg, \name
    add \reg, \reg, :lo12:\name
.endm

.section .text
.global efi_main
// x0 = init request (ABI.md): +8 arguments, +72 the UART output.
efi_main:
    ldr x1, [x0, #72]
    cbz x1, 9f
    address x2, raw_putc
    str x1, [x2]
    ldr x1, [x0, #8]            // "/NUL" discards
    cbz x1, 3f
1:
    ldrb w2, [x1], #1
    cbz w2, 3f
    cmp w2, #'/'
    b.ne 1b
    ldrb w2, [x1]
    orr w2, w2, #0x20
    cmp w2, #'n'
    b.ne 1b
    address x2, discard
    mov x3, #1
    str x3, [x2]
3:
    address x1, device_name
    ldr x1, [x1]
    str x1, [x0, #16]
    str xzr, [x0, #24]          // reads: end of file
    address x1, prn_write
    str x1, [x0, #32]
    mov x1, #0xa0               // character device, output until busy
    str x1, [x0, #40]
    mov x1, #0
    ret
9:
    mov x1, #1
    ret

// x0 = buffer, x1 = count. Returns x0 = count.
prn_write:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov x19, x0
    mov x20, x1
    address x9, discard
    ldr x9, [x9]
    cbnz x9, 2f
    mov x21, #0
1:
    cmp x21, x20
    b.hs 2f
    ldrb w0, [x19, x21]
    address x9, raw_putc
    ldr x9, [x9]
    blr x9
    add x21, x21, #1
    b 1b
2:
    mov x0, x20
    ldp x19, x20, [sp, #16]
    ldr x21, [sp, #32]
    ldp x29, x30, [sp], #48
    ret

.section .rodata
.balign 8
device_name: .ascii "PRN\0\0\0\0\0"
.section .bss
.balign 8
raw_putc: .skip 8
discard: .skip 8
