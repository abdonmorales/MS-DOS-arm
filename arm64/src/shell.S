// SPDX-License-Identifier: MIT
.section .text
shell_prompt:
    frame
    address x0, drive_prefix
    bl puts
    address x0, current_directory
    bl puts
    address x0, prompt_suffix
    bl puts
    unframe

// In-place tokenization, supporting quoted filenames. x0=token, x1=tail.
next_word:
1:
    ldrb w2, [x0]
    cmp w2, #' '
    b.eq 2f
    cmp w2, #9
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
    cbz w2, 7f
    cmp w2, #'"'
    b.eq 6f
    add x1, x1, #1
    b 4b
5:
    ldrb w2, [x1]
    cbz w2, 7f
    cmp w2, #' '
    b.eq 6f
    cmp w2, #9
    b.eq 6f
    add x1, x1, #1
    b 5b
6:
    strb wzr, [x1], #1
7:
    ret

cmd_cd:
    frame
    bl next_word
    ldrb w2, [x0]
    cbnz w2, 1f
    address x0, drive_prefix
    bl puts
    address x0, current_directory
    bl puts
    address x0, newline
    bl puts
    b 2f
1:
    bl dos_chdir
    bl shell_check_error
2:
    unframe
cmd_md:
    mov w8, #0x39
    b cmd_path_call
cmd_rd:
    mov w8, #0x3a
cmd_path_call:
    frame
    str x19, [sp, #-16]!
    mov w19, w8
    bl next_word
    mov w8, w19
    bl dos_call
    bl shell_check_error
    ldr x19, [sp], #16
    unframe
shell_check_error:
    cbz x1, 1f
    address x0, file_error
    b puts
1:
    ret

cmd_ren:
    frame
    str x19, [sp, #-16]!
    bl next_word
    mov x19, x0
    mov x0, x1
    bl next_word
    mov x1, x0
    mov x0, x19
    bl dos_rename
    bl shell_check_error
    ldr x19, [sp], #16
    unframe

cmd_copy:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    bl next_word
    mov x19, x0
    mov x0, x1
    bl next_word
    mov x20, x0
    ldrb w2, [x19]
    cbz w2, copy_cmd_error
    ldrb w2, [x20]
    cbz w2, copy_cmd_error
    // Compare canonical paths before the destination can be truncated.
    mov x0, x19
    address x1, copy_source_path
    bl canonicalize_path
    cbnz x1, copy_cmd_error
    mov x0, x20
    address x1, canonical_buffer
    bl canonicalize_path
    cbnz x1, copy_cmd_error
    address x0, copy_source_path
    address x1, canonical_buffer
    bl strcasecmp
    cbz x0, copy_cmd_error
    mov x0, x19
    mov x1, #0
    bl dos_open
    cbnz x1, copy_cmd_error
    mov x21, x0
    mov x0, x20
    mov x1, #0
    bl dos_create
    cbnz x1, copy_cmd_close_source_error
    mov x22, x0
1:
    mov x0, x21
    address x1, io_buffer
    mov x2, #512
    bl dos_read
    cbnz x1, copy_cmd_close_both_error
    cbz x0, copy_cmd_done
    mov x19, x0
    mov x2, x0
    mov x0, x22
    address x1, io_buffer
    bl dos_write
    cbnz x1, copy_cmd_close_both_error
    cmp x0, x19
    b.ne copy_cmd_close_both_error
    b 1b
copy_cmd_done:
    mov x0, x22
    bl dos_close
    cbnz x1, copy_cmd_close_source_error
    mov x0, x21
    bl dos_close
    cbnz x1, copy_cmd_error
    address x0, copy_success
    bl puts
    b copy_cmd_return
copy_cmd_close_both_error:
    mov x0, x22
    bl dos_close
copy_cmd_close_source_error:
    mov x0, x21
    bl dos_close
copy_cmd_error:
    address x0, file_error
    bl puts
copy_cmd_return:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

strcasecmp:
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
    cmp w2, w3
    b.ne 4f
    cbnz w2, 1b
4:
    sub w0, w2, w3
    ret

cmd_attrib:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, #0                 // bits to add
    mov x20, #0                 // bits to clear
1:
    bl next_word
    ldrb w2, [x0]
    cmp w2, #'+'
    b.eq 2f
    cmp w2, #'-'
    b.ne attrib_path
2:
    ldrb w3, [x0, #1]
    bic w3, w3, #0x20
    mov x4, #1
    cmp w3, #'R'
    b.eq 3f
    mov x4, #2
    cmp w3, #'H'
    b.eq 3f
    mov x4, #4
    cmp w3, #'S'
    b.eq 3f
    mov x4, #32
    cmp w3, #'A'
    b.ne attrib_cmd_error
3:
    ldrb w3, [x0, #2]
    cbnz w3, attrib_cmd_error
    cmp w2, #'+'
    b.ne 4f
    orr x19, x19, x4
    bic x20, x20, x4
    b 5f
4:
    orr x20, x20, x4
    bic x19, x19, x4
5:
    mov x0, x1
    b 1b
attrib_path:
    cbz w2, attrib_cmd_error
    mov x21, x0
    mov x1, #0
    bl dos_attributes
    cbnz x1, attrib_cmd_error
    mov x22, x0
    orr x2, x19, x20
    cbnz x2, attrib_update
    mov x19, #0
    address x20, attribute_letters
1:
    ldrb w1, [x20, x19]
    cbz w1, 2f
    mov x0, #' '
    lsr x2, x22, x19
    tst x2, #1
    csel x0, x1, x0, ne
    bl putc
    add x19, x19, #1
    b 1b
2:
    mov x0, #' '
    bl putc
    mov x0, x21
    bl puts
    address x0, newline
    bl puts
    b attrib_cmd_return
attrib_update:
    orr x2, x22, x19
    bic x2, x2, x20
    bic x2, x2, #16
    mov x0, x21
    mov x1, #1
    bl dos_attributes
    cbnz x1, attrib_cmd_error
    b attrib_cmd_return
attrib_cmd_error:
    address x0, file_error
    bl puts
attrib_cmd_return:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

cmd_dir:
    frame
    stp x19, x20, [sp, #-16]!
    mov x20, x0
    bl dos_get_dta
    mov x19, x0
    address x0, shell_dta
    mov x1, #280
    bl dos_set_dta
    mov x0, x20
    bl next_word
    ldrb w2, [x0]
    cbnz w2, 1f
    address x0, search_all
1:
    mov x1, #0x16
    bl dos_find_first
2:
    cbnz x1, dir_cmd_end
    address x0, shell_dta
    add x0, x0, #24
    bl puts
    address x0, shell_dta
    ldr x0, [x0]
    tbz x0, #4, 3f
    address x0, directory_marker
    bl puts
3:
    address x0, newline
    bl puts
    bl dos_find_next
    b 2b
dir_cmd_end:
    cmp x0, #18
    b.eq 4f
    address x0, file_error
    bl puts
4:
    mov x0, x19
    mov x1, #280
    bl dos_set_dta
    ldp x19, x20, [sp], #16
    unframe
.section .rodata
drive_prefix: .asciz "A:"
prompt_suffix: .asciz "> "
copy_success: .asciz "        1 file(s) copied.\r\n"
attribute_letters: .asciz "RHSVDA"
directory_marker: .asciz "  <DIR>"
.section .bss
.balign 16
copy_source_path: .skip 256
shell_dta: .skip 280
