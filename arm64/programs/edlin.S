// SPDX-License-Identifier: MIT
// EDLIN [d:][path]filename [/B] (v4.0/src/CMD/EDLIN): the line editor.
// Commands: [n] edit, [n]I insert, [r]L list, [r]P page, [r]D delete,
// [r][?]S text search, [r][?]R old^Znew replace, r,n[,c]C copy, r,nM move,
// [n]T file transfer, [n]A append, [n]W write, E end (keeps NAME.BAK),
// Q quit. Line numbers may be n, ".", "#", +n or -n. The whole file is held
// in memory, so A and W only report.
.include "lib.inc"
.equ MAX_LINES, 16384
.equ POOL_SIZE, 1048576
.equ LINE_MAX, 253

main:
    enter
    mov x19, x0
    bl next_arg
    mov x19, x1
    ldrb w2, [x0]
    cbz w2, no_name
    address x1, file_name
    bl strcpy
1:
    mov x0, x19                 // /B: ignore ^Z in the file
    bl next_arg
    mov x19, x1
    ldrb w2, [x0]
    cbz w2, 2f
    ldrb w0, [x0, #1]
    bl toupper
    cmp w0, #'B'
    b.ne 1b
    address x9, binary_mode
    mov x2, #1
    str x2, [x9]
    b 1b
2:
    address x0, file_name
    bl strupr
    address x9, line_count
    str xzr, [x9]
    address x9, current
    mov x2, #1
    str x2, [x9]
    address x0, file_name
    mov x1, #0
    bl fopen
    cbz x1, 3f
    say "New file\r\n"
    address x9, new_file
    mov x2, #1
    str x2, [x9]
    b command_loop
3:
    mov x20, x0
    mov x0, x20
    mov x1, #0                  // insert at the start
    bl read_lines_into
    mov x0, x20
    bl fclose
    address x9, load_partial
    ldr x10, [x9]
    address x9, partial_load
    str x10, [x9]
    address x9, load_offset     // T loads later must not move it
    ldr x10, [x9]
    address x9, partial_offset
    str x10, [x9]
    say "End of input file\r\n"
command_loop:
    mov x0, #'*'
    bl putc
    address x0, input
    mov w2, #LINE_MAX
    strb w2, [x0]
    bl read_console_line
    mov x19, x0
    bl execute
    b command_loop
no_name:
    say "File name must be specified\r\n"
    mov x0, #1
    leave

// x0 = command text.
execute:
    enter
    mov x19, x0
    mov x20, #0                 // argument count
    address x21, args
1:
    mov x0, x19
    bl skip_blanks
    mov x19, x0
    ldrb w2, [x19]
    cmp w2, #'?'
    b.eq 2f
    cmp w2, #'0'
    b.lo 21f
    cmp w2, #'9'
    b.ls 3f
21:
    cmp w2, #'.'
    b.eq 3f
    cmp w2, #'#'
    b.eq 3f
    cmp w2, #'+'
    b.eq 3f
    cmp w2, #'-'
    b.eq 3f
    cmp w2, #','
    b.ne 6f
    // empty argument
    cmp x20, #4
    b.hs bad
    mov x3, #-1
    str x3, [x21, x20, lsl #3]
    add x20, x20, #1
    add x19, x19, #1
    b 1b
2:
    address x9, query
    mov x2, #1
    str x2, [x9]
    add x19, x19, #1
    b 1b
3:
    mov x0, x19
    bl parse_line_number
    cbnz x1, bad
    mov x19, x2
    cmp x20, #4
    b.hs bad
    str x0, [x21, x20, lsl #3]
    add x20, x20, #1
    mov x0, x19
    bl skip_blanks
    mov x19, x0
    ldrb w2, [x19]
    cmp w2, #','
    b.ne 6f
    add x19, x19, #1
    // a trailing comma before the command means "empty next argument"
    mov x0, x19
    bl skip_blanks
    ldrb w2, [x0]
    cmp w2, #','
    b.eq 1b
    bl is_number_start
    cbnz x0, 1b
    mov x3, #-1
    str x3, [x21, x20, lsl #3]
    add x20, x20, #1
    b 1b
6:
    address x9, arg_count
    str x20, [x9]
    ldrb w0, [x19]
    add x22, x19, #1            // text after the command letter
    cbz w0, edit_command
    bl toupper
    cmp w0, #'I'
    b.eq do_insert
    cmp w0, #'L'
    b.eq do_list
    cmp w0, #'P'
    b.eq do_page
    cmp w0, #'D'
    b.eq do_delete
    cmp w0, #'S'
    b.eq do_search
    cmp w0, #'R'
    b.eq do_replace
    cmp w0, #'C'
    b.eq do_copy
    cmp w0, #'M'
    b.eq do_move
    cmp w0, #'T'
    b.eq do_transfer
    cmp w0, #'A'
    b.eq do_append
    cmp w0, #'W'
    b.eq do_write
    cmp w0, #'E'
    b.eq do_end
    cmp w0, #'Q'
    b.eq do_quit
bad:
    say "Entry error\r\n"
done:
    address x9, query
    str xzr, [x9]
    leave

// x0 = text. Returns x0 = 1 if a line number starts there.
is_number_start:
    ldrb w1, [x0]
    cmp w1, #'0'
    b.lo 1f
    cmp w1, #'9'
    b.ls 2f
1:
    cmp w1, #'.'
    b.eq 2f
    cmp w1, #'#'
    b.eq 2f
    cmp w1, #'+'
    b.eq 2f
    cmp w1, #'-'
    b.eq 2f
    mov x0, #0
    ret
2:
    mov x0, #1
    ret

// x0 = text: n, ".", "#", +n, -n. Returns x0 = 1-based line (may exceed
// the count), x1 = 0 / 1 error, x2 = text after it.
parse_line_number:
    frame
    ldrb w3, [x0]
    address x9, current
    ldr x4, [x9]
    cmp w3, #'.'
    b.ne 1f
    add x2, x0, #1
    mov x0, x4
    b 8f
1:
    cmp w3, #'#'
    b.ne 2f
    add x2, x0, #1
    address x9, line_count
    ldr x0, [x9]
    add x0, x0, #1
    b 8f
2:
    cmp w3, #'+'
    b.eq 3f
    cmp w3, #'-'
    b.eq 3f
    bl parse_dec
    cbnz x1, 9f
    cbz x0, 9f
    b 8f
3:
    stp x3, x4, [sp, #-16]!
    add x0, x0, #1
    bl parse_dec
    ldp x3, x4, [sp], #16
    cbnz x1, 9f
    cmp w3, #'+'
    b.ne 4f
    add x0, x4, x0
    b 8f
4:
    subs x0, x4, x0
    b.gt 8f
    mov x0, #1
8:
    mov x1, #0
    unframe
9:
    mov x1, #1
    unframe

// x0 = argument index, x1 = default. Returns x0 = value.
arg:
    address x9, arg_count
    ldr x9, [x9]
    cmp x0, x9
    b.hs 1f
    address x9, args
    ldr x2, [x9, x0, lsl #3]
    cmn x2, #1
    b.eq 1f
    mov x0, x2
    ret
1:
    mov x0, x1
    ret

// ---------------------------------------------------------------------------
// Line storage.

// x0 = text, x1 = length. Returns x0 = pooled copy (NUL-terminated).
pool_string:
    address x9, pool_used
    ldr x2, [x9]
    add x3, x2, x1
    add x3, x3, #1
    mov x4, #POOL_SIZE
    cmp x3, x4
    b.hi 3f
    str x3, [x9]
    address x9, pool
    add x5, x9, x2
    mov x6, #0
1:
    cmp x6, x1
    b.hs 2f
    ldrb w7, [x0, x6]
    strb w7, [x5, x6]
    add x6, x6, #1
    b 1b
2:
    strb wzr, [x5, x6]
    mov x0, x5
    ret
3:
    mov x0, #0
    ret

// x0 = 0-based position, x1 = pooled text. Returns x1 = 0 / 1 when full.
insert_line:
    address x9, line_count
    ldr x2, [x9]
    mov x3, #MAX_LINES
    cmp x2, x3
    b.hs 3f
    cbz x1, 3f
    address x4, lines
    mov x5, x2
1:
    cmp x5, x0
    b.ls 2f
    sub x6, x5, #1
    ldr x7, [x4, x6, lsl #3]
    str x7, [x4, x5, lsl #3]
    mov x5, x6
    b 1b
2:
    str x1, [x4, x0, lsl #3]
    add x2, x2, #1
    str x2, [x9]
    mov x1, #0
    ret
3:
    mov x1, #1
    ret

// x0 = first (0-based), x1 = count: removes those lines.
delete_lines:
    address x9, line_count
    ldr x2, [x9]
    address x4, lines
    add x3, x0, x1              // source
1:
    cmp x3, x2
    b.hs 2f
    ldr x5, [x4, x3, lsl #3]
    str x5, [x4, x0, lsl #3]
    add x0, x0, #1
    add x3, x3, #1
    b 1b
2:
    sub x2, x2, x1
    str x2, [x9]
    ret

// x0 = 1-based line: prints "     n:*text" (the star marks the current).
print_line:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    mov x1, #8
    bl put_dec
    mov x0, #':'
    bl putc
    address x9, current
    ldr x2, [x9]
    mov x0, #' '
    cmp x2, x19
    b.ne 1f
    mov x0, #'*'
1:
    bl putc
    address x9, lines
    sub x2, x19, #1
    ldr x0, [x9, x2, lsl #3]
    bl puts
    bl crlf
    ldp x19, x20, [sp], #16
    unframe

// x0 = handle, x1 = position (0-based): reads lines into the buffer.
// Returns x0 = lines read.
read_lines_into:
    enter
    mov x19, x1
    mov x20, #0
    mov x21, x0
    mov x1, x0
    address x0, reader
    bl lr_init
    address x9, binary_mode     // /B: ^Z does not end the text
    ldr x9, [x9]
    cbz x9, 1f
    address x0, reader
    bl lr_binary
1:
    // The file offset of the next line: where a partial load stops.
    mov x0, x21
    mov x1, #0
    mov x2, #1
    bl fseek
    address x9, reader
    ldp x10, x11, [x9, #8]      // position, length
    sub x11, x11, x10
    sub x0, x0, x11
    address x9, load_offset
    str x0, [x9]
    address x0, reader
    address x1, scratch
    mov x2, #LINE_MAX + 1
    bl lr_getline
    cbnz x1, 2f
    mov x1, x0
    address x0, scratch
    bl pool_string
    mov x1, x0
    add x0, x19, x20
    bl insert_line
    cbnz x1, 3f
    add x20, x20, #1
    b 1b
3:
    say "Insufficient memory\r\n"
    address x9, load_partial    // the initial load: E copies the rest
    mov x10, #1
    str x10, [x9]
2:
    mov x0, x20
    leave

// ---------------------------------------------------------------------------
// Commands. They run inside execute's frame (x22 = text after the letter).

edit_command:
    address x9, arg_count
    ldr x2, [x9]
    cbz x2, 1f
    mov x0, #0
    mov x1, #0
    bl arg
    b 2f
1:
    address x9, current         // Enter alone: the next line
    ldr x0, [x9]
    add x0, x0, #1
    address x9, edited_once
    ldr x2, [x9]
    cbnz x2, 2f
    sub x0, x0, #1
2:
    address x9, line_count
    ldr x2, [x9]
    cmp x0, x2
    b.hi done
    cbz x0, done
    address x9, current
    str x0, [x9]
    address x9, edited_once
    mov x2, #1
    str x2, [x9]
    mov x23, x0
    bl print_line
    mov x0, x23
    mov x1, #8
    bl put_dec
    say ":*"
    address x0, input
    mov w2, #LINE_MAX
    strb w2, [x0]
    bl read_console_line
    ldrb w2, [x0]
    cbz w2, done                // Enter keeps the line
    cmp w2, #0x1a
    b.eq done
    mov x24, x0
    bl strlen
    mov x1, x0
    mov x0, x24
    bl pool_string
    cbz x0, done
    address x9, lines
    sub x2, x23, #1
    str x0, [x9, x2, lsl #3]
    b done

do_insert:
    address x9, current
    ldr x1, [x9]
    mov x0, #0
    bl arg
    address x9, line_count
    ldr x2, [x9]
    add x2, x2, #1
    cmp x0, x2
    csel x23, x0, x2, ls        // insert before this 1-based line
1:
    mov x0, x23
    mov x1, #8
    bl put_dec
    say ":*"
    address x0, input
    mov w2, #LINE_MAX
    strb w2, [x0]
    bl read_console_line
    mov x24, x0
    bl strlen
    mov x25, x0
    cbz x25, 2f
    sub x2, x25, #1
    ldrb w3, [x24, x2]
    cmp w3, #0x1a
    b.ne 2f
    // A ^Z ends input (text before it is kept as the last line).
    cbz x2, 3f
    mov x1, x2
    mov x0, x24
    bl pool_string
    mov x1, x0
    sub x0, x23, #1
    bl insert_line
    add x23, x23, #1
    b 3f
2:
    mov x0, x24
    mov x1, x25
    bl pool_string
    mov x1, x0
    sub x0, x23, #1
    bl insert_line
    cbnz x1, 3f
    add x23, x23, #1
    b 1b
3:
    address x9, current
    str x23, [x9]
    b done

// [first][,last]L: default 11 lines before the current through 23 lines.
do_list:
    address x9, current
    ldr x23, [x9]
    subs x1, x23, #11
    b.gt 1f
    mov x1, #1
1:
    mov x0, #0
    bl arg
    mov x24, x0
    add x1, x24, #22
    mov x0, #1
    bl arg
    mov x25, x0
    bl list_range
    b done

// [first][,last]P: pages from the current line, and makes the last current.
do_page:
    address x9, current
    ldr x1, [x9]
    address x9, edited_once
    ldr x2, [x9]
    cbz x2, 1f
    add x1, x1, #1
1:
    mov x0, #0
    bl arg
    mov x24, x0
    add x1, x24, #22
    mov x0, #1
    bl arg
    mov x25, x0
    bl list_range
    address x9, line_count
    ldr x2, [x9]
    cmp x25, x2
    csel x25, x25, x2, ls
    cbz x25, done
    address x9, current
    str x25, [x9]
    address x9, edited_once
    mov x2, #1
    str x2, [x9]
    b done

// Prints lines x24..x25 (clipped).
list_range:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x24
    address x9, line_count
    ldr x20, [x9]
    cmp x25, x20
    csel x20, x25, x20, ls
1:
    cmp x19, x20
    b.hi 2f
    cbz x19, 11f
    mov x0, x19
    bl print_line
11:
    add x19, x19, #1
    b 1b
2:
    ldp x19, x20, [sp], #16
    unframe

do_delete:
    address x9, current
    ldr x1, [x9]
    mov x0, #0
    bl arg
    mov x23, x0
    mov x1, x23
    mov x0, #1
    bl arg
    mov x24, x0
    cmp x24, x23
    b.lo bad
    address x9, line_count
    ldr x2, [x9]
    cmp x23, x2
    b.hi done
    cmp x24, x2
    csel x24, x24, x2, ls
    sub x0, x23, #1
    sub x1, x24, x23
    add x1, x1, #1
    bl delete_lines
    address x9, current
    str x23, [x9]
    b done

// [first][,last][?]Stext
do_search:
    address x9, current
    ldr x1, [x9]
    add x1, x1, #1
    mov x0, #0
    bl arg
    mov x23, x0
    address x9, line_count
    ldr x1, [x9]
    mov x0, #1
    bl arg
    mov x24, x0
    ldrb w2, [x22]
    cbz w2, 1f
    mov x0, x22
    address x1, last_search
    bl strcpy
1:
    address x9, line_count
    ldr x2, [x9]
    cmp x24, x2
    csel x24, x24, x2, ls
2:
    cmp x23, x24
    b.hi not_found
    cbz x23, 3f
    address x9, lines
    sub x2, x23, #1
    ldr x0, [x9, x2, lsl #3]
    address x1, last_search
    mov x2, #0
    bl strstr
    cbz x0, 3f
    address x9, current
    str x23, [x9]
    mov x0, x23
    bl print_line
    address x9, query
    ldr x2, [x9]
    cbz x2, done
    address x0, ok_question
    bl ask_yn
    cbnz x0, done
3:
    add x23, x23, #1
    b 2b
not_found:
    say "Not found\r\n"
    b done

// [first][,last][?]Rold^Znew
do_replace:
    address x9, current
    ldr x1, [x9]
    add x1, x1, #1
    mov x0, #0
    bl arg
    mov x23, x0
    address x9, line_count
    ldr x1, [x9]
    mov x0, #1
    bl arg
    mov x24, x0
    // Split at ^Z: old text, new text.
    address x0, old_text
    address x1, new_text
    strb wzr, [x1]
    mov x2, x22
    mov x3, x0
1:
    ldrb w4, [x2], #1
    cbz w4, 3f
    cmp w4, #0x1a
    b.eq 2f
    strb w4, [x3], #1
    b 1b
2:
    strb wzr, [x3]
    mov x0, x2
    address x1, new_text
    bl strcpy
    b 4f
3:
    strb wzr, [x3]
4:
    address x0, old_text
    ldrb w2, [x0]
    cbz w2, bad
    mov x26, #0                 // replaced anything
    address x9, line_count
    ldr x2, [x9]
    cmp x24, x2
    csel x24, x24, x2, ls
5:
    cmp x23, x24
    b.hi 9f
    cbz x23, 8f
    address x9, lines
    sub x2, x23, #1
    ldr x25, [x9, x2, lsl #3]
    mov x0, x25
    address x1, old_text
    mov x2, #0
    bl strstr
    cbz x0, 8f
    // Build the replaced line in scratch.
    sub x27, x0, x25            // prefix length
    address x1, scratch
    mov x2, #0
6:
    cmp x2, x27
    b.hs 61f
    ldrb w3, [x25, x2]
    strb w3, [x1, x2]
    add x2, x2, #1
    b 6b
61:
    strb wzr, [x1, x2]
    address x0, scratch
    address x1, new_text
    bl strcat
    address x0, old_text
    bl strlen
    add x1, x25, x27
    add x1, x1, x0
    address x0, scratch
    bl strcat_from
    address x0, scratch
    bl strlen
    cmp x0, #LINE_MAX
    b.hi 8f
    mov x1, x0
    address x0, scratch
    bl pool_string
    cbz x0, 8f
    mov x28, x0
    address x9, query
    ldr x2, [x9]
    cbz x2, 7f
    address x9, lines           // show the proposed line, then ask
    sub x2, x23, #1
    ldr x3, [x9, x2, lsl #3]
    str x28, [x9, x2, lsl #3]
    stp x3, x2, [sp, #-16]!
    mov x0, x23
    bl print_line
    address x0, ok_question
    bl ask_yn
    ldp x3, x2, [sp], #16
    cbnz x0, 71f
    address x9, lines
    str x3, [x9, x2, lsl #3]
    b 8f
7:
    address x9, lines
    sub x2, x23, #1
    str x28, [x9, x2, lsl #3]
    mov x0, x23
    bl print_line
71:
    mov x26, #1
    address x9, current
    str x23, [x9]
8:
    add x23, x23, #1
    b 5b
9:
    cbnz x26, done
    say "Not found\r\n"
    b done

// x0 = destination string, x1 = text to append.
strcat_from:
    b strcat

// first,last,target[,count]C
do_copy:
    address x9, current
    ldr x1, [x9]
    mov x0, #0
    bl arg
    mov x23, x0
    mov x1, x23
    mov x0, #1
    bl arg
    mov x24, x0
    mov x0, #2
    mov x1, #0
    bl arg
    mov x25, x0
    cbz x25, bad
    mov x0, #3
    mov x1, #1
    bl arg
    mov x26, x0
    cmp x24, x23
    b.lo bad
    address x9, line_count
    ldr x2, [x9]
    cmp x24, x2
    b.hi bad
    cmp x25, x23
    b.ls 1f
    cmp x25, x24
    b.ls bad                    // target inside the range
1:
    sub x27, x24, x23
    add x27, x27, #1            // lines per copy
    mov x28, #0                 // copied
2:
    cmp x26, #0
    b.eq 5f
    mov x3, #0
3:
    cmp x3, x27
    b.hs 4f
    // Source shifts when the target is before it.
    add x0, x23, x3
    cmp x25, x23
    b.hi 31f
    add x0, x0, x28
31:
    address x9, lines
    sub x0, x0, #1
    ldr x1, [x9, x0, lsl #3]
    add x0, x25, x28
    sub x0, x0, #1
    stp x3, xzr, [sp, #-16]!
    bl insert_line
    ldp x3, xzr, [sp], #16
    cbnz x1, 5f
    add x28, x28, #1
    add x3, x3, #1
    b 3b
4:
    sub x26, x26, #1
    b 2b
5:
    address x9, current
    str x25, [x9]
    b done

// first,last,targetM
do_move:
    address x9, current
    ldr x1, [x9]
    mov x0, #0
    bl arg
    mov x23, x0
    mov x1, x23
    mov x0, #1
    bl arg
    mov x24, x0
    mov x0, #2
    mov x1, #0
    bl arg
    mov x25, x0
    cbz x25, bad
    cmp x24, x23
    b.lo bad
    address x9, line_count
    ldr x2, [x9]
    cmp x24, x2
    b.hi bad
    cmp x25, x23
    b.ls 1f
    cmp x25, x24
    b.ls bad
1:
    sub x27, x24, x23
    add x27, x27, #1
    // Copy the pointers aside, delete, insert at the adjusted target.
    address x9, lines
    address x10, move_buffer
    mov x3, #0
2:
    cmp x3, x27
    b.hs 3f
    add x4, x23, x3
    sub x4, x4, #1
    ldr x5, [x9, x4, lsl #3]
    str x5, [x10, x3, lsl #3]
    add x3, x3, #1
    b 2b
3:
    sub x0, x23, #1
    mov x1, x27
    bl delete_lines
    cmp x25, x24
    b.ls 4f
    sub x25, x25, x27
4:
    mov x26, #0
5:
    cmp x26, x27
    b.hs 6f
    address x10, move_buffer
    ldr x1, [x10, x26, lsl #3]
    add x0, x25, x26
    sub x0, x0, #1
    bl insert_line
    add x26, x26, #1
    b 5b
6:
    address x9, current
    str x25, [x9]
    b done

// [line]Tfilename: inserts the file before the line.
do_transfer:
    address x9, current
    ldr x1, [x9]
    mov x0, #0
    bl arg
    mov x23, x0
    mov x0, x22
    bl skip_blanks
    mov x22, x0
    ldrb w2, [x22]
    cbz w2, bad
    mov x0, x22
    mov x1, #0
    bl fopen
    cbz x1, 1f
    say "File not found\r\n"
    b done
1:
    mov x24, x0
    address x9, line_count
    ldr x2, [x9]
    add x2, x2, #1
    cmp x23, x2
    csel x23, x23, x2, ls
    mov x0, x24
    sub x1, x23, #1
    bl read_lines_into
    mov x0, x24
    bl fclose
    address x9, current
    str x23, [x9]
    b done

do_append:
    say "End of input file\r\n"
    b done

do_write:
    b done

do_end:
    address x9, new_file
    ldr x2, [x9]
    cbnz x2, 2f
    // NAME.EXT -> NAME.BAK (an old backup goes first).
    address x0, file_name
    address x1, backup_name
    bl strcpy
    address x0, backup_name
    bl basename
    bl lib_last_dot
    address x1, backup_name
    address x0, backup_name
    bl basename
    mov x23, x0
    bl lib_last_dot
    cmp x0, #0
    b.ge 1f
    mov x0, x23
    bl strlen
1:
    add x0, x23, x0
    address x1, bak_suffix
    mov x2, x0
    mov x0, x1
    mov x1, x2
    bl strcpy
    address x0, backup_name
    address x1, file_name
    bl strcmpi
    cbnz x0, 1f                 // editing a .BAK file: no backup, so a
    address x9, partial_load    // partial load has nowhere to copy from
    ldr x9, [x9]
    cbz x9, 2f
    say "Cannot end a partly loaded .BAK file\r\n"
    b done
1:
    address x0, backup_name
    dos 0x41
    address x0, file_name
    address x1, backup_name
    dos 0x56
2:
    // A partial load needs NAME.BAK for the unread rest: open it before
    // the file is rewritten.
    address x9, partial_load
    ldr x9, [x9]
    cbz x9, 21f
    address x0, backup_name
    mov x1, #0
    bl fopen
    cbz x1, 20f
    say "Cannot open the backup file; file not written\r\n"
    b done
20:
    address x9, bak_handle
    str x0, [x9]
21:
    address x0, file_name
    mov x1, #0
    bl fcreate
    cbz x1, 3f
    say "Cannot create file\r\n"
    b done
3:
    mov x23, x0
    address x9, line_count
    ldr x24, [x9]
    mov x25, #0
4:
    cmp x25, x24
    b.hs 5f
    address x9, lines
    ldr x26, [x9, x25, lsl #3]
    mov x0, x26
    bl strlen
    mov x2, x0
    mov x1, x26
    mov x0, x23
    bl write_checked
    mov x0, x23
    address x1, crlf_bytes
    mov x2, #2
    bl write_checked
    add x25, x25, #1
    b 4b
5:
    // A partial load: the lines never read follow, from the original
    // (now NAME.BAK).
    address x9, partial_load
    ldr x9, [x9]
    cbz x9, 7f
    address x9, bak_handle
    ldr x0, [x9]
    mov x24, x0
    address x9, partial_offset
    ldr x1, [x9]
    mov x2, #0
    bl fseek
    mov x25, #0
6:
    mov x0, x24
    address x1, scratch
    mov x2, #1024
    bl fread
    cbnz x1, 61f
    cbz x0, 61f
    mov x2, x0
    address x9, binary_mode     // text ends at ^Z
    ldr x9, [x9]
    cbnz x9, 62f
    address x1, scratch
    mov x3, #0
63:
    ldrb w4, [x1, x3]
    cmp w4, #0x1a
    b.eq 64f
    add x3, x3, #1
    cmp x3, x2
    b.lo 63b
    b 62f
64:
    mov x2, x3
    mov x25, #1                 // stop after this piece
62:
    mov x0, x23
    address x1, scratch
    bl write_checked
    cmp x25, #1
    b.ne 6b
61:
    mov x0, x24
    bl fclose
7:
    mov x0, x23
    address x1, eof_byte
    mov x2, #1
    bl write_checked
    mov x0, x23
    bl fclose
    mov x0, #0
    bl exit

// x0 = handle, x1 = data, x2 = count: a short write ends EDLIN (errorlevel 1).
write_checked:
    frame
    str x19, [sp, #-16]!
    mov x19, x2
    cbz x19, 1f
    bl fwrite
    cbnz x1, 2f
    cmp x0, x19
    b.lo 2f
1:
    ldr x19, [sp], #16
    unframe
2:
    say "Disk full. Edits lost.\r\n"
    mov x0, #1
    bl exit

do_quit:
    address x0, abort_question
    bl ask_yn
    cbz x0, done
    mov x0, #0
    bl exit

.section .rodata
ok_question: .asciz "O.K.? "
abort_question: .asciz "Abort edit (Y/N)? "
bak_suffix: .asciz ".BAK"
crlf_bytes: .ascii "\r\n"
eof_byte: .byte 0x1a
.section .bss
.balign 8
binary_mode: .skip 8
partial_load: .skip 8
load_partial: .skip 8
load_offset: .skip 8
partial_offset: .skip 8
bak_handle: .skip 8
new_file: .skip 8
line_count: .skip 8
current: .skip 8
edited_once: .skip 8
query: .skip 8
arg_count: .skip 8
args: .skip 32
pool_used: .skip 8
file_name: .skip 256
backup_name: .skip 256
input: .skip 260
scratch: .skip 1024
last_search: .skip 256
old_text: .skip 256
new_text: .skip 256
reader: .skip LR_SIZE
lines: .skip 8 * MAX_LINES
move_buffer: .skip 8 * MAX_LINES
pool: .skip POOL_SIZE
