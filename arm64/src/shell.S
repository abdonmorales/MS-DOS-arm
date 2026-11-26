// SPDX-License-Identifier: MIT
.section .text
shell_execute:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    sub sp, sp, #128
    mov x19, x0
    bl line_has_pipe
    cbz x0, 7f
    mov x0, x19
    bl pipe_execute
    b shell_execute_return
7:
    mov x0, x19
    mov x1, sp
    bl redirect_begin
    cbnz x1, shell_redirect_failed
    mov x0, x19
    bl next_word
    mov x19, x0
    mov x20, x1
    mov x2, x19
1:
    ldrb w3, [x2]
    cbz w3, 2f
    cmp w3, #'a'
    b.lo 3f
    cmp w3, #'z'
    b.hi 3f
    sub w3, w3, #32
    strb w3, [x2]
3:
    add x2, x2, #1
    b 1b
2:
    ldrb w2, [x19]
    cbz w2, shell_execute_done
    cmp w2, #':'
    b.eq shell_execute_done
    cmp w2, #'@'
    b.ne 8f
    add x19, x19, #1              // @command: no echo (batch handles it)
    ldrb w2, [x19]
    cbz w2, shell_execute_done
8:
    ldrb w2, [x19, #1]          // "B:" selects a drive
    cmp w2, #':'
    b.ne 81f
    ldrb w2, [x19, #2]
    cbnz w2, 81f
    ldrb w2, [x19]
    sub x21, x2, #'A'
    cmp x21, #26
    b.hs 82f
    add x0, x21, #1
    bl drive_physical
    cbnz x1, 82f
    mov x0, x21
    bl dos_set_drive
    b shell_execute_done
82:
    address x0, invalid_drive_message
    bl puts
    b shell_execute_done
81:
    ldrb w2, [x19, #4]
    cmp w2, #'.'
    b.ne 9f
    strb wzr, [x19, #4]
    mov x0, x19
    address x1, name_echo
    bl strcmp
    cbnz x0, 10f
    add x0, x19, #5               // ECHO.text prints text (or a blank line)
    bl puts
    address x0, newline
    bl puts
    b shell_execute_done
10:
    mov w2, #'.'
    strb w2, [x19, #4]
9:
    address x21, commands
4:
    ldrsw x1, [x21]
    cbz x1, 5f
    add x1, x21, x1
    mov x0, x19
    bl strcmp
    cbz x0, 6f
    add x21, x21, #8
    b 4b
5:
    mov x0, x19
    mov x1, x20
    bl shell_external
    b shell_execute_done
6:
    ldrsw x2, [x21, #4]
    add x2, x21, x2
    mov x0, x20
    blr x2
shell_execute_done:
    mov x0, sp
    bl redirect_end
    b shell_execute_return
shell_redirect_failed:
    mov x0, sp
    bl redirect_end
    address x0, file_error
    bl puts
shell_execute_return:
    add sp, sp, #128
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

shell_external:
    frame
    bl path_search_run
    cbz x1, 1f
    mov x0, #1
    address x2, shell_errorlevel
    str x0, [x2]
    address x0, unknown_message
    bl puts
1:
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
    bl print_current_drive
    address x0, current_directory
    bl puts
    address x0, newline
    bl puts
    b 2f
1:
    ldrb w3, [x0, #1]           // "CD B:" shows that drive's directory
    cmp w3, #':'
    b.ne 3f
    ldrb w3, [x0, #2]
    cbnz w3, 3f
    bic w2, w2, #0x20
    sub x2, x2, #'A'
    cmp x2, #26
    b.hs 4f
    stp x2, xzr, [sp, #-16]!
    add x0, x2, #1
    bl drive_physical
    ldp x2, xzr, [sp], #16
    cbnz x1, 4f
    add w0, w2, #'A'
    stp x2, xzr, [sp, #-16]!
    bl stdout_putc
    mov x0, #':'
    bl stdout_putc
    ldp x0, xzr, [sp], #16
    bl drive_cwd
    bl puts
    address x0, newline
    bl puts
    b 2f
4:
    address x0, invalid_drive_message
    bl puts
    b 2f
3:
    bl dos_chdir
    bl shell_check_error
2:
    unframe
// Prints the current drive as "A:".
print_current_drive:
    frame
    adrp x0, current_drive
    ldr x0, [x0, :lo12:current_drive]
    add w0, w0, #'A'
    bl stdout_putc
    mov x0, #':'
    bl stdout_putc
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
    address x2, shell_errorlevel
    cbnz x1, 2f
    str xzr, [x2]
    b 1f
2:
    str x0, [x2]
    address x0, file_error
    b puts
1:
    ret

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


.section .rodata
exe_suffix: .asciz ".EXE"
bat_suffix: .asciz ".BAT"
prompt_suffix: .asciz "> "
copy_success: .asciz "        1 file(s) copied.\r\n"
directory_marker: .asciz "  <DIR>"
directory_glob_suffix: .asciz "\\*"
.section .bss
.balign 16
external_path: .skip 256
shell_errorlevel: .skip 8
shell_exit_requested: .skip 8
copy_source_path: .skip 256
shell_dta: .skip 280
dir_pattern: .skip 256
