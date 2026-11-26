// SPDX-License-Identifier: MIT
// Shared core of RAMDRIVE.SYS and VDISK.SYS: a block device kept in memory
// from 48h, formatted with FAT12 at install time (as both drivers did).
// The including file defines RD_DEFAULT_KB, RD_DEFAULT_BPS, RD_DEFAULT_DIRS,
// RD_MIN_DIRS and rd_banner (x0 = drive number; geometry in rd_* globals),
// rd_oem (8 bytes) and rd_label (11 bytes).
//
// Block driver interface (ABI.md): the init request's +48 (sectors) being
// nonzero makes this a block device; +24 is rw(x0 sector, x1 buffer,
// x2 count, x3 = 1 to write) returning x0 = 0; +56 the sector size; +64 in
// is the drive the unit gets.
.macro address reg, name
    adrp \reg, \name
    add \reg, \reg, :lo12:\name
.endm
.macro dos fn
    mov w8, #\fn
    adrp x9, rd_dos
    ldr x9, [x9, :lo12:rd_dos]
    blr x9
.endm
.macro say text
    .pushsection .rodata
9876:
    .asciz "\text"
    .popsection
    adrp x0, 9876b
    add x0, x0, :lo12:9876b
    bl rd_puts
.endm
.section .text
.global efi_main
efi_main:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov x19, x0
    ldr x1, [x19]
    address x2, rd_dos
    str x1, [x2]
    // Arguments: size in KB, sector size, directory entries; switches are
    // accepted (memory is flat, there is no extended or expanded memory).
    mov x20, #RD_DEFAULT_KB
    mov x21, #RD_DEFAULT_BPS
    mov x22, #RD_DEFAULT_DIRS
    ldr x0, [x19, #8]
    bl rd_skip
    bl rd_number
    cbz x1, 1f
    mov x20, x2
    bl rd_skip
    bl rd_number
    cbz x1, 1f
    mov x21, x2
    bl rd_skip
    bl rd_number
    cbz x1, 1f
    mov x22, x2
1:
    // Sizes: 16 KB to 4096 KB; sectors 512 or 1024 bytes (the FAT driver
    // needs at least 512); 2 to 1024 directory entries.
    cmp x20, #16
    mov x2, #16
    csel x20, x2, x20, lo
    mov x2, #4096
    cmp x20, x2
    csel x20, x2, x20, hi
    cmp x21, #1024
    mov x2, #1024
    mov x3, #512
    csel x21, x2, x3, hs
    cmp x22, #RD_MIN_DIRS
    mov x2, #RD_MIN_DIRS
    csel x22, x2, x22, lo
    mov x2, #1024
    cmp x22, x2
    csel x22, x2, x22, hi
    // Geometry: root sectors (entries rounded up to fill them), then the
    // smallest cluster size that keeps FAT12, then the FAT size.
    lsl x2, x20, #10
    udiv x3, x2, x21            // total sectors
    address x9, rd_total
    str x3, [x9]
    lsl x4, x22, #5
    add x4, x4, x21
    sub x4, x4, #1
    udiv x4, x4, x21            // root sectors
    mul x5, x4, x21
    lsr x22, x5, #5             // entries
    address x9, rd_dirs
    str x22, [x9]
    address x9, rd_root_secs
    str x4, [x9]
    mov x6, #1                  // sectors per cluster
2:
    mov x7, #1                  // FAT sectors
3:
    sub x8, x3, #1
    sub x8, x8, x4
    sub x8, x8, x7
    udiv x8, x8, x6             // clusters
    add x10, x8, #2
    add x10, x10, x10, lsl #1
    lsr x10, x10, #1
    add x10, x10, #1            // FAT12 bytes
    add x10, x10, x21
    sub x10, x10, #1
    udiv x10, x10, x21
    cmp x10, x7
    b.ls 4f
    mov x7, x10
    b 3b
4:
    mov x10, #4084
    cmp x8, x10
    b.ls 5f
    lsl x6, x6, #1
    b 2b
5:
    address x9, rd_spc
    str x6, [x9]
    address x9, rd_fat_secs
    str x7, [x9]
    address x9, rd_bps
    str x21, [x9]
    address x9, rd_kb
    str x20, [x9]
    // Memory.
    mul x0, x3, x21
    dos 0x48
    cbnz x1, rd_no_memory
    address x9, rd_base
    str x0, [x9]
    bl rd_format
    ldr x0, [x19, #64]
    bl rd_banner
    address x0, rd_rw
    str x0, [x19, #24]
    address x9, rd_total
    ldr x0, [x9]
    str x0, [x19, #48]
    str x21, [x19, #56]
    mov x1, #0
    b 9f
rd_no_memory:
    say "Insufficient memory for the virtual disk\r\n"
    mov x1, #1
9:
    ldp x19, x20, [sp, #16]
    ldp x21, x22, [sp, #32]
    ldp x29, x30, [sp], #48
    ret

// Writes the boot record, an empty FAT and a root directory holding the
// volume label into the memory block.
rd_format:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    address x9, rd_base
    ldr x0, [x9]
    address x9, rd_total
    ldr x1, [x9]
    address x9, rd_bps
    ldr x2, [x9]
    mul x1, x1, x2
    mov x3, #0
1:
    str xzr, [x0, x3]
    add x3, x3, #8
    cmp x3, x1
    b.lo 1b
    mov w3, #0xeb
    strb w3, [x0]
    mov w3, #0x3c
    strb w3, [x0, #1]
    mov w3, #0x90
    strb w3, [x0, #2]
    address x4, rd_oem
    mov x6, #0
11:
    ldrb w7, [x4, x6]
    add x8, x0, x6
    strb w7, [x8, #3]
    add x6, x6, #1
    cmp x6, #8
    b.lo 11b
    strb w2, [x0, #11]
    lsr w3, w2, #8
    strb w3, [x0, #12]
    address x9, rd_spc
    ldr x3, [x9]
    strb w3, [x0, #13]
    mov w3, #1
    strb w3, [x0, #14]          // reserved sectors
    strb w3, [x0, #16]          // one FAT copy
    address x9, rd_dirs
    ldr x3, [x9]
    strb w3, [x0, #17]
    lsr w3, w3, #8
    strb w3, [x0, #18]
    address x9, rd_total
    ldr x3, [x9]
    strb w3, [x0, #19]
    lsr w3, w3, #8
    strb w3, [x0, #20]
    mov w3, #0xf8
    strb w3, [x0, #21]
    address x9, rd_fat_secs
    ldr x3, [x9]
    strb w3, [x0, #22]
    lsr w3, w3, #8
    strb w3, [x0, #23]
    mov w3, #1
    strb w3, [x0, #24]          // sectors per track
    strb w3, [x0, #26]          // heads
    mov w3, #0x29
    strb w3, [x0, #38]
    dos 0x2c                    // serial number from the time of day
    address x9, rd_base
    ldr x5, [x9]
    orr w4, w2, w0, lsl #8
    orr w4, w4, w3, lsl #16
    strb w4, [x5, #39]
    lsr w4, w4, #8
    strb w4, [x5, #40]
    lsr w4, w4, #8
    strb w4, [x5, #41]
    mov w4, #0x52
    strb w4, [x5, #42]
    add x8, x5, #43
    bl rd_copy_label
    address x4, rd_fs_type
    mov x6, #0
21:
    ldrb w7, [x4, x6]
    add x8, x5, x6
    strb w7, [x8, #54]
    add x6, x6, #1
    cmp x6, #8
    b.lo 21b
    mov w4, #0x55
    strb w4, [x5, #510]
    mov w4, #0xaa
    strb w4, [x5, #511]
    // FAT: media byte, then the end-of-chain marker for cluster 1.
    address x9, rd_bps
    ldr x2, [x9]
    add x6, x5, x2
    mov w4, #0xf8
    strb w4, [x6]
    mov w4, #0xff
    strb w4, [x6, #1]
    strb w4, [x6, #2]
    // Root directory: the volume label.
    address x9, rd_fat_secs
    ldr x3, [x9]
    add x3, x3, #1
    madd x8, x3, x2, x5
    bl rd_copy_label
    mov w4, #0x08
    strb w4, [x8, #11]
    str x8, [sp, #-16]!         // the label's time and date: now
    dos 0x2c
    lsl w4, w0, #11
    orr w4, w4, w2, lsl #5
    lsr w3, w3, #1
    orr w4, w4, w3
    ldr x8, [sp]
    strh w4, [x8, #22]
    dos 0x2a
    sub w0, w0, #1980
    lsl w4, w0, #9
    orr w4, w4, w2, lsl #5
    orr w4, w4, w3
    ldr x8, [sp], #16
    strh w4, [x8, #24]
    ldp x29, x30, [sp], #16
    ret

// x8 = destination: the 11-byte label.
rd_copy_label:
    address x4, rd_label
    mov x6, #0
1:
    ldrb w7, [x4, x6]
    strb w7, [x8, x6]
    add x6, x6, #1
    cmp x6, #11
    b.lo 1b
    ret

// The block device: x0 sector, x1 buffer, x2 count, x3 = 1 to write.
rd_rw:
    address x9, rd_total
    ldr x9, [x9]
    add x4, x0, x2
    cmp x4, x9
    b.hi 8f
    address x9, rd_bps
    ldr x9, [x9]
    address x10, rd_base
    ldr x10, [x10]
    madd x10, x0, x9, x10       // the sector in memory
    mul x11, x2, x9             // bytes
    mov x12, x1
    cbz x3, 1f
    mov x12, x10                // write: buffer -> memory
    mov x10, x1
1:
    // copy x11 bytes from x10 to x12
    mov x13, #0
2:
    cmp x13, x11
    b.hs 3f
    ldr x14, [x10, x13]
    str x14, [x12, x13]
    add x13, x13, #8
    b 2b
3:
    mov x0, #0
    ret
8:
    mov x0, #1
    ret

// x0 = text: skips blanks. Returns x0.
rd_skip:
    ldrb w1, [x0]
    cmp w1, #' '
    b.eq 1f
    cmp w1, #9
    b.ne 2f
1:
    add x0, x0, #1
    b rd_skip
2:
    ret

// x0 = text. Returns x1 = 1 with x2 = a decimal number and x0 past it, or
// x1 = 0 at the end. Switches ("/E", "/E:8", "/A", "/X") are skipped.
rd_number:
    ldrb w1, [x0]
    cmp w1, #'/'
    b.ne 2f
1:
    add x0, x0, #1
    ldrb w1, [x0]
    cbz w1, 3f
    cmp w1, #' '
    b.ne 1b
4:
    add x0, x0, #1
    ldrb w1, [x0]
    cmp w1, #' '
    b.eq 4b
    b rd_number
2:
    mov x2, #0
    mov x1, #0
    mov x4, #10
21:
    ldrb w3, [x0]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi 22f
    madd x2, x2, x4, x3
    mov x1, #1
    add x0, x0, #1
    b 21b
22:
    ret
3:
    mov x1, #0
    ret

// x0 = text (NUL-terminated) to standard output.
rd_puts:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x1, x0
    mov x2, #0
1:
    ldrb w3, [x1, x2]
    cbz w3, 2f
    add x2, x2, #1
    b 1b
2:
    mov x0, #1
    dos 0x40
    ldp x29, x30, [sp], #16
    ret

// x0 = value: decimal to standard output.
rd_put_dec:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    address x1, rd_digits + 23
    strb wzr, [x1]
    mov x2, #10
1:
    udiv x3, x0, x2
    msub x4, x3, x2, x0
    add w4, w4, #'0'
    strb w4, [x1, #-1]!
    mov x0, x3
    cbnz x0, 1b
    mov x0, x1
    bl rd_puts
    ldp x29, x30, [sp], #16
    ret

// x0 = character to standard output.
rd_putc:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    address x1, rd_digits
    strb w0, [x1]
    strb wzr, [x1, #1]
    mov x0, x1
    bl rd_puts
    ldp x29, x30, [sp], #16
    ret

.section .rodata
rd_fs_type: .ascii "FAT12   "
.section .bss
.balign 8
rd_dos: .skip 8
rd_base: .skip 8
rd_total: .skip 8
rd_bps: .skip 8
rd_spc: .skip 8
rd_kb: .skip 8
rd_dirs: .skip 8
rd_root_secs: .skip 8
rd_fat_secs: .skip 8
rd_digits: .skip 32
.section .text
