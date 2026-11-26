// SPDX-License-Identifier: MIT
// Shared runtime for the native utilities (programs/*.S). Each program is a
// separate PE32+ image, so this file is assembled into every one of them.
// A program defines `main` (x0 = command tail, returns x0 = exit code).
//
// Conventions: AAPCS64. Library routines may clobber x0-x17 only.
.macro address reg, name
    adrp \reg, \name
    add \reg, \reg, :lo12:\name
.endm
.macro dos fn
    mov w8, #\fn
    bl dos_entry
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
.macro frame
    stp x29, x30, [sp, #-16]!
    mov x29, sp
.endm
.macro unframe
    ldp x29, x30, [sp], #16
    ret
.endm
// Prints a string literal.
.macro say text
    .pushsection .rodata
9876:
    .asciz "\text"
    .popsection
    adrp x0, 9876b
    add x0, x0, :lo12:9876b
    bl puts
.endm

.section .text
.global efi_main
efi_main:
    frame
    cbz x0, 1f
    address x1, lib_descriptor
    str x0, [x1]
    ldr x2, [x0, #24]
    address x1, lib_dos
    str x2, [x1]
    ldr x0, [x0, #32]
    bl main
    and x0, x0, #255
    dos 0x4c
1:
    mov x0, #1
    unframe

dos_entry:
    adrp x9, lib_dos
    ldr x9, [x9, :lo12:lib_dos]
    br x9

// x0 = exit code.
exit:
    and x0, x0, #255
    dos 0x4c

// Returns x0 = the environment block (NAME=value strings, empty one ends).
get_environment:
    address x0, lib_descriptor
    ldr x0, [x0]
    ldr x0, [x0, #40]
    ret

// x0 = name. Returns x0 = value, or 0.
getenv:
    frame
    mov x10, x0
    bl get_environment
1:
    ldrb w2, [x0]
    cbz w2, 5f
    mov x3, x0
    mov x4, x10
2:
    ldrb w5, [x4], #1
    ldrb w6, [x3], #1
    cbz w5, 3f
    cmp w6, #'a'
    b.lo 21f
    cmp w6, #'z'
    b.hi 21f
    sub w6, w6, #32
21:
    cmp w5, #'a'
    b.lo 22f
    cmp w5, #'z'
    b.hi 22f
    sub w5, w5, #32
22:
    cmp w5, w6
    b.eq 2b
    b 4f
3:
    cmp w6, #'='
    b.ne 4f
    mov x0, x3
    unframe
4:
    ldrb w2, [x0], #1
    cbnz w2, 4b
    b 1b
5:
    mov x0, #0
    unframe

// ---------------------------------------------------------------------------
// Strings.
strlen:
    mov x1, x0
1:
    ldrb w2, [x1], #1
    cbnz w2, 1b
    sub x0, x1, x0
    sub x0, x0, #1
    ret

// x0 = source, x1 = destination. Returns x0 = the destination's NUL.
strcpy:
1:
    ldrb w2, [x0], #1
    strb w2, [x1], #1
    cbnz w2, 1b
    sub x0, x1, #1
    ret

// x0 = string to append to, x1 = text.
strcat:
    frame
    stp x0, x1, [sp, #-16]!
    bl strlen
    ldp x2, x3, [sp], #16
    add x1, x2, x0
    mov x0, x3
    bl strcpy
    unframe

// w0 = character. Returns it upper-cased (ASCII).
toupper:
    cmp w0, #'a'
    b.lo 1f
    cmp w0, #'z'
    b.hi 1f
    sub w0, w0, #32
1:
    ret

// x0, x1 = strings. Returns x0 = 0 if equal ignoring case, else the
// difference of the first unequal upper-cased bytes.
strcmpi:
1:
    ldrb w2, [x0], #1
    ldrb w3, [x1], #1
    cmp w2, #'a'
    b.lo 2f
    cmp w2, #'z'
    b.hi 2f
    sub w2, w2, #32
2:
    cmp w3, #'a'
    b.lo 3f
    cmp w3, #'z'
    b.hi 3f
    sub w3, w3, #32
3:
    subs w4, w2, w3
    b.ne 4f
    cbnz w2, 1b
4:
    sxtw x0, w4
    ret

// x0, x1 = strings (case-sensitive). Same result convention.
strcmp:
1:
    ldrb w2, [x0], #1
    ldrb w3, [x1], #1
    subs w4, w2, w3
    b.ne 2f
    cbnz w2, 1b
2:
    sxtw x0, w4
    ret

// x0 = string: upper-cases it in place.
strupr:
    mov x1, x0
1:
    ldrb w2, [x1]
    cbz w2, 3f
    cmp w2, #'a'
    b.lo 2f
    cmp w2, #'z'
    b.hi 2f
    sub w2, w2, #32
    strb w2, [x1]
2:
    add x1, x1, #1
    b 1b
3:
    ret

// x0 = string. Returns x0 past blanks and tabs.
skip_blanks:
    ldrb w1, [x0]
    cmp w1, #' '
    b.eq 1f
    cmp w1, #9
    b.ne 2f
1:
    add x0, x0, #1
    b skip_blanks
2:
    ret

// x0 = string: removes trailing blanks, tabs, CR and LF in place.
rtrim:
    mov x1, x0
1:
    ldrb w2, [x1]
    cbz w2, 2f
    add x1, x1, #1
    b 1b
2:
    cmp x1, x0
    b.eq 4f
    ldurb w2, [x1, #-1]
    cmp w2, #' '
    b.eq 3f
    cmp w2, #9
    b.eq 3f
    cmp w2, #13
    b.eq 3f
    cmp w2, #10
    b.ne 4f
3:
    sub x1, x1, #1
    strb wzr, [x1]
    b 2b
4:
    ret

// x0 = text, x1 = pattern. Returns x0 = pointer to the first occurrence or
// 0. x2 = 1 to ignore case.
strstr:
    frame
1:
    mov x3, x0
    mov x4, x1
2:
    ldrb w6, [x4], #1
    cbz w6, 5f
    ldrb w5, [x3], #1
    cbz w5, 6f
    cbz x2, 3f
    cmp w5, #'a'
    b.lo 21f
    cmp w5, #'z'
    b.hi 21f
    sub w5, w5, #32
21:
    cmp w6, #'a'
    b.lo 3f
    cmp w6, #'z'
    b.hi 3f
    sub w6, w6, #32
3:
    cmp w5, w6
    b.eq 2b
    add x0, x0, #1
    b 1b
5:
    unframe
6:
    mov x0, #0
    unframe

// x0 = path. Returns x0 = pointer to its last component.
basename:
    mov x1, x0
1:
    ldrb w2, [x1], #1
    cbz w2, 2f
    cmp w2, #'\\'
    b.eq 11f
    cmp w2, #'/'
    b.eq 11f
    cmp w2, #':'
    b.ne 1b
11:
    mov x0, x1
    b 1b
2:
    ret

// x0 = string. Returns x0 = 1 if it holds '*' or '?'.
has_wild:
    ldrb w1, [x0], #1
    cbz w1, 1f
    cmp w1, #'*'
    b.eq 2f
    cmp w1, #'?'
    b.ne has_wild
2:
    mov x0, #1
    ret
1:
    mov x0, #0
    ret

// x0 = command line cursor. Splits off one argument (quotes allowed,
// '/' starts a new argument): x0 = argument (NUL-terminated in place,
// empty at the end), x1 = rest. The byte after the argument is saved in
// lib_split_char so that "a/b" splits into "a" and "/b".
next_arg:
    address x9, lib_split_char
    ldrb w10, [x9]
    cbz w10, 1f
    strb wzr, [x9]
    sub x0, x0, #1              // restore the '/' consumed last time
    strb w10, [x0]
1:
    ldrb w2, [x0]
    cmp w2, #' '
    b.eq 2f
    cmp w2, #9
    b.eq 2f
    cmp w2, #','
    b.eq 2f
    cmp w2, #';'
    b.ne 3f
2:
    add x0, x0, #1
    b 1b
3:
    mov x1, x0
    cmp w2, #'"'
    b.ne 5f
    add x0, x0, #1
    mov x1, x0
4:
    ldrb w2, [x1]
    cbz w2, 8f
    cmp w2, #'"'
    b.eq 7f
    add x1, x1, #1
    b 4b
5:
    cmp w2, #'/'
    b.ne 6f
    add x1, x1, #1              // a switch: '/' plus what follows
6:
    ldrb w2, [x1]
    cbz w2, 8f
    cmp w2, #' '
    b.eq 7f
    cmp w2, #9
    b.eq 7f
    cmp w2, #','
    b.eq 7f
    cmp w2, #';'
    b.eq 7f
    cmp w2, #'/'
    b.eq 61f
    add x1, x1, #1
    b 6b
61:
    strb w2, [x9]               // remembered; restored on the next call
    strb wzr, [x1], #1
    ret
7:
    strb wzr, [x1], #1
8:
    ret

// x0 = text. Parses a decimal number: x0 = value, x1 = 0 ok / 1 none,
// x2 = first byte after it.
parse_dec:
    mov x3, #0
    mov x4, #0
    mov x6, #10
1:
    ldrb w5, [x0]
    sub w5, w5, #'0'
    cmp w5, #9
    b.hi 2f
    madd x3, x3, x6, x5
    add x4, x4, #1
    add x0, x0, #1
    b 1b
2:
    mov x2, x0
    mov x0, x3
    cmp x4, #0
    cset x1, eq
    ret

// ---------------------------------------------------------------------------
// Output. Standard output is handle 1, errors go to handle 2.
puts:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    bl strlen
    mov x2, x0
    mov x1, x19
    mov x0, #1
    dos 0x40
    ldp x19, x20, [sp], #16
    unframe

eputs:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    bl strlen
    mov x2, x0
    mov x1, x19
    mov x0, #2
    dos 0x40
    ldp x19, x20, [sp], #16
    unframe

// x0 = buffer, x1 = count: to standard output.
write_out:
    frame
    mov x2, x1
    mov x1, x0
    mov x0, #1
    dos 0x40
    unframe

putc:
    frame
    sub sp, sp, #16
    strb w0, [sp]
    mov x0, #1
    mov x1, sp
    mov x2, #1
    dos 0x40
    add sp, sp, #16
    unframe

crlf:
    frame
    address x0, lib_crlf
    bl puts
    unframe

// x0 = count: prints that many spaces.
spaces:
    frame
    str x19, [sp, #-16]!
    mov x19, x0
1:
    cbz x19, 2f
    mov x0, #' '
    bl putc
    sub x19, x19, #1
    b 1b
2:
    ldr x19, [sp], #16
    unframe

// x0 = value, x1 = buffer (24 bytes). Returns x0 = the decimal string in it.
utoa:
    add x3, x1, #23
    strb wzr, [x3]
    mov x2, #10
1:
    udiv x4, x0, x2
    msub x5, x4, x2, x0
    add w5, w5, #'0'
    strb w5, [x3, #-1]!
    mov x0, x4
    cbnz x0, 1b
    mov x0, x3
    ret

// x0 = value, x1 = width (spaces on the left).
put_dec:
    mov x2, #' '
    b put_number
// x0 = value, x1 = width (zeros on the left).
put_dec0:
    mov x2, #'0'
put_number:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    sub sp, sp, #32
    mov x20, x1
    mov x21, x2
    mov x1, sp
    bl utoa
    mov x19, x0
    bl strlen
    subs x20, x20, x0
    b.ls 2f
1:
    mov x0, x21
    bl putc
    subs x20, x20, #1
    b.ne 1b
2:
    mov x0, x19
    bl puts
    add sp, sp, #32
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// x0 = value with thousands separators (",") in a field of x1 characters.
put_dec_commas:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    sub sp, sp, #64
    mov x20, x1
    add x1, sp, #32
    bl utoa
    mov x19, x0
    bl strlen
    mov x21, x0                 // digits
    mov x2, sp
    mov x3, #0                  // digits copied
1:
    ldrb w4, [x19, x3]
    cbz w4, 3f
    strb w4, [x2], #1
    add x3, x3, #1
    sub x5, x21, x3
    cbz x5, 3f
    mov x6, #3
    udiv x7, x5, x6
    msub x7, x7, x6, x5
    cbnz x7, 1b
    mov w4, #','
    strb w4, [x2], #1
    b 1b
3:
    strb wzr, [x2]
    mov x0, sp
    bl strlen
    subs x0, x20, x0
    b.ls 4f
    bl spaces
4:
    mov x0, sp
    bl puts
    add sp, sp, #64
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// x0 = value, x1 = digits: upper-case hexadecimal.
put_hex:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    mov x20, x1
1:
    cbz x20, 2f
    sub x20, x20, #1
    lsl x2, x20, #2
    lsr x0, x19, x2
    and x0, x0, #15
    cmp x0, #10
    add x1, x0, #'0'
    add x2, x0, #('A' - 10)
    csel x0, x1, x2, lo
    bl putc
    b 1b
2:
    ldp x19, x20, [sp], #16
    unframe

// x0 = DOS error code: prints the standard message to standard output.
print_error:
    frame
    address x1, lib_error_table
1:
    ldrb w2, [x1]
    cbz w2, 3f
    cmp w2, w0
    b.eq 4f
    add x1, x1, #1
2:
    ldrb w2, [x1], #1
    cbnz w2, 2b
    b 1b
4:
    add x0, x1, #1
    bl puts
    bl crlf
    unframe
3:
    address x0, lib_error_other
    bl puts
    bl crlf
    unframe

// ---------------------------------------------------------------------------
// Files. Each returns x1 = 0, or x1 = 1 with a DOS error in x0.
fopen:                          // x0 path, x1 mode
    frame
    dos 0x3d
    unframe
fcreate:                        // x0 path, x1 attributes
    frame
    dos 0x3c
    unframe
fclose:
    frame
    dos 0x3e
    unframe
fread:                          // x0 handle, x1 buffer, x2 count
    frame
    dos 0x3f
    unframe
fwrite:
    frame
    dos 0x40
    unframe
fseek:                          // x0 handle, x1 offset, x2 origin
    frame
    dos 0x42
    unframe

// Buffered line reader. x0 = reader (LR_SIZE bytes), x1 = handle.
.equ LR_SIZE, 4120
lr_init:
    str x1, [x0]
    str xzr, [x0, #8]           // position
    str xzr, [x0, #16]          // length
    ret

// x0 = reader: ^Z is ordinary text from now on (EDLIN /B).
lr_binary:
    ldr x1, [x0]
    orr x1, x1, #(1 << 63)
    str x1, [x0]
    ret

// x0 = reader, x1 = destination, x2 = capacity. Reads one line without its
// CR/LF. Returns x0 = length, x1 = 0, or x1 = 1 at end of file (nothing
// read). A ^Z ends the text. Overlong lines are split.
lr_getline:
    enter
    mov x19, x0
    mov x20, x1
    sub x21, x2, #1
    mov x22, #0                 // stored
    mov x23, #0                 // anything seen
1:
    ldr x2, [x19, #8]
    ldr x3, [x19, #16]
    cmp x2, x3
    b.lo 2f
    ldr x0, [x19]
    and x0, x0, #0xffffffff     // bit 63: binary (lr_binary)
    add x1, x19, #24
    mov x2, #4096
    dos 0x3f
    cbnz x1, 8f
    cbz x0, 8f
    str x0, [x19, #16]
    str xzr, [x19, #8]
    b 1b
2:
    add x4, x19, #24
    ldrb w5, [x4, x2]
    add x2, x2, #1
    str x2, [x19, #8]
    cmp w5, #0x1a
    b.ne 21f
    ldr x6, [x19]
    tbz x6, #63, 7f
21:
    mov x23, #1
    cmp w5, #10
    b.eq 9f
    cmp w5, #13
    b.eq 1b
    cmp x22, x21
    b.lo 3f
    sub x2, x2, #1              // full: the byte starts the next piece
    str x2, [x19, #8]
    b 9f
3:
    strb w5, [x20, x22]
    add x22, x22, #1
    b 1b
7:
    sub x2, x2, #1              // ^Z stays: every later read is EOF
    str x2, [x19, #8]
8:
    cbnz x23, 9f
    strb wzr, [x20, x22]
    mov x0, #0
    mov x1, #1
    leave
9:
    strb wzr, [x20, x22]
    mov x0, x22
    mov x1, #0
    leave

// Directory walkers call this when a tree is deeper than they can follow,
// with x0 = the directory they cannot descend from: if it really has a
// subdirectory, says once that deeper levels were skipped.
depth_note:
    enter
    mov x19, x0
    address x9, depth_noted
    ldr x10, [x9]
    cbnz x10, 9f
    dos 0x2f                    // keep the caller's DTA
    mov x20, x0
    mov x21, x2
    address x0, depth_dta
    mov x1, #280
    dos 0x1a
    mov x0, x19
    address x1, depth_all
    address x2, depth_path
    bl join_path
    address x0, depth_path
    mov x1, #0x10
    dos 0x4e
1:
    cbnz x1, 8f
    address x9, depth_dta
    ldrb w10, [x9]              // attributes (native DTA)
    tbz w10, #4, 2f
    ldrb w10, [x9, #24]         // name: "." and ".." do not count
    cmp w10, #'.'
    b.eq 2f
    address x9, depth_noted
    mov x10, #1
    str x10, [x9]
    say "Directory tree too deep: deeper levels were skipped\r\n"
    b 8f
2:
    dos 0x4f
    b 1b
8:
    mov x0, x20
    mov x1, x21
    dos 0x1a
9:
    leave

// x0 = question text. Reads Y or N; returns x0 = 1 for yes.
ask_yn:
    frame
    str x19, [sp, #-16]!
    mov x19, x0
1:
    mov x0, x19
    bl puts
    dos 0x01
    str x0, [sp, #8]
    bl crlf
    ldr x0, [sp, #8]
    bl toupper
    cmp w0, #'Y'
    b.eq 2f
    cmp w0, #'N'
    b.ne 1b
    mov x0, #0
    b 3f
2:
    mov x0, #1
3:
    ldr x19, [sp], #16
    unframe

// Waits for a key ("Press any key to continue . . .").
press_any_key:
    frame
    address x0, lib_press_key
    bl puts
    dos 0x08
    bl crlf
    unframe

// x0 = name, x1 = template ("*.BAK", "A?C.*"), x2 = output: DOS rename
// template ('?' keeps the character, '*' the rest of that part).
apply_template:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x0, x19
    bl lib_last_dot
    mov x23, x0
    mov x0, x19
    bl strlen
    mov x22, x0
    mov x0, x20
    bl lib_last_dot
    mov x25, x0
    mov x0, x20
    bl strlen
    mov x24, x0
    cmp x23, #0
    b.ge 1f
    mov x26, x22
    mov x27, x19
    mov x28, #0
    b 2f
1:
    mov x26, x23
    add x27, x19, x23
    add x27, x27, #1
    sub x28, x22, x23
    sub x28, x28, #1
2:
    cmp x25, #0
    b.ge 3f
    mov x9, x24
    mov x10, #0
    mov x11, x20
    b 4f
3:
    mov x9, x25
    add x11, x20, x25
    add x11, x11, #1
    sub x10, x24, x25
    sub x10, x10, #1
4:
    mov x0, x19
    mov x1, x26
    mov x2, x20
    mov x3, x9
    mov x4, x21
    bl lib_template_part
    mov x21, x0
    cbz x10, 6f
    mov w5, #'.'
    strb w5, [x21], #1
    mov x0, x27
    mov x1, x28
    mov x2, x11
    mov x3, x10
    mov x4, x21
    bl lib_template_part
    cmp x0, x21
    b.ne 5f
    sub x0, x0, #1
5:
    strb wzr, [x0]
    leave
6:
    strb wzr, [x21]
    leave

lib_template_part:
    mov x5, #0
    mov x6, #0
1:
    cmp x6, x3
    b.hs 9f
    ldrb w7, [x2, x6]
    add x6, x6, #1
    cmp w7, #'*'
    b.eq 5f
    cmp w7, #'?'
    b.ne 3f
    cmp x5, x1
    b.hs 4f
    ldrb w7, [x0, x5]
    strb w7, [x4], #1
4:
    add x5, x5, #1
    b 1b
3:
    strb w7, [x4], #1
    add x5, x5, #1
    b 1b
5:
    cmp x5, x1
    b.hs 9f
    ldrb w7, [x0, x5]
    strb w7, [x4], #1
    add x5, x5, #1
    b 5b
9:
    mov x0, x4
    ret

lib_last_dot:
    mov x1, #-1
    mov x2, #0
1:
    ldrb w3, [x0, x2]
    cbz w3, 2f
    cmp w3, #'.'
    csel x1, x2, x1, eq
    add x2, x2, #1
    b 1b
2:
    mov x0, x1
    ret

// x0 = path. Returns x0 = 1 if it names a directory (or is empty, "" or
// ends in ':' or '').
is_directory:
    frame
    str x19, [sp, #-16]!
    mov x19, x0
    ldrb w2, [x19]
    cbz w2, 2f
    bl strlen
    add x1, x19, x0
    ldurb w2, [x1, #-1]
    cmp w2, #'\\'
    b.eq 2f
    cmp w2, #':'
    b.eq 2f
    mov x0, x19
    bl has_wild
    cbnz x0, 1f
    mov x0, x19
    mov x1, #0
    dos 0x43
    cbnz x1, 1f
    tbz x0, #4, 1f
2:
    mov x0, #1
    b 3f
1:
    mov x0, #0
3:
    ldr x19, [sp], #16
    unframe

// x0 = directory (as is_directory accepts), x1 = name, x2 = output.
join_path:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x1
    mov x20, x2
    mov x1, x2
    bl strcpy
    mov x1, x0
    cmp x1, x20
    b.eq 1f
    ldurb w2, [x1, #-1]
    cmp w2, #'\\'
    b.eq 1f
    cmp w2, #':'
    b.eq 1f
    mov w2, #'\\'
    strb w2, [x1], #1
1:
    mov x0, x19
    bl strcpy
    ldp x19, x20, [sp], #16
    unframe

// x0 = path. Returns x0 = its drive letter ('A'...): the "d:" it starts
// with, or the current drive.
path_drive_letter:
    frame
    ldrb w1, [x0]
    cbz w1, 1f
    ldrb w2, [x0, #1]
    cmp w2, #':'
    b.ne 1f
    sub w3, w1, #'a'
    cmp w3, #26
    b.hs 2f
    sub w1, w1, #32
2:
    mov x0, x1
    unframe
1:
    dos 0x19
    add x0, x0, #'A'
    unframe

// x0 = line buffer (DOS 0Ah format, capacity in byte 0). Reads a line from
// the console; returns x0 = the NUL-terminated text.
read_console_line:
    frame
    str x19, [sp, #-16]!
    mov x19, x0
    dos 0x0a
    bl crlf
    ldrb w2, [x19, #1]
    add x0, x19, #2
    strb wzr, [x0, x2]
    ldr x19, [sp], #16
    unframe

.section .rodata
lib_crlf: .asciz "\r\n"
lib_press_key: .asciz "Press any key to continue . . ."
lib_error_other: .asciz "File/device error"
lib_error_table:
    .byte 2
    .asciz "File not found"
    .byte 3
    .asciz "Path not found"
    .byte 4
    .asciz "Too many open files"
    .byte 5
    .asciz "Access denied"
    .byte 8
    .asciz "Insufficient memory"
    .byte 15
    .asciz "Invalid drive specification"
    .byte 18
    .asciz "File not found"
    .byte 32
    .asciz "Sharing violation"
    .byte 39
    .asciz "Insufficient disk space"
    .byte 80
    .asciz "File exists"
    .byte 0
.section .rodata
depth_all: .asciz "*.*"
.section .bss
.balign 8
lib_descriptor: .skip 8
lib_dos: .skip 8
lib_split_char: .skip 8
depth_noted: .skip 8
depth_dta: .skip 280
depth_path: .skip 260
.section .text
