// SPDX-License-Identifier: MIT
// FIND [/V] [/C] [/N] [/I] "string" [[d:][path]filename ...]
// Native port of v4.0/src/CMD/FIND: prints the lines of each file (or of
// standard input) that contain the string. /V lines without it, /C only a
// count, /N line numbers, /I ignore case.
.include "lib.inc"

main:
    enter
    mov x19, x0                 // cursor
    mov x20, #0                 // flags: 1 /V, 2 /C, 4 /N, 8 /I
    mov x21, #0                 // pattern
    mov x22, #0                 // file count
1:
    mov x0, x19
    bl next_arg
    mov x19, x1
    ldrb w2, [x0]
    cbz w2, 4f
    cmp w2, #'/'
    b.ne 3f
    ldrb w0, [x0, #1]
    bl toupper
    mov x2, #1
    cmp w0, #'V'
    b.eq 2f
    mov x2, #2
    cmp w0, #'C'
    b.eq 2f
    mov x2, #4
    cmp w0, #'N'
    b.eq 2f
    mov x2, #8
    cmp w0, #'I'
    b.ne bad_switch
2:
    orr x20, x20, x2
    b 1b
3:
    cbnz x21, 31f
    mov x21, x0
    b 1b
31:
    address x2, files
    cmp x22, #32
    b.hs 1b
    str x0, [x2, x22, lsl #3]
    add x22, x22, #1
    b 1b
4:
    cbz x21, missing
    address x2, opt_flags
    str x20, [x2]
    address x2, opt_pattern
    str x21, [x2]
    cbnz x22, 5f
    mov x0, #0                  // standard input
    mov x1, #0
    bl find_in
    b done
5:
    mov x23, #0
6:
    cmp x23, x22
    b.hs done
    address x2, files
    ldr x24, [x2, x23, lsl #3]
    mov x0, x24
    bl has_wild
    cbnz x0, 7f
    mov x0, x24
    mov x1, #0
    bl fopen
    cbnz x1, not_found
    mov x25, x0
    mov x0, x25
    mov x1, x24
    bl find_in
    mov x0, x25
    bl fclose
    b 8f
7:
    mov x0, x24                 // wildcards: each match in its directory
    bl find_wild
8:
    add x23, x23, #1
    b 6b
not_found:
    say "File not found - "
    mov x0, x24
    bl puts
    bl crlf
    mov x0, #2
    address x1, exit_code
    str x0, [x1]
    b 8b
done:
    address x0, exit_code
    ldr x0, [x0]
    leave
missing:
    say "FIND: Required parameter missing\r\n"
    mov x0, #2
    leave
bad_switch:
    say "FIND: Invalid switch\r\n"
    mov x0, #2
    leave

// x0 = pattern with wildcards: searches every matching file.
find_wild:
    enter
    mov x19, x0
    mov x0, x19
    address x1, path_buf
    bl strcpy
    address x0, path_buf
    bl basename
    address x1, path_buf
    sub x20, x0, x1             // directory prefix length
    address x0, dta
    mov x1, #280
    dos 0x1a
    mov x0, x19
    mov x1, #0
    dos 0x4e
1:
    cbnz x1, 3f
    address x0, dta
    add x0, x0, #24
    address x1, path_buf
    add x1, x1, x20
    bl strcpy
    address x0, path_buf
    mov x1, #0
    bl fopen
    cbnz x1, 2f
    mov x21, x0
    mov x0, x21
    address x1, path_buf
    bl find_in
    mov x0, x21
    bl fclose
2:
    dos 0x4f
    b 1b
3:
    leave

// x0 = handle, x1 = name for the header (0 for standard input).
find_in:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, #0                 // line number
    mov x22, #0                 // count
    cbz x20, 1f
    address x0, header
    bl puts
    mov x0, x20
    bl strupr
    mov x0, x20
    bl puts
    address x2, opt_flags
    ldr x2, [x2]
    tbnz x2, #1, 1f
    bl crlf
1:
    address x0, reader
    mov x1, x19
    bl lr_init
2:
    address x0, reader
    address x1, line
    mov x2, #1024
    bl lr_getline
    cbnz x1, 5f
    add x21, x21, #1
    address x0, line
    address x1, opt_pattern
    ldr x1, [x1]
    address x2, opt_flags
    ldr x2, [x2]
    ubfx x2, x2, #3, #1         // /I
    bl strstr
    cmp x0, #0
    cset x23, ne
    address x2, opt_flags
    ldr x2, [x2]
    and x2, x2, #1
    eor x23, x23, x2            // /V inverts
    cbz x23, 2b
    add x22, x22, #1
    address x2, opt_flags
    ldr x2, [x2]
    tbnz x2, #1, 2b             // /C: count only
    tbz x2, #2, 3f
    mov x0, #'['
    bl putc
    mov x0, x21
    mov x1, #0
    bl put_dec
    mov x0, #']'
    bl putc
3:
    address x0, line
    bl puts
    bl crlf
    b 2b
5:
    address x2, opt_flags
    ldr x2, [x2]
    tbz x2, #1, 6f
    cbz x20, 51f
    say ": "
51:
    mov x0, x22
    mov x1, #0
    bl put_dec
    bl crlf
6:
    leave

.section .rodata
header: .asciz "\r\n---------- "
.section .bss
.balign 8
exit_code: .skip 8
files: .skip 8 * 32
dta: .skip 288
path_buf: .skip 256
opt_flags: .skip 8
opt_pattern: .skip 8
line: .skip 1024
reader: .skip LR_SIZE
