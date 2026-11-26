// SPDX-License-Identifier: MIT
// COMP [file1] [file2] (v4.0/src/CMD/COMP): byte-by-byte comparison.
// file1 may hold wildcards; file2 may be a directory or a template. Shows
// up to 10 mismatches, then asks "Compare more files (Y/N) ?".
.include "lib.inc"

main:
    enter
    mov x19, x0
    bl next_arg
    mov x19, x1
    address x1, name1
    bl strcpy
    mov x0, x19
    bl next_arg
    address x1, name2
    bl strcpy
1:
    address x0, name1
    ldrb w2, [x0]
    cbnz w2, 2f
    say "Enter primary file name\r\n"
    address x0, line
    mov w2, #120
    strb w2, [x0]
    bl read_console_line
    bl skip_blanks
    address x1, name1
    bl strcpy
    address x0, name1
    bl rtrim
    b 1b
2:
    address x0, name2
    ldrb w2, [x0]
    cbnz w2, 3f
    say "Enter 2nd file name or drive id\r\n"
    address x0, line
    mov w2, #120
    strb w2, [x0]
    bl read_console_line
    bl skip_blanks
    address x1, name2
    bl strcpy
    address x0, name2
    bl rtrim
    address x0, name2
    ldrb w2, [x0]
    cbz w2, 2b
3:
    bl compare_set
    bl crlf
    address x0, more_question
    bl ask_yn
    cbz x0, 4f
    address x0, name1
    strb wzr, [x0]
    address x0, name2
    strb wzr, [x0]
    b 1b
4:
    mov x0, #0
    leave

// Compares name1 (wildcards allowed) with name2.
compare_set:
    enter
    address x0, name1
    bl has_wild
    mov x19, x0
    address x0, name2
    bl is_directory
    mov x20, x0                 // 1: name2 is a directory
    address x0, name1
    address x1, prefix
    bl strcpy
    address x0, prefix
    bl basename
    strb wzr, [x0]              // prefix = directory part of name1
    cbnz x19, 1f
    address x0, name1
    bl compare_target
    leave
1:
    address x0, dta
    mov x1, #280
    dos 0x1a
    address x0, name1
    mov x1, #0
    dos 0x4e
    cbz x1, 2f
    address x0, name1
    bl puts
    say " - File not found\r\n"
    leave
2:
    address x0, prefix
    address x1, dta
    add x1, x1, #24
    address x2, path1
    bl join_path_prefix
    address x0, path1
    bl compare_target
    dos 0x4f
    cbz x1, 2b
    leave

// x0 = file1 path: works out file2 from name2 and compares.
compare_target:
    enter
    mov x19, x0
    mov x0, x19
    bl basename
    mov x21, x0                 // file1's name
    address x0, name2
    bl is_directory
    cbz x0, 1f
    address x0, name2
    mov x1, x21
    address x2, path2
    bl join_path
    b 3f
1:
    address x0, name2
    bl has_wild
    cbz x0, 2f
    address x0, name2
    bl basename
    mov x1, x0
    mov x0, x21
    address x2, scratch
    bl apply_template
    address x0, name2
    address x1, path2
    bl strcpy
    address x0, path2
    bl basename
    strb wzr, [x0]
    address x0, path2
    address x1, scratch
    bl strcat
    b 3f
2:
    address x0, name2
    address x1, path2
    bl strcpy
3:
    mov x0, x19
    address x1, path2
    bl compare_files
    leave

// x0 = directory prefix (may be empty), x1 = name, x2 = output.
join_path_prefix:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x1
    mov x20, x2
    mov x1, x2
    bl strcpy
    mov x0, x19
    mov x1, x20
    bl strcat
    ldp x19, x20, [sp], #16
    unframe

// x0, x1 = paths.
compare_files:
    enter
    mov x19, x0
    mov x20, x1
    say "Comparing "
    mov x0, x19
    bl strupr
    mov x0, x19
    bl puts
    say " and "
    mov x0, x20
    bl strupr
    mov x0, x20
    bl puts
    say "...\r\n"
    mov x0, x19
    mov x1, #0
    bl fopen
    cbnz x1, open1_error
    mov x21, x0
    mov x0, x20
    mov x1, #0
    bl fopen
    cbnz x1, open2_error
    mov x22, x0
    mov x0, x21
    mov x1, #0
    mov x2, #2
    bl fseek
    mov x23, x0
    mov x0, x22
    mov x1, #0
    mov x2, #2
    bl fseek
    mov x24, x0
    mov x0, x21
    mov x1, #0
    mov x2, #0
    bl fseek
    mov x0, x22
    mov x1, #0
    mov x2, #0
    bl fseek
    cmp x23, x24
    b.eq 1f
    say "Files are different sizes\r\n"
    b close_both
1:
    mov x25, #0                 // offset
    mov x26, #0                 // mismatches
2:
    mov x0, x21
    address x1, buffer1
    mov x2, #4096
    bl fread
    cbnz x1, 8f
    mov x27, x0
    cbz x27, 8f
    mov x0, x22
    address x1, buffer2
    mov x2, x27
    bl fread
    mov x28, #0
3:
    cmp x28, x27
    b.hs 6f
    address x1, buffer1
    ldrb w2, [x1, x28]
    address x1, buffer2
    ldrb w3, [x1, x28]
    cmp w2, w3
    b.eq 5f
    stp x2, x3, [sp, #-16]!
    say "Compare error at OFFSET "
    add x0, x25, x28
    mov x1, #0
    bl hex_trimmed
    bl crlf
    say "file1 = "
    ldr x0, [sp]
    mov x1, #2
    bl put_hex
    bl crlf
    say "file2 = "
    ldr x0, [sp, #8]
    mov x1, #2
    bl put_hex
    bl crlf
    add sp, sp, #16
    add x26, x26, #1
    cmp x26, #10
    b.lo 5f
    say "10 Mismatches - ending compare\r\n"
    b close_both
5:
    add x28, x28, #1
    b 3b
6:
    add x25, x25, x27
    b 2b
8:
    cbnz x26, close_both
    say "Files compare OK\r\n"
close_both:
    mov x0, x22
    bl fclose
    mov x0, x21
    bl fclose
    leave
open2_error:
    mov x23, x0
    mov x0, x21
    bl fclose
    mov x0, x23
    bl print_error
    leave
open1_error:
    bl print_error
    leave

// x0 = value: hexadecimal without leading zeros.
hex_trimmed:
    frame
    mov x1, #1
    mov x2, x0
1:
    lsr x2, x2, #4
    cbz x2, 2f
    add x1, x1, #1
    b 1b
2:
    bl put_hex
    unframe

.section .rodata
more_question: .asciz "Compare more files (Y/N) ? "
.section .bss
.balign 8
dta: .skip 288
name1: .skip 256
name2: .skip 256
prefix: .skip 256
path1: .skip 256
path2: .skip 256
scratch: .skip 256
line: .skip 132
buffer1: .skip 4096
buffer2: .skip 4096
