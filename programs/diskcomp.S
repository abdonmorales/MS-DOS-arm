// SPDX-License-Identifier: MIT
// DISKCOMP [d1: [d2:]] [/1] [/8] (v4.0/src/CMD/DISKCOMP): compares two
// disks track by track. The boot record's volume serial number is ignored,
// since DISKCOPY gives each copy its own. Drives: see diskdrv.inc.
.include "lib.inc"
.include "fatlib.inc"
.include "cds.inc"
.include "diskdrv.inc"

main:
    enter
    bl dd_parse
    cbnz x1, 9f
    address x9, dd_drive1
    ldp x19, x20, [x9]
again:
    say "\r\nInsert FIRST diskette in drive "
    mov x0, x19
    bl dd_put_drive
    bl crlf
    cmp x19, x20
    b.eq 1f
    say "\r\nInsert SECOND diskette in drive "
    mov x0, x20
    bl dd_put_drive
    bl crlf
1:
    bl crlf
    bl press_any_key
    mov x0, x20
    bl dd_select
    cbnz x1, read_error
    mov x21, x0
    mov x22, x2
    mov x0, x19
    bl dd_select
    cbnz x1, read_error
    cmp x0, x21
    b.ne incompatible
    cmp x2, x22
    b.ne incompatible
    address x9, dd_total
    str x0, [x9]
    address x9, dd_bps
    str x2, [x9]
    mov x0, #0
    mov x1, #1
    address x2, dd_buffer
    bl fl_read
    cbnz x1, read_error
    say "\r\nComparing "
    mov x0, #1
    bl dd_geometry
    bl crlf
    // Track by track.
    address x9, dd_spt
    ldr x2, [x9]
    address x9, dd_heads
    ldr x3, [x9]
    mov x27, x2                 // sectors per track (one compare unit)
    mov x23, #0                 // sector
    mov x28, #0                 // errors
2:
    cmp x23, x21
    b.hs 6f
    sub x24, x21, x23
    cmp x24, x27
    csel x24, x24, x27, lo
    cmp x24, #DD_CHUNK
    mov x2, #DD_CHUNK
    csel x24, x24, x2, lo
    mov x0, x19
    bl dd_select
    mov x0, x23
    mov x1, x24
    address x2, dd_buffer
    bl fl_read
    cbnz x1, read_error_at
    mov x0, x20
    bl dd_select
    mov x0, x23
    mov x1, x24
    address x2, dd_buffer2
    bl fl_read
    cbnz x1, read_error2_at
    // Compare, skipping the serial number in the boot record.
    mul x2, x24, x22
    address x3, dd_buffer
    address x4, dd_buffer2
    mov x5, #0
3:
    cmp x5, x2
    b.hs 5f
    cbnz x23, 31f
    sub x6, x5, #39
    cmp x6, #4
    b.lo 4f
31:
    ldrb w6, [x3, x5]
    ldrb w7, [x4, x5]
    cmp w6, w7
    b.ne 41f
4:
    add x5, x5, #1
    b 3b
41:
    say "Compare error on\r\n"
    mov x0, x23
    bl dd_put_track
    add x28, x28, #1
5:
    add x23, x23, x24
    b 2b
6:
    cbnz x28, 7f
    say "Compare OK\r\n"
7:
    address x0, another
    bl ask_yn
    cbnz x0, again
    cmp x28, #0
    cset x0, ne
    leave
incompatible:
    say "\r\nDrive types or diskette types\r\nnot compatible\r\n"
    mov x0, #2
    leave
read_error:
    mov x23, #0
read_error_at:
    say "\r\nUnrecoverable read error on drive "
    mov x0, x19
    bl dd_put_drive
    bl crlf
    mov x0, x23
    bl dd_put_track
    mov x0, #2
    leave
read_error2_at:
    say "\r\nUnrecoverable read error on drive "
    mov x0, x20
    bl dd_put_drive
    bl crlf
    mov x0, x23
    bl dd_put_track
    mov x0, #2
    leave
9:
    mov x0, #2
    leave

.section .rodata
another: .asciz "\r\nCompare another diskette (Y/N) ? "
