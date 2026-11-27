// SPDX-License-Identifier: MIT
// VDISK.SYS [bbb] [sss] [ddd] [/E[:m]] [/X[:m]] (MS-DOS 4.0 src/DEV/VDISK): the
// IBM virtual disk. Defaults: 64 KB, 128-byte sectors (512 here: the FAT
// driver needs at least 512), 64 directory entries.
.equ RD_DEFAULT_KB, 64
.equ RD_DEFAULT_BPS, 512
.equ RD_DEFAULT_DIRS, 64
.equ RD_MIN_DIRS, 2
.include "drivers/ramdisk.inc"

// x0 = drive number.
rd_banner:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x0, [sp, #16]
    say "\r\nVDISK Version 4.00 virtual disk "
    ldr x0, [sp, #16]
    add x0, x0, #'A'
    bl rd_putc
    say ":\r\n   Buffer size:       "
    address x9, rd_kb
    ldr x0, [x9]
    bl rd_put_dec
    say " KB\r\n   Sector size:       "
    address x9, rd_bps
    ldr x0, [x9]
    bl rd_put_dec
    say "\r\n   Directory entries: "
    address x9, rd_dirs
    ldr x0, [x9]
    bl rd_put_dec
    say "\r\n"
    ldp x29, x30, [sp], #32
    ret

.section .rodata
rd_oem: .ascii "VDISK4.0"
rd_label: .ascii "VDISK V4.0 "
