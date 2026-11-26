// SPDX-License-Identifier: MIT
// COMMAND environment (ENV.ASM / TENV.ASM): a block of NAME=value strings
// ending in an empty string, passed to every program as descriptor +40.
// SET, PATH and PROMPT, PATH search for external commands, and the PROMPT
// metacharacters ($P $G $N $D $T $V $L $B $Q $$ $_ $E $H).
.equ ENV_SIZE, 4096
.section .text

env_init:
    frame
    address x0, env_default
    address x1, env_block
    mov x2, #(env_default_end - env_default)
    bl copy_bytes
    unframe

// x0 = name. Returns x0 = entry start (or 0), x1 = its value.
env_find:
    address x9, env_block
1:
    ldrb w10, [x9]
    cbz w10, 5f
    mov x11, x9
    mov x12, x0
2:
    ldrb w13, [x11]
    ldrb w14, [x12]
    cmp w14, #0
    b.ne 3f
    cmp w13, #'='
    b.eq 6f
    b 4f
3:
    sub w15, w13, #'a'
    cmp w15, #25
    b.hi 31f
    sub w13, w13, #32
31:
    sub w15, w14, #'a'
    cmp w15, #25
    b.hi 32f
    sub w14, w14, #32
32:
    cmp w13, w14
    b.ne 4f
    add x11, x11, #1
    add x12, x12, #1
    b 2b
4:
    ldrb w10, [x9], #1          // skip to the next entry
    cbnz w10, 4b
    b 1b
5:
    mov x0, #0
    mov x1, #0
    ret
6:
    mov x0, x9
    add x1, x11, #1
    ret

// x0 = name. Returns x0 = value or 0.
env_get:
    frame
    bl env_find
    mov x0, x1
    unframe

// x0 = name, x1 = value (empty or 0 removes). Returns x1 = 0, or x1 = 1
// when the block is full ("Out of environment space").
env_set:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    bl env_find
    cbz x0, 3f
    // Remove the old entry by moving the rest of the block down.
    mov x9, x0
1:
    ldrb w10, [x9], #1
    cbnz w10, 1b
    mov x10, x0
2:
    ldrb w11, [x9]
    cbz w11, 22f
21:
    ldrb w11, [x9], #1
    strb w11, [x10], #1
    cbnz w11, 21b
    b 2b
22:
    strb wzr, [x10]
3:
    cbz x20, 9f
    ldrb w9, [x20]
    cbz w9, 9f
    // Append at the end: find the terminating empty string.
    address x21, env_block
4:
    ldrb w9, [x21]
    cbz w9, 6f
5:
    ldrb w9, [x21], #1
    cbnz w9, 5b
    b 4b
6:
    mov x0, x19
    bl fat_strlen
    mov x22, x0
    mov x0, x20
    bl fat_strlen
    add x9, x22, x0
    add x9, x9, #3              // '=', NUL, final NUL
    address x10, env_block
    sub x11, x21, x10
    add x11, x11, x9
    cmp x11, #ENV_SIZE
    b.hi 8f
    mov x9, x19
7:
    ldrb w0, [x9], #1
    cbz w0, 71f
    str x9, [sp, #-16]!
    bl nls_upper                // variable names are upper case
    ldr x9, [sp], #16
    strb w0, [x21], #1
    b 7b
71:
    mov w0, #'='
    strb w0, [x21], #1
    mov x0, x20
    mov x1, x21
    bl copy_cstring
72:
    ldrb w0, [x21], #1
    cbnz w0, 72b
    strb wzr, [x21]
9:
    mov x1, #0
    b 10f
8:
    address x0, env_full_message
    bl puts
    mov x1, #1
10:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// SET [name=[value]]
cmd_set:
    frame
    stp x19, x20, [sp, #-16]!
    bl skip_blanks
    mov x19, x0
    ldrb w9, [x19]
    cbnz w9, 2f
    address x20, env_block      // list every variable
1:
    ldrb w9, [x20]
    cbz w9, 9f
    mov x0, x20
    bl puts
    address x0, newline
    bl puts
11:
    ldrb w9, [x20], #1
    cbnz w9, 11b
    b 1b
2:
    mov x9, x19
3:
    ldrb w10, [x9]
    cbz w10, 8f
    cmp w10, #'='
    b.eq 4f
    add x9, x9, #1
    b 3b
4:
    cmp x9, x19
    b.eq 8f
    strb wzr, [x9]
    add x1, x9, #1
    mov x0, x19
    bl trim_trailing
    mov x0, x19
    bl env_set
    b 9f
8:
    address x0, syntax_error_message
    bl puts
9:
    ldp x19, x20, [sp], #16
    unframe

// PATH [;|dirs]
cmd_path:
    frame
    str x19, [sp, #-16]!
    bl skip_blanks
    mov x19, x0
    ldrb w9, [x19]
    cbnz w9, 2f
    address x0, path_keyword
    bl env_get
    cbz x0, 1f
    mov x19, x0
    address x0, path_equals
    bl puts
    mov x0, x19
    bl puts
    address x0, newline
    bl puts
    b 9f
1:
    address x0, no_path_message
    bl puts
    b 9f
2:
    cmp w9, #';'
    b.ne 3f
    ldrb w10, [x19, #1]
    cbnz w10, 3f
    address x0, path_keyword
    mov x1, #0
    bl env_set
    b 9f
3:
    mov x0, x19
    bl trim_trailing
    mov x11, x19
4:
    ldrb w0, [x11]
    cbz w0, 5f
    bl nls_upper
    strb w0, [x11], #1
    b 4b
5:
    address x0, path_keyword
    mov x1, x19
    bl env_set
9:
    ldr x19, [sp], #16
    unframe

// PROMPT [text]
cmd_prompt:
    frame
    bl skip_blanks
    mov x1, x0
    address x0, prompt_keyword
    bl env_set
    unframe

// Shell prompt from PROMPT (default $P$G).
shell_prompt:
    frame
    stp x19, x20, [sp, #-16]!
    address x0, prompt_keyword
    bl env_get
    mov x19, x0
    cbnz x19, 1f
    address x19, prompt_default
1:
    ldrb w20, [x19], #1
    cbz w20, 9f
    cmp w20, #'$'
    b.eq 2f
    mov x0, x20
    bl stdout_putc
    b 1b
2:
    ldrb w0, [x19], #1
    cbz w0, 9f
    bl nls_upper
    mov w20, w0
    cmp w20, #'P'
    b.ne 3f
    address x0, drive_prefix
    bl puts
    address x0, current_directory
    bl puts
    b 1b
3:
    mov w0, #'>'
    cmp w20, #'G'
    b.eq 8f
    mov w0, #'<'
    cmp w20, #'L'
    b.eq 8f
    mov w0, #'|'
    cmp w20, #'B'
    b.eq 8f
    mov w0, #'='
    cmp w20, #'Q'
    b.eq 8f
    mov w0, #'$'
    cmp w20, #'$'
    b.eq 8f
    mov w0, #27
    cmp w20, #'E'
    b.eq 8f
    mov w0, #8
    cmp w20, #'H'
    b.eq 8f
    cmp w20, #'N'
    b.ne 4f
    mov w0, #'A'
    b 8f
4:
    cmp w20, #'_'
    b.ne 5f
    address x0, newline
    bl puts
    b 1b
5:
    cmp w20, #'D'
    b.ne 6f
    bl print_date_long
    b 1b
6:
    cmp w20, #'T'
    b.ne 7f
    bl print_time_long
    b 1b
7:
    cmp w20, #'V'
    b.ne 1b                     // unknown metacharacters print nothing
    address x0, version_message_short
    bl puts
    b 1b
8:
    bl stdout_putc
    b 1b
9:
    ldp x19, x20, [sp], #16
    unframe

// x0 = command name without extension handling done by the caller,
// x1 = command tail. Tries the name, then name.EXE and name.BAT, first in
// the current directory and then in each PATH directory (COMMAND's search).
// Returns x1 = 0 when something ran, x1 = 1 with x0 = 2 when not found.
path_search_run:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x0, x19
    mov x1, x20
    bl run_candidates
    cbz x1, 9f
    cmp x0, #2
    b.ne 9f
    // A name with a drive or directory is never searched for on PATH.
    mov x9, x19
1:
    ldrb w10, [x9], #1
    cbz w10, 2f
    cmp w10, #'\\'
    b.eq 8f
    cmp w10, #':'
    b.eq 8f
    cmp w10, #'/'
    b.eq 8f
    b 1b
2:
    address x0, path_keyword
    bl env_get
    cbz x0, 8f
    mov x21, x0                 // PATH cursor
3:
    ldrb w9, [x21]
    cbz w9, 8f
    address x22, path_candidate
    mov x23, #0
4:
    ldrb w9, [x21]
    cbz w9, 5f
    add x21, x21, #1
    cmp w9, #';'
    b.eq 5f
    cmp x23, #200
    b.hs 4b
    strb w9, [x22, x23]
    add x23, x23, #1
    b 4b
5:
    cbz x23, 3b
    sub x9, x23, #1
    ldrb w10, [x22, x9]
    cmp w10, #'\\'
    b.eq 6f
    mov w10, #'\\'
    strb w10, [x22, x23]
    add x23, x23, #1
6:
    mov x0, x19
    add x1, x22, x23
    bl copy_cstring
    mov x0, x22
    mov x1, x20
    bl run_candidates
    cbz x1, 9f
    cmp x0, #2
    b.eq 3b
    cmp x0, #3
    b.eq 3b
    b 9f
8:
    mov x0, #2
    mov x1, #1
9:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// x0 = path, x1 = tail: run path as given (.BAT by suffix, otherwise as a
// program), then path.EXE, then path.BAT. x1 = 1, x0 = 2 if none exists.
run_candidates:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    bl fat_strlen
    mov x21, x0
    cmp x21, #4
    b.lo 1f
    add x0, x19, x21
    sub x0, x0, #4
    address x1, bat_suffix
    bl strcasecmp
    cbnz x0, 1f
    mov x0, x19
    mov x1, x20
    bl batch_run
    b 9f
1:
    mov x0, x19
    mov x1, x20
    bl run_program
    cbz x1, 9f
    cmp x0, #2
    b.ne 9f
    cmp x21, #240
    b.hi 9f
    mov x0, x19
    address x1, external_path
    bl copy_cstring
    address x0, exe_suffix
    address x1, external_path
    add x1, x1, x21
    bl copy_cstring
    address x0, external_path
    mov x1, x20
    bl run_program
    cbz x1, 9f
    cmp x0, #2
    b.ne 9f
    address x0, bat_suffix
    address x1, external_path
    add x1, x1, x21
    bl copy_cstring
    address x0, external_path
    mov x1, x20
    bl batch_run
9:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// x0 = program path, x1 = tail. Runs it and records ERRORLEVEL.
run_program:
    frame
    mov x2, #0
    bl dos_exec
    cbnz x1, 1f
    bl dos_get_exit_code
    address x2, shell_errorlevel
    str x0, [x2]
    mov x0, #0
    mov x1, #0
1:
    unframe

// Helpers. x0 = string: returns x0 past spaces and tabs.
skip_blanks:
    ldrb w9, [x0]
    cmp w9, #' '
    b.eq 1f
    cmp w9, #9
    b.ne 2f
1:
    add x0, x0, #1
    b skip_blanks
2:
    ret
// x0 = string: removes trailing spaces and tabs in place.
trim_trailing:
    mov x9, x0
1:
    ldrb w10, [x9]
    cbz w10, 2f
    add x9, x9, #1
    b 1b
2:
    cmp x9, x0
    b.eq 3f
    ldurb w10, [x9, #-1]
    cmp w10, #' '
    b.eq 4f
    cmp w10, #9
    b.ne 3f
4:
    sub x9, x9, #1
    strb wzr, [x9]
    b 2b
3:
    ret

.section .rodata
env_default:
    .asciz "COMSPEC=A:\\EFI\\BOOT\\BOOTAA64.EFI"
    .asciz "PATH=A:\\"
    .byte 0
env_default_end:
prompt_keyword: .asciz "PROMPT"
prompt_default: .asciz "$P$G"
path_equals: .asciz "PATH="
no_path_message: .asciz "No Path\r\n"
env_full_message: .asciz "Out of environment space\r\n"
syntax_error_message: .asciz "Syntax error\r\n"
version_message_short: .asciz "MS-DOS Version 4.00 (AArch64)"

.section .bss
.balign 16
env_block: .skip ENV_SIZE
path_candidate: .skip 256
