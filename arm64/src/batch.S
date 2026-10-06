// SPDX-License-Identifier: MIT
// Native command interpreter: streamed BAT files, bounded expansion, CALL,
// GOTO, IF EXIST/ERRORLEVEL, positional parameters, and EXIT /B.
.equ BATCH_FRAME_SIZE, 1664
.section .text
batch_run:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    sub sp, sp, #BATCH_FRAME_SIZE
    mov x21, sp
    mov x19, x0
    mov x20, x1
    address x0, batch_depth
    ldr x0, [x0]
    cmp x0, #16
    b.hs batch_depth_error
    mov x0, x19
    mov x1, #0
    bl dos_open
    cbnz x1, batch_return
    str x0, [x21, #8]
    address x0, batch_context
    ldr x1, [x0]
    str x1, [x21]
    str x21, [x0]
    address x0, batch_depth
    ldr x1, [x0]
    add x1, x1, #1
    str x1, [x0]
    str xzr, [x21, #96]
    mov x0, x19
    add x1, x21, #1152
    bl copy_cstring
    add x0, x21, #1152
    str x0, [x21, #16]
    mov x0, x20
    add x1, x21, #640
    bl copy_cstring
    mov x0, x20
    add x1, x21, #896
    bl copy_cstring
    add x0, x21, #896
    mov x22, #1
1:
    bl next_word
    add x2, x21, #16
    str x0, [x2, x22, lsl #3]
    mov x0, x1
    add x22, x22, #1
    cmp x22, #10
    b.lo 1b
batch_next_line:
    ldr x0, [x21, #96]
    cbnz x0, batch_finish
    address x0, shell_exit_requested
    ldr x0, [x0]
    cbnz x0, batch_finish
    ldr x0, [x21, #8]
    add x1, x21, #128
    bl batch_read_line
    cbnz x1, batch_read_end
    add x0, x21, #128
    add x1, x21, #384
    mov x2, x21
    bl batch_expand
    cbnz x0, batch_command_error
    add x19, x21, #384
1:
    ldrb w2, [x19]
    cmp w2, #' '
    b.ne 2f
    add x19, x19, #1
    b 1b
2:
    cbz w2, batch_next_line
    cmp w2, #':'
    b.eq batch_next_line
    cmp w2, #'@'
    b.ne 3f
    add x19, x19, #1
    b 4f
3:
    address x0, batch_echo_enabled
    ldr x0, [x0]
    cbz x0, 4f
    mov x0, x19
    bl puts
    address x0, newline
    bl puts
4:
    mov x0, x19
    bl shell_execute
    b batch_next_line
batch_read_end:
    cmp x1, #1
    b.eq batch_finish
batch_command_error:
    address x0, file_error
    bl puts
    address x0, shell_errorlevel
    mov x1, #1
    str x1, [x0]
batch_finish:
    ldr x0, [x21, #8]
    bl dos_close
    address x0, batch_context
    ldr x1, [x21]
    str x1, [x0]
    address x0, batch_depth
    ldr x1, [x0]
    sub x1, x1, #1
    str x1, [x0]
    mov x0, #0
    mov x1, #0
    b batch_return
batch_depth_error:
    mov x0, #8
    mov x1, #1
batch_return:
    add sp, sp, #BATCH_FRAME_SIZE
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// x1=0 line, 1 EOF, 2 I/O/line-length error. Final line need not have LF.
batch_read_line:
    frame
    stp x19, x20, [sp, #-16]!
    str x21, [sp, #-16]!
    sub sp, sp, #16
    mov x19, x0
    mov x20, x1
    mov x21, #0
1:
    mov x0, x19
    mov x1, sp
    mov x2, #1
    bl dos_read
    cbnz x1, 5f
    cbz x0, 4f
    ldrb w2, [sp]
    cmp w2, #13
    b.eq 1b
    cmp w2, #10
    b.eq 3f
    cmp x21, #255
    b.hs 5f
    strb w2, [x20, x21]
    add x21, x21, #1
    b 1b
3:
    strb wzr, [x20, x21]
    mov x0, x21
    mov x1, #0
    b 6f
4:
    cbnz x21, 3b
    mov x1, #1
    b 6f
5:
    mov x1, #2
6:
    add sp, sp, #16
    ldr x21, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

batch_expand:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, #0
1:
    ldrb w2, [x19], #1
    cbz w2, 8f
    cmp w2, #'%'
    b.ne 7f
    ldrb w2, [x19], #1
    cbz w2, 8f
    cmp w2, #'%'
    b.eq 7f
    cmp w2, #'*'
    b.eq 3f
    sub w3, w2, #'0'
    cmp w3, #9
    b.hi 4f
    add x0, x21, #16
    ldr x0, [x0, x3, lsl #3]
    b 6f
3:
    add x0, x21, #640
    b 6f
4:
    sub x19, x19, #1
    address x23, expansion_name
    mov x24, #0
5:
    ldrb w2, [x19], #1
    cbz w2, 8f
    cmp w2, #'%'
    b.eq 9f
    cmp x24, #31
    b.hs batch_expand_error
    strb w2, [x23, x24]
    add x24, x24, #1
    b 5b
9:
    strb wzr, [x23, x24]
    mov x0, x23
    bl environment_get
    cbz x0, 1b
6:
    cbz x0, 1b
    ldrb w2, [x0], #1
    cbz w2, 1b
    cmp x22, #255
    b.hs batch_expand_error
    strb w2, [x20, x22]
    add x22, x22, #1
    b 6b
7:
    cmp x22, #255
    b.hs batch_expand_error
    strb w2, [x20, x22]
    add x22, x22, #1
    b 1b
8:
    strb wzr, [x20, x22]
    mov x0, #0
    b batch_expand_return
batch_expand_error:
    mov x0, #1
batch_expand_return:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

cmd_rem:
    ret
cmd_echo:
    frame
    str x19, [sp, #-16]!
    mov x19, x0
    address x1, echo_off_keyword
    bl strcasecmp
    cbnz x0, 1f
    address x0, batch_echo_enabled
    str xzr, [x0]
    b echo_return
1:
    mov x0, x19
    address x1, echo_on_keyword
    bl strcasecmp
    cbnz x0, 2f
    address x0, batch_echo_enabled
    mov x1, #1
    str x1, [x0]
    b echo_return
2:
    ldrb w2, [x19]
    cbnz w2, 3f
    address x0, batch_echo_enabled
    ldr x0, [x0]
    cbnz x0, 4f
    address x19, echo_off_status
    b 3f
4:
    address x19, echo_on_status
3:
    mov x2, #0
5:
    ldrb w3, [x19, x2]
    cbz w3, 6f
    add x2, x2, #1
    b 5b
6:
    mov x0, #1
    mov x1, x19
    bl dos_write
    address x1, newline
    mov x0, #1
    mov x2, #2
    bl dos_write
echo_return:
    ldr x19, [sp], #16
    unframe
cmd_call:
    frame
    bl next_word
    bl shell_external
    unframe
cmd_goto:
    frame
    stp x19, x20, [sp, #-16]!
    address x19, batch_context
    ldr x19, [x19]
    cbz x19, goto_error
    bl next_word
    mov x20, x0
    address x1, eof_label
    bl strcasecmp
    cbnz x0, 1f
    mov x0, #1
    str x0, [x19, #96]
    b goto_return
1:
    mov x0, x20
    add x1, x19, #1408
    bl copy_cstring
    ldr x0, [x19, #8]
    mov x1, #0
    mov x2, #0
    bl dos_seek
    cbnz x1, goto_error
2:
    ldr x0, [x19, #8]
    add x1, x19, #128
    bl batch_read_line
    cbnz x1, goto_missing
    add x0, x19, #128
    ldrb w2, [x0]
    cmp w2, #':'
    b.ne 2b
    add x0, x0, #1
    bl next_word
    add x1, x19, #1408
    bl strcasecmp
    cbnz x0, 2b
    b goto_return
goto_missing:
    mov x0, #1
    str x0, [x19, #96]
goto_error:
    address x0, file_error
    bl puts
goto_return:
    ldp x19, x20, [sp], #16
    unframe

cmd_if:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x21, #0
    bl next_word
    mov x19, x0
    mov x20, x1
    address x1, not_keyword
    bl strcasecmp
    cbnz x0, 1f
    mov x21, #1
    mov x0, x20
    bl next_word
    mov x19, x0
    mov x20, x1
1:
    mov x0, x19
    address x1, errorlevel_keyword
    bl strcasecmp
    cbnz x0, 2f
    mov x0, x20
    bl next_word
    mov x20, x1
    bl parse_unsigned
    cbnz x1, if_error
    address x2, shell_errorlevel
    ldr x2, [x2]
    and x2, x2, #255
    cmp x2, x0
    cset x22, hs
    b if_evaluate
2:
    mov x0, x19
    address x1, exist_keyword
    bl strcasecmp
    cbnz x0, if_error
    mov x0, x20
    bl next_word
    mov x20, x1
    mov x1, #1
    mov x2, #0
    bl open_path_object
    mov x22, #0
    cbnz x1, if_evaluate
    mov x22, #1
    ldr x3, [x0, #16]
    blr x3
if_evaluate:
    eor x22, x22, x21
    cbz x22, if_return
    mov x0, x20
    bl shell_execute
    b if_return
if_error:
    address x0, file_error
    bl puts
if_return:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

shell_exit:
    frame
    stp x19, x20, [sp, #-16]!
    bl next_word
    mov x19, x1
    address x1, batch_exit_switch
    bl strcasecmp
    cbnz x0, 2f
    address x20, batch_context
    ldr x20, [x20]
    cbz x20, 2f
    mov x0, #1
    str x0, [x20, #96]
    mov x0, x19
    bl next_word
    ldrb w2, [x0]
    cbz w2, 3f
    bl parse_unsigned
    cbnz x1, 3f
    address x2, shell_errorlevel
    and x0, x0, #255
    str x0, [x2]
    b 3f
2:
    address x0, shell_exit_requested
    mov x1, #1
    str x1, [x0]
3:
    ldp x19, x20, [sp], #16
    unframe

parse_unsigned:
    mov x2, #0
    mov x3, #0
    mov x5, #10
1:
    ldrb w4, [x0], #1
    cbz w4, 2f
    sub w4, w4, #'0'
    cmp w4, #9
    b.hi 3f
    madd x2, x2, x5, x4
    mov x6, #65535
    cmp x2, x6
    b.hi 3f
    add x3, x3, #1
    b 1b
2:
    cbz x3, 3f
    mov x0, x2
    mov x1, #0
    ret
3:
    mov x0, #1
    mov x1, #1
    ret

unsigned_to_string:
    mov x2, #10
    add x3, x1, #31
    strb wzr, [x3]
1:
    udiv x4, x0, x2
    msub x5, x4, x2, x0
    add w5, w5, #'0'
    strb w5, [x3, #-1]!
    mov x0, x4
    cbnz x0, 1b
    mov x0, x3
    ret

environment_get:
    frame
    str x19, [sp, #-16]!
    mov x19, x0
    address x1, errorlevel_keyword
    bl strcasecmp
    cbnz x0, 1f
    address x0, shell_errorlevel
    ldr x0, [x0]
    and x0, x0, #255
    address x1, expansion_number
    bl unsigned_to_string
    b 3f
1:
    mov x0, x19
    address x1, path_keyword
    bl strcasecmp
    cbnz x0, 2f
    address x0, default_path
    b 3f
2:
    mov x0, x19
    address x1, comspec_keyword
    bl strcasecmp
    cbnz x0, 4f
    address x0, default_comspec
    b 3f
4:
    mov x0, #0
3:
    ldr x19, [sp], #16
    unframe
.section .rodata
errorlevel_keyword: .asciz "ERRORLEVEL"
echo_off_keyword: .asciz "OFF"
echo_on_keyword: .asciz "ON"
echo_off_status: .asciz "ECHO is off."
echo_on_status: .asciz "ECHO is on."
exist_keyword: .asciz "EXIST"
not_keyword: .asciz "NOT"
path_keyword: .asciz "PATH"
comspec_keyword: .asciz "COMSPEC"
default_path: .asciz "A:\\"
default_comspec: .asciz "A:\\EFI\\BOOT\\BOOTAA64.EFI"
batch_exit_switch: .asciz "/B"
eof_label: .asciz ":EOF"
.section .data
.balign 8
batch_echo_enabled: .quad 1
.section .bss
.balign 16
batch_context: .skip 8
batch_depth: .skip 8
expansion_name: .skip 32
expansion_number: .skip 32
shell_expanded_line: .skip 256
shell_empty_parameters: .skip 896
