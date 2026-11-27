// SPDX-License-Identifier: MIT
// REPLACE [d:][path]filename [d:][path] [/A] [/P] [/R] [/S] [/U] [/W]
// (MS-DOS 4.0 src/CMD/REPLACE): replaces files in the target directory (and with
// /S its subdirectories) by the source files of the same name, or with /A
// adds the source files the target lacks. /P asks first, /R also replaces
// read-only files, /U only replaces older files, /W waits for a key.
.include "lib.inc"
.equ OPT_A, 1
.equ OPT_P, 2
.equ OPT_R, 4
.equ OPT_S, 8
.equ OPT_U, 16
.equ OPT_W, 32
.equ LEVEL, 1024
.equ L_DIR, 0
.equ L_DTA, 512
.equ MAX_DEPTH, 13
.equ BUF_SIZE, 65536

main:
    enter
    mov x19, x0
    mov x20, #0                 // options
    mov x21, #0                 // source
    mov x22, #0                 // target
1:
    mov x0, x19
    bl next_arg
    mov x19, x1
    ldrb w2, [x0]
    cbz w2, 4f
    cmp w2, #'/'
    b.eq 2f
    cbnz x21, 11f
    mov x21, x0
    b 1b
11:
    cbnz x22, bad_parm
    mov x22, x0
    b 1b
2:
    ldrb w3, [x0, #2]
    cbnz w3, bad_switch
    ldrb w0, [x0, #1]
    bl toupper
    address x9, switch_letters
    mov x3, #1
21:
    ldrb w4, [x9], #1
    cbz w4, bad_switch
    cmp w0, w4
    b.eq 22f
    lsl x3, x3, #1
    b 21b
22:
    orr x20, x20, x3
    b 1b
4:
    cbz x21, missing
    // /A cannot be combined with /S or /U.
    tbz x20, #0, 41f
    mov x2, #(OPT_S | OPT_U)
    tst x20, x2
    b.ne bad_combo
41:
    address x9, options
    str x20, [x9]
    mov x0, x21
    bl strupr
    mov x0, x21
    bl basename
    mov x23, x0
    address x1, pattern
    bl strcpy
    sub x2, x23, x21
    address x1, source_dir
    mov x3, #0
42:
    cmp x3, x2
    b.hs 43f
    ldrb w4, [x21, x3]
    strb w4, [x1, x3]
    add x3, x3, #1
    b 42b
43:
    strb wzr, [x1, x3]
    address x24, levels
    strb wzr, [x24, #L_DIR]
    cbz x22, 44f
    mov x0, x22
    bl strupr
    mov x0, x22
    bl is_directory
    cbz x0, bad_path
    mov x0, x22
    add x1, x24, #L_DIR
    bl strcpy
44:
    // The source must match something.
    address x0, source_dir
    address x1, pattern
    address x2, spath
    bl join_path
    address x0, source_dta
    mov x1, #280
    dos 0x1a
    address x0, spath
    mov x1, #0x01
    dos 0x4e
    cbz x1, 45f
    say "No files found "
    address x0, spath
    bl puts
    bl crlf
    mov x0, #2
    leave
45:
    tbz x20, #5, 46f            // /W
    bl press_any_key
46:
    tbz x20, #0, 47f
    bl add_files
    b 48f
47:
    mov x0, #0
    bl walk
48:
    bl crlf
    address x9, done_count
    ldr x0, [x9]
    cbnz x0, 49f
    address x9, options
    ldr x2, [x9]
    tbz x2, #0, 481f
    say "No files added\r\n"
    b 50f
481:
    say "No files replaced\r\n"
    b 50f
49:
    mov x1, #5
    bl put_dec
    address x9, options
    ldr x2, [x9]
    tbz x2, #0, 491f
    say " file(s) added\r\n"
    b 50f
491:
    say " file(s) replaced\r\n"
50:
    address x9, failed
    ldr x0, [x9]
    leave
missing:
    say "Source path required\r\n"
    mov x0, #11
    leave
bad_parm:
    say "Too many parameters\r\n"
    mov x0, #11
    leave
bad_switch:
    say "Invalid switch\r\n"
    mov x0, #11
    leave
bad_combo:
    say "Invalid parameter combination\r\n"
    mov x0, #11
    leave
bad_path:
    say "Path not found - "
    mov x0, x22
    bl puts
    bl crlf
    mov x0, #3
    leave

// /A: every source file the target directory lacks.
add_files:
    enter
    address x19, levels
1:
    address x0, source_dir
    address x1, pattern
    address x2, spath
    bl join_path
    address x0, source_dta
    mov x1, #280
    dos 0x1a
    address x0, spath
    mov x1, #0x01
    dos 0x4e
2:
    cbnz x1, 9f
    address x0, source_dir
    address x1, source_dta + 24
    address x2, spath
    bl join_path
    add x0, x19, #L_DIR
    address x1, source_dta + 24
    address x2, dpath
    bl join_path
    address x0, dpath
    bl target_info
    cbz x1, 3f                  // already there
    address x0, adding
    bl act
3:
    address x0, source_dta
    mov x1, #280
    dos 0x1a
    dos 0x4f
    b 2b
9:
    leave

// x0 = depth: replaces the files of levels[depth] that the source has.
walk:
    enter
    mov x19, x0
    address x20, levels
    mov x2, #LEVEL
    madd x20, x19, x2, x20
    address x0, source_dir
    address x1, pattern
    address x2, spath
    bl join_path
    address x0, source_dta
    mov x1, #280
    dos 0x1a
    address x0, spath
    mov x1, #0x01
    dos 0x4e
1:
    cbnz x1, 5f
    address x0, source_dir
    address x1, source_dta + 24
    address x2, spath
    bl join_path
    add x0, x20, #L_DIR
    address x1, source_dta + 24
    address x2, dpath
    bl join_path
    address x0, dpath
    bl target_info
    cbnz x1, 4f                 // not in this directory
    mov x21, x0                 // attributes
    mov x22, x2                 // date << 16 | time
    // A source copy never replaces itself.
    address x0, spath
    address x1, truename1
    dos 0x60
    address x0, dpath
    address x1, truename2
    dos 0x60
    address x0, truename1
    address x1, truename2
    bl strcmp
    cbz x0, 4f
    address x9, options
    ldr x23, [x9]
    tbz x23, #4, 2f             // /U: only older targets
    address x9, source_dta
    ldrh w2, [x9, #18]
    ldrh w3, [x9, #16]
    orr x2, x3, x2, lsl #16
    cmp x22, x2
    b.hs 4f
2:
    tbz x21, #0, 3f
    tbnz x23, #2, 21f           // /R
    say "Access denied - "
    bl show_target
    bl crlf
    address x9, failed
    mov x2, #5
    str x2, [x9]
    b 4f
21:
    address x0, dpath
    mov x1, #1
    mov x2, #0x20
    dos 0x43
3:
    address x0, replacing
    bl act
4:
    address x0, source_dta
    mov x1, #280
    dos 0x1a
    dos 0x4f
    b 1b
5:
    address x9, options
    ldr x2, [x9]
    tbz x2, #3, 9f              // /S
    cmp x19, #MAX_DEPTH - 1
    b.lo 7788f
    add x0, x20, #L_DIR
    bl depth_note               // deeper directories are skipped, not lost
    b 9f
7788:
    add x0, x20, #L_DIR
    address x1, star_star
    address x2, spath
    bl join_path
    add x0, x20, #L_DTA
    mov x1, #280
    dos 0x1a
    address x0, spath
    mov x1, #0x10
    dos 0x4e
6:
    cbnz x1, 9f
    ldr x2, [x20, #L_DTA]
    tbz x2, #4, 7f
    ldrb w2, [x20, #L_DTA + 24]
    cmp w2, #'.'
    b.eq 7f
    add x0, x20, #L_DIR
    add x1, x20, #L_DTA + 24
    add x2, x20, #LEVEL + L_DIR
    bl join_path
    add x0, x19, #1
    bl walk
    add x0, x20, #L_DTA
    mov x1, #280
    dos 0x1a
7:
    dos 0x4f
    b 6b
9:
    leave

// x0 = path. Returns x1 = 0 when it is an existing file, with x0 = its
// attributes and x2 = date << 16 | time; x1 = 1 otherwise.
target_info:
    frame
    str x0, [sp, #-16]!
    address x0, probe_dta
    mov x1, #280
    dos 0x1a
    ldr x0, [sp], #16
    mov x1, #0x07
    dos 0x4e
    cbnz x1, 9f
    address x9, probe_dta
    ldr x0, [x9]
    ldrh w2, [x9, #18]
    ldrh w3, [x9, #16]
    orr x2, x3, x2, lsl #16
    mov x1, #0
9:
    unframe

// x0 = verb ("Replacing " / "Adding "): asks with /P, then copies spath
// to dpath.
act:
    enter
    mov x19, x0
    address x9, options
    ldr x20, [x9]
    tbz x20, #1, 1f
    // "Replace A:\X? (Y/N)" / "Add A:\X? (Y/N)"
    address x0, ask_add
    ldrb w2, [x19]
    cmp w2, #'R'
    b.ne 11f
    address x0, ask_replace
11:
    bl puts
    bl show_target
    address x0, yes_no
    bl ask_yn
    cbz x0, 9f
1:
    mov x0, x19
    bl puts
    bl show_target
    bl crlf
    bl copy_file
9:
    leave

// Prints dpath as a full path (A:\DIR\NAME).
show_target:
    frame
    address x0, dpath
    address x1, truename2
    dos 0x60
    address x0, truename2
    cbz x1, 1f
    address x0, dpath
1:
    bl puts
    unframe

// Copies spath to dpath, keeping the date and time.
copy_file:
    enter
    address x0, spath
    mov x1, #0
    bl fopen
    cbnz x1, 8f
    mov x19, x0
    address x0, dpath
    mov x1, #0
    bl fcreate
    cbz x1, 1f
    mov x20, x0
    mov x0, x19
    bl fclose
    mov x0, x20
    b 8f
1:
    mov x20, x0
2:
    mov x0, x19
    address x1, buffer
    mov x2, #BUF_SIZE
    bl fread
    cbnz x1, 7f
    cbz x0, 3f
    mov x21, x0
    mov x2, x0
    mov x0, x20
    address x1, buffer
    bl fwrite
    cbnz x1, 7f
    cmp x0, x21
    b.eq 2b
    mov x0, #39                 // disk full
    b 7f
3:
    mov x0, x19
    mov x1, #0
    dos 0x57
    mov x0, x20
    mov x1, #1
    dos 0x57
    mov x0, x19
    bl fclose
    mov x0, x20
    bl fclose
    address x9, done_count
    ldr x2, [x9]
    add x2, x2, #1
    str x2, [x9]
    leave
7:
    mov x21, x0
    mov x0, x19
    bl fclose
    mov x0, x20
    bl fclose
    mov x0, x21
8:
    cmp x0, #39
    b.ne 81f
    say "Insufficient disk space\r\n"
    b 82f
81:
    bl print_error
82:
    address x9, failed
    mov x2, #8
    str x2, [x9]
    leave

.section .rodata
switch_letters: .asciz "APRSUW"
star_star: .asciz "*.*"
replacing: .asciz "Replacing "
adding: .asciz "Adding "
yes_no: .asciz "? (Y/N)"
ask_replace: .asciz "Replace "
ask_add: .asciz "Add "
.section .bss
.balign 8
options: .skip 8
done_count: .skip 8
failed: .skip 8
pattern: .skip 128
source_dir: .skip 256
spath: .skip 512
dpath: .skip 512
truename1: .skip 128
truename2: .skip 128
.balign 8
source_dta: .skip 280
.balign 8
probe_dta: .skip 280
.balign 16
levels: .skip LEVEL * MAX_DEPTH
buffer: .skip BUF_SIZE
