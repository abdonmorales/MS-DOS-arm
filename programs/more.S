// SPDX-License-Identifier: MIT
// MORE < file, or command | MORE: shows standard input a screen at a time
// (MS-DOS 4.0 src/CMD/MORE). After 24 lines it prints "-- More --" and waits for a
// key from the console (handle 2, switched to raw mode), as DOS did.
.include "lib.inc"
.equ SCREEN_LINES, 24
.equ SCREEN_COLUMNS, 80

main:
    enter
    mov x19, #0                 // lines on screen
    mov x20, #0                 // column
1:
    mov x0, #0
    address x1, buffer
    mov x2, #512
    bl fread
    cbnz x1, 9f
    cbz x0, 9f
    mov x21, x0
    mov x22, #0
2:
    cmp x22, x21
    b.hs 1b
    address x1, buffer
    ldrb w23, [x1, x22]
    add x22, x22, #1
    cmp w23, #0x1a
    b.eq 9f
    mov x0, x23
    bl putc
    cmp w23, #10
    b.eq 3f
    cmp w23, #13
    b.eq 21f
    cmp w23, #9
    b.ne 22f
    orr x20, x20, #7            // tab to the next multiple of 8
22:
    add x20, x20, #1
    cmp x20, #SCREEN_COLUMNS
    b.lo 2b
3:
    mov x20, #0
    add x19, x19, #1
    cmp x19, #SCREEN_LINES
    b.lo 2b
    bl more_prompt
    mov x19, #0
    b 2b
21:
    mov x20, #0
    b 2b
9:
    mov x0, #0
    leave

// "-- More --", then one key read from the console in raw mode.
more_prompt:
    enter
    address x0, prompt
    mov x2, #11
    mov x1, x0
    mov x0, #2
    dos 0x40
    mov x0, #2
    mov x1, #0
    dos 0x44                    // device information of handle 2
    mov x19, x0
    orr x2, x19, #0x20
    and x2, x2, #0xff
    mov x0, #2
    mov x1, #1
    dos 0x44                    // raw: one key, no line editing
    mov x0, #2
    address x1, key
    mov x2, #1
    dos 0x3f
    mov x0, #2
    mov x1, #1
    bic x2, x19, #0x20
    dos 0x44
    address x0, erase
    mov x2, #13
    mov x1, x0
    mov x0, #2
    dos 0x40
    leave

.section .rodata
prompt: .ascii "-- More -- "
erase: .ascii "\r           \r"
.section .bss
.balign 8
key: .skip 8
buffer: .skip 512
