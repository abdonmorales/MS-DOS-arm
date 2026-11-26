// SPDX-License-Identifier: MIT
// BACKUP source d: [/S] [/M] [/A] [/D:date [/T:time]] [/F] [/L[:log]]
// (v4.0/src/CMD/BACKUP): copies files into a backup set (backup.inc) on
// drive d:. /S includes subdirectories, /M only files changed since the last
// backup, /A adds to the set already there, /D and /T only files changed on
// or after that date and time, /L logs to \BACKUP.LOG (or the file given)
// on the source drive. Backed-up files have their archive bit cleared. A
// full disk asks for the next one; /F (format) is not needed for these.
.include "lib.inc"
.include "cds.inc"
.include "backup.inc"
.equ OPT_S, 1
.equ OPT_M, 2
.equ OPT_A, 4
.equ OPT_D, 8
.equ OPT_T, 16
.equ OPT_L, 32
.equ LEVEL, 1024
.equ L_DIR, 0
.equ L_DTA, 512
.equ L_BLOCK, 800               // this directory's block in CONTROL (-1)
.equ L_BLOCKDISK, 808           // ... on which disk
.equ MAX_DEPTH, 15
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
    cmp w0, #'M'
    b.ne 22f
    orr x20, x20, #OPT_M
    b 1b
22:
    cmp w0, #'A'
    b.ne 23f
    orr x20, x20, #OPT_A
    b 1b
23:
    cmp w0, #'F'
    b.eq 1b                     // the disks need no formatting here
    cmp w0, #'L'
    b.ne 24f
    orr x20, x20, #OPT_L
    cmp w24, #':'
    b.ne 1b
    add x0, x23, #3
    address x1, log_name
    bl strcpy
    b 1b
24:
    cmp w24, #':'
    b.ne bad_parm
    cmp w0, #'D'
    b.ne 25f
    add x0, x23, #3
    bl parse_date
    cbnz x1, bad_parm
    address x9, min_date
    str x0, [x9]
    orr x20, x20, #OPT_D
    b 1b
25:
    cmp w0, #'T'
    b.ne bad_parm
    add x0, x23, #3
    bl parse_time
    cbnz x1, bad_parm
    address x9, min_time
    str x0, [x9]
    orr x20, x20, #OPT_T
    b 1b
4:
    cbz x22, bad_count
    address x9, options
    str x20, [x9]
    // Target drive.
    mov x0, x22
    mov x1, #0
    bl cds_parse_drive
    cmn x0, #1
    b.eq bad_drive
    ldrb w2, [x22, #2]
    cbnz w2, bad_parm
    mov x23, x0
    add x0, x23, #1
    dos 0x36
    cbnz x1, bad_drive
    address x9, target
    str x23, [x9]
    // Source: a directory means all its files.
    mov x0, x21
    bl strupr
    mov x0, x21
    address x1, levels + L_DIR
    dos 0x60
    cbnz x1, bad_source
    address x24, levels + L_DIR
    ldrb w2, [x24]
    sub x2, x2, #'A'
    cmp x2, x23
    b.eq same_drive
    mov x0, x21
    bl is_directory
    cbz x0, 41f
    address x0, star_star
    address x1, pattern
    bl strcpy
    b 42f
41:
    mov x0, x24
    bl basename
    mov x25, x0
    address x1, pattern
    bl strcpy
    strb wzr, [x25]             // keep "A:\DIR\" or "A:\"
    sub x2, x25, x24
    cmp x2, #3
    b.ls 42f
    sub x25, x25, #1
    strb wzr, [x25]             // "A:\DIR"
42:
    // The set's directory on the target.
    mov x0, x23
    address x1, set_dir
    bl bk_set_dir
    address x0, set_dir
    bl strlen
    cmp x0, #3
    b.ls 43f
    address x1, set_dir         // a fixed target: make \BACKUP
    sub x0, x0, #1
    strb wzr, [x1, x0]
    str x0, [sp, #-16]!
    address x0, set_dir
    dos 0x39
    ldr x0, [sp], #16
    address x1, set_dir
    mov w2, #'\\'
    strb w2, [x1, x0]
43:
    address x9, last_block
    mov x2, #-1
    str x2, [x9]
    tbnz x20, #2, append
    mov x0, #1
    bl ask_disk
    bl erase_set
    mov x0, #1
    bl start_disk
    cbnz x1, target_error
    b 5f
append:
    bl load_last_set
    cbnz x1, target_error
5:
    say "\r\n*** Backing up files to drive "
    address x9, target
    ldr x0, [x9]
    add x0, x0, #'A'
    bl putc
    say ": ***\r\nDiskette Number: "
    address x9, disk_no
    ldr x0, [x9]
    bl bk_put_disk
    say "\r\n\r\n"
    tbz x20, #5, 6f
    bl open_log
6:
    mov x0, #0
    bl walk
    address x9, stopped
    ldr x2, [x9]
    cbnz x2, 8f
    mov x0, #1                  // the last disk of the set
    bl write_control
    cbnz x1, target_error
    bl close_log
    address x9, files
    ldr x0, [x9]
    cbnz x0, 7f
    say "\r\nWarning! No files were found to back up\r\n"
    mov x0, #1
    leave
7:
    mov x0, #0
    leave
8:
    bl close_log
    mov x0, #4
    leave
bad_count:
    say "Invalid number of parameters\r\n"
    mov x0, #4
    leave
bad_parm:
    say "Invalid parameter\r\n"
    mov x0, #4
    leave
bad_drive:
    say "Invalid drive specification\r\n"
    mov x0, #4
    leave
bad_source:
    say "Invalid path\r\n"
    mov x0, #4
    leave
same_drive:
    say "Source and target drives are the same\r\n"
    mov x0, #4
    leave
target_error:
    say "Error writing to the backup disk\r\n"
    mov x0, #4
    leave

// x0 = disk number: "Insert backup diskette NN in drive B:" and the erase
// warning, then waits for a key.
ask_disk:
    frame
    str x0, [sp, #-16]!
    say "\r\nInsert backup diskette "
    ldr x0, [sp]
    bl bk_put_disk
    say " in drive "
    address x9, target
    ldr x0, [x9]
    add x0, x0, #'A'
    bl putc
    say ":\r\n\r\nWARNING! Files in the target drive\r\n"
    address x0, set_dir
    bl puts
    address x0, set_dir
    bl strlen
    cmp x0, #3
    b.hi 1f
    say " root directory will be erased\r\n"
    b 2f
1:
    say " directory will be erased\r\n"
2:
    bl press_any_key
    ldr x0, [sp], #16
    unframe

// Deletes every file in the set's directory.
erase_set:
    enter
    address x0, set_dir
    address x1, star_star
    address x2, path
    bl join_path
    address x0, erase_dta
    mov x1, #280
    dos 0x1a
    address x0, path
    mov x1, #0x07
    dos 0x4e
1:
    cbnz x1, 9f
    address x0, set_dir
    address x1, erase_dta + 24
    address x2, path2
    bl join_path
    address x0, path2
    mov x1, #1
    mov x2, #0
    dos 0x43
    address x0, path2
    dos 0x41
    address x0, erase_dta
    mov x1, #280
    dos 0x1a
    dos 0x4f
    b 1b
9:
    leave

// x0 = disk number: creates BACKUP.nnn and starts CONTROL in memory.
// Returns x1 = 0 / 1.
start_disk:
    enter
    address x9, disk_no
    str x0, [x9]
    mov x19, x0
    address x0, set_dir
    mov x1, x19
    address x2, bk_backup
    address x3, path
    bl bk_name
    address x0, path
    mov x1, #0
    dos 0x3c
    cbnz x1, 9f
    address x9, data_handle
    str x0, [x9]
    address x9, data_offset
    str xzr, [x9]
    address x9, disk_files
    str xzr, [x9]
    address x9, last_block
    mov x2, #-1
    str x2, [x9]
    address x20, control
    mov x2, #0
1:
    strb wzr, [x20, x2]
    add x2, x2, #1
    cmp x2, #BK_HEADER
    b.lo 1b
    mov w2, #0x8b
    strb w2, [x20]
    address x0, bk_signature
    mov x2, #0
2:
    ldrb w3, [x0, x2]
    add x4, x20, x2
    strb w3, [x4, #1]
    add x2, x2, #1
    cmp x2, #8
    b.lo 2b
    strb w19, [x20, #9]
    address x9, control_len
    mov x2, #BK_HEADER
    str x2, [x9]
    mov x1, #0
    leave
9:
    mov x1, #1
    leave

// x0 = 1 for the last disk. Writes CONTROL.nnn and closes BACKUP.nnn.
write_control:
    enter
    address x20, control
    cmp x0, #0
    mov w2, #0xff
    csel w2, w2, wzr, ne
    strb w2, [x20, #BK_LAST]
    address x0, set_dir
    address x9, disk_no
    ldr x1, [x9]
    address x2, bk_control
    address x3, path
    bl bk_name
    address x0, path
    mov x1, #0
    dos 0x3c
    cbnz x1, 9f
    mov x19, x0
    address x9, control_len
    ldr x2, [x9]
    mov x1, x20
    dos 0x40
    mov x0, x19
    dos 0x3e
    address x9, data_handle
    ldr x0, [x9]
    dos 0x3e
    mov x1, #0
    leave
9:
    mov x1, #1
    leave

// /A: finds the set's last CONTROL.nnn and continues it.
load_last_set:
    enter
    say "\r\nInsert last backup diskette in drive "
    address x9, target
    ldr x0, [x9]
    add x0, x0, #'A'
    bl putc
    say ":\r\n"
    bl press_any_key
    mov x19, #0                 // the highest disk found
    mov x20, #1
1:
    cmp x20, #99
    b.hi 2f
    address x0, set_dir
    mov x1, x20
    address x2, bk_control
    address x3, path
    bl bk_name
    address x0, path
    mov x1, #0
    dos 0x43
    cbnz x1, 11f
    mov x19, x20
11:
    add x20, x20, #1
    b 1b
2:
    cbnz x19, 3f
    mov x0, #1                  // no set yet: a new one
    bl start_disk
    leave
3:
    address x9, disk_no
    str x19, [x9]
    address x0, set_dir
    mov x1, x19
    address x2, bk_control
    address x3, path
    bl bk_name
    address x0, path
    mov x1, #0
    dos 0x3d
    cbnz x1, 9f
    mov x20, x0
    address x1, control
    mov x2, #CTL_SIZE
    dos 0x3f
    mov x21, x0
    mov x0, x20
    dos 0x3e
    cmp x21, #BK_HEADER
    b.lo 9f
    address x9, control_len
    str x21, [x9]
    // The last directory block, for linking new ones.
    address x22, control
    mov x23, #BK_HEADER
    mov x24, #-1
4:
    cmp x23, x21
    b.hs 5f
    mov x24, x23
    add x0, x22, x23
    add x0, x0, #65
    bl bk_get32
    cmn w0, #1
    b.eq 5f
    mov w23, w0
    b 4b
5:
    address x9, last_block
    str x24, [x9]
    // Data continues at the end of BACKUP.nnn.
    address x0, set_dir
    mov x1, x19
    address x2, bk_backup
    address x3, path
    bl bk_name
    address x0, path
    mov x1, #2
    dos 0x3d
    cbnz x1, 9f
    address x9, data_handle
    str x0, [x9]
    mov x1, #0
    mov x2, #2
    dos 0x42
    address x9, data_offset
    str x0, [x9]
    address x9, disk_files
    mov x2, #1
    str x2, [x9]
    mov x1, #0
    leave
9:
    mov x1, #1
    leave

// x0 = depth.
walk:
    enter
    mov x19, x0
    address x20, levels
    mov x2, #LEVEL
    madd x20, x19, x2, x20
    mov x2, #-1
    str x2, [x20, #L_BLOCK]
    add x0, x20, #L_DIR
    address x1, pattern
    address x2, path
    bl join_path
    add x0, x20, #L_DTA
    mov x1, #280
    dos 0x1a
    address x0, path
    mov x1, #0x07
    dos 0x4e
1:
    cbnz x1, 4f
    address x9, stopped
    ldr x2, [x9]
    cbnz x2, 9f
    ldr x21, [x20, #L_DTA]
    address x9, options
    ldr x22, [x9]
    tbz x22, #1, 2f             // /M: changed since the last backup
    tbz x21, #5, 3f
2:
    tbz x22, #3, 21f            // /D (and /T on that day)
    ldrh w2, [x20, #L_DTA + 18]
    address x9, min_date
    ldr x3, [x9]
    cmp x2, x3
    b.lo 3f
    b.hi 21f
    tbz x22, #4, 21f
    ldrh w2, [x20, #L_DTA + 16]
    address x9, min_time
    ldr x3, [x9]
    cmp x2, x3
    b.lo 3f
21:
    mov x0, x20
    bl backup_file
3:
    add x0, x20, #L_DTA
    mov x1, #280
    dos 0x1a
    dos 0x4f
    b 1b
4:
    address x9, options
    ldr x2, [x9]
    tbz x2, #0, 9f              // /S
    cmp x19, #MAX_DEPTH - 1
    b.hs 9f
    add x0, x20, #L_DIR
    address x1, star_star
    address x2, path
    bl join_path
    add x0, x20, #L_DTA
    mov x1, #280
    dos 0x1a
    address x0, path
    mov x1, #0x16
    dos 0x4e
5:
    cbnz x1, 9f
    ldr x2, [x20, #L_DTA]
    tbz x2, #4, 6f
    ldrb w2, [x20, #L_DTA + 24]
    cmp w2, #'.'
    b.eq 6f
    add x0, x20, #L_DIR
    add x1, x20, #L_DTA + 24
    add x2, x20, #LEVEL + L_DIR
    bl join_path
    add x0, x20, #LEVEL + L_DIR // not the backup set's own directory
    address x1, set_dir
    bl same_dir
    cbnz x0, 6f
    add x0, x19, #1
    bl walk
    add x0, x20, #L_DTA
    mov x1, #280
    dos 0x1a
6:
    address x9, stopped
    ldr x2, [x9]
    cbnz x2, 9f
    dos 0x4f
    b 5b
9:
    leave

// x0 = "A:\DIR", x1 = "A:\DIR\" (set_dir). Returns x0 = 1 when the same.
same_dir:
    ldrb w2, [x0], #1
    ldrb w3, [x1], #1
    cbz w2, 1f
    cmp w2, w3
    b.eq same_dir
    mov x0, #0
    ret
1:
    cmp w3, #'\\'
    cset x0, eq
    ret

// x0 = level whose DTA holds the file.
backup_file:
    enter
    mov x19, x0
    add x0, x19, #L_DTA + 24
    bl strlen
    cmp x0, #12
    b.hi 9f                     // long names have no place in the set
    add x0, x19, #L_DIR
    add x1, x19, #L_DTA + 24
    address x2, path
    bl join_path
    ldr x21, [x19, #L_DTA + 8]  // size
    // Room on this disk for the data and the index?
    address x9, target
    ldr x0, [x9]
    add x0, x0, #1
    dos 0x36
    mul x0, x0, x2              // free bytes
    address x9, control_len
    ldr x2, [x9]
    add x3, x21, x2
    mov x4, #(BK_DIRBLOCK + BK_FILEBLOCK + 8192)
    add x3, x3, x4
    cmp x3, x0
    b.ls 2f
    address x9, disk_files
    ldr x2, [x9]
    cbnz x2, 1f
    say "Insufficient disk space for "
    address x0, path + 2
    bl puts
    bl crlf
    b 9f
1:
    bl next_disk
    cbnz x1, stop
2:
    // The directory's block on this disk.
    ldr x2, [x19, #L_BLOCK]
    cmn x2, #1
    b.eq 3f
    ldr x3, [x19, #L_BLOCKDISK]
    address x9, disk_no
    ldr x4, [x9]
    cmp x3, x4
    b.eq 4f
3:
    address x9, control_len
    ldr x22, [x9]
    address x20, control
    add x23, x20, x22
    mov x2, #0
31:
    strb wzr, [x23, x2]
    add x2, x2, #1
    cmp x2, #BK_DIRBLOCK
    b.lo 31b
    mov w2, #0x46
    strb w2, [x23]
    add x0, x19, #L_DIR + 3     // the path without "A:\"
    mov x2, #0
32:
    ldrb w3, [x0, x2]
    cbz w3, 33f
    add x4, x23, x2
    strb w3, [x4, #1]
    add x2, x2, #1
    cmp x2, #63
    b.lo 32b
33:
    add x0, x23, #65
    mov x1, #-1
    bl bk_put32
    address x9, last_block
    ldr x2, [x9]
    str x22, [x9]
    cmn x2, #1
    b.eq 34f
    add x0, x20, x2
    add x0, x0, #65
    mov x1, x22
    bl bk_put32
34:
    str x22, [x19, #L_BLOCK]
    address x9, disk_no
    ldr x2, [x9]
    str x2, [x19, #L_BLOCKDISK]
    add x22, x22, #BK_DIRBLOCK
    address x9, control_len
    str x22, [x9]
4:
    // The data.
    address x0, path
    mov x1, #0
    dos 0x3d
    cbz x1, 41f
    bl print_error
    b 9f
41:
    mov x24, x0
42:
    mov x0, x24
    address x1, buffer
    mov x2, #BUF_SIZE
    dos 0x3f
    cbnz x1, 44f
    cbz x0, 43f
    mov x25, x0
    mov x2, x0
    address x9, data_handle
    ldr x0, [x9]
    address x1, buffer
    dos 0x40
    cbnz x1, 44f
    cmp x0, x25
    b.ne 44f
    b 42b
43:
    mov x0, x24
    dos 0x3e
    // The file block.
    address x9, control_len
    ldr x22, [x9]
    address x20, control
    add x23, x20, x22
    mov x2, #0
45:
    strb wzr, [x23, x2]
    add x2, x2, #1
    cmp x2, #BK_FILEBLOCK
    b.lo 45b
    mov w2, #0x22
    strb w2, [x23]
    add x0, x19, #L_DTA + 24
    add x1, x23, #1
    bl strcpy
    mov w2, #3                  // complete, last part
    strb w2, [x23, #13]
    add x0, x23, #14
    mov x1, x21
    bl bk_put32
    add x0, x23, #18
    mov x1, #1
    bl bk_put16
    address x9, data_offset
    ldr x1, [x9]
    add x2, x1, x21
    str x2, [x9]
    add x0, x23, #20
    bl bk_put32
    add x0, x23, #24
    mov x1, x21
    bl bk_put32
    ldr x2, [x19, #L_DTA]
    strb w2, [x23, #28]
    add x0, x23, #30
    ldrh w1, [x19, #L_DTA + 16]
    bl bk_put16
    add x0, x23, #32
    ldrh w1, [x19, #L_DTA + 18]
    bl bk_put16
    add x22, x22, #BK_FILEBLOCK
    address x9, control_len
    str x22, [x9]
    ldr x2, [x19, #L_BLOCK]     // one more file in the directory block
    add x2, x20, x2
    ldrb w3, [x2, #64]
    add w3, w3, #1
    strb w3, [x2, #64]
    address x9, files
    ldr x2, [x9]
    add x2, x2, #1
    str x2, [x9]
    address x9, disk_files
    ldr x2, [x9]
    add x2, x2, #1
    str x2, [x9]
    address x0, path + 2
    bl puts
    bl crlf
    bl log_file
    ldr x2, [x19, #L_DTA]       // backed up: clear the archive bit
    bic x2, x2, #0x20
    and x2, x2, #0x07
    address x0, path
    mov x1, #1
    dos 0x43
    b 9f
44:
    mov x0, x24
    dos 0x3e
    say "Error writing to the backup disk\r\n"
stop:
    address x9, stopped
    mov x2, #1
    str x2, [x9]
9:
    leave

// Ends this disk and starts the next. Returns x1 = 0 / 1.
next_disk:
    frame
    mov x0, #0
    bl write_control
    cbnz x1, 9f
    address x9, disk_no
    ldr x0, [x9]
    add x0, x0, #1
    str x0, [sp, #-16]!
    bl ask_disk
    bl erase_set
    ldr x0, [sp], #16
    bl start_disk
    cbnz x1, 9f
    say "\r\nDiskette Number: "
    address x9, disk_no
    ldr x0, [x9]
    bl bk_put_disk
    say "\r\n\r\n"
    mov x1, #0
9:
    unframe

// /L: the log file (default \BACKUP.LOG on the source drive), opened for
// appending, with the date and time of this backup.
open_log:
    enter
    address x19, log_name
    ldrb w2, [x19]
    cbnz w2, 1f
    address x9, levels
    ldrb w2, [x9]
    strb w2, [x19]
    address x0, default_log
    add x1, x19, #1
    bl strcpy
1:
    mov x0, x19
    mov x1, #1
    dos 0x3d
    cbz x1, 2f
    mov x0, x19
    mov x1, #0
    dos 0x3c
    cbnz x1, 9f
2:
    address x9, log_handle
    str x0, [x9]
    mov x1, #0
    mov x2, #2
    dos 0x42
    dos 0x2a                    // "mm-dd-yyyy  hh:mm:ss"
    address x20, log_line
    mov x21, x0
    mov x0, x2
    mov x1, x20
    bl two_digits
    mov w2, #'-'
    strb w2, [x20, #2]
    mov x0, x3
    add x1, x20, #3
    bl two_digits
    mov w2, #'-'
    strb w2, [x20, #5]
    mov x0, x21
    add x1, x20, #6
    bl four_digits
    mov w2, #' '
    strb w2, [x20, #10]
    strb w2, [x20, #11]
    dos 0x2c
    mov x21, x2
    mov x22, x3
    add x1, x20, #12
    bl two_digits
    mov w2, #':'
    strb w2, [x20, #14]
    mov x0, x21
    add x1, x20, #15
    bl two_digits
    mov w2, #':'
    strb w2, [x20, #17]
    mov x0, x22
    add x1, x20, #18
    bl two_digits
    mov w2, #13
    strb w2, [x20, #20]
    mov w2, #10
    strb w2, [x20, #21]
    address x9, log_handle
    ldr x0, [x9]
    address x1, crlf_text
    mov x2, #2
    dos 0x40
    address x9, log_handle
    ldr x0, [x9]
    mov x1, x20
    mov x2, #22
    dos 0x40
9:
    leave

// "NNN  \DIR\FILE" for the file in `path`.
log_file:
    enter
    address x9, log_handle
    ldr x19, [x9]
    cbz x19, 9f
    address x9, disk_no
    ldr x0, [x9]
    address x20, log_line
    mov x1, #100
    udiv x2, x0, x1
    msub x0, x2, x1, x0
    add w2, w2, #'0'
    strb w2, [x20]
    add x1, x20, #1
    bl two_digits
    mov w2, #' '
    strb w2, [x20, #3]
    strb w2, [x20, #4]
    address x0, path + 2
    add x1, x20, #5
    bl strcpy
    mov w2, #13
    strb w2, [x0], #1
    mov w2, #10
    strb w2, [x0], #1
    sub x2, x0, x20
    mov x0, x19
    mov x1, x20
    dos 0x40
9:
    leave

close_log:
    frame
    address x9, log_handle
    ldr x0, [x9]
    cbz x0, 1f
    dos 0x3e
1:
    unframe

// x0 = value, x1 = output: two (four) decimal digits.
two_digits:
    mov x4, #10
    udiv x5, x0, x4
    msub x6, x5, x4, x0
    udiv x7, x5, x4
    msub x5, x7, x4, x5
    add w5, w5, #'0'
    add w6, w6, #'0'
    strb w5, [x1]
    strb w6, [x1, #1]
    ret
four_digits:
    mov x4, #100
    udiv x5, x0, x4
    msub x0, x5, x4, x0
    str x0, [sp, #-16]!
    stp x1, x30, [sp, #-16]!
    mov x0, x5
    bl two_digits
    ldp x1, x30, [sp], #16
    ldr x0, [sp], #16
    add x1, x1, #2
    b two_digits

.section .rodata
star_star: .asciz "*.*"
default_log: .asciz ":\\BACKUP.LOG"
crlf_text: .ascii "\r\n"
.section .bss
.balign 8
options: .skip 8
target: .skip 8
min_date: .skip 8
min_time: .skip 8
disk_no: .skip 8
disk_files: .skip 8
files: .skip 8
stopped: .skip 8
data_handle: .skip 8
data_offset: .skip 8
control_len: .skip 8
last_block: .skip 8
log_handle: .skip 8
log_name: .skip 128
log_line: .skip 300
pattern: .skip 128
set_dir: .skip 128
path: .skip 512
path2: .skip 512
.balign 8
erase_dta: .skip 280
.balign 16
levels: .skip LEVEL * MAX_DEPTH
control: .skip CTL_SIZE
buffer: .skip BUF_SIZE
