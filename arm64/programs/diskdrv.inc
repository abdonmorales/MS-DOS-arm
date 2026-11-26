// SPDX-License-Identifier: MIT
// Shared by DISKCOPY and DISKCOMP: the two drive arguments and their
// geometry. As in DOS, only "diskette" drives qualify: here the drives of
// block device drivers (RAMDRIVE, VDISK); the boot disk is non-removable.
// Include after lib.inc, fatlib.inc and cds.inc.
.equ DD_CHUNK, 64               // sectors per transfer

// x0 = command tail. Fills dd_drive1/dd_drive2 (0-based; both default to
// the current drive). Returns x1 = 0, or x1 = 1 after printing the error.
dd_parse:
    enter
    mov x19, x0
    bl cds_init
    dos 0x19
    address x9, dd_drive1
    str x0, [x9]
    address x9, dd_drive2
    str x0, [x9]
    mov x20, #0                 // drives seen
1:
    mov x0, x19
    bl next_arg
    mov x19, x1
    ldrb w2, [x0]
    cbz w2, 3f
    cmp w2, #'/'
    b.eq 1b                     // /1 and /8: one side or 8 sectors, moot here
    cmp x20, #2
    b.hs 8f
    mov x1, #0
    bl cds_parse_drive
    cmn x0, #1
    b.eq 8f
    address x9, dd_drive1
    add x9, x9, x20, lsl #3
    str x0, [x9]
    add x20, x20, #1
    b 1b
3:
    address x9, dd_drive1
    ldr x0, [x9]
    bl dd_check
    cbnz x1, 9f
    address x9, dd_drive2
    ldr x0, [x9]
    bl dd_check
    cbnz x1, 9f
    mov x1, #0
    leave
8:
    say "Invalid parameter\r\n"
    mov x1, #1
    leave
9:
    say "Invalid drive specification\r\nSpecified drive does not exist\r\nor is non-removable\r\n"
    mov x1, #1
    leave

// x0 = drive: prints its letter and ':'.
dd_put_drive:
    frame
    add x0, x0, #'A'
    bl putc
    mov x0, #':'
    bl putc
    unframe

// x0 = LBA: prints "side S, track T" for it.
dd_put_track:
    frame
    stp x19, x20, [sp, #-16]!
    address x9, dd_spt
    ldr x1, [x9]
    udiv x19, x0, x1            // track * heads + side
    address x9, dd_heads
    ldr x1, [x9]
    udiv x20, x19, x1
    msub x19, x20, x1, x19
    say "side "
    mov x0, x19
    mov x1, #0
    bl put_dec
    say ", track "
    mov x0, x20
    mov x1, #0
    bl put_dec
    bl crlf
    ldp x19, x20, [sp], #16
    unframe

// x0 = drive: x1 = 0 when it is a block device driver's drive.
dd_check:
    frame
    address x9, cds_count
    ldr x9, [x9]
    cmp x0, x9
    b.hs 8f
    bl cds_entry
    ldr x2, [x0, #DRV_FLAGS]
    cmp x2, #DF_VALID
    b.ne 8f
    ldr x2, [x0, #DRV_ASSIGN]
    cbnz x2, 8f
    ldr x2, [x0, #DRV_RW]
    cbz x2, 8f
    mov x1, #0
    unframe
8:
    mov x1, #1
    unframe

// x0 = drive: selects it for fl_read/fl_write and loads its geometry.
// Returns x1 = 0, x0 = total sectors, x2 = bytes per sector.
dd_select:
    frame
    add x0, x0, #1
    address x9, fl_drive
    str x0, [x9]
    bl fl_init
    cbnz x1, 1f
    flp x0, FL_TOTAL
    flp x2, FL_BPS
    mov x1, #0
1:
    unframe

// x0 = 0 for DISKCOPY's wording, 1 for DISKCOMP's. Prints the track count
// and geometry from the boot record in dd_buffer (one sector per track and
// one side when it has none).
dd_geometry:
    enter
    mov x22, x0
    address x19, dd_buffer
    ldrb w20, [x19, #24]
    ldrb w2, [x19, #25]
    orr w20, w20, w2, lsl #8    // sectors per track
    ldrb w21, [x19, #26]
    ldrb w2, [x19, #27]
    orr w21, w21, w2, lsl #8    // heads
    cbz x20, 1f
    cbnz x21, 2f
1:
    mov x20, #1
    mov x21, #1
2:
    address x9, dd_spt
    str x20, [x9]
    address x9, dd_heads
    str x21, [x9]
    address x9, dd_total
    ldr x0, [x9]
    mul x2, x20, x21
    udiv x0, x0, x2
    mov x1, #0
    bl put_dec
    say " tracks\r\n"
    mov x0, x20
    mov x1, #0
    bl put_dec
    cbnz x22, 3f
    say " Sectors/Track, "
    mov x0, x21
    mov x1, #0
    bl put_dec
    say " Side(s)\r\n"
    leave
3:
    say " sectors per track, "
    mov x0, x21
    mov x1, #0
    bl put_dec
    say " side(s)\r\n"
    leave

.section .bss
.balign 8
dd_drive1: .skip 8
dd_drive2: .skip 8
dd_total: .skip 8
dd_bps: .skip 8
dd_spt: .skip 8
dd_heads: .skip 8
.balign 16
dd_buffer: .skip DD_CHUNK * 4096
dd_buffer2: .skip DD_CHUNK * 4096
dd_letter: .skip 8
.section .text
