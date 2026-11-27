// SPDX-License-Identifier: MIT
// DISKCOPY [d1: [d2:]] [/1] (v4.0/src/CMD/DISKCOPY): copies a whole disk,
// sector for sector, to another of the same size, then gives the copy its
// own volume serial number. The disks are block device drives (RAMDRIVE,
// VDISK); see diskdrv.inc.
.include "lib.inc"
.include "fatlib.inc"
.include "cds.inc"
.include "diskdrv.inc"

main:
    enter
    bl dd_parse
    cbnz x1, 9f
    address x9, dd_drive1
    ldp x19, x20, [x9]          // source, target
again:
    say "\r\nInsert SOURCE diskette in drive "
    mov x0, x19
    bl dd_put_drive
    bl crlf
    cmp x19, x20
    b.eq 1f
    say "\r\nInsert TARGET diskette in drive "
    mov x0, x20
    bl dd_put_drive
    bl crlf
1:
    bl crlf
    bl press_any_key
    // Same size and sector size.
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
    say "\r\nCopying "
    mov x0, #0
    bl dd_geometry
    // The copy, a chunk at a time.
    mov x23, #0                 // sector
2:
    cmp x23, x21
    b.hs 4f
    sub x24, x21, x23
    mov x2, #DD_CHUNK
    cmp x24, x2
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
    address x2, dd_buffer
    bl fl_write
    cbnz x1, write_error_at
    add x23, x23, x24
    b 2b
4:
    // A fresh serial number for the copy (DOS 4).
    mov x0, #0
    mov x1, #1
    address x2, dd_buffer
    bl fl_read
    cbnz x1, 5f
    address x25, dd_buffer
    ldrb w2, [x25, #38]
    cmp w2, #0x29
    b.ne 5f
    dos 0x2c
    orr w4, w3, w0, lsl #24
    orr w4, w4, w2, lsl #16
    str w4, [sp, #-16]!
    dos 0x2a
    ldr w4, [sp], #16
    orr w5, w3, w2, lsl #8
    add w5, w5, w0, lsl #16
    add w26, w4, w5
    strb w26, [x25, #39]
    lsr w2, w26, #8
    strb w2, [x25, #40]
    lsr w2, w26, #16
    strb w2, [x25, #41]
    lsr w2, w26, #24
    strb w2, [x25, #42]
    mov x0, #0
    mov x1, #1
    mov x2, x25
    bl fl_write
    cbnz x1, write_error_at
    add x0, x20, #1             // the target's new boot record and FAT
    mov x1, #0x0d
    mov x2, #0x0840
    dos 0x44
    say "\r\nVolume Serial Number is "
    lsr w0, w26, #16
    mov x1, #4
    bl put_hex
    mov x0, #'-'
    bl putc
    and w0, w26, #0xffff
    mov x1, #4
    bl put_hex
    bl crlf
5:
    address x0, another
    bl ask_yn
    cbnz x0, again
    mov x0, #0
    leave
incompatible:
    say "\r\nDrive types or diskette types\r\nnot compatible\r\n"
    mov x0, #4
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
    mov x0, #4
    leave
write_error_at:
    say "\r\nUnrecoverable write error on drive "
    mov x0, x20
    bl dd_put_drive
    bl crlf
    mov x0, x23
    bl dd_put_track
    mov x0, #4
    leave
9:
    mov x0, #4
    leave

.section .rodata
another: .asciz "\r\nCopy another diskette (Y/N)? "
