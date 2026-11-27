// SPDX-License-Identifier: MIT
// RESTORE d: [d:][path]filespec [/S] [/P] [/B:date] [/A:date] [/E:time]
//         [/L:time] [/M] [/N]  (MS-DOS 4.0 src/CMD/RESTORE): restores files from
// the backup set (backup.inc) on drive d:. /S includes subdirectories, /P
// asks before replacing read-only files or files changed since the backup,
// /B and /A only files changed on or before / on or after the date, /E and
// /L at or earlier / at or later than the time, /M only files changed since
// the last backup (or gone), /N only files that no longer exist. Restored
// files get back their date, time and attributes; missing directories are
// created.
.include "lib.inc"
.include "cds.inc"
.include "backup.inc"
.equ OPT_S, 1
.equ OPT_P, 2
.equ OPT_M, 4
.equ OPT_N, 8
.equ OPT_B, 16
.equ OPT_A, 32
.equ OPT_E, 64
.equ OPT_L, 128
.equ CTL_SIZE, 65536
.equ BUF_SIZE, 65536

main:
    enter
    mov x19, x0
    bl cds_init
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
    cbnz x22, bad_count
    mov x22, x0
    b 1b
2:
    mov x23, x0
    ldrb w0, [x23, #1]
    bl toupper
    ldrb w24, [x23, #2]
    cmp w0, #'S'
    b.ne 21f
    orr x20, x20, #OPT_S
    b 1b
21:
    cmp w0, #'P'
    b.ne 22f
    orr x20, x20, #OPT_P
    b 1b
22:
    cmp w0, #'M'
    b.ne 23f
    orr x20, x20, #OPT_M
    b 1b
23:
    cmp w0, #'N'
    b.ne 24f
    orr x20, x20, #OPT_N
    b 1b
24:
    cmp w24, #':'
    b.ne bad_parm
    mov w25, w0
    add x0, x23, #3
    cmp w25, #'B'
    b.ne 25f
    bl parse_date
    cbnz x1, bad_parm
    address x9, before_date
    str x0, [x9]
    orr x20, x20, #OPT_B
    b 1b
25:
    cmp w25, #'A'
    b.ne 26f
    bl parse_date
    cbnz x1, bad_parm
    address x9, after_date
    str x0, [x9]
    orr x20, x20, #OPT_A
    b 1b
26:
    cmp w25, #'E'
    b.ne 27f
    bl parse_time
    cbnz x1, bad_parm
    address x9, early_time
    str x0, [x9]
    orr x20, x20, #OPT_E
    b 1b
27:
    cmp w25, #'L'
    b.ne bad_parm
    bl parse_time
    cbnz x1, bad_parm
    address x9, late_time
    str x0, [x9]
    orr x20, x20, #OPT_L
    b 1b
4:
    cbz x22, bad_count
    address x9, options
    str x20, [x9]
    // Source drive.
    mov x0, x21
    mov x1, #0
    bl cds_parse_drive
    cmn x0, #1
    b.eq bad_drive
    ldrb w2, [x21, #2]
    cbnz w2, bad_parm
    mov x23, x0
    add x0, x23, #1
    dos 0x36
    cbnz x1, bad_drive
    address x9, source
    str x23, [x9]
    // Target: a directory means all its files.
    mov x0, x22
    bl strupr
    mov x0, x22
    address x1, target_full
    dos 0x60
    cbnz x1, bad_path
    address x24, target_full
    ldrb w2, [x24]
    address x9, target_drive
    strb w2, [x9]
    sub x2, x2, #'A'
    cmp x2, x23
    b.eq same_drive
    mov x0, x22
    bl is_directory
    cbz x0, 41f
    address x0, star_star
    address x1, pattern_name
    bl strcpy
    b 42f
41:
    mov x0, x24
    bl basename
    mov x25, x0
    address x1, pattern_name
    bl strcpy
    strb wzr, [x25]             // "A:\DIR\" or "A:\"
    sub x2, x25, x24
    cmp x2, #3
    b.ls 42f
    sub x25, x25, #1
    strb wzr, [x25]             // "A:\DIR"
42:
    address x0, pattern_name
    address x1, pattern11
    bl fcb11
    mov x0, x23
    address x1, set_dir
    bl bk_set_dir
    say "\r\nInsert backup diskette 01 in drive "
    add x0, x23, #'A'
    bl putc
    say ":\r\n"
    bl press_any_key
    mov x24, #1                 // disk number
    mov x25, #1                 // the first disk read
disk:
    address x0, set_dir
    mov x1, x24
    address x2, bk_control
    address x3, path
    bl bk_name
    address x0, path
    mov x1, #0
    dos 0x3d
    cbnz x1, no_backup
    mov x26, x0
    address x1, control
    mov x2, #CTL_SIZE
    dos 0x3f
    mov x27, x0
    mov x0, x26
    mov x1, #0
    dos 0x57
    mov x28, x2                 // the backup's date
    mov x0, x26
    dos 0x3e
    cmp x27, #BK_HEADER
    b.lo no_backup
    address x20, control
    ldrb w2, [x20]
    cmp w2, #0x8b
    b.ne no_backup
    address x0, bk_signature
    mov x2, #0
5:
    ldrb w3, [x0, x2]
    add x4, x20, x2
    ldrb w4, [x4, #1]
    cmp w3, w4
    b.ne no_backup
    add x2, x2, #1
    cmp x2, #8
    b.lo 5b
    ldrb w2, [x20, #9]
    cmp x2, x24
    b.eq 6f
    say "\r\nWarning! Diskette is out of sequence\r\nReplace diskette or continue if okay\r\n"
    bl press_any_key
6:
    cbz x25, 7f
    mov x25, #0
    say "\r\n*** Files were backed up "
    mov x0, x28
    bl put_date
    say " ***\r\n\r\n*** Restoring files from drive "
    add x0, x23, #'A'
    bl putc
    say ": ***\r\n"
7:
    say "Diskette: "
    mov x0, x24
    bl bk_put_disk
    bl crlf
    address x0, set_dir
    mov x1, x24
    address x2, bk_backup
    address x3, path
    bl bk_name
    address x0, path
    mov x1, #0
    dos 0x3d
    cbnz x1, no_backup
    address x9, data_handle
    str x0, [x9]
    // The blocks, in order: each directory block is followed by its files.
    mov x19, #BK_HEADER
    mov x21, #0                 // this directory is wanted
8:
    cmp x19, x27
    b.hs 9f
    ldrb w2, [x20, x19]
    cmp w2, #0x46
    b.ne 81f
    add x2, x19, #BK_DIRBLOCK
    cmp x2, x27
    b.hi 9f
    add x0, x20, x19
    add x0, x0, #1
    address x1, dir_path
    mov x2, #0
71:
    ldrb w3, [x0, x2]
    strb w3, [x1, x2]
    add x2, x2, #1
    cmp x2, #63
    b.lo 71b
    strb wzr, [x1, #63]
    address x0, dir_path
    bl match_dir
    mov x21, x0
    add x19, x19, #BK_DIRBLOCK
    b 8b
81:
    cmp w2, #0x22
    b.ne 9f
    add x2, x19, #BK_FILEBLOCK
    cmp x2, x27
    b.hi 9f
    cbz x21, 82f
    add x0, x20, x19
    bl restore_file
82:
    add x19, x19, #BK_FILEBLOCK
    b 8b
9:
    address x9, data_handle
    ldr x0, [x9]
    dos 0x3e
    ldrb w2, [x20, #BK_LAST]
    cmp w2, #0xff
    b.eq finish
    add x24, x24, #1
    say "\r\nInsert backup diskette "
    mov x0, x24
    bl bk_put_disk
    say " in drive "
    add x0, x23, #'A'
    bl putc
    say ":\r\n"
    bl press_any_key
    b disk
finish:
    address x9, files
    ldr x0, [x9]
    cbnz x0, 1f
    say "\r\nWarning! No files were found to restore\r\n"
    mov x0, #1
    leave
1:
    mov x0, #0
    leave
no_backup:
    say "\r\nSource does not contain backup files\r\n"
    mov x0, #1
    leave
bad_count:
    say "Invalid number of parameters\r\n"
    mov x0, #1
    leave
bad_parm:
    say "Invalid parameter\r\n"
    mov x0, #1
    leave
bad_drive:
    say "Invalid drive specification\r\n"
    mov x0, #1
    leave
bad_path:
    say "Invalid path\r\n"
    mov x0, #1
    leave
same_drive:
    say "Source and target drives are the same\r\n"
    mov x0, #1
    leave

// x0 = a directory block's path ("DIR\SUB", no drive). Returns x0 = 1 when
// it is the target directory (or, with /S, below it).
match_dir:
    address x1, target_full + 3
    mov x6, x1
1:
    ldrb w2, [x0]
    ldrb w3, [x1]
    cbz w3, 3f
    sub w4, w2, #'a'
    cmp w4, #25
    b.hi 11f
    sub w2, w2, #32
11:
    sub w4, w3, #'a'
    cmp w4, #25
    b.hi 12f
    sub w3, w3, #32
12:
    cmp w2, w3
    b.ne 8f
    add x0, x0, #1
    add x1, x1, #1
    b 1b
3:
    cbz w2, 9f
    address x9, options
    ldr x4, [x9]
    tbz x4, #0, 8f              // /S
    cmp x1, x6
    b.eq 9f                     // below the root
    cmp w2, #'\\'
    b.eq 9f
8:
    mov x0, #0
    ret
9:
    mov x0, #1
    ret

// x0 = file block. Restores that file when it matches.
restore_file:
    enter
    mov x19, x0
    add x0, x19, #1
    address x1, file_name
    mov x2, #0
1:
    ldrb w3, [x0, x2]
    strb w3, [x1, x2]
    add x2, x2, #1
    cmp x2, #12
    b.lo 1b
    strb wzr, [x1, #12]
    address x0, file_name
    address x1, name11
    bl fcb11
    address x0, pattern11
    address x1, name11
    bl match11
    cbz x0, 99f
    add x0, x19, #32
    bl bk_get16
    mov x20, x0                 // date
    add x0, x19, #30
    bl bk_get16
    mov x21, x0                 // time
    address x9, options
    ldr x22, [x9]
    tbz x22, #4, 2f             // /B
    address x9, before_date
    ldr x2, [x9]
    cmp x20, x2
    b.hi 99f
2:
    tbz x22, #5, 3f             // /A
    address x9, after_date
    ldr x2, [x9]
    cmp x20, x2
    b.lo 99f
3:
    tbz x22, #6, 4f             // /E
    address x9, early_time
    ldr x2, [x9]
    cmp x21, x2
    b.hi 99f
4:
    tbz x22, #7, 5f             // /L
    address x9, late_time
    ldr x2, [x9]
    cmp x21, x2
    b.lo 99f
5:
    // "D:\DIR\NAME"
    address x23, path
    address x9, target_drive
    ldrb w2, [x9]
    strb w2, [x23]
    mov w2, #':'
    strb w2, [x23, #1]
    mov w2, #'\\'
    strb w2, [x23, #2]
    address x0, dir_path
    add x1, x23, #3
    bl strcpy
    add x2, x23, #3
    cmp x0, x2
    b.eq 51f
    mov w2, #'\\'
    strb w2, [x0], #1
51:
    mov x1, x0
    address x0, file_name
    bl strcpy
    add x0, x19, #18
    bl bk_get16
    mov x24, x0                 // part number
    cmp x24, #1
    b.hi 20f
    address x9, part1_restored  // only its own later parts may follow
    strb wzr, [x9]
    // The first part: does the file exist already?
    mov x0, x23
    mov x1, #0
    dos 0x43
    cbnz x1, 10f
    mov x25, x0
    tbnz x22, #3, 99f           // /N: only missing files
    tbz x22, #2, 6f             // /M: only files changed since
    tbz x25, #5, 99f
6:
    tbz x22, #1, 9f             // /P
    tbz x25, #0, 7f
    say "Warning! File "
    address x0, file_name
    bl puts
    address x0, read_only_text
    bl ask_yn
    cbz x0, 99f
    b 9f
7:
    mov x0, x23
    mov x1, #0
    dos 0x3d
    cbnz x1, 9f
    mov x26, x0
    mov x1, #0
    dos 0x57
    mov x27, x2
    mov x28, x3
    mov x0, x26
    dos 0x3e
    cmp x27, x20
    b.ne 8f
    cmp x28, x21
    b.eq 9f
8:
    say "Warning! File "
    address x0, file_name
    bl puts
    address x0, changed_text
    bl ask_yn
    cbz x0, 99f
9:
    and x2, x25, #7
    cbz x2, 10f
    mov x0, x23                 // read-only, hidden or system: replaceable
    mov x1, #1
    mov x2, #0
    dos 0x43
10:
    mov x0, x23
    bl make_dirs
    mov x0, x23
    mov x1, #0
    dos 0x3c
    cbnz x1, 98f
    mov x25, x0
    mov x0, x23
    address x1, part1_restored
    bl strcpy
    b 30f
20:
    // A later part continues the file, if its first part was restored
    // (not skipped by /P, /N, /M or a selection).
    mov x0, x23
    address x1, part1_restored
    bl strcmpi
    cbnz x0, 99f
    mov x0, x23
    mov x1, #1
    dos 0x3d
    cbz x1, 21f
    mov x0, x23
    mov x1, #0
    dos 0x3c
    cbnz x1, 98f
21:
    mov x25, x0
    mov x1, #0
    mov x2, #2
    dos 0x42
30:
    address x9, data_handle
    ldr x26, [x9]
    add x0, x19, #20
    bl bk_get32
    mov x1, x0
    mov x0, x26
    mov x2, #0
    dos 0x42
    add x0, x19, #24
    bl bk_get32
    mov x27, x0                 // bytes left
31:
    cbz x27, 33f
    mov x2, #BUF_SIZE
    cmp x27, x2
    csel x2, x27, x2, lo
    mov x0, x26
    address x1, buffer
    dos 0x3f
    cbnz x1, 32f
    cbz x0, 32f
    mov x28, x0
    mov x2, x0
    mov x0, x25
    address x1, buffer
    dos 0x40
    cbnz x1, 32f
    cmp x0, x28
    b.ne 32f
    sub x27, x27, x28
    b 31b
32:
    mov x0, x25
    dos 0x3e
    say "Error restoring "
    add x0, x23, #2
    bl puts
    bl crlf
    b 99f
33:
    mov x0, x25
    mov x1, #1
    mov x2, x20
    mov x3, x21
    dos 0x57
    mov x0, x25
    dos 0x3e
    ldrb w2, [x19, #13]
    tbz x2, #0, 34f             // the attributes go with the last part
    ldrb w2, [x19, #28]
    mov x3, #0x27
    and x2, x2, x3
    cbz x2, 34f
    mov x0, x23
    mov x1, #1
    dos 0x43
34:
    add x0, x23, #2
    bl puts
    bl crlf
    address x9, files
    ldr x2, [x9]
    add x2, x2, #1
    str x2, [x9]
    b 99f
98:
    add x0, x23, #2
    bl puts
    say ": "
    bl print_error
99:
    leave

// x0 = "D:\DIR\SUB\NAME": creates DIR and DIR\SUB when missing.
make_dirs:
    enter
    mov x19, x0
    add x20, x19, #3
1:
    ldrb w2, [x20]
    cbz w2, 9f
    cmp w2, #'\\'
    b.ne 2f
    strb wzr, [x20]
    mov x0, x19
    dos 0x39
    mov w2, #'\\'
    strb w2, [x20]
2:
    add x20, x20, #1
    b 1b
9:
    leave

// x0 = name or pattern, x1 = 11-byte output: the FCB form ("FC1     TXT",
// '*' as '?'s).
fcb11:
    frame
    mov x2, #0
    mov x3, #8
    bl fcb_part
    ldrb w4, [x0]
    cmp w4, #'.'
    b.ne 1f
    add x0, x0, #1
1:
    mov x3, #11
    bl fcb_part
    unframe
// x0 = text, x1 = output, x2 = position, x3 = end. Returns x0 past the
// part and x2 = x3.
fcb_part:
1:
    ldrb w4, [x0]
    cbz w4, 3f
    cmp w4, #'.'
    b.eq 3f
    cmp w4, #'*'
    b.ne 2f
    mov w5, #'?'
11:
    cmp x2, x3
    b.hs 12f
    strb w5, [x1, x2]
    add x2, x2, #1
    b 11b
12:
    add x0, x0, #1
    b 1b
2:
    cmp x2, x3
    b.hs 22f
    sub w5, w4, #'a'
    cmp w5, #25
    b.hi 21f
    sub w4, w4, #32
21:
    strb w4, [x1, x2]
    add x2, x2, #1
22:
    add x0, x0, #1
    b 1b
3:
    mov w5, #' '
31:
    cmp x2, x3
    b.hs 4f
    strb w5, [x1, x2]
    add x2, x2, #1
    b 31b
4:
    ret

// x0 = pattern, x1 = name (both FCB form). Returns x0 = 1 on a match.
match11:
    mov x2, #0
1:
    ldrb w3, [x0, x2]
    ldrb w4, [x1, x2]
    cmp w3, #'?'
    b.eq 2f
    cmp w3, w4
    b.ne 8f
2:
    add x2, x2, #1
    cmp x2, #11
    b.lo 1b
    mov x0, #1
    ret
8:
    mov x0, #0
    ret

// x0 = packed date: prints mm-dd-yyyy.
put_date:
    frame
    str x19, [sp, #-16]!
    mov x19, x0
    ubfx x0, x19, #5, #4
    mov x1, #2
    bl put_dec0
    mov x0, #'-'
    bl putc
    and x0, x19, #31
    mov x1, #2
    bl put_dec0
    mov x0, #'-'
    bl putc
    lsr x0, x19, #9
    add x0, x0, #1980
    mov x1, #4
    bl put_dec0
    ldr x19, [sp], #16
    unframe

.section .rodata
star_star: .asciz "*.*"
read_only_text: .asciz "\r\nis a read-only file\r\nReplace the file (Y/N)?"
changed_text: .asciz "\r\nwas changed after it was backed up\r\nReplace the file (Y/N)?"
.section .bss
part1_restored: .skip 256
.balign 8
options: .skip 8
source: .skip 8
files: .skip 8
data_handle: .skip 8
before_date: .skip 8
after_date: .skip 8
early_time: .skip 8
late_time: .skip 8
target_drive: .skip 8
pattern11: .skip 16
name11: .skip 16
file_name: .skip 16
pattern_name: .skip 128
target_full: .skip 128
set_dir: .skip 128
dir_path: .skip 80
path: .skip 512
.balign 16
control: .skip CTL_SIZE
buffer: .skip BUF_SIZE
