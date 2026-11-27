// SPDX-License-Identifier: MIT
// RAMDRIVE.SYS [DiskSize SectorSize [NumEntries]] [/E | /A]
// (MS-DOS 4.0 src/DEV/RAMDRIVE): a virtual disk in memory. Defaults: 64 KB,
// 512-byte sectors, 64 directory entries.
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
    say "\r\nMicrosoft RAMDrive version 3.06 virtual disk "
    ldr x0, [sp, #16]
    add x0, x0, #'A'
    bl rd_putc
    say ":\r\n    Disk size: "
    address x9, rd_kb
    ldr x0, [x9]
    bl rd_put_dec
    say "k\r\n    Sector size: "
    address x9, rd_bps
    ldr x0, [x9]
    bl rd_put_dec
    say " bytes\r\n    Allocation unit: "
    address x9, rd_spc
    ldr x0, [x9]
    bl rd_put_dec
    say " sectors\r\n    Directory entries: "
    address x9, rd_dirs
    ldr x0, [x9]
    bl rd_put_dec
    say "\r\n\r\n"
    ldp x29, x30, [sp], #32
    ret

.section .rodata
rd_oem: .ascii "RDV 1.20"
rd_label: .ascii "MS-RAMDRIVE"
