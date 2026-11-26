// SPDX-License-Identifier: MIT
// COMMAND file commands (TCMD1A/TCMD1B/COPY.ASM in COMMAND): DIR with /W and
// /P, DEL/ERASE with wildcards, /P and the *.* confirmation, REN with
// templates, and COPY with wildcards, directory targets, "+" concatenation
// and device sources such as CON (copied up to ^Z).
.equ WILD_LIST_SIZE, 32768
.section .text

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

// x0 = string. Returns x0 = length.
cstrlen:
    mov x1, x0
1:
    ldrb w2, [x1], #1
    cbnz w2, 1b
    sub x0, x1, x0
    sub x0, x0, #1
    ret

// x0 = path. Returns x0 = length of its directory part (through the last
// '\' or ':'), 0 when it is a bare name.
dir_prefix_len:
    mov x1, #0
    mov x2, #0
1:
    ldrb w3, [x0, x1]
    cbz w3, 3f
    add x1, x1, #1
    cmp w3, #'\\'
    b.eq 2f
    cmp w3, #':'
    b.ne 1b
2:
    mov x2, x1
    b 1b
3:
    mov x0, x2
    ret

// x0 = string. Returns x0 = index of its last '.', or -1.
last_dot:
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

// x0 = path. Returns x0 = 1 if it is empty or ends in '\' or ':'.
ends_with_sep:
    ldrb w1, [x0]
    cbz w1, 2f
1:
    ldrb w2, [x0, #1]
    cbz w2, 3f
    add x0, x0, #1
    b 1b
3:
    ldrb w1, [x0]
    cmp w1, #'\\'
    b.eq 2f
    cmp w1, #':'
    b.eq 2f
    mov x0, #0
    ret
2:
    mov x0, #1
    ret

// x0 = path buffer (256 bytes): appends "\*.*" (or "*.*" after a separator).
append_star:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    bl ends_with_sep
    mov x20, x0
    mov x0, x19
    bl cstrlen
    cmp x0, #250
    b.hs 2f
    add x1, x19, x0
    cbnz x20, 1f
    cbz x0, 1f                  // "" and "B:" take "*.*" as they are
    ldurb w2, [x1, #-1]
    cmp w2, #':'
    b.eq 1f
    mov w2, #'\\'
    strb w2, [x1], #1
1:
    address x0, c3_star_dot_star
    bl copy_cstring
2:
    ldp x19, x20, [sp], #16
    unframe

// x0 = prefix, x1 = prefix length, x2 = name, x3 = 256-byte output.
// Returns x1 = 1 if the result had to be truncated.
join_path:
    mov x4, #0
1:
    cmp x4, x1
    b.hs 2f
    ldrb w5, [x0, x4]
    strb w5, [x3, x4]
    add x4, x4, #1
    b 1b
2:
    ldrb w5, [x2], #1
    strb w5, [x3, x4]
    cbz w5, 3f
    add x4, x4, #1
    cmp x4, #255
    b.lo 2b
    strb wzr, [x3, x4]
    mov x1, #1
    ret
3:
    mov x1, #0
    ret

// x0 = source part, x1 = its length, x2 = template part, x3 = its length,
// x4 = output cursor. Returns x0 = new cursor. '?' keeps the source
// character, '*' keeps the rest of the source part.
template_part:
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

// x0 = name, x1 = template ("*.BAK", "A?C.*"), x2 = output (256 bytes).
apply_template:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x0, x20
    address x1, c3_star
    bl strcmp
    cbz x0, 7f
    mov x0, x20
    address x1, c3_star_dot_star
    bl strcmp
    cbz x0, 7f
    mov x0, x19
    bl cstrlen
    mov x22, x0
    mov x0, x19
    bl last_dot
    mov x23, x0
    mov x0, x20
    bl cstrlen
    mov x24, x0
    mov x0, x20
    bl last_dot
    mov x25, x0
    cmp x23, #0
    b.ge 1f
    mov x26, x22                // name without extension
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
    mov x9, x24                 // template without extension
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
    bl template_part
    mov x21, x0
    cbz x10, 6f
    mov w5, #'.'
    strb w5, [x21], #1
    mov x0, x27
    mov x1, x28
    mov x2, x11
    mov x3, x10
    mov x4, x21
    bl template_part
    cmp x0, x21
    b.ne 5f
    sub x0, x0, #1              // empty extension: drop the dot
5:
    strb wzr, [x0]
    leave
6:
    strb wzr, [x21]
    leave
7:
    mov x0, x19
    mov x1, x21
    bl copy_cstring
    leave

// x0 = pattern, x1 = attribute mask. Fills wild_list with the matching
// names (not "." or ".."), each NUL terminated, ending with an empty name.
// Returns x1 = 0 and x0 = count, or x1 = 1 and x0 = DOS error.
wild_collect:
    enter
    mov x19, x0
    mov x20, x1
    bl dos_get_dta
    mov x21, x0
    mov x22, x2
    address x0, wild_dta
    mov x1, #280
    bl dos_set_dta
    address x23, wild_list
    mov x24, #0
    mov x25, #0
    mov x0, x19
    mov x1, x20
    bl dos_find_first
1:
    cbnz x1, 5f
    address x26, wild_dta
    add x26, x26, #24
    ldrb w2, [x26]
    cmp w2, #'.'
    b.ne 2f
    ldrb w2, [x26, #1]
    cbz w2, 4f
    cmp w2, #'.'
    b.ne 2f
    ldrb w2, [x26, #2]
    cbz w2, 4f
2:
    mov x0, x26
    bl cstrlen
    mov x27, x0
    add x2, x25, x0
    add x2, x2, #2
    mov x3, #WILD_LIST_SIZE
    cmp x2, x3
    b.hi 6f
    mov x0, x26
    add x1, x23, x25
    bl copy_cstring
    add x25, x25, x27
    add x25, x25, #1
    add x24, x24, #1
4:
    bl dos_find_next
    b 1b
5:
    cmp x0, #18
    b.eq 6f
    cmp x0, #2
    b.eq 6f
    mov x27, x0
    strb wzr, [x23, x25]
    mov x0, x21
    mov x1, x22
    bl dos_set_dta
    mov x0, x27
    mov x1, #1
    leave
6:
    strb wzr, [x23, x25]
    mov x0, x21
    mov x1, x22
    bl dos_set_dta
    mov x0, x24
    mov x1, #0
    leave

// x0 = entry in wild_list. Returns x0 = the next entry.
wild_next:
    ldrb w1, [x0], #1
    cbnz w1, wild_next
    ret

// x0 = DOS error code: prints COMMAND's message for it.
print_dos_error:
    frame
    address x1, c3_file_not_found
    cmp x0, #2
    b.eq 1f
    cmp x0, #18
    b.eq 1f
    address x1, c3_path_not_found
    cmp x0, #3
    b.eq 1f
    address x1, c3_access_denied
    cmp x0, #5
    b.eq 1f
    address x1, c3_disk_full
    cmp x0, #39
    b.eq 1f
    address x1, c3_sharing
    cmp x0, #32
    b.eq 1f
    address x1, file_error
1:
    mov x0, x1
    bl puts
    unframe

// x0 = question. Returns x0 = 1 for Y, 0 for N.
ask_yes_no:
    frame
    str x19, [sp, #-16]!
    mov x19, x0
1:
    mov x0, x19
    bl puts
    mov w8, #0x01
    bl dos_call
    bic w2, w0, #0x20
    address x0, newline
    str x2, [sp, #8]
    bl puts
    ldr x2, [sp, #8]
    cmp w2, #'Y'
    b.eq 2f
    cmp w2, #'N'
    b.ne 1b
    mov x0, #0
    b 3f
2:
    mov x0, #1
3:
    ldr x19, [sp], #16
    unframe

// x0 = value, x1 = width: right-aligned decimal padded with spaces.
print_number_width:
    frame
    stp x19, x20, [sp, #-16]!
    sub sp, sp, #32
    mov x20, x1
    mov x1, sp
    bl unsigned_to_string
    mov x19, x0
    bl cstrlen
    subs x20, x20, x0
    b.ls 2f
1:
    mov x0, #' '
    bl stdout_putc
    subs x20, x20, #1
    b.ne 1b
2:
    mov x0, x19
    bl puts
    add sp, sp, #32
    ldp x19, x20, [sp], #16
    unframe

// x0 = text, x1 = byte count, x2 = column width: prints the bytes and pads
// with spaces to the width.
put_padded:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, #0
1:
    cmp x22, x20
    b.hs 2f
    ldrb w0, [x19, x22]
    bl stdout_putc
    add x22, x22, #1
    b 1b
2:
    cmp x22, x21
    b.hs 3f
    mov x0, #' '
    bl stdout_putc
    add x22, x22, #1
    b 2b
3:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// x0 = token: cuts it at a '/' switch. Returns x0 = token, x1 = the switch
// letter upper-cased (0 if none).
split_switch:
    mov x1, #0
    mov x2, x0
1:
    ldrb w3, [x2]
    cbz w3, 2f
    cmp w3, #'/'
    b.eq 3f
    add x2, x2, #1
    b 1b
3:
    strb wzr, [x2]
    ldrb w1, [x2, #1]
    cmp w1, #'a'
    b.lo 2f
    cmp w1, #'z'
    b.hi 2f
    sub w1, w1, #32
2:
    ret

// ---------------------------------------------------------------------------
// DEL / ERASE [path] [/P]
cmd_del:
    enter
    mov x19, x0
    mov x28, #0                 // /P
    address x0, del_path
    strb wzr, [x0]
1:
    mov x0, x19
    bl next_word
    mov x19, x1
    ldrb w2, [x0]
    cbz w2, 3f
    bl split_switch
    cmp w1, #'P'
    b.ne 2f
    mov x28, #1
2:
    ldrb w2, [x0]
    cbz w2, 1b
    address x1, del_path
    bl copy_cstring
    b 1b
3:
    address x19, del_path
    ldrb w2, [x19]
    cbz w2, del_missing
    mov x0, x19
    bl has_wild
    cbnz x0, 4f
    mov x0, x19
    bl ends_with_sep
    cbnz x0, 31f
    mov x0, x19
    mov x1, #0
    bl dos_attributes
    cbnz x1, 4f
    tbz x0, #4, 4f
31:
    mov x0, x19                 // DEL directory = DEL directory\*.*
    bl append_star
4:
    mov x0, x19
    bl dir_prefix_len
    mov x20, x0
    cbnz x28, 5f
    add x0, x19, x20
    address x1, c3_star_dot_star
    bl strcmp
    cbz x0, 41f
    add x0, x19, x20
    address x1, c3_star
    bl strcmp
    cbnz x0, 5f
41:
    address x0, c3_all_files
    bl ask_yes_no
    cbz x0, del_done
5:
    mov x0, x19
    mov x1, #0
    bl wild_collect
    cbnz x1, del_error
    mov x22, #0
    cbz x0, del_not_found
    address x21, wild_list
6:
    ldrb w2, [x21]
    cbz w2, del_done
    mov x0, x19
    mov x1, x20
    mov x2, x21
    address x3, del_full
    bl join_path
    cbz x28, 7f
    address x0, del_full
    bl puts
    address x0, c3_delete_query
    bl ask_yes_no
    cbz x0, 8f
7:
    address x0, del_full
    mov w8, #0x41
    bl dos_call
    cbz x1, 8f
    bl print_dos_error
8:
    mov x0, x21
    bl wild_next
    mov x21, x0
    b 6b
del_not_found:
    mov x0, #2
del_error:
    bl print_dos_error
    b del_done
del_missing:
    address x0, c3_missing
    bl puts
del_done:
    leave

// ---------------------------------------------------------------------------
// REN / RENAME source newname: the new name is a template in the source's
// directory ("REN *.TXT *.BAK").
cmd_ren:
    enter
    bl next_word
    mov x19, x0
    mov x0, x1
    bl next_word
    mov x20, x0
    ldrb w2, [x19]
    cbz w2, ren_missing
    ldrb w2, [x20]
    cbz w2, ren_missing
    mov x0, x20
    bl dir_prefix_len
    cbnz x0, ren_invalid
    mov x0, x19
    bl dir_prefix_len
    mov x21, x0
    mov x0, x19
    bl has_wild
    mov x22, x0
    mov x0, x20
    bl has_wild
    orr x22, x22, x0
    cbnz x22, 1f
    mov x0, x19                 // plain names: files or directories
    mov x1, x21
    mov x2, x20
    address x3, ren_new
    bl join_path
    mov x0, x19
    address x1, ren_new
    bl dos_rename
    cbz x1, ren_done
    b ren_failed
1:
    mov x0, x19
    mov x1, #0
    bl wild_collect
    cbnz x1, ren_error
    cbz x0, ren_failed
    address x23, wild_list
2:
    ldrb w2, [x23]
    cbz w2, ren_done
    mov x0, x23
    mov x1, x20
    address x2, ren_name
    bl apply_template
    mov x0, x19
    mov x1, x21
    mov x2, x23
    address x3, ren_old
    bl join_path
    mov x0, x19
    mov x1, x21
    address x2, ren_name
    address x3, ren_new
    bl join_path
    address x0, ren_old
    address x1, ren_new
    bl dos_rename
    cbz x1, 3f
    address x0, c3_duplicate
    bl puts
3:
    mov x0, x23
    bl wild_next
    mov x23, x0
    b 2b
ren_error:
    cmp x0, #3
    b.ne ren_failed
    bl print_dos_error
    b ren_done
ren_failed:
    address x0, c3_duplicate
    bl puts
    b ren_done
ren_invalid:
    address x0, c3_invalid_parameter
    bl puts
    b ren_done
ren_missing:
    address x0, c3_missing
    bl puts
ren_done:
    leave

// ---------------------------------------------------------------------------
// x0 = source, x1 = destination, x2 = 1 to append. Returns x1 = 0, or
// x1 = 1 with x0 = DOS error (-1 when both name the same file).
copy_file:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x26, #0
    mov x0, x19
    address x1, copy_canon_a
    bl canonicalize_path
    cbnz x1, cf_error
    mov x0, x20
    address x1, copy_canon_b
    bl canonicalize_path
    cbnz x1, cf_error
    address x0, copy_canon_a
    address x1, copy_canon_b
    bl strcasecmp
    cbnz x0, 1f
    mov x0, #-1
    mov x1, #1
    leave
1:
    mov x0, x19
    bl dev_lookup
    mov x24, x0                 // device source: stop at ^Z
    mov x0, x19
    mov x1, #0
    bl dos_open
    cbnz x1, cf_error
    mov x22, x0
    cbz x21, 2f
    mov x0, x20
    mov x1, #2
    bl dos_open
    cbnz x1, cf_close_source
    mov x23, x0
    mov x1, #0
    mov x2, #2
    mov w8, #0x42
    bl dos_call
    cbnz x1, cf_close_both
    b 3f
2:
    mov x0, x20
    mov x1, #0
    bl dos_create
    cbnz x1, cf_close_source
    mov x23, x0
3:
    mov x0, x22
    address x1, io_buffer
    mov x2, #512
    bl dos_read
    cbnz x1, cf_close_both
    cbz x0, cf_done
    mov x25, x0
    cbz x24, 6f
    address x1, io_buffer
    mov x2, #0
4:
    cmp x2, x25
    b.hs 6f
    ldrb w3, [x1, x2]
    cmp w3, #0x1a
    b.eq 5f
    add x2, x2, #1
    b 4b
5:
    mov x25, x2
    mov x26, #1
6:
    cbz x25, 7f
    mov x0, x23
    address x1, io_buffer
    mov x2, x25
    bl dos_write
    cbnz x1, cf_close_both
    cmp x0, x25
    b.ne cf_full
7:
    cbnz x26, cf_done
    b 3b
cf_done:
    cbnz x24, 8f                // files keep their date and time
    cbnz x21, 8f
    mov x0, x22
    mov x1, #0
    mov w8, #0x57
    bl dos_call
    cbnz x1, 8f
    mov x0, x23
    mov x1, #1
    mov w8, #0x57
    bl dos_call
8:
    mov x0, x23
    bl dos_close
    mov x0, x22
    bl dos_close
    mov x1, #0
    leave
cf_full:
    mov x0, #39
cf_close_both:
    mov x27, x0
    mov x0, x23
    bl dos_close
    mov x0, x22
    bl dos_close
    mov x0, x27
    mov x1, #1
    leave
cf_close_source:
    mov x27, x0
    mov x0, x22
    bl dos_close
    mov x0, x27
cf_error:
    mov x1, #1
    leave

// COPY [/A|/B] source[+source...] [destination] [/V]
cmd_copy:
    enter
    mov x19, x0
    address x0, copy_src
    strb wzr, [x0]
    address x0, copy_dst
    strb wzr, [x0]
copy_parse:
    mov x0, x19
    bl next_word
    mov x19, x1
    ldrb w2, [x0]
    cbz w2, copy_parsed
    bl split_switch             // /A /B /V: binary copies always
    ldrb w2, [x0]
    cbz w2, copy_parse
    mov x20, x0
    address x21, copy_src
    mov x0, x21
    bl cstrlen
    mov x22, x0
    cbz x22, 1f
    sub x2, x22, #1
    ldrb w2, [x21, x2]
    cmp w2, #'+'
    b.eq 1f
    ldrb w2, [x20]
    cmp w2, #'+'
    b.eq 1f
    address x1, copy_dst
    ldrb w2, [x1]
    cbnz w2, copy_too_many
    mov x0, x20
    bl copy_cstring
    b copy_parse
1:
    mov x0, x20
    bl cstrlen
    add x2, x22, x0
    cmp x2, #255
    b.hs copy_invalid
    mov x0, x20
    add x1, x21, x22
    bl copy_cstring
    b copy_parse
copy_parsed:
    address x21, copy_src
    address x25, copy_dst
    ldrb w2, [x21]
    cbz w2, copy_missing
    mov x0, x21
1:
    ldrb w2, [x0], #1
    cbz w2, 2f
    cmp w2, #'+'
    b.eq copy_concat
    b 1b
2:
    mov x0, x21
    bl has_wild
    mov x22, x0
    cbnz x22, 3f
    mov x0, x21
    bl dev_lookup
    cbnz x0, 3f
    mov x0, x21
    mov x1, #0
    bl dos_attributes
    cbnz x1, 3f
    tbz x0, #4, 3f
    mov x0, x21                 // COPY directory = COPY directory\*.*
    bl append_star
    mov x22, #1
3:
    mov x0, x21
    bl dir_prefix_len
    mov x23, x0
    ldrb w2, [x25]
    cbz w2, copy_dst_dir
    mov x0, x25
    bl has_wild
    cbnz x0, copy_dst_template
    mov x0, x25
    bl ends_with_sep
    cbnz x0, copy_dst_dir
    mov x0, x25
    bl dev_lookup
    cbnz x0, copy_dst_file
    mov x0, x25
    mov x1, #0
    bl dos_attributes
    cbnz x1, copy_dst_file
    tbz x0, #4, copy_dst_file
    mov x0, x25
    bl cstrlen
    cmp x0, #250
    b.hs copy_invalid
    add x1, x25, x0
    mov w2, #'\\'
    strb w2, [x1]
    strb wzr, [x1, #1]
copy_dst_dir:
    mov x24, #0
    b copy_collect
copy_dst_template:
    mov x24, #1
    b copy_collect
copy_dst_file:
    mov x24, #2
    cbnz x22, copy_concat       // wildcards into one file concatenate
copy_collect:
    cbz x22, 4f
    mov x0, x21
    mov x1, #0
    bl wild_collect
    cbnz x1, copy_dos_error
    cbz x0, copy_not_found
    b 5f
4:
    add x0, x21, x23
    ldrb w2, [x0]
    cbz w2, copy_invalid
    address x1, wild_list
    bl copy_cstring
    address x0, wild_list
    bl cstrlen
    address x1, wild_list
    add x1, x1, x0
    strb wzr, [x1, #1]
5:
    mov x27, #0
    address x28, wild_list
copy_loop:
    ldrb w2, [x28]
    cbz w2, copy_report
    mov x0, x21
    mov x1, x23
    mov x2, x28
    address x3, copy_full_src
    bl join_path
    cmp x24, #2
    b.eq 7f
    cmp x24, #1
    b.eq 6f
    mov x0, x25
    bl cstrlen
    mov x1, x0
    mov x0, x25
    mov x2, x28
    address x3, copy_full_dst
    bl join_path
    b 8f
6:
    mov x0, x25
    bl dir_prefix_len
    mov x20, x0
    mov x0, x28
    add x1, x25, x20
    address x2, copy_name
    bl apply_template
    mov x0, x25
    mov x1, x20
    address x2, copy_name
    address x3, copy_full_dst
    bl join_path
    b 8f
7:
    mov x0, x25
    address x1, copy_full_dst
    bl copy_cstring
8:
    cbz x22, 9f
    address x0, copy_full_src
    bl puts
    address x0, newline
    bl puts
9:
    address x0, copy_full_src
    address x1, copy_full_dst
    mov x2, #0
    bl copy_file
    cbnz x1, 10f
    add x27, x27, #1
    b 11f
10:
    cmn x0, #1
    b.ne 12f
    address x0, c3_onto_itself
    bl puts
    b 13f
12:
    bl print_dos_error
13:
    cbz x22, copy_report
11:
    mov x0, x28
    bl wild_next
    mov x28, x0
    b copy_loop
copy_report:
    mov x0, x27
    mov x1, #8
    bl print_number_width
    address x0, c3_copied
    bl puts
    leave

// Sources joined with '+' (or a wildcard source to one file) go into one
// destination; without a destination they are appended to the first source.
copy_concat:
    mov x24, #0                 // first write creates the destination
    mov x27, #0                 // anything copied
    mov x19, x21
    ldrb w2, [x25]
    cbnz w2, 2f
    mov x0, x21                 // destination = first source, kept
    mov x1, x25
1:
    ldrb w2, [x0], #1
    cmp w2, #'+'
    b.eq 11f
    strb w2, [x1], #1
    cbnz w2, 1b
    sub x0, x0, #1
11:
    strb wzr, [x1]
    mov x19, x0
    mov x24, #1
    mov x27, #1
2:
    ldrb w2, [x19]
    cbz w2, concat_done
    cmp w2, #'+'
    b.ne 3f
    add x19, x19, #1
    b 2b
3:
    address x20, copy_part
    mov x1, x20
4:
    ldrb w2, [x19]
    cbz w2, 5f
    cmp w2, #'+'
    b.eq 5f
    strb w2, [x1], #1
    add x19, x19, #1
    b 4b
5:
    strb wzr, [x1]
    mov x0, x20
    bl dir_prefix_len
    mov x23, x0
    mov x0, x20
    bl has_wild
    mov x22, x0
    cbz x22, 6f
    mov x0, x20
    mov x1, #0
    bl wild_collect
    cbnz x1, 2b
    b 7f
6:
    add x0, x20, x23
    address x1, wild_list
    bl copy_cstring
    address x0, wild_list
    bl cstrlen
    address x1, wild_list
    add x1, x1, x0
    strb wzr, [x1, #1]
7:
    address x28, wild_list
8:
    ldrb w2, [x28]
    cbz w2, 2b
    mov x0, x20
    mov x1, x23
    mov x2, x28
    address x3, copy_full_src
    bl join_path
    cbz x22, 9f
    address x0, copy_full_src
    bl puts
    address x0, newline
    bl puts
9:
    address x0, copy_full_src
    mov x1, x25
    mov x2, x24
    bl copy_file
    cbz x1, 10f
    cmn x0, #1                  // the destination itself is skipped
    b.eq 12f
    bl print_dos_error
    b 12f
10:
    mov x24, #1
    mov x27, #1
12:
    mov x0, x28
    bl wild_next
    mov x28, x0
    b 8b
concat_done:
    b copy_report

copy_not_found:
    mov x0, #2
copy_dos_error:
    bl print_dos_error
    mov x27, #0
    b copy_report
copy_too_many:
    address x0, c3_too_many
    bl puts
    leave
copy_invalid:
    address x0, c3_invalid_parameter
    bl puts
    leave
copy_missing:
    address x0, c3_missing
    bl puts
    leave

// ---------------------------------------------------------------------------
// DIR [path] [/P] [/W]
cmd_dir:
    enter
    mov x19, x0
    mov x26, #0                 // bit 0 /W, bit 1 /P
    address x0, dir_arg
    strb wzr, [x0]
1:
    mov x0, x19
    bl next_word
    mov x19, x1
    ldrb w2, [x0]
    cbz w2, 4f
2:
    bl split_switch
    cbz w1, 3f
    mov x2, #1
    cmp w1, #'W'
    b.eq 21f
    mov x2, #2
    cmp w1, #'P'
    b.ne dir_bad_switch
21:
    orr x26, x26, x2
3:
    ldrb w2, [x0]
    cbz w2, 1b
    address x1, dir_arg
    bl copy_cstring
    b 1b
4:
    address x20, dir_pattern
    address x0, dir_arg
    ldrb w2, [x0]
    cbnz w2, 5f
    address x0, c3_star_dot_star
    mov x1, x20
    bl copy_cstring
    b dir_header
5:
    mov x1, x20
    bl copy_cstring
    mov x0, x20
    bl has_wild
    cbnz x0, dir_header
    mov x0, x20
    bl ends_with_sep
    cbnz x0, 6f
    mov x0, x20
    mov x1, #0
    bl dos_attributes
    cbnz x1, dir_header
    tbz x0, #4, dir_header
6:
    mov x0, x20
    bl append_star
dir_header:
    mov x0, x20
    address x1, dir_canon
    bl canonicalize_path
    cbnz x1, dir_not_found
    address x0, canonical_logical   // the drive and path as named
    address x1, dir_canon
    bl copy_cstring
    ldv x0, canonical_logical_drive
    add w0, w0, #'A'
    address x1, dir_drive
    strb w0, [x1]
    mov w0, #':'
    strb w0, [x1, #1]
    strb wzr, [x1, #2]
    address x0, dir_drive
    bl cmd_vol
    address x0, c3_directory_of
    bl puts
    address x0, dir_drive
    bl puts
    address x0, dir_canon
    bl dir_prefix_len
    address x1, dir_canon
    cmp x0, #1
    b.ls 7f
    sub x0, x0, #1
7:
    strb wzr, [x1, x0]
    address x0, dir_canon
    bl puts
    address x0, newline
    bl puts
    address x0, newline
    bl puts
    bl dos_get_dta
    mov x21, x0
    mov x22, x2
    address x0, dir_dta
    mov x1, #280
    bl dos_set_dta
    mov x23, #0                 // entries
    mov x24, #0                 // /W column
    mov x27, #4                 // lines on screen
    mov x0, x20
    mov x1, #0x10                // hidden and system files are not listed
    bl dos_find_first
dir_loop:
    cbnz x1, dir_end
    address x0, dir_dta
    and x1, x26, #1
    bl dir_entry
    add x23, x23, #1
    tbz x26, #0, 8f
    add x24, x24, #1
    cmp x24, #5
    b.lo dir_next
    mov x24, #0
    address x0, newline
    bl puts
8:
    add x27, x27, #1
    tbz x26, #1, dir_next
    cmp x27, #23
    b.lo dir_next
    address x0, c3_strike_key
    bl puts
    mov w8, #0x08
    bl dos_call
    address x0, newline
    bl puts
    mov x27, #0
dir_next:
    bl dos_find_next
    b dir_loop
dir_end:
    mov x25, x0
    cbz x24, 9f
    address x0, newline
    bl puts
9:
    mov x0, x21
    mov x1, x22
    bl dos_set_dta
    cbnz x23, 10f
    cmp x25, #18
    b.eq dir_not_found
    cmp x25, #2
    b.eq dir_not_found
    mov x0, x25
    bl print_dos_error
    leave
10:
    mov x0, x23
    mov x1, #9
    bl print_number_width
    address x0, c3_files
    bl puts
    address x0, dir_drive       // free space of the listed drive
    ldrb w0, [x0]
    sub x0, x0, #('A' - 1)
    mov w8, #0x36
    bl dos_call
    mul x0, x0, x2
    mov x1, #10
    bl print_number_width
    address x0, c3_bytes_free
    bl puts
    leave
dir_not_found:
    address x0, c3_file_not_found
    bl puts
    leave
dir_bad_switch:
    address x0, c3_invalid_switch
    bl puts
    leave

// x0 = search DTA, x1 = 1 for /W. Prints "NAME     EXT     size date time".
dir_entry:
    enter
    mov x19, x0
    mov x20, x1
    add x21, x19, #24
    mov x0, x21
    bl cstrlen
    mov x22, x0
    mov x23, x22                // base length
    mov x24, x22                // extension start
    ldrb w2, [x21]
    cmp w2, #'.'
    b.eq 2f
    mov x0, x21
    bl last_dot
    cmp x0, #0
    b.lt 2f
    mov x23, x0
    add x24, x0, #1
2:
    sub x25, x22, x24
    cmp x23, #8
    b.hi 4f
    cmp x25, #3
    b.hi 4f
    mov x2, #0
3:
    ldrb w3, [x21, x2]
    cbz w3, 31f
    cmp w3, #' '
    b.eq 4f
    add x2, x2, #1
    b 3b
31:
    mov x0, x21
    mov x1, x23
    mov x2, #8
    bl put_padded
    mov x0, #' '
    bl stdout_putc
    add x0, x21, x24
    mov x1, x25
    mov x2, #3
    bl put_padded
    mov x26, #12
    b 5f
4:
    mov x0, x21                 // long name: shown whole
    mov x1, x22
    mov x2, #12
    bl put_padded
    mov x26, x22
    cmp x26, #12
    b.hs 5f
    mov x26, #12
5:
    cbz x20, 7f
    mov x27, #16
    cmp x26, #15
    b.lo 6f
    add x27, x26, #1
6:
    cmp x26, x27
    b.hs 61f
    mov x0, #' '
    bl stdout_putc
    add x26, x26, #1
    b 6b
61:
    leave
7:
    ldr x0, [x19]
    tbz x0, #4, 8f
    address x0, c3_dir_marker
    bl puts
    b 9f
8:
    ldr x0, [x19, #8]
    mov x1, #10
    bl print_number_width
9:
    mov x0, #' '
    bl stdout_putc
    ldrh w0, [x19, #18]
    bl print_packed_date
    mov x0, #' '
    bl stdout_putc
    ldrh w0, [x19, #16]
    bl print_packed_time
    address x0, newline
    bl puts
    leave

// w0 = packed FAT date: " m-dd-yy" in the country's order and separator.
print_packed_date:
    enter
    and x19, x0, #31            // day
    ubfx x20, x0, #5, #4        // month
    ubfx x21, x0, #9, #7
    add x21, x21, #1980
    mov x2, #100
    udiv x3, x21, x2
    msub x21, x3, x2, x21       // two-digit year
    bl country_formats
    mov x22, x1
    mov x23, x20                // M D Y
    mov x24, x19
    mov x25, x21
    cmp x0, #1
    b.ne 1f
    mov x23, x19                // D M Y
    mov x24, x20
1:
    cmp x0, #2
    b.ne 2f
    mov x23, x21                // Y M D
    mov x24, x20
    mov x25, x19
2:
    mov x0, x23
    mov x1, #2
    bl print_number_width
    mov x0, x22
    bl stdout_putc
    mov x0, x24
    mov x1, #2
    bl print_padded_number
    mov x0, x22
    bl stdout_putc
    mov x0, x25
    mov x1, #2
    bl print_padded_number
    leave

// w0 = packed FAT time: "  3:51a" (12-hour countries) or " 15:51".
print_packed_time:
    enter
    ubfx x19, x0, #11, #5
    ubfx x20, x0, #5, #6
    bl country_formats
    mov x21, x2                 // separator
    mov x22, x3                 // 0 = 12-hour
    mov x23, #0
    cbnz x22, 1f
    mov x23, #'a'
    cmp x19, #12
    b.lo 2f
    mov x23, #'p'
    sub x19, x19, #12
2:
    cbnz x19, 1f
    mov x19, #12
1:
    mov x0, x19
    mov x1, #3
    bl print_number_width
    mov x0, x21
    bl stdout_putc
    mov x0, x20
    mov x1, #2
    bl print_padded_number
    cbz x23, 3f
    mov x0, x23
    bl stdout_putc
3:
    leave

.section .rodata
c3_star: .asciz "*"
c3_star_dot_star: .asciz "*.*"
c3_empty: .asciz ""
c3_file_not_found: .asciz "File not found\r\n"
c3_path_not_found: .asciz "Path not found\r\n"
c3_access_denied: .asciz "Access denied\r\n"
c3_disk_full: .asciz "Insufficient disk space\r\n"
c3_sharing: .asciz "Sharing violation\r\n"
c3_missing: .asciz "Required parameter missing\r\n"
c3_invalid_parameter: .asciz "Invalid parameter\r\n"
c3_invalid_switch: .asciz "Invalid switch\r\n"
c3_too_many: .asciz "Too many parameters\r\n"
c3_duplicate: .asciz "Duplicate file name or file not found\r\n"
c3_onto_itself: .asciz "File cannot be copied onto itself\r\n"
c3_copied: .asciz " File(s) copied\r\n"
c3_all_files: .asciz "All files in directory will be deleted!\r\nAre you sure (Y/N)?"
c3_delete_query: .asciz ",    Delete (Y/N)?"
c3_directory_of: .asciz " Directory of  "
c3_dir_marker: .asciz " <DIR>    "
c3_files: .asciz " File(s)"
c3_bytes_free: .asciz " bytes free\r\n"
c3_strike_key: .asciz "Strike a key when ready . . . "
.section .bss
dir_drive: .skip 8
.balign 16
wild_dta: .skip 288
dir_dta: .skip 288
wild_list: .skip WILD_LIST_SIZE
del_path: .skip 256
del_full: .skip 256
ren_old: .skip 256
ren_new: .skip 256
ren_name: .skip 256
copy_src: .skip 256
copy_dst: .skip 256
copy_part: .skip 256
copy_full_src: .skip 256
copy_full_dst: .skip 256
copy_name: .skip 256
copy_canon_a: .skip 256
copy_canon_b: .skip 256
dir_arg: .skip 256
dir_canon: .skip 256

.section .text
// Boot: run \AUTOEXEC.BAT, or ask for the date and time when there is none.
run_autoexec:
    frame
    address x0, c3_autoexec
    mov x1, #0
    bl dos_attributes
    cbnz x1, 1f
    address x0, c3_autoexec
    address x1, c3_empty
    bl batch_run
    unframe
1:
    address x0, c3_empty
    bl cmd_date
    address x0, c3_empty
    bl cmd_time
    unframe
.section .rodata
c3_autoexec: .asciz "\\AUTOEXEC.BAT"
