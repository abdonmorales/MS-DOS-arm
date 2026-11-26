// SPDX-License-Identifier: MIT
// COMMAND internal commands (TCMD1/TCMD2/TBATCH/TFOR/TPIPE in COMMAND):
// pipes, FOR, SHIFT, IF string comparison, VOL, VERIFY, BREAK, CTTY, PAUSE,
// CHCP, TRUENAME, and DATE/TIME with country formats and prompting.
.section .text

// ---------------------------------------------------------------------------
// x0 = line. Returns x0 = 1 if it holds an unquoted '|'.
line_has_pipe:
    mov x9, #0                  // inside quotes
1:
    ldrb w10, [x0], #1
    cbz w10, 3f
    cmp w10, #'"'
    b.ne 2f
    eor x9, x9, #1
    b 1b
2:
    cbnz x9, 1b
    cmp w10, #'|'
    b.ne 1b
    mov x0, #1
    ret
3:
    mov x0, #0
    ret

// x0 = line with pipes. Each stage writes a temporary file that the next
// stage reads, as COMMAND did: "a | b" runs "a >T1" then "b <T1".
.equ PIPE_FRAME, 768
pipe_execute:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    sub sp, sp, #PIPE_FRAME
    mov x1, sp                  // [sp] line copy (256), [sp+256] stage (512)
    bl copy_cstring
    // Split at unquoted '|': x20 = stage count (at most 8).
    mov x19, sp
    mov x20, #1
    mov x9, #0
1:
    ldrb w10, [x19]
    cbz w10, 3f
    cmp w10, #'"'
    b.ne 2f
    eor x9, x9, #1
2:
    cbnz x9, 21f
    cmp w10, #'|'
    b.ne 21f
    strb wzr, [x19]
    add x20, x20, #1
    cmp x20, #8
    b.hi pipe_error
21:
    add x19, x19, #1
    b 1b
3:
    mov x19, sp                 // current stage text
    mov x21, #0                 // stage index
4:
    cmp x21, x20
    b.hs 8f
    add x22, sp, #256
    mov x0, x19
    mov x1, x22
    bl copy_cstring
    mov x0, x22
    bl fat_strlen
    add x23, x22, x0
    cbz x21, 5f
    mov w9, #' '
    strb w9, [x23], #1
    mov w9, #'<'
    strb w9, [x23], #1
    sub x0, x21, #1
    mov x1, x23
    bl pipe_name
    mov x23, x0
5:
    add x9, x21, #1
    cmp x9, x20
    b.hs 6f
    mov w9, #' '
    strb w9, [x23], #1
    mov w9, #'>'
    strb w9, [x23], #1
    mov x0, x21
    mov x1, x23
    bl pipe_name
6:
    add x0, sp, #256
    bl shell_execute
    // Next stage text follows this one's NUL.
7:
    ldrb w9, [x19], #1
    cbnz w9, 7b
    add x21, x21, #1
    address x9, shell_exit_requested
    ldr x9, [x9]
    cbz x9, 4b
8:
    mov x21, #0                 // delete the temporary files
81:
    add x9, x21, #1
    cmp x9, x20
    b.hs 9f
    mov x0, x21
    add x1, sp, #256
    bl pipe_name
    add x0, sp, #256
    bl dos_delete
    add x21, x21, #1
    b 81b
pipe_error:
    address x0, syntax_error_message
    bl puts
9:
    add sp, sp, #PIPE_FRAME
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// x0 = index, x1 = destination. Writes "\%PIPEn.$$$"; returns x0 = end.
pipe_name:
    address x9, pipe_template
1:
    ldrb w10, [x9], #1
    cmp w10, #'#'
    b.ne 2f
    add w10, w0, #'1'
2:
    strb w10, [x1], #1
    cbnz w10, 1b
    sub x0, x1, #1
    ret

// ---------------------------------------------------------------------------
// FOR %v IN (set) DO command. In batch files %%v reaches here as %v.
.equ FOR_FRAME, 1104
cmd_for:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    sub sp, sp, #FOR_FRAME
    // [sp] set (256), [sp+256] template (256), [sp+512] item (256),
    // [sp+768] command (256), [sp+1024] saved DTA pointer/capacity.
    address x9, for_active
    ldr x10, [x9]
    cbnz x10, for_nested
    bl skip_blanks
    ldrb w9, [x0]
    cmp w9, #'%'
    b.ne for_syntax
    ldrb w19, [x0, #1]          // variable character
    cbz w19, for_syntax
    add x0, x0, #2
    bl skip_blanks
    address x1, for_in_keyword
    bl keyword_prefix
    cbz x1, for_syntax
    bl skip_blanks
    ldrb w9, [x0]
    cmp w9, #'('
    b.ne for_syntax
    add x0, x0, #1
    mov x9, sp
1:
    ldrb w10, [x0], #1
    cbz w10, for_syntax
    cmp w10, #')'
    b.eq 2f
    strb w10, [x9], #1
    b 1b
2:
    strb wzr, [x9]
    bl skip_blanks
    address x1, for_do_keyword
    bl keyword_prefix
    cbz x1, for_syntax
    bl skip_blanks
    add x1, sp, #256
    bl copy_cstring
    address x9, for_active
    mov x10, #1
    str x10, [x9]
    mov x20, sp                 // set cursor
for_next_item:
    ldrb w9, [x20]
    cbz w9, for_done
    cmp w9, #' '
    b.eq 3f
    cmp w9, #','
    b.eq 3f
    cmp w9, #';'
    b.eq 3f
    cmp w9, #9
    b.eq 3f
    cmp w9, #'='
    b.ne 4f
3:
    add x20, x20, #1
    b for_next_item
4:
    add x21, sp, #512           // copy one item
    mov x22, #0                 // wildcard seen
5:
    ldrb w9, [x20]
    cbz w9, 6f
    cmp w9, #' '
    b.eq 6f
    cmp w9, #','
    b.eq 6f
    cmp w9, #';'
    b.eq 6f
    cmp w9, #9
    b.eq 6f
    cmp w9, #'*'
    b.eq 51f
    cmp w9, #'?'
    b.ne 52f
51:
    mov x22, #1
52:
    strb w9, [x21], #1
    add x20, x20, #1
    b 5b
6:
    strb wzr, [x21]
    cbnz x22, for_wild
    add x0, sp, #512
    bl for_run
    b for_next_item
for_wild:
    // Matching files; the directory part of the pattern is kept.
    bl dos_get_dta
    str x0, [sp, #1024]
    str x2, [sp, #1032]
    address x0, for_dta
    mov x1, #280
    bl dos_set_dta
    add x0, sp, #512
    mov x1, #0
    bl dos_find_first
    mov x23, x1
    add x0, sp, #512            // x24 = length of the directory prefix
    mov x24, #0
    mov x9, #0
7:
    ldrb w10, [x0, x9]
    cbz w10, 8f
    add x9, x9, #1
    cmp w10, #'\\'
    b.eq 71f
    cmp w10, #':'
    b.ne 7b
71:
    mov x24, x9
    b 7b
8:
    ldr x0, [sp, #1024]
    ldr x1, [sp, #1032]
    bl dos_set_dta
    cbnz x23, for_next_item
    address x0, for_dta
    add x0, x0, #24
    add x1, sp, #512
    add x1, x1, x24
    bl copy_cstring
    add x0, sp, #512
    bl for_run
    bl dos_get_dta
    str x0, [sp, #1024]
    str x2, [sp, #1032]
    address x0, for_dta
    mov x1, #280
    bl dos_set_dta
    bl dos_find_next
    mov x23, x1
    b 8b
for_done:
    address x9, for_active
    str xzr, [x9]
    b for_return
for_nested:
    address x0, for_nested_message
    bl puts
    b for_return
for_syntax:
    address x0, syntax_error_message
    bl puts
for_return:
    add sp, sp, #FOR_FRAME
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// x0 = item. Substitutes %v (w19) in the template at [caller sp+256]
// into [caller sp+768] and runs it. Uses the caller's frame (x29-relative
// would be cleaner, but FOR_FRAME is fixed): frame base = x29 of cmd_for.
for_run:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    add x9, sp, #16             // cmd_for's buffers
    add x10, x9, #256           // template
    add x11, x9, #768           // command
    mov x12, #0
1:
    ldrb w13, [x10], #1
    cbz w13, 4f
    cmp w13, #'%'
    b.ne 3f
    ldrb w14, [x10]
    cmp w14, w19
    b.ne 3f
    add x10, x10, #1
    mov x15, x0
2:
    ldrb w13, [x15], #1
    cbz w13, 1b
    cmp x12, #254
    b.hs 1b
    strb w13, [x11, x12]
    add x12, x12, #1
    b 2b
3:
    cmp x12, #254
    b.hs 1b
    strb w13, [x11, x12]
    add x12, x12, #1
    b 1b
4:
    strb wzr, [x11, x12]
    mov x0, x11
    bl shell_execute
    ldp x29, x30, [sp], #16
    ret

// x0 = text, x1 = upper-case keyword. If text starts with the keyword
// followed by a blank or '(' returns x0 past it and x1 = 1; else x1 = 0.
keyword_prefix:
    mov x9, x0
1:
    ldrb w10, [x1], #1
    cbz w10, 2f
    ldrb w11, [x9], #1
    sub w12, w11, #'a'
    cmp w12, #25
    b.hi 11f
    sub w11, w11, #32
11:
    cmp w10, w11
    b.eq 1b
    mov x1, #0
    ret
2:
    ldrb w11, [x9]
    cbz w11, 3f
    cmp w11, #' '
    b.eq 3f
    cmp w11, #9
    b.eq 3f
    cmp w11, #'('
    b.eq 3f
    mov x1, #0
    ret
3:
    mov x0, x9
    mov x1, #1
    ret

// ---------------------------------------------------------------------------
// SHIFT: %0 <- %1 ... %9 <- next unused argument.
cmd_shift:
    frame
    stp x19, x20, [sp, #-16]!
    address x19, batch_context
    ldr x19, [x19]
    cbz x19, 3f
    mov x9, #0
1:
    add x10, x19, #16
    add x11, x9, #1
    ldr x12, [x10, x11, lsl #3]
    str x12, [x10, x9, lsl #3]
    mov x9, x11
    cmp x9, #9
    b.lo 1b
    ldr x0, [x19, #104]         // rest of the original arguments
    bl next_word
    str x0, [x19, #88]          // %9
    str x1, [x19, #104]
3:
    ldp x19, x20, [sp], #16
    unframe

// ---------------------------------------------------------------------------
// IF [NOT] ERRORLEVEL n | EXIST file | string1==string2 command
cmd_if:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x21, #0                 // NOT
    bl skip_blanks
    mov x19, x0
    address x1, not_keyword
    bl keyword_prefix
    cbz x1, 1f
    mov x21, #1
    bl skip_blanks
    mov x19, x0
1:
    mov x0, x19
    address x1, errorlevel_keyword
    bl keyword_prefix
    cbz x1, 2f
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
    bl keyword_prefix
    cbz x1, if_strings
    bl next_word
    mov x20, x1
    bl if_file_exists
    mov x22, x0
    b if_evaluate
if_strings:
    // string1==string2: both sides are compared exactly (quotes included).
    mov x9, x19
3:
    ldrb w10, [x9]
    cbz w10, if_error
    cmp w10, #'='
    b.ne 4f
    ldrb w11, [x9, #1]
    cmp w11, #'='
    b.eq 5f
4:
    add x9, x9, #1
    b 3b
5:
    mov x10, x9                 // end of string1 (trim blanks before ==)
51:
    cmp x10, x19
    b.eq 52f
    ldurb w11, [x10, #-1]
    cmp w11, #' '
    b.ne 52f
    sub x10, x10, #1
    b 51b
52:
    sub x22, x10, x19           // length of string1
    add x0, x9, #2
    bl skip_blanks
    mov x9, x0                  // string2 runs to the next blank
6:
    ldrb w11, [x9]
    cbz w11, 7f
    cmp w11, #' '
    b.eq 7f
    cmp w11, #9
    b.eq 7f
    add x9, x9, #1
    b 6b
7:
    sub x12, x9, x0
    mov x20, x9
    cmp x12, x22
    b.ne 9f
    mov x13, #0
8:
    cmp x13, x12
    b.hs 10f
    ldrb w14, [x19, x13]
    ldrb w15, [x0, x13]
    cmp w14, w15
    b.ne 9f
    add x13, x13, #1
    b 8b
9:
    mov x22, #0
    b if_evaluate
10:
    mov x22, #1
if_evaluate:
    eor x22, x22, x21
    cbz x22, if_return
    mov x0, x20
    bl skip_blanks
    bl shell_execute
    b if_return
if_error:
    address x0, syntax_error_message
    bl puts
if_return:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// x0 = path (wildcards allowed). Returns x0 = 1 if anything matches.
if_file_exists:
    frame
    stp x19, x20, [sp, #-16]!
    sub sp, sp, #16
    mov x19, x0
    bl dos_get_dta
    stp x0, x2, [sp]
    address x0, if_dta
    mov x1, #280
    bl dos_set_dta
    mov x0, x19
    mov x1, #0x16
    bl dos_find_first
    cmp x1, #0
    cset x20, eq
    cbz x20, 1f
    // Finish the search so its directory object is released.
2:
    bl dos_find_next
    cbz x1, 2b
1:
    ldp x0, x1, [sp]
    bl dos_set_dta
    mov x0, x20
    add sp, sp, #16
    ldp x19, x20, [sp], #16
    unframe

// ---------------------------------------------------------------------------
// VOL: label and serial number from the boot record.
// x0 = arguments: an optional drive ("B:").
cmd_vol:
    frame
    str x19, [sp, #-16]!
    sub sp, sp, #32
    mov x19, #0                 // DOS drive number (0: the current one)
5:
    ldrb w2, [x0]
    cmp w2, #' '
    b.ne 6f
    add x0, x0, #1
    b 5b
6:
    cbz w2, 7f
    ldrb w3, [x0, #1]
    cmp w3, #':'
    b.ne 7f
    bic w2, w2, #0x20
    sub w19, w2, #('A' - 1)
7:
    mov x0, #0
    mov x1, x19
    mov x2, sp
    bl dos_media_id
    cbnz x1, 3f
    address x0, vol_drive_message
    bl puts
    mov x0, x19
    bl drive_letter
    bl stdout_putc
    mov x0, #' '
    bl stdout_putc
    add x0, sp, #6
    address x1, fcb_no_name
    mov x2, #11
    bl label_equal
    cbz x0, 1f
    address x0, vol_no_label
    bl puts
    b 2f
1:
    address x0, vol_is
    bl puts
    strb wzr, [sp, #17]
    add x0, sp, #6
    bl trim_trailing
    add x0, sp, #6
    bl puts
    address x0, newline
    bl puts
2:
    address x0, vol_serial_message
    bl puts
    ldrb w0, [sp, #5]
    ldrb w9, [sp, #4]
    orr w0, w9, w0, lsl #8
    mov x1, #4
    bl print_hex_digits
    mov x0, #'-'
    bl stdout_putc
    ldrb w0, [sp, #3]
    ldrb w9, [sp, #2]
    orr w0, w9, w0, lsl #8
    mov x1, #4
    bl print_hex_digits
    address x0, newline
    bl puts
    b 4f
3:
    address x0, invalid_drive_message
    bl puts
4:
    add sp, sp, #32
    ldr x19, [sp], #16
    unframe

// x0 = DOS drive number (0 current, 1 A:). Returns x0 = its letter.
drive_letter:
    cbnz x0, 1f
    adrp x0, current_drive
    ldr x0, [x0, :lo12:current_drive]
    add x0, x0, #1
1:
    add x0, x0, #('A' - 1)
    ret

// x0, x1, x2 = count: x0 = 1 when the byte ranges are equal.
label_equal:
    cbz x2, 1f
    ldrb w9, [x0], #1
    ldrb w10, [x1], #1
    cmp w9, w10
    b.ne 2f
    sub x2, x2, #1
    b label_equal
1:
    mov x0, #1
    ret
2:
    mov x0, #0
    ret

// x0 = value, x1 = digits: upper-case hexadecimal.
print_hex_digits:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    lsl x20, x1, #2
1:
    subs x20, x20, #4
    b.mi 2f
    lsr x0, x19, x20
    and x0, x0, #15
    cmp x0, #10
    add x1, x0, #'0'
    add x2, x0, #('A' - 10)
    csel x0, x1, x2, lo
    bl stdout_putc
    b 1b
2:
    ldp x19, x20, [sp], #16
    unframe

// ---------------------------------------------------------------------------
// x0 = argument, x1 = "X is" message. Returns x0 = -1 no argument,
// 0 OFF, 1 ON, 2 invalid.
on_off_argument:
    frame
    stp x19, x20, [sp, #-16]!
    bl skip_blanks
    mov x19, x0
    bl trim_trailing
    ldrb w9, [x19]
    mov x0, #-1
    cbz w9, 9f
    mov x0, x19
    address x1, echo_on_keyword
    bl strcasecmp
    mov x9, x0
    mov x0, #1
    cbz x9, 9f
    mov x0, x19
    address x1, echo_off_keyword
    bl strcasecmp
    mov x9, x0
    mov x0, #0
    cbz x9, 9f
    mov x0, #2
9:
    ldp x19, x20, [sp], #16
    unframe

// x0 = message prefix, x1 = state.
print_on_off:
    frame
    str x1, [sp, #-16]!
    bl puts
    ldr x1, [sp], #16
    address x0, off_word
    cbz x1, 1f
    address x0, on_word
1:
    bl puts
    unframe

cmd_verify:
    frame
    bl on_off_argument
    cmn x0, #1
    b.ne 1f
    bl dos_get_verify
    mov x1, x0
    address x0, verify_is
    bl print_on_off
    unframe
1:
    cmp x0, #2
    b.eq 2f
    bl dos_set_verify
    unframe
2:
    address x0, on_off_required
    bl puts
    unframe

cmd_break:
    frame
    bl on_off_argument
    cmn x0, #1
    b.ne 1f
    mov x0, #0
    bl dos_break
    mov x1, x2
    address x0, break_is
    bl print_on_off
    unframe
1:
    cmp x0, #2
    b.eq 2f
    mov x1, x0
    mov x0, #1
    bl dos_break
    unframe
2:
    address x0, on_off_required
    bl puts
    unframe

// CTTY device: standard input, output and error use that device.
cmd_ctty:
    frame
    stp x19, x20, [sp, #-16]!
    bl skip_blanks
    mov x19, x0
    bl trim_trailing
    mov x0, x19
    bl dev_lookup
    cbz x0, 3f
    address x9, dev_objects
    cmp x0, x9
    b.ne 1f
    // CON: back to the unredirected console.
    mov x20, #0
11:
    mov x0, x20
    bl dos_close
    add x20, x20, #1
    cmp x20, #3
    b.lo 11b
    b 4f
1:
    mov x0, x19
    mov x1, #2
    bl dos_open
    cbnz x1, 3f
    mov x19, x0
    mov x20, #0
2:
    mov x0, x19
    mov x1, x20
    bl dos_dup2
    add x20, x20, #1
    cmp x20, #3
    b.lo 2b
    mov x0, x19
    bl dos_close
    b 4f
3:
    address x0, invalid_device_message
    bl puts
4:
    ldp x19, x20, [sp], #16
    unframe

cmd_pause:
    frame
    address x0, pause_message
    bl puts
    bl dos_console_noecho
    address x0, newline
    bl puts
    unframe

cmd_chcp:
    frame
    bl skip_blanks
    ldrb w9, [x0]
    cbnz w9, 1f
    address x0, chcp_message
    bl puts
    mov x0, #1
    bl dos_code_page
    mov x1, #0
    bl print_number_width
    address x0, newline
    bl puts
    unframe
1:
    bl parse_unsigned
    cbnz x1, 2f
    mov x1, x0
    mov x0, #2
    bl dos_code_page
    cbz x1, 3f
2:
    address x0, chcp_invalid
    bl puts
3:
    unframe

cmd_truename:
    frame
    sub sp, sp, #128
    bl skip_blanks
    ldrb w9, [x0]
    cbnz w9, 1f
    address x0, dot_path
1:
    mov x1, sp
    bl dos_truename
    cbnz x1, 2f
    mov x0, sp
    bl puts
    address x0, newline
    bl puts
    b 3f
2:
    address x0, file_error
    bl puts
3:
    add sp, sp, #128
    unframe

// ---------------------------------------------------------------------------
// Dates and times in the selected country's format.
// x0 = 0 for date parts order: returns x0 = date format, x1 = date separator,
// x2 = time separator, x3 = time format (0 12-hour).
country_formats:
    frame
    sub sp, sp, #48
    mov x0, sp
    mov x1, #0
    bl dos_country
    ldrh w0, [sp]
    ldrb w1, [sp, #11]
    ldrb w2, [sp, #13]
    ldrb w3, [sp, #17]
    add sp, sp, #48
    unframe

// "Thu 11-26-2026" (order and separator from the country).
print_date_long:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    bl dos_get_date
    mov x19, x0
    mov x20, x2
    mov x21, x3
    address x9, day_names
    add x0, x9, x4, lsl #2
    bl puts
    mov x0, #' '
    bl stdout_putc
    bl country_formats
    mov x22, x0
    mov x23, x1
    mov x0, x20                 // M/D/Y
    mov x1, x21
    mov x2, x19
    cmp x22, #1
    b.ne 1f
    mov x0, x21                 // D/M/Y
    mov x1, x20
1:
    cmp x22, #2
    b.ne 2f
    mov x0, x19                 // Y/M/D
    mov x1, x20
    mov x2, x21
2:
    mov x24, x2
    mov x19, x1
    bl print_date_field
    mov x0, x23
    bl stdout_putc
    mov x0, x19
    bl print_date_field
    mov x0, x23
    bl stdout_putc
    mov x0, x24
    bl print_date_field
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe
print_date_field:
    mov x1, #2
    cmp x0, #100
    b.lo 1f
    mov x1, #4
1:
    b print_padded_number

// "15:43:12.34" (24-hour) or " 3:43:12.34p" (12-hour countries).
print_time_long:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    bl dos_get_time
    mov x19, x0
    mov x20, x2
    mov x21, x3
    mov x22, x4
    bl country_formats
    mov x23, x2                 // time separator
    mov x24, x3                 // time format
    mov x0, x19
    cbnz x24, 1f
    cmp x0, #12
    b.lo 11f
    sub x0, x0, #12
11:
    cbnz x0, 1f
    mov x0, #12
1:
    cbnz x24, 2f
    cmp x0, #10
    b.hs 2f
    str x0, [sp, #-16]!
    mov x0, #' '
    bl stdout_putc
    ldr x0, [sp], #16
    mov x1, #1
    bl print_padded_number
    b 3f
2:
    mov x1, #2
    bl print_padded_number
3:
    mov x0, x23
    bl stdout_putc
    mov x0, x20
    mov x1, #2
    bl print_padded_number
    mov x0, x23
    bl stdout_putc
    mov x0, x21
    mov x1, #2
    bl print_padded_number
    mov x0, #'.'
    bl stdout_putc
    mov x0, x22
    mov x1, #2
    bl print_padded_number
    cbnz x24, 4f
    mov x0, #'a'
    cmp x19, #12
    b.lo 41f
    mov x0, #'p'
41:
    bl stdout_putc
4:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// x0 = text: up to three numbers separated by any non-digit. Returns
// x1 = count, numbers in date_numbers[0..2], x2 = first letter seen (a/p).
parse_numbers:
    address x9, date_numbers
    stp xzr, xzr, [x9]
    str xzr, [x9, #16]
    mov x1, #0                  // count
    mov x2, #0
    mov x10, #0                 // in a number
1:
    ldrb w11, [x0], #1
    cbz w11, 4f
    sub w12, w11, #'0'
    cmp w12, #9
    b.hi 2f
    cmp x1, #3
    b.hs 1b
    ldr x13, [x9, x1, lsl #3]
    mov x14, #10
    madd x13, x13, x14, x12
    str x13, [x9, x1, lsl #3]
    mov x10, #1
    b 1b
2:
    orr w13, w11, #0x20
    cmp w13, #'a'
    b.lo 3f
    cmp w13, #'z'
    b.hi 3f
    cbnz x2, 3f
    mov x2, x13
3:
    cbz x10, 1b
    add x1, x1, #1
    mov x10, #0
    b 1b
4:
    cbz x10, 5f
    add x1, x1, #1
5:
    ret

// DATE [date]: without an argument shows the date and asks for a new one.
cmd_date:
    frame
    stp x19, x20, [sp, #-16]!
    bl skip_blanks
    mov x19, x0
    ldrb w9, [x19]
    cbnz w9, date_set
    address x0, current_date_message
    bl puts
    bl print_date_long
    address x0, newline
    bl puts
date_ask:
    bl country_formats
    address x9, date_prompts
    add x0, x9, x0, lsl #5
    bl puts
    address x0, command_buffer
    mov x1, #20
    bl read_line
    address x19, command_buffer
    ldrb w9, [x19]
    cbz w9, date_return         // Enter keeps the date
date_set:
    mov x0, x19
    bl parse_numbers
    cmp x1, #3
    b.ne date_invalid
    bl country_formats
    address x9, date_numbers
    ldr x10, [x9]
    ldr x11, [x9, #8]
    ldr x12, [x9, #16]
    mov x1, x10                 // month
    mov x2, x11                 // day
    mov x0, x12                 // year
    cmp x0, #1
    b.ne 1f
    mov x1, x11                 // D/M/Y
    mov x2, x10
1:
    cmp x0, #2
    b.ne 2f
    mov x0, x10                 // Y/M/D
    mov x1, x11
    mov x2, x12
    b 3f
2:
    mov x0, x12
3:
    cmp x0, #80
    b.hs 4f
    add x0, x0, #2000           // two-digit years: 80-99 1900s, 00-79 2000s
    b 5f
4:
    cmp x0, #100
    b.hs 5f
    add x0, x0, #1900
5:
    bl dos_set_date
    cbz x1, date_return
date_invalid:
    address x0, invalid_date_message
    bl puts
    b date_ask
date_return:
    ldp x19, x20, [sp], #16
    unframe

// TIME [time]
cmd_time:
    frame
    stp x19, x20, [sp, #-16]!
    bl skip_blanks
    mov x19, x0
    ldrb w9, [x19]
    cbnz w9, time_set
    address x0, current_time_message
    bl puts
    bl print_time_long
    address x0, newline
    bl puts
time_ask:
    address x0, time_prompt
    bl puts
    address x0, command_buffer
    mov x1, #20
    bl read_line
    address x19, command_buffer
    ldrb w9, [x19]
    cbz w9, time_return
time_set:
    mov x0, x19
    bl parse_numbers
    cbz x1, time_invalid
    address x9, date_numbers
    ldr x0, [x9]
    ldr x10, [x9, #8]
    ldr x11, [x9, #16]
    cmp x2, #'p'
    b.ne 1f
    cmp x0, #12
    b.hs 1f
    add x0, x0, #12
1:
    cmp x2, #'a'
    b.ne 2f
    cmp x0, #12
    b.ne 2f
    mov x0, #0
2:
    mov x1, x10
    mov x2, x11
    mov x3, #0
    bl dos_set_time
    cbz x1, time_return
time_invalid:
    address x0, invalid_time_message
    bl puts
    b time_ask
time_return:
    ldp x19, x20, [sp], #16
    unframe

.section .rodata
pipe_template: .asciz "\\%PIPE#.$$$"
for_in_keyword: .asciz "IN"
for_do_keyword: .asciz "DO"
for_nested_message: .asciz "FOR cannot be nested\r\n"
vol_drive_message: .asciz " Volume in drive "
invalid_drive_message: .asciz "Invalid drive specification\r\n"
vol_no_label: .asciz "has no label\r\n"
vol_is: .asciz "is "
vol_serial_message: .asciz " Volume Serial Number is "
verify_is: .asciz "VERIFY is "
break_is: .asciz "BREAK is "
on_word: .asciz "on\r\n"
off_word: .asciz "off\r\n"
on_off_required: .asciz "Must specify ON or OFF\r\n"
invalid_device_message: .asciz "Invalid device\r\n"
pause_message: .asciz "Press any key to continue . . ."
chcp_message: .asciz "Active code page: "
chcp_invalid: .asciz "Invalid code page\r\n"
dot_path: .asciz "."
day_names: .ascii "Sun\0Mon\0Tue\0Wed\0Thu\0Fri\0Sat\0"
current_date_message: .asciz "Current date is "
current_time_message: .asciz "Current time is "
.balign 32
date_prompts:
    .asciz "Enter new date (mm-dd-yy): "
    .balign 32
    .asciz "Enter new date (dd-mm-yy): "
    .balign 32
    .asciz "Enter new date (yy-mm-dd): "
time_prompt: .asciz "Enter new time: "
invalid_date_message: .asciz "Invalid date\r\n"
invalid_time_message: .asciz "Invalid time\r\n"

.section .bss
.balign 16
for_active: .skip 8
for_dta: .skip 280
if_dta: .skip 280
date_numbers: .skip 24
