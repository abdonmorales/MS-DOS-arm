// SPDX-License-Identifier: MIT
// SORT [/R] [/+n] < input > output (MS-DOS 4.0 src/CMD/SORT): sorts the lines of
// standard input, ignoring case as the DOS collating table does, starting
// at column n; /R reverses the order. Holds up to 63 KiB, as DOS did.
.include "lib.inc"
.equ TEXT_SIZE, 64512
.equ MAX_LINES, 8192

main:
    enter
    mov x19, x0
    mov x20, #0                 // reverse
    mov x21, #0                 // column offset (0-based)
1:
    mov x0, x19
    bl next_arg
    mov x19, x1
    ldrb w2, [x0]
    cbz w2, 3f
    cmp w2, #'/'
    b.ne bad_parameter
    ldrb w2, [x0, #1]
    cmp w2, #'+'
    b.eq 2f
    mov w0, w2
    bl toupper
    cmp w0, #'R'
    b.ne bad_parameter
    mov x20, #1
    b 1b
2:
    add x0, x0, #2
    bl parse_dec
    cbnz x1, bad_parameter
    cbz x0, bad_parameter
    sub x21, x0, #1
    b 1b
3:
    address x0, sort_reverse
    str x20, [x0]
    address x0, sort_column
    str x21, [x0]
    // Read all of standard input.
    address x22, text
    mov x23, #0
4:
    mov x0, #0
    add x1, x22, x23
    mov x2, #TEXT_SIZE - 2
    sub x2, x2, x23
    cbz x2, too_large
    bl fread
    cbnz x1, 5f
    cbz x0, 5f
    add x23, x23, x0
    b 4b
5:
    strb wzr, [x22, x23]
    // Split into lines (CR/LF or LF; ^Z ends the text).
    address x24, lines
    mov x25, #0                 // line count
    mov x26, #0                 // offset
6:
    cmp x26, x23
    b.hs 9f
    add x0, x22, x26
    ldrb w2, [x0]
    cmp w2, #0x1a
    b.eq 9f
    cmp x25, #MAX_LINES
    b.hs too_large
    str x0, [x24, x25, lsl #3]
    add x25, x25, #1
7:
    cmp x26, x23
    b.hs 9f
    ldrb w2, [x22, x26]
    cmp w2, #0x1a
    b.eq 71f
    cmp w2, #10
    b.eq 8f
    cmp w2, #13
    b.ne 72f
    strb wzr, [x22, x26]
72:
    add x26, x26, #1
    b 7b
71:
    strb wzr, [x22, x26]
    b 9f
8:
    strb wzr, [x22, x26]
    add x26, x26, #1
    b 6b
9:
    // Shell sort of the line pointers.
    lsr x19, x25, #1            // gap
10:
    cbz x19, 14f
    mov x20, x19                // i
11:
    cmp x20, x25
    b.hs 13f
    ldr x26, [x24, x20, lsl #3] // temp
    mov x21, x20                // j
12:
    cmp x21, x19
    b.lo 121f
    sub x2, x21, x19
    ldr x27, [x24, x2, lsl #3]
    mov x0, x27
    mov x1, x26
    bl compare_lines
    cmp x0, #0
    b.le 121f
    str x27, [x24, x21, lsl #3]
    sub x21, x21, x19
    b 12b
121:
    str x26, [x24, x21, lsl #3]
    add x20, x20, #1
    b 11b
13:
    lsr x19, x19, #1
    b 10b
14:
    mov x20, #0
15:
    cmp x20, x25
    b.hs 16f
    ldr x0, [x24, x20, lsl #3]
    bl puts
    bl crlf
    add x20, x20, #1
    b 15b
16:
    mov x0, #0
    leave
too_large:
    address x0, too_large_message
    bl eputs
    mov x0, #1
    leave
bad_parameter:
    address x0, bad_parameter_message
    bl eputs
    mov x0, #1
    leave

// x0, x1 = lines. Returns x0 < 0, 0, > 0 (reversed for /R), comparing
// from the sort column, ignoring case.
compare_lines:
    address x9, sort_column
    ldr x9, [x9]
    mov x2, x0
    mov x3, x1
    mov x4, #0
1:
    cmp x4, x9
    b.hs 3f
    ldrb w5, [x2]
    cbz w5, 2f
    add x2, x2, #1
2:
    ldrb w5, [x3]
    cbz w5, 21f
    add x3, x3, #1
21:
    add x4, x4, #1
    b 1b
3:
    ldrb w5, [x2], #1
    ldrb w6, [x3], #1
    cmp w5, #'a'
    b.lo 4f
    cmp w5, #'z'
    b.hi 4f
    sub w5, w5, #32
4:
    cmp w6, #'a'
    b.lo 5f
    cmp w6, #'z'
    b.hi 5f
    sub w6, w6, #32
5:
    subs w7, w5, w6
    b.ne 6f
    cbnz w5, 3b
6:
    sxtw x0, w7
    address x9, sort_reverse
    ldr x9, [x9]
    cbz x9, 7f
    neg x0, x0
7:
    ret

.section .rodata
too_large_message: .asciz "SORT: Insufficient memory\r\n"
bad_parameter_message: .asciz "SORT: Invalid parameter\r\n"
.section .bss
.balign 8
sort_reverse: .skip 8
sort_column: .skip 8
lines: .skip 8 * MAX_LINES
text: .skip TEXT_SIZE
