// SPDX-License-Identifier: MIT
// The DOS 3.3+ backup set shared by BACKUP and RESTORE. Each backup disk
// holds BACKUP.nnn (the files' data, one after another) and CONTROL.nnn:
//   header (139 bytes): 8Bh, "BACKUP  ", disk number, 128 zero bytes,
//                        FFh when this is the last disk of the set;
//   directory block (70): 46h, path (63 bytes, no drive or leading '\'),
//                        file count, u32 offset of the next block (or -1);
//   file block (34):      22h, name (12 bytes, ASCIIZ), flags (1 last
//                        part, 2 complete), u32 file size, u16 part
//                        number, u32 offset in BACKUP.nnn, u32 length,
//                        attributes, reserved, u16 time, u16 date.
// A removable target (a block device drive) keeps them in its root; any
// other drive in \BACKUP, as DOS did for fixed disks.
.equ BK_HEADER, 139
.equ BK_DIRBLOCK, 70
.equ BK_FILEBLOCK, 34
.equ BK_LAST, 138

// x0 = drive (0-based), x1 = output: "B:\" or "A:\BACKUP\" (the set's
// directory on that drive).
bk_set_dir:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    add w2, w19, #'A'
    strb w2, [x20]
    mov w2, #':'
    strb w2, [x20, #1]
    mov w2, #'\\'
    strb w2, [x20, #2]
    strb wzr, [x20, #3]
    mov x0, x19
    bl cds_entry
    ldr x2, [x0, #DRV_RW]
    cbnz x2, 1f
    address x0, bk_fixed_dir
    add x1, x20, #3
    bl strcpy
1:
    ldp x19, x20, [sp], #16
    unframe

// x0 = set directory, x1 = disk number, x2 = "CONTROL" / "BACKUP", x3 =
// output. Builds "B:\CONTROL.001".
bk_name:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x1
    mov x20, x2
    mov x21, x3
    mov x1, x21
    bl strcpy
    mov x1, x0
    mov x0, x20
    bl strcpy
    mov w2, #'.'
    strb w2, [x0], #1
    mov x3, #100
    udiv x4, x19, x3
    msub x19, x4, x3, x19
    add w4, w4, #'0'
    strb w4, [x0], #1
    mov x3, #10
    udiv x4, x19, x3
    msub x19, x4, x3, x19
    add w4, w4, #'0'
    strb w4, [x0], #1
    add w4, w19, #'0'
    strb w4, [x0], #1
    strb wzr, [x0]
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// x0 = disk number: prints it with two digits.
bk_put_disk:
    frame
    mov x1, #10
    udiv x2, x0, x1
    msub x3, x2, x1, x0
    str x3, [sp, #-16]!
    add x0, x2, #'0'
    bl putc
    ldr x3, [sp], #16
    add x0, x3, #'0'
    bl putc
    unframe

// Little-endian stores and loads at any offset.
// x0 = address, x1 = value.
bk_put16:
    strb w1, [x0]
    lsr w1, w1, #8
    strb w1, [x0, #1]
    ret
bk_put32:
    strb w1, [x0]
    lsr w2, w1, #8
    strb w2, [x0, #1]
    lsr w2, w1, #16
    strb w2, [x0, #2]
    lsr w2, w1, #24
    strb w2, [x0, #3]
    ret
// x0 = address. Returns x0.
bk_get16:
    ldrb w1, [x0]
    ldrb w2, [x0, #1]
    orr w0, w1, w2, lsl #8
    ret
bk_get32:
    ldrb w1, [x0]
    ldrb w2, [x0, #1]
    orr w1, w1, w2, lsl #8
    ldrb w2, [x0, #2]
    orr w1, w1, w2, lsl #16
    ldrb w2, [x0, #3]
    orr w0, w1, w2, lsl #24
    ret

// x0 = "mm-dd-yy[yy]". Returns x0 = packed date, x1 = 0 / 1.
parse_date:
    frame
    stp x19, x20, [sp, #-16]!
    bl parse_dec
    cbnz x1, 9f
    mov x19, x0
    ldrb w3, [x2]
    cmp w3, #'-'
    b.ne 9f
    add x0, x2, #1
    bl parse_dec
    cbnz x1, 9f
    mov x20, x0
    ldrb w3, [x2]
    cmp w3, #'-'
    b.ne 9f
    add x0, x2, #1
    bl parse_dec
    cbnz x1, 9f
    cmp x0, #80
    b.hs 1f
    add x0, x0, #2000
    b 2f
1:
    cmp x0, #100
    b.hs 2f
    add x0, x0, #1900
2:
    subs x0, x0, #1980
    b.lo 9f
    lsl x0, x0, #9
    orr x0, x0, x19, lsl #5
    orr x0, x0, x20
    mov x1, #0
    b 8f
9:
    mov x1, #1
8:
    ldp x19, x20, [sp], #16
    unframe

// x0 = "hh:mm[:ss]". Returns x0 = packed time, x1 = 0 / 1.
parse_time:
    frame
    stp x19, x20, [sp, #-16]!
    bl parse_dec
    cbnz x1, 9f
    mov x19, x0
    ldrb w3, [x2]
    cmp w3, #':'
    b.ne 9f
    add x0, x2, #1
    bl parse_dec
    cbnz x1, 9f
    mov x20, x0
    mov x3, #0
    ldrb w4, [x2]
    cmp w4, #':'
    b.ne 1f
    add x0, x2, #1
    bl parse_dec
    cbnz x1, 9f
    mov x3, x0
1:
    lsl x0, x19, #11
    orr x0, x0, x20, lsl #5
    orr x0, x0, x3, lsr #1
    mov x1, #0
    b 8f
9:
    mov x1, #1
8:
    ldp x19, x20, [sp], #16
    unframe

.section .rodata
bk_fixed_dir: .asciz "BACKUP\\"
bk_control: .asciz "CONTROL"
bk_backup: .asciz "BACKUP"
bk_signature: .ascii "BACKUP  "
.section .text
