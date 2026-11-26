// SPDX-License-Identifier: MIT
// XCOPY source [destination] [/A] [/D:date] [/E] [/M] [/P] [/S] [/V] [/W]
// (v4.0/src/CMD/XCOPY): copies files and, with /S, directory trees.
// /A only archive files, /M the same and then clears their archive bit,
// /D:mm-dd-yy files dated on or after, /E also empty directories, /P asks
// for each file, /W waits for a key first. /V is accepted (writes are
// always checked by the FAT layer).
.include "lib.inc"
.equ OPT_A, 1
.equ OPT_E, 2
.equ OPT_M, 4
.equ OPT_P, 8
.equ OPT_S, 16
.equ OPT_W, 32
.equ OPT_D, 64
.equ LEVEL, 1024                // per depth: source dir, target dir, DTA
.equ L_SRC, 0
.equ L_DST, 256
.equ L_DTA, 512
.equ L_MADE, 800
.equ MAX_DEPTH, 15              // the kernel keeps 16 search contexts
.equ BUF_SIZE, 65536

main:
    enter
    mov x19, x0
    mov x20, #0                 // options
    mov x21, #0                 // source
    mov x22, #0                 // destination
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
    cbnz x22, too_many
    mov x22, x0
    b 1b
2:
    mov x23, x0
    ldrb w0, [x23, #1]
    bl toupper
    ldrb w2, [x23, #2]
    cmp w0, #'D'
    b.eq 3f
    cbnz w2, bad_switch
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
3:
    cmp w2, #':'
    b.ne bad_switch
    add x0, x23, #3
    bl parse_date
    cbnz x1, bad_date
    address x9, min_date
    str x0, [x9]
    orr x20, x20, #OPT_D
    b 1b
4:
    cbz x21, missing
    address x9, options
    str x20, [x9]
    // Source: a directory means all of its files.
    mov x0, x21
    bl strupr
    address x23, levels
    mov x0, x21
    bl is_directory
    cbz x0, 5f
    mov x0, x21
    add x1, x23, #L_SRC
    bl strcpy
    address x0, star_star
    address x1, pattern
    bl strcpy
    b 6f
5:
    mov x0, x21
    bl basename
    mov x24, x0
    address x1, pattern
    bl strcpy
    sub x2, x24, x21            // the directory part, separator kept
    add x1, x23, #L_SRC
    mov x3, #0
51:
    cmp x3, x2
    b.hs 52f
    ldrb w4, [x21, x3]
    strb w4, [x1, x3]
    add x3, x3, #1
    b 51b
52:
    strb wzr, [x1, x3]
6:
    // Destination: a directory (existing, or ending in '\' or ':'), or a
    // file name template; DOS 4 asks when the name does not exist.
    address x9, template
    address x0, star_star
    mov x1, x9
    bl strcpy
    cbz x22, 8f
    mov x0, x22
    bl strupr
    mov x0, x22
    bl is_directory
    cbz x0, 7f
    mov x0, x22
    add x1, x23, #L_DST
    bl strcpy
    b 9f
7:
    mov x0, x22
    bl has_wild
    cbnz x0, 72f
    mov x0, x22                 // an existing file is a file
    mov x1, #0
    dos 0x43
    cbz x1, 72f
71:
    say "Does "
    mov x0, x22
    bl puts
    say " specify a file name\r\nor directory name on the target\r\n(F = file, D = directory)?"
    dos 0x01
    mov x24, x0
    bl crlf
    mov x0, x24
    bl toupper
    cmp w0, #'D'
    b.eq 73f
    cmp w0, #'F'
    b.ne 71b
72:
    // A file name: its directory part is the target directory.
    mov x0, x22
    bl basename
    mov x24, x0
    address x1, template
    bl strcpy
    sub x2, x24, x22
    add x1, x23, #L_DST
    mov x3, #0
74:
    cmp x3, x2
    b.hs 75f
    ldrb w4, [x22, x3]
    strb w4, [x1, x3]
    add x3, x3, #1
    b 74b
75:
    strb wzr, [x1, x3]
    b 9f
73:
    mov x0, x22
    add x1, x23, #L_DST
    bl strcpy
    b 9f
8:
    add x1, x23, #L_DST
    strb wzr, [x1]
9:
    // /S into the source tree would copy forever (CHK_CYCLIC_COPY).
    tbz x20, #4, 91f
    add x0, x23, #L_SRC
    address x1, true_src
    bl truename_dir
    add x0, x23, #L_DST
    address x1, true_dst
    bl truename_dir
    address x0, true_src
    bl strlen
    mov x2, x0
    address x3, true_src
    address x4, true_dst
    mov x5, #0
92:
    cmp x5, x2
    b.hs 93f
    ldrb w6, [x3, x5]
    ldrb w7, [x4, x5]
    cmp w6, w7
    b.ne 91f
    add x5, x5, #1
    b 92b
93:
    ldrb w7, [x4, x5]           // equal, or a subdirectory of the source
    cbz w7, 94f
    cmp w7, #'\\'
    b.eq 94f
    sub x5, x5, #1
    ldrb w6, [x3, x5]
    cmp w6, #'\\'                // the source is a root ("A:\")
    b.ne 91f
94:
    say "Cannot perform a cyclic copy\r\n"
    mov x0, #4
    bl exit
91:
    tbz x20, #5, 10f            // /W
    say "Press any key to begin copying file(s)"
    dos 0x08
    bl crlf
10:
    say "Reading source file(s)...\r\n"
    mov x0, #0
    bl walk
    address x9, copied
    ldr x0, [x9]
    cbnz x0, 12f
    address x9, matched
    ldr x2, [x9]
    cbnz x2, 12f
    address x9, stopped
    ldr x2, [x9]
    cbnz x2, 12f
    say "File not found - "
    address x0, pattern
    bl puts
    bl crlf
    mov x0, #0
12:
    mov x1, #9
    bl put_dec
    say " File(s) copied\r\n"
    address x9, failed
    ldr x0, [x9]
    cbz x0, 13f
    mov x0, #4
    leave
13:
    address x9, copied
    ldr x0, [x9]
    cmp x0, #0
    cset x0, eq                 // 1: no files found
    leave
too_many:
    say "Too many parameters\r\n"
    mov x0, #4
    leave
missing:
    say "Invalid number of parameters\r\n"
    mov x0, #4
    leave
bad_switch:
    say "Invalid parameter\r\n"
    mov x0, #4
    leave
bad_date:
    say "Invalid date\r\n"
    mov x0, #4
    leave

// x0 = "mm-dd-yy" (or yyyy; '-' or '.'). Returns x0 = packed FAT date,
// x1 = 0, or x1 = 1 when malformed.
parse_date:
    frame
    stp x19, x20, [sp, #-16]!
    str x21, [sp, #-16]!
    bl parse_dec
    cbnz x1, 9f
    mov x19, x0                 // month
    ldrb w3, [x2]
    cmp w3, #'-'
    b.eq 1f
    cmp w3, #'.'
    b.ne 9f
1:
    add x0, x2, #1
    bl parse_dec
    cbnz x1, 9f
    mov x20, x0                 // day
    ldrb w3, [x2]
    cmp w3, #'-'
    b.eq 2f
    cmp w3, #'.'
    b.ne 9f
2:
    add x0, x2, #1
    bl parse_dec
    cbnz x1, 9f
    ldrb w3, [x2]
    cbnz w3, 9f
    mov x21, x0
    cmp x21, #80
    b.hs 3f
    add x21, x21, #2000
    b 4f
3:
    cmp x21, #100
    b.hs 4f
    add x21, x21, #1900
4:
    cmp x21, #1980
    b.lo 9f
    sub x21, x21, #1980
    cmp x21, #127
    b.hi 9f
    sub x2, x19, #1
    cmp x2, #11
    b.hi 9f
    sub x2, x20, #1
    cmp x2, #30
    b.hi 9f
    lsl x0, x21, #9
    orr x0, x0, x19, lsl #5
    orr x0, x0, x20
    mov x1, #0
    b 8f
9:
    mov x1, #1
8:
    ldr x21, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// x0 = depth. Copies the matching files of levels[depth].src into
// levels[depth].dst, then (with /S) every subdirectory.
walk:
    enter
    mov x19, x0
    address x20, levels
    mov x2, #LEVEL
    madd x20, x19, x2, x20
    str xzr, [x20, #L_MADE]
    address x9, options
    ldr x21, [x9]
    // With /E the directory exists even when nothing is copied into it.
    cbz x19, 1f
    tbz x21, #1, 1f
    mov x0, x20
    bl make_target
1:
    add x0, x20, #L_SRC
    address x1, pattern
    address x2, spath
    bl join_path
    add x0, x20, #L_DTA
    mov x1, #280
    dos 0x1a
    address x0, spath
    mov x1, #0x21               // read-only and archive files too
    dos 0x4e
2:
    cbnz x1, 6f
    address x9, stopped
    ldr x2, [x9]
    cbnz x2, 9f
    ldr x2, [x20, #L_DTA]
    mov x3, #0x16               // directories, hidden, system: skipped
    tst x2, x3
    b.ne 5f
    address x9, matched
    mov x3, #1
    str x3, [x9]
    mov x3, #(OPT_A | OPT_M)
    tst x21, x3
    b.eq 3f
    tbz x2, #5, 5f              // not archived
3:
    tbz x21, #6, 4f             // /D
    ldrh w2, [x20, #L_DTA + 18]
    address x9, min_date
    ldr x3, [x9]
    cmp x2, x3
    b.lo 5f
4:
    mov x0, x20
    bl copy_entry
5:
    add x0, x20, #L_DTA
    mov x1, #280
    dos 0x1a
    dos 0x4f
    b 2b
6:
    tbz x21, #4, 9f             // /S
    cmp x19, #MAX_DEPTH - 1
    b.lo 7788f
    bl depth_note               // deeper directories are skipped, not lost
    b 9f
7788:
    add x0, x20, #L_SRC
    address x1, star_star
    address x2, spath
    bl join_path
    add x0, x20, #L_DTA
    mov x1, #280
    dos 0x1a
    address x0, spath
    mov x1, #0x10
    dos 0x4e
7:
    cbnz x1, 9f
    ldr x2, [x20, #L_DTA]
    tbz x2, #4, 8f
    tst x2, #0x06
    b.ne 8f
    ldrb w2, [x20, #L_DTA + 24]
    cmp w2, #'.'
    b.eq 8f
    add x22, x20, #LEVEL        // the child level
    add x0, x20, #L_SRC
    add x1, x20, #L_DTA + 24
    add x2, x22, #L_SRC
    bl join_path
    add x0, x20, #L_DST
    add x1, x20, #L_DTA + 24
    add x2, x22, #L_DST
    bl join_path
    add x0, x19, #1
    bl walk
    add x0, x20, #L_DTA
    mov x1, #280
    dos 0x1a
8:
    address x9, stopped
    ldr x2, [x9]
    cbnz x2, 9f
    dos 0x4f
    b 7b
9:
    leave

// x0 = level: creates its target directory and any missing parents.
make_target:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    ldr x2, [x19, #L_MADE]
    cbnz x2, 9f
    mov x2, #1
    str x2, [x19, #L_MADE]
    add x0, x19, #L_DST
    ldrb w2, [x0]
    cbz w2, 9f
    address x1, mkpath
    bl strcpy
    address x20, mkpath
    mov x2, #1
1:
    ldrb w3, [x20, x2]
    cbz w3, 3f
    cmp w3, #'\\'
    b.ne 2f
    sub x4, x2, #1
    ldrb w4, [x20, x4]
    cmp w4, #':'
    b.eq 2f
    strb wzr, [x20, x2]
    str x2, [sp, #-16]!
    mov x0, x20
    dos 0x39
    ldr x2, [sp], #16
    mov w3, #'\\'
    strb w3, [x20, x2]
2:
    add x2, x2, #1
    b 1b
3:
    sub x4, x2, #1
    ldrb w4, [x20, x4]
    cmp w4, #'\\'
    b.eq 9f
    cmp w4, #':'
    b.eq 9f
    mov x0, x20
    dos 0x39
9:
    ldp x19, x20, [sp], #16
    unframe

// x0 = level whose DTA holds the file to copy.
copy_entry:
    enter
    mov x19, x0
    add x0, x19, #L_SRC
    add x1, x19, #L_DTA + 24
    address x2, spath
    bl join_path
    add x0, x19, #L_DTA + 24
    address x1, template
    address x2, dname
    bl apply_template
    add x0, x19, #L_DST
    address x1, dname
    address x2, dpath
    bl join_path
    address x9, options
    ldr x21, [x9]
    tbz x21, #3, 1f             // /P
    address x0, spath
    bl puts
    address x0, yes_no
    bl ask_yn
    cbz x0, 9f
    b 2f
1:
    address x0, spath
    bl puts
    bl crlf
2:
    mov x0, x19
    bl make_target
    // A file never overwrites itself.
    address x0, spath
    address x1, truename1
    dos 0x60
    address x0, dpath
    address x1, truename2
    dos 0x60
    cbnz x1, 3f
    address x0, truename1
    address x1, truename2
    bl strcmp
    cbnz x0, 3f
    say "File cannot be copied onto itself\r\n"
    b stop
3:
    address x0, spath
    mov x1, #0
    bl fopen
    cbnz x1, fail
    mov x20, x0
    address x0, dpath
    mov x1, #0
    bl fcreate
    cbz x1, 4f
    mov x22, x0
    mov x0, x20
    bl fclose
    mov x0, x22
    b fail
4:
    mov x22, x0
5:
    mov x0, x20
    address x1, buffer
    mov x2, #BUF_SIZE
    bl fread
    cbnz x1, 7f
    cbz x0, 6f
    mov x23, x0
    mov x2, x0
    mov x0, x22
    address x1, buffer
    bl fwrite
    cbnz x1, 7f
    cmp x0, x23
    b.eq 5b
    mov x0, x20
    bl fclose
    mov x0, x22
    bl fclose
    address x0, dpath
    dos 0x41
    say "Insufficient disk space\r\n"
    b stop
6:
    mov x0, x20                 // the copy keeps the date and time
    mov x1, #0
    dos 0x57
    mov x0, x22
    mov x1, #1
    dos 0x57
    mov x0, x20
    bl fclose
    mov x0, x22
    bl fclose
    address x9, copied
    ldr x2, [x9]
    add x2, x2, #1
    str x2, [x9]
    tbz x21, #2, 9f             // /M clears the source's archive bit
    ldr x2, [x19, #L_DTA]
    bic x2, x2, #0x20
    and x2, x2, #0x07
    address x0, spath
    mov x1, #1
    dos 0x43
    b 9f
7:
    mov x23, x0
    mov x0, x20
    bl fclose
    mov x0, x22
    bl fclose
    mov x0, x23
fail:
    bl print_error
    address x9, failed
    mov x2, #1
    str x2, [x9]
    b 9f
stop:
    address x9, stopped
    mov x2, #1
    str x2, [x9]
    address x9, failed
    str x2, [x9]
9:
    leave

// x0 = directory ("" = current), x1 = 128-byte buffer: its true name.
truename_dir:
    frame
    ldrb w2, [x0]
    cbnz w2, 1f
    address x0, dot_dir
1:
    dos 0x60
    unframe

.section .rodata
dot_dir: .asciz "."
switch_letters: .asciz "AEMPSW"
star_star: .asciz "*.*"
yes_no: .asciz " (Y/N)?"
.section .bss
.balign 8
options: .skip 8
min_date: .skip 8
copied: .skip 8
matched: .skip 8
failed: .skip 8
stopped: .skip 8
pattern: .skip 128
template: .skip 128
dname: .skip 128
spath: .skip 512
dpath: .skip 512
mkpath: .skip 256
truename1: .skip 128
truename2: .skip 128
.balign 16
levels: .skip LEVEL * MAX_DEPTH
true_src: .skip 128
true_dst: .skip 128
buffer: .skip BUF_SIZE
