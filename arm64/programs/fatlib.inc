// SPDX-License-Identifier: MIT
// Raw FAT access for the disk utilities (CHKDSK, LABEL, RECOVER), through
// IOCTL 440Dh 0860h/0861h/0841h, the native form of INT 25h/26h.
// Include after lib.inc.

.section .text
// Reads the volume geometry. Returns x1 = 0, or x1 = 1 on failure.
fl_init:
    frame
    mov x0, #0
    mov x1, #0x0d
    mov x2, #0x0860
    address x3, fl_params
    dos 0x44
    cbnz x1, 1f
    address x9, fl_fat_cached
    mov x2, #-1
    str x2, [x9]
    mov x1, #0
1:
    unframe

// x0 = first sector, x1 = count, x2 = buffer.
fl_read:
    mov x3, #0x0861
    b fl_transfer
fl_write:
    mov x3, #0x0841
fl_transfer:
    frame
    sub sp, sp, #32
    stp x0, x1, [sp]
    str x2, [sp, #16]
    mov x2, x3
    mov x3, sp
    mov x0, #0
    mov x1, #0x0d
    dos 0x44
    add sp, sp, #32
    unframe

// Geometry accessors (fl_params layout from ABI.md).
.equ FL_BPS, 0
.equ FL_SPC, 8
.equ FL_TYPE, 16
.equ FL_DATA, 24
.equ FL_CLUSTERS, 32
.equ FL_FAT_START, 40
.equ FL_FAT_SECTORS, 48
.equ FL_FATS, 56
.equ FL_ROOT_START, 64
.equ FL_ROOT_ENTRIES, 72
.equ FL_ROOT_CLUSTER, 80
.macro flp reg, field
    adrp \reg, fl_params
    add \reg, \reg, :lo12:fl_params
    ldr \reg, [\reg, #\field]
.endm

// x0 = cluster. Returns x0 = its first sector.
fl_cluster_sector:
    sub x0, x0, #2
    flp x1, FL_SPC
    mul x0, x0, x1
    flp x1, FL_DATA
    add x0, x0, x1
    ret

// x0 = byte offset into the FAT. Loads the sector holding it (and the next,
// for FAT12 entries that straddle two sectors) into fl_fat_buffer.
// Returns x0 = pointer to that byte, x1 = 0 / 1 on error.
fl_fat_byte:
    frame
    stp x19, x20, [sp, #-16]!
    flp x2, FL_BPS
    udiv x19, x0, x2            // sector within the FAT
    msub x20, x19, x2, x0       // offset within it
    address x9, fl_fat_cached
    ldr x3, [x9]
    cmp x3, x19
    b.eq 1f
    str x19, [x9]
    flp x0, FL_FAT_START
    add x0, x0, x19
    mov x1, #2
    address x2, fl_fat_buffer
    bl fl_read
    cbz x1, 1f
    address x9, fl_fat_cached
    mov x2, #-1
    str x2, [x9]
    mov x1, #1
    b 2f
1:
    address x0, fl_fat_buffer
    add x0, x0, x20
    mov x1, #0
2:
    ldp x19, x20, [sp], #16
    unframe

// x0 = cluster. Returns x0 = its FAT entry (end of chain >= fl_eoc()).
fl_get:
    frame
    str x19, [sp, #-16]!
    mov x19, x0
    flp x2, FL_TYPE
    cmp x2, #12
    b.eq 12f
    cmp x2, #16
    b.eq 16f
    lsl x0, x19, #2
    bl fl_fat_byte
    ldr w0, [x0]
    and x0, x0, #0x0fffffff
    b 9f
16:
    lsl x0, x19, #1
    bl fl_fat_byte
    ldrh w0, [x0]
    b 9f
12:
    add x0, x19, x19, lsr #1
    bl fl_fat_byte
    ldrb w2, [x0]
    ldrb w3, [x0, #1]
    orr w0, w2, w3, lsl #8
    tbz x19, #0, 1f
    lsr w0, w0, #4
1:
    and w0, w0, #0xfff
9:
    ldr x19, [sp], #16
    unframe

// Returns x0 = the smallest end-of-chain value for this FAT type.
fl_eoc:
    flp x1, FL_TYPE
    mov x0, #0xff8
    cmp x1, #12
    b.eq 1f
    mov x0, #0xfff8
    cmp x1, #16
    b.eq 1f
    mov x0, #0x0ffffff8
1:
    ret

// x0 = cluster, x1 = value: writes the entry into every FAT copy.
fl_set:
    enter
    mov x19, x0
    mov x20, x1
    flp x2, FL_TYPE
    cmp x2, #12
    b.eq 12f
    cmp x2, #16
    b.eq 16f
    lsl x0, x19, #2
    bl fl_fat_byte
    cbnz x1, 9f
    ldr w2, [x0]
    and w2, w2, #0xf0000000
    and w3, w20, #0x0fffffff
    orr w2, w2, w3
    str w2, [x0]
    lsl x21, x19, #2
    b 5f
16:
    lsl x0, x19, #1
    bl fl_fat_byte
    cbnz x1, 9f
    strh w20, [x0]
    lsl x21, x19, #1
    b 5f
12:
    add x0, x19, x19, lsr #1
    mov x21, x0
    bl fl_fat_byte
    cbnz x1, 9f
    ldrb w2, [x0]
    ldrb w3, [x0, #1]
    orr w2, w2, w3, lsl #8
    and w4, w20, #0xfff
    tbz x19, #0, 1f
    and w2, w2, #0x000f
    orr w2, w2, w4, lsl #4
    b 2f
1:
    and w2, w2, #0xf000
    orr w2, w2, w4
2:
    strb w2, [x0]
    lsr w2, w2, #8
    strb w2, [x0, #1]
5:
    // Write the two buffered sectors back to each FAT copy.
    flp x2, FL_BPS
    udiv x22, x21, x2           // sector within the FAT
    flp x23, FL_FATS
    mov x24, #0
6:
    cmp x24, x23
    b.hs 8f
    flp x0, FL_FAT_SECTORS
    mul x0, x0, x24
    flp x1, FL_FAT_START
    add x0, x0, x1
    add x0, x0, x22
    mov x1, #2
    flp x2, FL_FAT_SECTORS
    sub x2, x2, x22
    cmp x2, #1
    b.hi 7f
    mov x1, #1                  // last FAT sector: only one
7:
    address x2, fl_fat_buffer
    bl fl_write
    add x24, x24, #1
    b 6b
8:
    mov x1, #0
9:
    leave

// x0 = first cluster of a directory (0 = root), x1 = buffer, x2 = capacity.
// Reads the whole directory. Returns x0 = bytes read, x1 = 0 / 1. The sector
// list is kept in fl_dir_sectors for fl_dir_write.
fl_dir_load:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, #0                 // bytes
    mov x23, #0                 // sectors listed
    flp x24, FL_BPS
    cbnz x19, 3f
    flp x2, FL_TYPE
    cmp x2, #32
    b.ne 1f
    flp x19, FL_ROOT_CLUSTER
    b 3f
1:
    flp x25, FL_ROOT_ENTRIES    // fixed root region
    lsl x25, x25, #5
    add x25, x25, x24
    sub x25, x25, #1
    udiv x25, x25, x24          // root sectors
    flp x26, FL_ROOT_START
    mov x27, #0
2:
    cmp x27, x25
    b.hs 8f
    add x0, x26, x27
    bl fl_dir_sector
    cbnz x1, 9f
    add x27, x27, #1
    b 2b
3:
    bl fl_eoc
    mov x28, x0
4:
    cmp x19, #2
    b.lo 8f
    cmp x19, x28
    b.hs 8f
    mov x0, x19
    bl fl_cluster_sector
    mov x26, x0
    flp x25, FL_SPC
    mov x27, #0
5:
    cmp x27, x25
    b.hs 6f
    add x0, x26, x27
    bl fl_dir_sector
    cbnz x1, 9f
    add x27, x27, #1
    b 5b
6:
    mov x0, x19
    bl fl_get
    mov x19, x0
    b 4b
8:
    address x9, fl_dir_count
    str x23, [x9]
    mov x0, x22
    mov x1, #0
    leave
9:
    mov x1, #1
    leave

// Helper of fl_dir_load (its registers): x0 = sector to append.
fl_dir_sector:
    add x2, x22, x24
    cmp x2, x21
    b.hi 1f
    cmp x23, #FL_MAX_DIR_SECTORS
    b.hs 1f
    address x9, fl_dir_sectors
    str x0, [x9, x23, lsl #3]
    add x23, x23, #1
    frame
    mov x1, #1
    add x2, x20, x22
    bl fl_read
    cbnz x1, 2f
    flp x2, FL_BPS
    add x22, x22, x2
2:
    unframe
1:
    mov x1, #0                  // full: stop quietly (treated as the end)
    ret

// x0 = buffer previously loaded by fl_dir_load: writes it back.
fl_dir_write:
    enter
    mov x19, x0
    address x20, fl_dir_sectors
    address x9, fl_dir_count
    ldr x21, [x9]
    mov x22, #0
    flp x23, FL_BPS
1:
    cmp x22, x21
    b.hs 2f
    ldr x0, [x20, x22, lsl #3]
    mov x1, #1
    mul x2, x22, x23
    add x2, x19, x2
    bl fl_write
    cbnz x1, 3f
    add x22, x22, #1
    b 1b
2:
    mov x1, #0
3:
    leave

// x0 = 32-byte entry, x1 = output: "NAME.EXT" from the 8.3 fields.
fl_entry_name:
    mov x2, #0
1:
    ldrb w3, [x0, x2]
    cmp w3, #' '
    b.eq 2f
    strb w3, [x1], #1
    add x2, x2, #1
    cmp x2, #8
    b.lo 1b
2:
    ldrb w3, [x0, #8]
    cmp w3, #' '
    b.eq 4f
    mov w3, #'.'
    strb w3, [x1], #1
    mov x2, #8
3:
    ldrb w3, [x0, x2]
    cmp w3, #' '
    b.eq 4f
    strb w3, [x1], #1
    add x2, x2, #1
    cmp x2, #11
    b.lo 3b
4:
    strb wzr, [x1]
    ret

// x0 = entry. Returns x0 = first cluster (high word on FAT32).
fl_entry_cluster:
    ldrh w1, [x0, #26]
    ldrh w2, [x0, #20]
    flp x3, FL_TYPE
    cmp x3, #32
    b.ne 1f
    orr w1, w1, w2, lsl #16
1:
    mov x0, x1
    ret


// x0 = directory cluster (0 = root), x1 = name (long or 8.3, any case),
// x2 = buffer (fl_dir_load capacity in x3). Returns x0 = entry pointer in
// the buffer or 0, x1 = 0 / 1 on a disk error. The buffer stays loaded.
fl_find:
    enter
    mov x19, x1
    mov x20, x2
    mov x1, x2
    mov x2, x3
    bl fl_dir_load
    cbnz x1, 9f
    mov x21, x0
    mov x22, #0                 // offset
    address x23, fl_lfn
    strb wzr, [x23]
1:
    cmp x22, x21
    b.hs 8f
    add x24, x20, x22
    ldrb w2, [x24]
    cbz w2, 8f
    cmp w2, #0xe5
    b.eq 6f
    ldrb w3, [x24, #11]
    cmp w3, #0x0f
    b.ne 3f
    // Long-name piece: sequence (1-20) at byte 0, 13 UTF-16 characters.
    and w4, w2, #0x1f
    sub w4, w4, #1
    mov w5, #13
    mul w4, w4, w5
    cmp w4, #240
    b.hs 7f
    add x5, x23, x4
    address x6, fl_lfn_offsets
    mov x7, #0
2:
    ldrb w8, [x6, x7]
    ldrh w9, [x24, x8]
    mov w10, #0xffff
    cmp w9, w10
    b.eq 21f
    cmp w9, #0x7f
    b.ls 22f
    mov w9, #'_'
22:
    strb w9, [x5, x7]
    cbz w9, 7f
21:
    add x7, x7, #1
    cmp x7, #13
    b.lo 2b
    tbz w2, #6, 7f              // the last piece (0x40) ends the name
    strb wzr, [x5, #13]
    b 7f
3:
    tbnz w3, #3, 5f             // volume label
    ldrb w4, [x23]
    cbz w4, 4f
    mov x0, x23
    mov x1, x19
    bl strcmpi
    cbz x0, found
4:
    mov x0, x24
    address x1, fl_short
    bl fl_entry_name
    address x0, fl_short
    mov x1, x19
    bl strcmpi
    cbz x0, found
5:
    strb wzr, [x23]
    b 7f
6:
    strb wzr, [x23]
7:
    add x22, x22, #32
    b 1b
8:
    mov x0, #0
    mov x1, #0
    leave
found:
    mov x0, x24
    mov x1, #0
    leave
9:
    mov x1, #1
    leave

// x0 = path ("A:\DIR\FILE", "\DIR\FILE" or relative to the root),
// x1 = buffer, x2 = capacity. Finds the entry, leaving its directory in
// the buffer: x0 = entry or 0, x1 = 0 / 1 disk error, x2 = directory cluster.
fl_resolve:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x0, x19
    address x1, fl_true
    dos 0x60                    // canonical "A:\DIR\FILE"
    cbnz x1, 8f
    address x22, fl_true
    add x22, x22, #3            // past "A:\"
    mov x23, #0                 // directory cluster
1:
    ldrb w2, [x22]
    cbz w2, 8f
    mov x24, x22                // component
2:
    ldrb w2, [x22]
    cbz w2, 3f
    cmp w2, #'\\'
    b.eq 3f
    add x22, x22, #1
    b 2b
3:
    mov w25, w2
    strb wzr, [x22]
    mov x0, x23
    mov x1, x24
    mov x2, x20
    mov x3, x21
    bl fl_find
    cbnz x1, 9f
    cbz x0, 8f
    cbz w25, 4f
    mov x26, x0
    bl fl_entry_cluster
    mov x23, x0
    add x22, x22, #1
    b 1b
4:
    mov x2, x23
    mov x1, #0
    leave
8:
    mov x0, #0
    mov x1, #0
    leave
9:
    mov x1, #1
    leave

.equ FL_MAX_DIR_SECTORS, 1024
.section .bss
.balign 8
fl_params: .skip 88
fl_fat_cached: .skip 8
fl_dir_count: .skip 8
fl_dir_sectors: .skip 8 * FL_MAX_DIR_SECTORS
fl_fat_buffer: .skip 8192
fl_lfn: .skip 272
fl_short: .skip 16
fl_true: .skip 128
.section .rodata
fl_lfn_offsets: .byte 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30
.section .text
