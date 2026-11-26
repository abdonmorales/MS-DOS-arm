// SPDX-License-Identifier: MIT
// ATTRIB [+R|-R] [+A|-A] [+S|-S] [+H|-H] [d:][path]filename [/S]
// (v4.0/src/CMD/ATTRIB): shows or changes file attributes; wildcards are
// allowed and /S also processes the matching files in subdirectories.
// Without a file name, every file in the current directory is shown.
.include "lib.inc"
.equ LEVEL, 1024
.equ L_DIR, 0
.equ L_DTA, 512
.equ MAX_DEPTH, 15

main:
    enter
    mov x19, x0
    mov x20, #0                 // bits to set
    mov x21, #0                 // bits to clear
    mov x22, #0                 // file name
    mov x23, #0                 // /S
1:
    mov x0, x19
    bl next_arg
    mov x19, x1
    ldrb w2, [x0]
    cbz w2, 5f
    cmp w2, #'+'
    b.eq 2f
    cmp w2, #'-'
    b.eq 2f
    cmp w2, #'/'
    b.eq 4f
    cbnz x22, bad_parm
    mov x22, x0
    b 1b
2:
    mov x24, x0
    ldrb w3, [x24, #2]
    cbnz w3, bad_parm
    ldrb w0, [x24, #1]
    bl toupper
    mov x3, #1
    cmp w0, #'R'
    b.eq 3f
    mov x3, #2
    cmp w0, #'H'
    b.eq 3f
    mov x3, #4
    cmp w0, #'S'
    b.eq 3f
    mov x3, #0x20
    cmp w0, #'A'
    b.ne bad_parm
3:
    ldrb w2, [x24]
    cmp w2, #'+'
    b.ne 31f
    orr x20, x20, x3
    bic x21, x21, x3
    b 1b
31:
    orr x21, x21, x3
    bic x20, x20, x3
    b 1b
4:
    ldrb w0, [x0, #1]
    bl toupper
    cmp w0, #'S'
    b.ne bad_parm
    mov x23, #1
    b 1b
5:
    address x9, set_bits
    stp x20, x21, [x9]
    address x9, recurse
    str x23, [x9]
    address x24, levels
    cbnz x22, 6f
    address x0, star_star
    address x1, pattern
    bl strcpy
    strb wzr, [x24, #L_DIR]
    b 8f
6:
    mov x0, x22
    bl strupr
7:
    mov x0, x22
    bl basename
    mov x25, x0
    address x1, pattern
    bl strcpy
    sub x2, x25, x22
    mov x3, #0
71:
    cmp x3, x2
    b.hs 72f
    ldrb w4, [x22, x3]
    strb w4, [x24, x3]
    add x3, x3, #1
    b 71b
72:
    strb wzr, [x24, x3]
8:
    mov x0, #0
    bl walk
    address x9, matched
    ldr x0, [x9]
    cbnz x0, 9f
    say "File not found - "
    address x0, pattern
    bl puts
    bl crlf
    mov x0, #1
    leave
9:
    address x9, failed
    ldr x0, [x9]
    leave
bad_parm:
    say "Invalid parameter\r\n"
    mov x0, #1
    leave

// x0 = depth.
walk:
    enter
    mov x19, x0
    address x20, levels
    mov x2, #LEVEL
    madd x20, x19, x2, x20
    add x0, x20, #L_DIR
    address x1, pattern
    address x2, path
    bl join_path
    add x0, x20, #L_DTA
    mov x1, #280
    dos 0x1a
    address x0, path
    mov x1, #0x17               // read-only, hidden, system, directories
    dos 0x4e
1:
    cbnz x1, 4f
    ldrb w2, [x20, #L_DTA + 24]
    cmp w2, #'.'
    b.eq 3f
    ldr x21, [x20, #L_DTA]
    // Directories match only an explicit name, as in DOS.
    tbz x21, #4, 2f
    address x0, pattern
    bl has_wild
    cbnz x0, 3f
2:
    address x9, matched
    mov x2, #1
    str x2, [x9]
    add x0, x20, #L_DIR
    add x1, x20, #L_DTA + 24
    address x2, path
    bl join_path
    address x9, set_bits
    ldp x2, x3, [x9]
    orr x4, x2, x3
    cbz x4, 21f
    orr x2, x21, x2
    bic x2, x2, x3
    mov x4, #0x27
    and x2, x2, x4
    address x0, path
    mov x1, #1
    dos 0x43
    cbz x1, 3f
    bl print_error
    address x9, failed
    mov x2, #1
    str x2, [x9]
    b 3f
21:
    // "A  SHR     A:\PATH\NAME"
    mov x0, #' '
    tst x21, #0x20
    b.eq 22f
    mov x0, #'A'
22:
    bl putc
    mov x0, #2
    bl spaces
    mov x0, #' '
    tst x21, #4
    b.eq 23f
    mov x0, #'S'
23:
    bl putc
    mov x0, #' '
    tst x21, #2
    b.eq 24f
    mov x0, #'H'
24:
    bl putc
    mov x0, #' '
    tst x21, #1
    b.eq 25f
    mov x0, #'R'
25:
    bl putc
    mov x0, #5
    bl spaces
    address x0, path
    address x1, truename
    dos 0x60
    address x0, truename
    cbz x1, 26f
    address x0, path
26:
    bl puts
    bl crlf
3:
    add x0, x20, #L_DTA
    mov x1, #280
    dos 0x1a
    dos 0x4f
    b 1b
4:
    address x9, recurse
    ldr x2, [x9]
    cbz x2, 9f
    cmp x19, #MAX_DEPTH - 1
    b.lo 7788f
    add x0, x20, #L_DIR
    bl depth_note               // deeper directories are skipped, not lost
    b 9f
7788:
    add x0, x20, #L_DIR
    address x1, star_star
    address x2, path
    bl join_path
    add x0, x20, #L_DTA
    mov x1, #280
    dos 0x1a
    address x0, path
    mov x1, #0x16
    dos 0x4e
5:
    cbnz x1, 9f
    ldr x2, [x20, #L_DTA]
    tbz x2, #4, 6f
    ldrb w2, [x20, #L_DTA + 24]
    cmp w2, #'.'
    b.eq 6f
    add x0, x20, #L_DIR
    add x1, x20, #L_DTA + 24
    add x2, x20, #LEVEL + L_DIR
    bl join_path
    add x0, x19, #1
    bl walk
    add x0, x20, #L_DTA
    mov x1, #280
    dos 0x1a
6:
    dos 0x4f
    b 5b
9:
    leave

.section .rodata
star_star: .asciz "*.*"
.section .bss
.balign 8
set_bits: .skip 16
recurse: .skip 8
matched: .skip 8
failed: .skip 8
pattern: .skip 128
path: .skip 512
truename: .skip 128
.balign 16
levels: .skip LEVEL * MAX_DEPTH
