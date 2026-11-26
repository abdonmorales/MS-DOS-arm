// SPDX-License-Identifier: MIT
// FC [/A] [/B] [/C] [/L] [/LBn] [/N] [/T] [/W] [/nnnn] file1 file2
// (v4.0/src/CMD/FC). Text mode compares lines and resynchronises after a
// difference when /nnnn (default 2) lines match again; binary mode (/B, or
// .EXE .COM .SYS .OBJ .LIB .BIN files) lists differing bytes.
.include "lib.inc"
.equ TEXT_SIZE, 131072
.equ MAX_LINES, 8192

main:
    enter
    mov x19, x0
    mov x20, #0                 // flags: 1 /B 2 /L 4 /C 8 /N 16 /W 32 /A
    mov x21, #2                 // resync lines
    mov x22, #0                 // files seen
1:
    mov x0, x19
    bl next_arg
    mov x19, x1
    ldrb w2, [x0]
    cbz w2, 4f
    cmp w2, #'/'
    b.ne 3f
    add x23, x0, #1
    ldrb w0, [x23]
    sub w2, w0, #'0'
    cmp w2, #9
    b.hi 11f
    mov x0, x23
    bl parse_dec
    cbz x0, bad_switch
    mov x21, x0
    b 1b
11:
    bl toupper
    mov x2, #1
    cmp w0, #'B'
    b.eq 2f
    mov x2, #4
    cmp w0, #'C'
    b.eq 2f
    mov x2, #8
    cmp w0, #'N'
    b.eq 2f
    mov x2, #16
    cmp w0, #'W'
    b.eq 2f
    mov x2, #32
    cmp w0, #'A'
    b.eq 2f
    mov x2, #0
    cmp w0, #'T'
    b.eq 2f
    cmp w0, #'L'
    b.ne bad_switch
    mov x2, #2                  // /L and /LBn
2:
    orr x20, x20, x2
    b 1b
3:
    cmp x22, #2
    b.hs bad_count
    address x2, file_names
    str x0, [x2, x22, lsl #3]
    add x22, x22, #1
    b 1b
4:
    cmp x22, #2
    b.ne bad_count
    address x0, opt_flags
    str x20, [x0]
    address x0, opt_resync
    str x21, [x0]
    address x2, file_names
    ldr x23, [x2]
    ldr x24, [x2, #8]
    mov x0, x23
    bl strupr
    mov x0, x24
    bl strupr
    // Binary by switch or by extension, unless /L.
    tbnz x20, #1, 6f
    tbnz x20, #0, binary
    mov x0, x23
    bl binary_extension
    cbnz x0, binary
6:
    mov x0, x23
    address x1, text1
    address x2, lines1
    bl load_lines
    cbnz x1, open_error
    mov x25, x0
    mov x0, x24
    address x1, text2
    address x2, lines2
    bl load_lines
    cbnz x1, open_error
    mov x26, x0
    address x9, line_counts
    stp x25, x26, [x9]
    say "Comparing files "
    mov x0, x23
    bl puts
    say " and "
    mov x0, x24
    bl puts
    bl crlf
    mov x0, x25
    mov x1, x26
    bl text_compare
    leave
binary:
    say "Comparing files "
    mov x0, x23
    bl puts
    say " and "
    mov x0, x24
    bl puts
    bl crlf
    mov x0, x23
    mov x1, x24
    bl binary_compare
    leave
open_error:
    say "FC: cannot open "
    address x9, failed_name
    ldr x0, [x9]
    bl puts
    say " - No such file or directory\r\n"
    mov x0, #2
    leave
bad_count:
    say "FC: Incorrect number of parameters\r\n"
    mov x0, #2
    leave
bad_switch:
    say "FC: Invalid switch\r\n"
    mov x0, #2
    leave

// x0 = name. Returns x0 = 1 for .EXE .COM .SYS .OBJ .LIB .BIN.
binary_extension:
    frame
    str x19, [sp, #-16]!
    bl basename
    mov x19, x0
    bl lib_last_dot
    cmp x0, #0
    b.lt 2f
    add x19, x19, x0
    address x9, binary_types
1:
    ldrb w2, [x9]
    cbz w2, 2f
    mov x0, x19
    mov x1, x9
    str x9, [sp, #8]
    bl strcmpi
    ldr x9, [sp, #8]
    cbz x0, 3f
    add x9, x9, #5
    b 1b
2:
    mov x0, #0
    ldr x19, [sp], #16
    unframe
3:
    mov x0, #1
    ldr x19, [sp], #16
    unframe

// x0 = path, x1 = text buffer, x2 = line table. Returns x0 = line count,
// x1 = 0, or x1 = 1 if the file cannot be read.
load_lines:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, x2
    address x9, failed_name
    str x19, [x9]
    mov x0, x19
    mov x1, #0
    bl fopen
    cbnz x1, 9f
    mov x22, x0
    mov x23, #0
1:
    mov x0, x22
    add x1, x20, x23
    mov x2, #TEXT_SIZE - 2
    sub x2, x2, x23
    cbz x2, 2f
    bl fread
    cbnz x1, 2f
    cbz x0, 2f
    add x23, x23, x0
    b 1b
2:
    mov x0, x22
    bl fclose
    strb wzr, [x20, x23]
    mov x24, #0                 // lines
    mov x25, #0                 // offset
3:
    cmp x25, x23
    b.hs 8f
    ldrb w2, [x20, x25]
    cmp w2, #0x1a
    b.eq 8f
    cmp x24, #MAX_LINES
    b.hs 8f
    add x2, x20, x25
    str x2, [x21, x24, lsl #3]
    add x24, x24, #1
4:
    cmp x25, x23
    b.hs 8f
    ldrb w2, [x20, x25]
    cmp w2, #10
    b.eq 5f
    cmp w2, #0x1a
    b.eq 41f
    cmp w2, #13
    b.ne 42f
    strb wzr, [x20, x25]
42:
    add x25, x25, #1
    b 4b
41:
    strb wzr, [x20, x25]
    b 8f
5:
    strb wzr, [x20, x25]
    add x25, x25, #1
    b 3b
8:
    mov x0, x24
    mov x1, #0
    leave
9:
    mov x1, #1
    leave

// x0, x1 = line indexes into lines1/lines2. Returns x0 = 1 if equal
// (honouring /C and /W).
lines_equal:
    address x9, lines1
    ldr x2, [x9, x0, lsl #3]
    address x9, lines2
    ldr x3, [x9, x1, lsl #3]
    address x9, opt_flags
    ldr x9, [x9]
1:
    ldrb w4, [x2]
    ldrb w5, [x3]
    tbz x9, #4, 4f
    // /W: a run of blanks matches a run of blanks; ends ignore them.
    cmp w4, #' '
    ccmp w4, #9, #4, ne
    cset w6, eq
    cmp w5, #' '
    ccmp w5, #9, #4, ne
    cset w7, eq
    orr w10, w6, w7
    cbz w10, 4f
    and w11, w6, w7
    cbnz w11, 2f
    cbz w6, 3f
    cbnz w5, 6f                 // blank against text
    b 2f
3:
    cbnz w4, 6f
2:
    cbz w6, 21f
22:
    add x2, x2, #1
    ldrb w4, [x2]
    cmp w4, #' '
    b.eq 22b
    cmp w4, #9
    b.eq 22b
21:
    cbz w7, 1b
23:
    add x3, x3, #1
    ldrb w5, [x3]
    cmp w5, #' '
    b.eq 23b
    cmp w5, #9
    b.eq 23b
    b 1b
4:
    tbz x9, #2, 5f
    cmp w4, #'a'
    b.lo 41f
    cmp w4, #'z'
    b.hi 41f
    sub w4, w4, #32
41:
    cmp w5, #'a'
    b.lo 5f
    cmp w5, #'z'
    b.hi 5f
    sub w5, w5, #32
5:
    cmp w4, w5
    b.ne 6f
    cbz w4, 7f
    add x2, x2, #1
    add x3, x3, #1
    b 1b
6:
    mov x0, #0
    ret
7:
    mov x0, #1
    ret

// x0 = lines in file 1, x1 = lines in file 2.
text_compare:
    enter
    mov x19, x0                 // n1
    mov x20, x1                 // n2
    mov x21, #0                 // i
    mov x22, #0                 // j
    mov x28, #0                 // differences found
1:
    cmp x21, x19
    b.hs 7f
    cmp x22, x20
    b.hs 7f
    mov x0, x21
    mov x1, x22
    bl lines_equal
    cbz x0, 2f
    add x21, x21, #1
    add x22, x22, #1
    b 1b
2:
    // Smallest k = di + dj where the next `resync` lines agree.
    mov x23, #1                 // k
3:
    add x2, x21, x23
    add x3, x22, x23
    cmp x2, x19
    b.ls 31f
    cmp x3, x20
    b.hi resync_failed
31:
    mov x24, #0                 // di
4:
    cmp x24, x23
    b.hi 6f
    sub x25, x23, x24           // dj
    add x26, x21, x24
    add x27, x22, x25
    cmp x26, x19
    b.hi 5f
    cmp x27, x20
    b.hi 5f
    bl resync_here
    cbnz x0, found
5:
    add x24, x24, #1
    b 4b
6:
    add x23, x23, #1
    mov x2, #1000
    cmp x23, x2
    b.hi resync_failed
    b 3b
found:
    mov x28, #1
    mov x0, x21
    mov x1, x26
    mov x2, x19
    address x3, lines1
    address x9, file_names
    ldr x4, [x9]
    bl print_block
    mov x0, x22
    mov x1, x27
    mov x2, x20
    address x3, lines2
    address x9, file_names
    ldr x4, [x9, #8]
    bl print_block
    say "*****\r\n\r\n"
    mov x21, x26
    mov x22, x27
    b 1b
resync_failed:
    say "Resync failed.  Files are too different\r\n"
    mov x28, #1
    mov x0, x21
    mov x1, x19
    mov x2, x19
    address x3, lines1
    address x9, file_names
    ldr x4, [x9]
    bl print_block
    mov x0, x22
    mov x1, x20
    mov x2, x20
    address x3, lines2
    address x9, file_names
    ldr x4, [x9, #8]
    bl print_block
    say "*****\r\n\r\n"
    b 9f
7:
    // Leftover lines at the end of either file.
    cmp x21, x19
    b.lo 8f
    cmp x22, x20
    b.hs 9f
8:
    mov x28, #1
    mov x0, x21
    mov x1, x19
    mov x2, x19
    address x3, lines1
    address x9, file_names
    ldr x4, [x9]
    bl print_block
    mov x0, x22
    mov x1, x20
    mov x2, x20
    address x3, lines2
    address x9, file_names
    ldr x4, [x9, #8]
    bl print_block
    say "*****\r\n\r\n"
9:
    cbnz x28, 10f
    say "FC: no differences encountered\r\n\r\n"
    mov x0, #0
    leave
10:
    mov x0, #1
    leave

// Uses x26/x27 (candidate positions in the caller): x0 = 1 if `resync`
// lines agree there (or both files end).
resync_here:
    frame
    stp x19, x20, [sp, #-16]!
    address x9, opt_resync
    ldr x19, [x9]
    mov x20, #0
1:
    cmp x20, x19
    b.hs 3f
    add x0, x26, x20
    add x1, x27, x20
    address x9, line_counts
    ldr x2, [x9]
    ldr x3, [x9, #8]
    cmp x0, x2
    b.hs 2f
    cmp x1, x3
    b.hs 4f
    bl lines_equal
    cbz x0, 4f
    add x20, x20, #1
    b 1b
2:
    cmp x1, x3                  // file 1 ended: agree only if 2 did too
    b.lo 4f
3:
    mov x0, #1
    b 5f
4:
    mov x0, #0
5:
    ldp x19, x20, [sp], #16
    unframe

// x0 = first line, x1 = resync line, x2 = line count, x3 = table,
// x4 = file name. Prints "***** NAME" and the lines, framed by the last
// matching line before them and the first one after, as DOS does.
print_block:
    enter
    mov x19, x0
    cbz x19, 1f                 // the last matching line comes first
    sub x19, x19, #1
1:
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    say "***** "
    mov x0, x23
    bl puts
    bl crlf
    cmp x20, x21
    b.hs 1f
    add x20, x20, #1            // include the line where they agree again
1:
    cmp x19, x20
    b.hs 3f
    address x9, opt_flags
    ldr x9, [x9]
    tbz x9, #3, 2f
    add x0, x19, #1
    mov x1, #5
    bl put_dec
    say ":  "
2:
    ldr x0, [x22, x19, lsl #3]
    bl puts
    bl crlf
    add x19, x19, #1
    b 1b
3:
    leave

// x0, x1 = paths: "OFFSET: XX YY" for each differing byte.
binary_compare:
    enter
    mov x19, x0
    mov x20, x1
    mov x0, x19
    mov x1, #0
    bl fopen
    cbnz x1, 9f
    mov x21, x0
    mov x0, x20
    mov x1, #0
    bl fopen
    cbnz x1, 8f
    mov x22, x0
    mov x23, #0                 // offset
    mov x28, #0                 // differences
1:
    mov x0, x21
    address x1, text1
    mov x2, #4096
    bl fread
    mov x24, x0
    mov x0, x22
    address x1, text2
    mov x2, #4096
    bl fread
    mov x25, x0
    cmp x24, x25
    csel x26, x24, x25, lo      // common length
    mov x27, #0
2:
    cmp x27, x26
    b.hs 4f
    address x9, text1
    ldrb w2, [x9, x27]
    address x9, text2
    ldrb w3, [x9, x27]
    cmp w2, w3
    b.eq 3f
    mov x28, #1
    stp x2, x3, [sp, #-16]!
    add x0, x23, x27
    mov x1, #8
    bl put_hex
    say ": "
    ldr x0, [sp]
    mov x1, #2
    bl put_hex
    mov x0, #' '
    bl putc
    ldr x0, [sp, #8]
    mov x1, #2
    bl put_hex
    bl crlf
    add sp, sp, #16
3:
    add x27, x27, #1
    b 2b
4:
    add x23, x23, x26
    cmp x24, x25
    b.eq 5f
    mov x28, #1
    say "FC: "
    cmp x24, x25
    mov x0, x19
    mov x1, x20
    csel x2, x0, x1, hi
    csel x3, x1, x0, hi
    stp x2, x3, [sp, #-16]!
    mov x0, x2
    bl puts
    say " longer than "
    ldr x0, [sp, #8]
    bl puts
    add sp, sp, #16
    bl crlf
    b 6f
5:
    cbnz x24, 1b
6:
    mov x0, x22
    bl fclose
    mov x0, x21
    bl fclose
    cbnz x28, 7f
    say "FC: no differences encountered\r\n"
    mov x0, #0
    leave
7:
    bl crlf
    mov x0, #1
    leave
8:
    mov x0, x21
    bl fclose
9:
    mov x19, x20
    say "FC: cannot open file\r\n"
    mov x0, #2
    leave

.section .rodata
binary_types:
    .asciz ".EXE"
    .asciz ".COM"
    .asciz ".SYS"
    .asciz ".OBJ"
    .asciz ".LIB"
    .asciz ".BIN"
    .byte 0
.section .bss
.balign 8
opt_flags: .skip 8
opt_resync: .skip 8
failed_name: .skip 8
file_names: .skip 16
line_counts: .skip 16
lines1: .skip 8 * MAX_LINES
lines2: .skip 8 * MAX_LINES
text1: .skip TEXT_SIZE
text2: .skip TEXT_SIZE
