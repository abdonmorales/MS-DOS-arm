// SPDX-License-Identifier: MIT
// FORMAT d: [/S] [/V[:label]] (v4.0/src/CMD/FORMAT): writes a new FAT12 or
// FAT16 file system over the whole device (its size from IOCTL 0860h),
// asks for a volume label, and with /S transfers the system. The drive's
// boot record is re-read with IOCTL 0840h when the layout is written.
// Floppy geometry switches (/1 /4 /8 /B /N /T /F) have no device here.
// /SELECT (undocumented, as DOS 4's SELECT used it) is for INSTALL: no
// questions; the disk was confirmed and the label is given with /V.
.include "lib.inc"
.include "fatlib.inc"
.include "cds.inc"
.include "sysxfer.inc"
.equ ZERO_SECTORS, 32

main:
    enter
    mov x19, x0
    bl cds_init
    mov x20, #-1                // drive
    mov x21, #0                 // 1 /S, 2 /V given with a label
1:
    mov x0, x19
    bl next_arg
    mov x19, x1
    ldrb w2, [x0]
    cbz w2, 3f
    cmp w2, #'/'
    b.eq 2f
    cmn x20, #1
    b.ne bad_parm
    mov x1, #0
    bl cds_parse_drive
    cmn x0, #1
    b.eq bad_drive
    mov x20, x0
    b 1b
2:
    mov x22, x0
    address x1, select_switch
    bl strcmpi
    cbnz x0, 20f
    orr x21, x21, #4
    b 1b
20:
    ldrb w0, [x22, #1]
    bl toupper
    cmp w0, #'S'
    b.ne 21f
    ldrb w2, [x22, #2]
    cbnz w2, bad_parm
    orr x21, x21, #1
    b 1b
21:
    cmp w0, #'V'
    b.ne 22f
    ldrb w2, [x22, #2]
    cbz w2, 1b                  // /V alone: asked anyway, as DOS 4 does
    cmp w2, #':'
    b.ne bad_parm
    add x0, x22, #3
    address x1, label_text
    bl strcpy
    orr x21, x21, #2
    b 1b
22:
    address x9, geometry_switches
23:
    ldrb w2, [x9], #1
    cbz w2, bad_parm
    cmp w0, w2
    b.ne 23b
    say "Parameters not supported by drive\r\n"
    mov x0, #4
    leave
3:
    cmn x20, #1
    b.eq missing
    // A physical drive; not the boot drive, not SUBST, ASSIGN or JOIN.
    address x9, cds_count
    ldr x9, [x9]
    cmp x20, x9
    b.hs bad_drive
    mov x0, x20
    bl cds_entry
    mov x22, x0
    ldr x2, [x22, #DRV_ASSIGN]
    cbnz x2, assigned
    ldr x2, [x22, #DRV_FLAGS]
    tbnz x2, #1, assigned
    tbnz x2, #2, assigned
    tbz x2, #0, bad_drive
    cbz x20, boot_drive
    add x2, x20, #1
    address x9, fl_drive
    str x2, [x9]
    bl fl_init
    cbnz x1, bad_drive
    flp x23, FL_BPS
    flp x24, FL_TOTAL
    cbz x24, bad_media
    say "\r\nWARNING, ALL DATA ON NON-REMOVABLE DISK\r\nDRIVE "
    add x0, x20, #'A'
    bl putc
    say ": WILL BE LOST!\r\n"
    tbnz x21, #2, 4f            // /SELECT: INSTALL asked already
    address x0, proceed
    bl ask_yn
    cbnz x0, 4f
    mov x0, #5
    leave
4:
    bl layout
    cbnz x1, too_big
    say "\r\nFormatting "
    mul x0, x24, x23
    lsr x0, x0, #10
    mov x1, #0
    bl put_dec
    say "K\r\n"
    bl write_system_area
    cbnz x1, write_failed
    say "100 percent of disk formatted\r\n"
    // The new boot record and FAT take effect.
    add x0, x20, #1
    mov x1, #0x0d
    mov x2, #0x0840
    dos 0x44
    cbnz x1, write_failed
    say "Format complete.\r\n"
    mov x25, #0                 // bytes taken by the system
    tbz x21, #0, 5f
    mov x0, x20
    bl sys_transfer
    cbnz x1, 41f
    mov x25, x0
    say "System transferred\r\n"
    b 5f
41:
    say "No room for system on destination disk\r\n"
5:
    tbnz x21, #1, 6f
    tbnz x21, #2, 6f            // /SELECT without /V: no label
51:
    say "\r\nVolume label (11 characters, ENTER for none)? "
    address x0, line
    mov w2, #12
    strb w2, [x0]
    bl read_console_line
    bl skip_blanks
    address x1, label_text
    bl strcpy
6:
    address x0, label_text
    bl rtrim
    address x0, label_text
    bl strupr
    address x0, label_text
    bl strlen
    cbz x0, 7f
    cmp x0, #11
    b.hi 61f
    bl check_label
    cbz x0, 62f
    bl write_label
    b 7f
61:
    say "Label too long\r\n"
    bic x21, x21, #2
    b 51b
62:
    say "Invalid characters in volume label\r\n"
    bic x21, x21, #2
    b 51b
7:
    // Statistics.
    bl crlf
    address x9, geo_clusters
    ldr x26, [x9]
    address x9, geo_spc
    ldr x2, [x9]
    mul x27, x2, x23            // allocation unit bytes
    mul x0, x26, x27
    mov x1, #12
    bl put_dec
    say " bytes total disk space\r\n"
    cbz x25, 71f
    add x0, x25, x27            // whole units
    sub x0, x0, #1
    udiv x0, x0, x27
    mul x0, x0, x27
    mov x1, #12
    bl put_dec
    say " bytes used by system\r\n"
71:
    add x0, x20, #1
    dos 0x36
    mov x28, x2                 // free units
    mul x0, x2, x27
    mov x1, #12
    bl put_dec
    say " bytes available on disk\r\n\r\n"
    mov x0, x27
    mov x1, #12
    bl put_dec
    say " bytes in each allocation unit\r\n"
    mov x0, x28
    mov x1, #12
    bl put_dec
    say " allocation units available on disk\r\n\r\nVolume Serial Number is "
    address x9, serial
    ldr w0, [x9]
    lsr w0, w0, #16
    mov x1, #4
    bl put_hex
    mov x0, #'-'
    bl putc
    address x9, serial
    ldrh w0, [x9]
    mov x1, #4
    bl put_hex
    bl crlf
    mov x0, #0
    leave

missing:
    say "Required parameter missing\r\n"
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
assigned:
    say "Cannot FORMAT an ASSIGNed, SUBSTed or JOINed drive\r\n"
    mov x0, #4
    leave
boot_drive:
    say "Cannot FORMAT the drive the system runs from\r\n"
    mov x0, #4
    leave
bad_media:
    say "Invalid media or Track 0 bad - disk unusable\r\n"
    mov x0, #4
    leave
too_big:
    say "Disk too large for FAT12/FAT16\r\n"
    mov x0, #4
    leave
write_failed:
    say "\r\nFormat terminated\r\n"
    mov x0, #4
    leave

// Picks the layout for x24 sectors of x23 bytes: one reserved sector, two
// FATs, a root directory sized like DOS's (112, 224 or 512 entries), the
// smallest cluster that keeps FAT12, else FAT16. Returns x1 = 0 / 1.
layout:
    mul x2, x24, x23
    mov x3, #512
    mov x4, #0xa000             // 368640
    movk x4, #5, lsl #16
    cmp x2, x4
    b.hi 1f
    mov x3, #112
    b 2f
1:
    mov x4, #0x6800             // 1474560
    movk x4, #0x16, lsl #16
    cmp x2, x4
    b.hi 2f
    mov x3, #224
2:
    lsl x4, x3, #5
    add x4, x4, x23
    sub x4, x4, #1
    udiv x4, x4, x23            // root sectors
    mul x5, x4, x23
    lsr x3, x5, #5              // entries fill them
    address x9, geo_root_entries
    str x3, [x9]
    address x9, geo_root_secs
    str x4, [x9]
    mov x10, #12                // FAT type
3:
    mov x6, #1                  // sectors per cluster
4:
    mov x7, #1                  // sectors per FAT
5:
    sub x8, x24, #1
    sub x8, x8, x4
    sub x8, x8, x7, lsl #1
    cmp x8, #0
    b.le 9f
    udiv x8, x8, x6             // clusters
    add x11, x8, #2
    cmp x10, #12
    b.ne 51f
    add x11, x11, x11, lsl #1   // FAT12: 1.5 bytes per entry
    add x11, x11, #1
    lsr x11, x11, #1
    b 52f
51:
    lsl x11, x11, #1
52:
    add x11, x11, x23
    sub x11, x11, #1
    udiv x11, x11, x23
    cmp x11, x7
    b.ls 6f
    mov x7, x11
    b 5b
6:
    cmp x10, #12
    b.ne 7f
    mov x12, #4084
    cmp x8, x12
    b.ls 8f
    lsl x6, x6, #1
    cmp x6, #8
    b.ls 4b
    mov x10, #16
    b 3b
7:
    mov x12, #65524
    cmp x8, x12
    b.ls 71f
    lsl x6, x6, #1
    cmp x6, #64
    b.ls 4b
    b 9f
71:
    mov x12, #4085
    cmp x8, x12
    b.lo 9f
8:
    address x9, geo_spc
    str x6, [x9]
    address x9, geo_fat_secs
    str x7, [x9]
    address x9, geo_clusters
    str x8, [x9]
    address x9, geo_type
    str x10, [x9]
    mov x1, #0
    ret
9:
    mov x1, #1
    ret

// Writes the boot record, both FATs and the root directory.
write_system_area:
    enter
    // Boot record.
    address x19, sector
    mov x0, x19
    mov x1, x23
    bl zero
    mov w2, #0xeb
    strb w2, [x19]
    mov w2, #0x3c
    strb w2, [x19, #1]
    mov w2, #0x90
    strb w2, [x19, #2]
    address x0, oem
    add x1, x19, #3
    mov x2, #8
    bl copy
    strb w23, [x19, #11]
    lsr w2, w23, #8
    strb w2, [x19, #12]
    address x9, geo_spc
    ldr x2, [x9]
    strb w2, [x19, #13]
    mov w2, #1
    strb w2, [x19, #14]         // reserved sectors
    mov w2, #2
    strb w2, [x19, #16]         // FAT copies
    address x9, geo_root_entries
    ldr x2, [x9]
    strb w2, [x19, #17]
    lsr w2, w2, #8
    strb w2, [x19, #18]
    mov x2, #0xffff
    cmp x24, x2
    b.hi 1f
    strb w24, [x19, #19]
    lsr w2, w24, #8
    strb w2, [x19, #20]
    b 2f
1:
    str w24, [x19, #32]         // aligned
2:
    mov w2, #0xf8
    strb w2, [x19, #21]
    address x9, geo_fat_secs
    ldr x2, [x9]
    strb w2, [x19, #22]
    lsr w2, w2, #8
    strb w2, [x19, #23]
    mov w2, #63
    strb w2, [x19, #24]         // sectors per track
    mov w2, #16
    strb w2, [x19, #26]         // heads
    mov w2, #0x80
    strb w2, [x19, #36]
    mov w2, #0x29
    strb w2, [x19, #38]
    bl make_serial
    address x9, serial
    ldr w2, [x9]
    strb w2, [x19, #39]
    lsr w2, w2, #8
    strb w2, [x19, #40]
    lsr w2, w2, #8
    strb w2, [x19, #41]
    lsr w2, w2, #8
    strb w2, [x19, #42]
    address x0, no_name
    add x1, x19, #43
    mov x2, #11
    bl copy
    address x0, fs_fat12
    address x9, geo_type
    ldr x2, [x9]
    cmp x2, #16
    b.ne 3f
    address x0, fs_fat16
3:
    add x1, x19, #54
    mov x2, #8
    bl copy
    mov w2, #0x55
    add x3, x19, #510
    strb w2, [x3]
    mov w2, #0xaa
    strb w2, [x3, #1]
    mov x0, #0
    mov x1, #1
    mov x2, x19
    bl fl_write
    cbnz x1, 9f
    // FATs and the root directory: zeros, then the first FAT entries.
    address x0, zeros
    mov x1, #(ZERO_SECTORS * 4096)
    bl zero
    address x9, geo_fat_secs
    ldr x2, [x9]
    lsl x20, x2, #1             // both FATs
    address x9, geo_root_secs
    ldr x2, [x9]
    add x20, x20, x2            // sectors after the boot record
    mov x21, #1
4:
    cbz x20, 5f
    mov x1, #ZERO_SECTORS
    cmp x20, x1
    csel x1, x20, x1, lo
    mov x22, x1
    mov x0, x21
    address x2, zeros
    bl fl_write
    cbnz x1, 9f
    add x21, x21, x22
    sub x20, x20, x22
    b 4b
5:
    mov x0, x19
    mov x1, x23
    bl zero
    mov w2, #0xf8
    strb w2, [x19]
    mov w2, #0xff
    strb w2, [x19, #1]
    strb w2, [x19, #2]
    address x9, geo_type
    ldr x3, [x9]
    cmp x3, #16
    b.ne 6f
    strb w2, [x19, #3]
6:
    mov x0, #1                  // FAT 1
    mov x1, #1
    mov x2, x19
    bl fl_write
    cbnz x1, 9f
    address x9, geo_fat_secs
    ldr x0, [x9]
    add x0, x0, #1              // FAT 2
    mov x1, #1
    mov x2, x19
    bl fl_write
9:
    leave

// Serial number from the date and time, as DOS made it.
make_serial:
    frame
    dos 0x2c
    orr w4, w3, w0, lsl #24     // seconds | hours
    orr w4, w4, w2, lsl #16     // minutes
    str w4, [sp, #-16]!
    dos 0x2a
    ldr w4, [sp], #16
    orr w5, w3, w2, lsl #8      // day | month
    add w5, w5, w0, lsl #16     // year
    add w4, w4, w5
    address x9, serial
    str w4, [x9]
    unframe

// Returns x0 = 1 when label_text holds no invalid character.
check_label:
    address x0, label_text
1:
    ldrb w2, [x0], #1
    cbz w2, 3f
    address x9, invalid_chars
2:
    ldrb w3, [x9], #1
    cbz w3, 1b
    cmp w2, w3
    b.ne 2b
    mov x0, #0
    ret
3:
    mov x0, #1
    ret

// Puts label_text in the root directory and in the boot record.
write_label:
    enter
    address x0, label_text      // pad to 11
    bl strlen
    address x1, label_text
    mov w2, #' '
1:
    cmp x0, #11
    b.hs 2f
    strb w2, [x1, x0]
    add x0, x0, #1
    b 1b
2:
    bl fl_init                  // the geometry after 0840h
    flp x19, FL_ROOT_START
    mov x0, x19
    mov x1, #1
    address x2, sector
    bl fl_read
    cbnz x1, 9f
    address x20, sector
    mov x21, #0
3:
    cmp x21, x23
    b.hs 9f
    ldrb w2, [x20, x21]
    cbz w2, 4f
    cmp w2, #0xe5
    b.eq 4f
    add x21, x21, #32
    b 3b
4:
    add x22, x20, x21
    mov x0, x22
    mov x1, #32
    bl zero
    address x0, label_text
    mov x1, x22
    mov x2, #11
    bl copy
    mov w2, #0x08
    strb w2, [x22, #11]
    mov x0, x19
    mov x1, #1
    mov x2, x20
    bl fl_write
    cbnz x1, 9f
    address x9, fl_drive        // and the boot record (69h get, set)
    ldr x1, [x9]
    mov x0, #0
    address x2, media
    dos 0x69
    cbnz x1, 9f
    address x0, label_text
    address x1, media + 6
    mov x2, #11
    bl copy
    mov x0, #1
    address x9, fl_drive
    ldr x1, [x9]
    address x2, media
    dos 0x69
9:
    leave

// x0 = buffer, x1 = bytes (multiple of 8).
zero:
    mov x2, #0
1:
    cmp x2, x1
    b.hs 2f
    str xzr, [x0, x2]
    add x2, x2, #8
    b 1b
2:
    ret

// x0 = source, x1 = destination, x2 = bytes.
copy:
    cbz x2, 2f
1:
    ldrb w3, [x0], #1
    strb w3, [x1], #1
    subs x2, x2, #1
    b.ne 1b
2:
    ret

.section .rodata
proceed: .asciz "Proceed with Format (Y/N)?"
select_switch: .asciz "/SELECT"
geometry_switches: .asciz "148BNTF"
oem: .ascii "MSDOS4.0"
no_name: .ascii "NO NAME    "
fs_fat12: .ascii "FAT12   "
fs_fat16: .ascii "FAT16   "
invalid_chars: .asciz "*?/\\|.,;:+=<>[]\"\t"
.section .bss
.balign 8
geo_spc: .skip 8
geo_fat_secs: .skip 8
geo_root_secs: .skip 8
geo_root_entries: .skip 8
geo_clusters: .skip 8
geo_type: .skip 8
serial: .skip 8
media: .skip 32
label_text: .skip 128
line: .skip 16
.balign 16
sector: .skip 4096
zeros: .skip ZERO_SECTORS * 4096
