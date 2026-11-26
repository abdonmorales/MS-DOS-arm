// SPDX-License-Identifier: MIT
// TREE [d:][path] [/F] [/A] (v4.0/src/CMD/TREE): the directory structure,
// drawn with code page 437 line characters (or ASCII with /A); /F also
// lists the files in each directory.
.include "lib.inc"
.equ POOL_SIZE, 65536

main:
    enter
    mov x19, x0
    mov x20, #0                 // flags: 1 /F, 2 /A
    address x0, path
    strb wzr, [x0]
1:
    mov x0, x19
    bl next_arg
    mov x19, x1
    ldrb w2, [x0]
    cbz w2, 3f
    cmp w2, #'/'
    b.ne 2f
    ldrb w0, [x0, #1]
    bl toupper
    cmp w0, #'F'
    b.ne 11f
    orr x20, x20, #1
    b 1b
11:
    cmp w0, #'A'
    b.ne bad
    orr x20, x20, #2
    b 1b
2:
    address x1, path
    bl strcpy
    b 1b
3:
    address x0, flags
    str x20, [x0]
    address x0, dta_stack
    address x1, dta_top
    str x0, [x1]
    // Header from the boot record.
    say "Directory PATH listing"
    mov x0, #0
    mov x1, #0
    address x2, media
    dos 0x69
    cbnz x1, 4f
    say " for Volume "
    address x0, media
    add x0, x0, #6
    strb wzr, [x0, #11]
    bl rtrim
    address x0, media
    add x0, x0, #6
    bl puts
    bl crlf
    say "Volume Serial Number is "
    address x0, media
    ldrh w0, [x0, #4]
    mov x1, #4
    bl put_hex
    mov x0, #'-'
    bl putc
    address x0, media
    ldrh w0, [x0, #2]
    mov x1, #4
    bl put_hex
4:
    bl crlf
    address x19, path
    ldrb w2, [x19]
    cbnz w2, 5f
    say "A:."
    b 6f
5:
    mov x0, x19
    bl strupr
    ldrb w2, [x19, #1]
    cmp w2, #':'
    b.eq 51f
    say "A:"
51:
    mov x0, x19
    bl puts
6:
    bl crlf
    address x0, prefix
    strb wzr, [x0]
    mov x0, #0
    bl walk
    address x0, any_directory
    ldr x0, [x0]
    cbnz x0, 7f
    say "No subdirectories exist\r\n"
7:
    mov x0, #0
    leave
bad:
    say "Invalid switch\r\n"
    mov x0, #1
    leave

// x0 = prefix length. Lists the directory in `path`, then its children.
walk:
    enter
    mov x19, x0
    address x20, path
    mov x0, x20
    bl strlen
    mov x21, x0                 // path length to restore
    address x22, pool
    address x9, pool_used
    ldr x23, [x9]               // our names start here
    mov x24, x23                // and end here
    mov x25, #0                 // directories
    // Collect names: kind byte ('D' or 'F') then the name.
    mov x0, x20
    mov x1, x21
    bl add_glob
    address x0, dta
    mov x1, #280
    dos 0x1a
    mov x0, x20
    mov x1, #0x16
    dos 0x4e
1:
    cbnz x1, 4f
    address x26, dta
    ldr x2, [x26]
    add x27, x26, #24
    ldrb w3, [x27]
    cmp w3, #'.'
    b.eq 3f
    mov w4, #'F'
    tbz x2, #4, 2f
    mov w4, #'D'
    add x25, x25, #1
2:
    cmp w4, #'F'
    b.ne 21f
    address x9, flags
    ldr x9, [x9]
    tbz x9, #0, 3f
21:
    mov x0, x27
    bl strlen
    add x2, x24, x0
    add x2, x2, #2
    mov x3, #POOL_SIZE
    cmp x2, x3
    b.hs 3f
    strb w4, [x22, x24]
    add x24, x24, #1
    mov x0, x27
    add x1, x22, x24
    bl strcpy
    add x1, x22, x24
    sub x0, x0, x1
    add x24, x24, x0
    add x24, x24, #1
3:
    dos 0x4f
    b 1b
4:
    strb wzr, [x20, x21]        // drop the glob
    address x9, pool_used
    str x24, [x9]
    cbz x25, 41f
    address x9, any_directory
    mov x2, #1
    str x2, [x9]
41:
    // Files first (with /F), indented under this directory.
    mov x26, x23
5:
    cmp x26, x24
    b.hs 7f
    ldrb w2, [x22, x26]
    add x27, x22, x26
    add x27, x27, #1
    cmp w2, #'F'
    b.ne 6f
    address x0, prefix
    bl puts
    address x0, vertical
    address x1, ascii_vertical
    address x9, flags
    ldr x9, [x9]
    tst x9, #2
    csel x0, x1, x0, ne
    cmp x25, #0
    address x1, blank4
    csel x0, x1, x0, eq
    bl puts
    mov x0, x27
    bl puts
    bl crlf
6:
    mov x0, x27
    bl strlen
    add x26, x26, x0
    add x26, x26, #2
    b 5b
7:
    // Then each directory, recursively.
    mov x26, x23
    mov x28, x25                // directories left
8:
    cmp x26, x24
    b.hs 12f
    ldrb w2, [x22, x26]
    add x27, x22, x26
    add x27, x27, #1
    cmp w2, #'D'
    b.ne 11f
    sub x28, x28, #1
    address x0, prefix
    bl puts
    address x9, flags
    ldr x9, [x9]
    tst x9, #2
    cbnz x28, 9f
    address x0, last_branch
    address x1, ascii_last
    csel x0, x1, x0, ne
    b 10f
9:
    address x0, branch
    address x1, ascii_branch
    csel x0, x1, x0, ne
10:
    bl puts
    mov x0, x27
    bl puts
    bl crlf
    // path += "\name"; prefix += "|   " or "    "
    mov x0, x20
    bl strlen
    add x1, x20, x0
    cbz x0, 101f
    ldurb w2, [x1, #-1]
    cmp w2, #'\\'
    b.eq 101f
    mov w2, #'\\'
    strb w2, [x1], #1
101:
    mov x0, x27
    bl strcpy
    address x9, flags
    ldr x9, [x9]
    tst x9, #2
    address x0, vertical
    address x1, ascii_vertical
    csel x1, x1, x0, ne
    address x0, blank4
    cmp x28, #0
    csel x1, x0, x1, eq
    address x0, prefix
    add x0, x0, x19
    cmp x19, #400
    b.hs 102f
    mov x2, x0
    mov x0, x1
    mov x1, x2
    bl strcpy
    add x0, x19, #4
    bl walk
102:
    address x0, prefix
    strb wzr, [x0, x19]
    strb wzr, [x20, x21]
11:
    mov x0, x27
    bl strlen
    add x26, x26, x0
    add x26, x26, #2
    b 8b
12:
    address x9, pool_used
    str x23, [x9]
    leave

// x0 = path, x1 = its length: appends "\*.*" (or "*.*" after "\" or ":").
add_glob:
    add x2, x0, x1
    cbz x1, 1f
    ldurb w3, [x2, #-1]
    cmp w3, #'\\'
    b.eq 1f
    cmp w3, #':'
    b.eq 1f
    mov w3, #'\\'
    strb w3, [x2], #1
1:
    mov w3, #'*'
    strb w3, [x2]
    mov w3, #'.'
    strb w3, [x2, #1]
    mov w3, #'*'
    strb w3, [x2, #2]
    strb wzr, [x2, #3]
    ret

.section .rodata
branch: .asciz "\xc3\xc4\xc4\xc4"
last_branch: .asciz "\xc0\xc4\xc4\xc4"
vertical: .asciz "\xb3   "
ascii_branch: .asciz "+---"
ascii_last: .asciz "\\---"
ascii_vertical: .asciz "|   "
blank4: .asciz "    "
.section .bss
.balign 8
flags: .skip 8
any_directory: .skip 8
pool_used: .skip 8
dta_top: .skip 8
media: .skip 32
dta: .skip 288
dta_stack: .skip 8
path: .skip 512
prefix: .skip 512
pool: .skip POOL_SIZE
