// SPDX-License-Identifier: MIT
// TESTDRV.SYS: a minimal installable character device used by the tests.
// DEVICE=\TESTDRV.SYS installs UPPER$: text written to it is kept and read
// back in upper case. Shows the native driver interface in ABI.md.
.macro address reg, name
    adrp \reg, \name
    add \reg, \reg, :lo12:\name
.endm
.section .text
.global efi_main
// x0 = init request: +0 dos_call, +8 arguments, +16 name (out, 8 bytes),
// +24 read function, +32 write function, +40 attribute word.
efi_main:
    address x1, device_name
    ldr x1, [x1]
    str x1, [x0, #16]
    address x1, upper_read
    str x1, [x0, #24]
    address x1, upper_write
    str x1, [x0, #32]
    mov x1, #0xc0
    str x1, [x0, #40]
    mov x1, #0
    ret

// x0 = buffer, x1 = count. Returns x0 = bytes stored.
// Writes append until everything written has been read back.
upper_write:
    address x2, stored
    address x3, stored_length
    ldr x6, [x3]
    mov x4, #0
1:
    cmp x4, x1
    b.hs 3f
    cmp x6, #256
    b.hs 3f
    ldrb w5, [x0, x4]
    cmp w5, #'a'
    b.lo 2f
    cmp w5, #'z'
    b.hi 2f
    sub w5, w5, #32
2:
    strb w5, [x2, x6]
    add x4, x4, #1
    add x6, x6, #1
    b 1b
3:
    str x6, [x3]
    mov x0, x1
    ret

// x0 = buffer, x1 = count. Returns x0 = bytes read (0 at the end).
upper_read:
    address x2, stored
    address x3, stored_length
    ldr x3, [x3]
    address x6, read_position
    ldr x4, [x6]
    mov x5, #0
1:
    cmp x5, x1
    b.hs 2f
    cmp x4, x3
    b.hs 2f
    ldrb w7, [x2, x4]
    strb w7, [x0, x5]
    add x4, x4, #1
    add x5, x5, #1
    b 1b
2:
    str x4, [x6]
    cbnz x5, 3f
    str xzr, [x6]               // all read: start over
    address x3, stored_length
    str xzr, [x3]
3:
    mov x0, x5
    ret

.section .rodata
.balign 8
device_name: .ascii "UPPER$\0\0"
.section .bss
.balign 8
stored_length: .skip 8
read_position: .skip 8
stored: .skip 256
