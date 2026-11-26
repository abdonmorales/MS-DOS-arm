// SPDX-License-Identifier: MIT
// INSTALL [disk] [/Y]: puts ARM DOS on a writable disk, as DOS 4's SELECT
// did. Run from the live ISO's prompt (or any firmware-mode boot): it lists
// the disks the firmware offers (ARM DOS extension E0h, see ABI.md), then
// writes an MBR with one partition of type EFh, attaches it as a drive
// letter, runs FORMAT d: /SELECT /V:ARMDOS and XCOPY of the boot drive,
// \EFI\BOOT\BOOTAA64.EFI included. The disk then boots ARM DOS on any ARM64
// UEFI machine. /Y skips the confirmation, for scripts; it needs the disk
// number, so nothing is erased by default.
.include "lib.inc"
.equ PART_MAX_MIB, 2000         // FORMAT's FAT16 limit is just under 2 GiB
.equ ZERO_BUF, 65536

main:
    enter
    mov x19, x0                 // command tail
    mov x20, #0                 // disk number given (1-based), 0 none
    mov x21, #0                 // /Y
1:
    mov x0, x19
    bl next_arg
    mov x19, x1
    ldrb w2, [x0]
    cbz w2, 3f
    cmp w2, #'/'
    b.ne 2f
    ldrb w2, [x0, #2]           // exactly /Y
    cbnz w2, bad_parm
    ldrb w0, [x0, #1]
    bl toupper
    cmp w0, #'Y'
    b.ne bad_parm
    mov x21, #1
    b 1b
2:
    cbnz x20, bad_parm
    bl parse_dec
    cbnz x1, bad_parm
    ldrb w2, [x2]
    cbnz w2, bad_parm
    cbz x0, bad_parm
    mov x20, x0
    b 1b
3:
    cbz x21, 31f
    cbz x20, need_disk          // /Y never picks a disk by itself
31:
    say "\r\nARM DOS Setup\r\n\r\n"
    mov x0, #0
    dos 0xe0
    cbnz x1, no_disks
    cbz x0, no_disks
    mov x22, x0                 // disks
    // List them: "  Disk 1: 2048 MB (removable)"
    mov x23, #0
4:
    cmp x23, x22
    b.hs 5f
    mov x0, #1
    mov x1, x23
    address x2, info
    dos 0xe0
    cbnz x1, failed
    say "  Disk "
    add x0, x23, #1
    mov x1, #0
    bl put_dec
    say ": "
    address x9, info
    ldp x10, x11, [x9]
    mul x0, x10, x11
    lsr x0, x0, #20
    mov x1, #0
    bl put_dec
    say " MB"
    address x9, info
    ldr x10, [x9, #16]
    cbz x10, 41f
    say " (removable)"
41:
    bl crlf
    add x23, x23, #1
    b 4b
5:
    cbnz x20, 6f
    // No disk named: ask, even when there is only one.
51:
    say "\r\nInstall ARM DOS on which disk (1-"
    mov x0, x22
    mov x1, #0
    bl put_dec
    say ", ENTER to cancel)? "
    address x0, line
    mov w1, #8
    strb w1, [x0]
    bl read_console_line
    bl skip_blanks
    mov x26, x0
    bl rtrim
    mov x0, x26
    ldrb w1, [x0]
    cbz w1, cancelled
    bl parse_dec
    cbnz x1, 51b
    ldrb w2, [x2]
    cbnz w2, 51b
    cbz x0, 51b
    cmp x0, x22
    b.hi 51b
    mov x20, x0
6:
    cmp x20, x22
    b.hi bad_disk
    sub x23, x20, #1            // disk index
    mov x0, #1
    mov x1, x23
    address x2, info
    dos 0xe0
    cbnz x1, failed
    address x9, info
    ldp x24, x25, [x9]          // block size, blocks
    // One partition from 1 MiB, of at most PART_MAX_MIB.
    mov x0, #0x100000
    udiv x26, x0, x24           // first block
    sub x27, x25, x26           // blocks
    mov x0, #PART_MAX_MIB
    lsl x0, x0, #20
    udiv x0, x0, x24
    cmp x27, x0
    csel x27, x0, x27, hi
    // Before anything is written: can that range become a drive?
    mov x0, #6
    mov x1, x23
    mov x2, x26
    mov x3, x27
    dos 0xe0
    cbnz x1, cannot_attach
    cbnz x21, 7f
    say "\r\nWARNING: ALL DATA ON DISK "
    mov x0, x20
    mov x1, #0
    bl put_dec
    say " WILL BE LOST!\r\n"
    address x0, proceed
    bl ask_yn
    cbz x0, cancelled
7:
    say "\r\nPartitioning disk "
    mov x0, x20
    mov x1, #0
    bl put_dec
    say " ("
    mul x0, x27, x24
    lsr x0, x0, #20
    mov x1, #0
    bl put_dec
    say " MB for ARM DOS)\r\n"
    // Zero the first MiB (old partition tables, the GPT header), the start
    // of the partition (an old boot record) and the end of the disk (the
    // backup GPT), then write the MBR.
    mov x0, #0
    mov x1, x26
    bl zero_blocks
    cbnz x1, write_error
    mov x0, #ZERO_BUF
    udiv x1, x0, x24
    cmp x1, x27
    csel x1, x27, x1, hi
    mov x0, x26
    bl zero_blocks
    cbnz x1, write_error
    mov x0, #ZERO_BUF
    udiv x1, x0, x24
    sub x0, x25, x1
    bl zero_blocks
    cbnz x1, write_error
    // The MBR: one bootable partition of type EFh (EFI).
    address x9, mbr
    mov w10, #0x4d44            // disk signature "DMRA"
    movk w10, #0x4152, lsl #16
    str w10, [x9, #440]
    add x10, x9, #446
    mov w11, #0x80
    strb w11, [x10]
    mov w11, #0xfe              // CHS fields: beyond 1024 cylinders
    strb w11, [x10, #1]
    mov w11, #0xff
    strb w11, [x10, #2]
    strb w11, [x10, #3]
    mov w11, #0xef
    strb w11, [x10, #4]
    mov w11, #0xfe
    strb w11, [x10, #5]
    mov w11, #0xff
    strb w11, [x10, #6]
    strb w11, [x10, #7]
    add x1, x10, #8             // u32 fields at an unaligned offset
    mov x0, x26
    bl store32
    add x1, x10, #12
    mov x0, x27
    bl store32
    mov w11, #0x55
    strb w11, [x9, #510]
    mov w11, #0xaa
    strb w11, [x9, #511]
    mov x0, #3
    mov x1, x23
    mov x2, #0
    mov x3, #1
    address x4, mbr
    dos 0xe0
    cbnz x1, write_error
    mov x0, #5
    mov x1, x23
    dos 0xe0
    // The partition becomes a drive letter.
    mov x0, #4
    mov x1, x23
    mov x2, x26
    mov x3, x27
    dos 0xe0
    cbnz x1, attach_error
    add x28, x0, #'A'           // the new drive's letter
    address x9, format_tail
    strb w28, [x9]
    address x9, xcopy_dest
    strb w28, [x9]
    // FORMAT and XCOPY come from the boot drive.
    mov x0, #5
    dos 0x33
    add w9, w2, #('A' - 1)
    address x10, format_path
    strb w9, [x10]
    address x10, xcopy_path
    strb w9, [x10]
    address x10, xcopy_tail
    strb w9, [x10]
    say "Formatting drive "
    mov x0, x28
    bl putc
    say ":\r\n"
    address x0, format_path
    address x1, format_tail
    bl run
    cbnz x0, format_error
    say "\r\nCopying ARM DOS to drive "
    mov x0, x28
    bl putc
    say ":\r\n"
    address x0, xcopy_path
    address x1, xcopy_tail
    bl run
    cbnz x0, copy_error
    mov x0, #5
    mov x1, x23
    dos 0xe0
    say "\r\nARM DOS is installed on disk "
    mov x0, x20
    mov x1, #0
    bl put_dec
    say " (drive "
    mov x0, x28
    bl putc
    say ": until restart).\r\nRemove the ISO, or pick the disk in the firmware boot menu, and\r\nrestart to boot ARM DOS from it.\r\n"
    mov x0, #0
    leave

// x0 = first block, x1 = blocks: writes zeros there (disk x23, block size
// x24). Returns x1 = 0, or 1 when a write failed.
zero_blocks:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    mov x20, x1
1:
    cbz x20, 2f
    mov x0, #ZERO_BUF
    udiv x3, x0, x24
    cmp x3, x20
    csel x3, x20, x3, hi
    sub x20, x20, x3
    mov x2, x19
    add x19, x19, x3
    mov x0, #3
    mov x1, x23
    address x4, zeros
    dos 0xe0
    cbnz x1, 3f
    b 1b
2:
    mov x1, #0
3:
    ldp x19, x20, [sp], #16
    unframe

// x0 = program path, x1 = command tail. Runs it; x0 = its exit code
// (or 1 when it cannot be started).
run:
    frame
    mov x2, #0
    dos 0x4b
    cbnz x1, 1f
    dos 0x4d
    and x0, x0, #0xffff
    unframe
1:
    mov x0, #1
    unframe

// x0 = value, x1 = destination: four little-endian bytes. Leaf.
store32:
    strb w0, [x1]
    lsr w0, w0, #8
    strb w0, [x1, #1]
    lsr w0, w0, #8
    strb w0, [x1, #2]
    lsr w0, w0, #8
    strb w0, [x1, #3]
    ret

no_disks:
    say "No disk to install on. INSTALL needs a writable disk other than\r\n"
    say "the one ARM DOS started from, and a UEFI boot (the live ISO).\r\n"
    say "Add a blank disk of at least 8 MB to the machine or VM and restart.\r\n"
    mov x0, #2
    leave
need_disk:
    say "INSTALL /Y needs the disk number, for example INSTALL 1 /Y\r\n"
    mov x0, #1
    leave
bad_parm:
    say "Invalid parameter\r\nUsage: INSTALL [disk] [/Y]\r\n"
    mov x0, #1
    leave
bad_disk:
    say "No such disk\r\n"
    mov x0, #1
    leave
cancelled:
    say "Setup cancelled; nothing was written\r\n"
    mov x0, #5
    leave
failed:
    say "Disk error\r\n"
    mov x0, #3
    leave
cannot_attach:
    mov x19, x0
    say "That disk cannot be used now: "
    cmp x19, #5
    b.ne 1f
    say "part of it is already a drive"
    b 9f
1:
    cmp x19, #34
    b.ne 2f
    say "its medium was changed; run INSTALL again"
    b 9f
2:
    cmp x19, #19
    b.ne 3f
    say "it is write-protected"
    b 9f
3:
    cmp x19, #8
    b.ne 4f
    say "not enough memory"
    b 9f
4:
    say "no drive letter is free"
9:
    say ".\r\nNothing was written.\r\n"
    mov x0, #3
    leave
write_error:
    say "Cannot write to the disk. It may be partly overwritten; run INSTALL\r\nagain.\r\n"
    mov x0, #3
    leave
attach_error:
    say "Cannot attach the new partition as a drive. The disk is partitioned\r\nbut not formatted; run INSTALL again.\r\n"
    mov x0, #3
    leave
format_error:
    say "FORMAT failed. The disk is partitioned but ARM DOS is not installed;\r\nrun INSTALL again.\r\n"
    mov x0, #3
    leave
copy_error:
    say "Copying failed; ARM DOS is not completely installed. Run INSTALL\r\nagain.\r\n"
    mov x0, #3
    leave

.section .rodata
proceed: .asciz "Proceed with Setup (Y/N)?"
.section .data
format_path: .asciz "A:\\FORMAT.EXE"
format_tail: .asciz "?: /SELECT /V:ARMDOS"
xcopy_path: .asciz "A:\\XCOPY.EXE"
xcopy_tail: .ascii "A:\\*.* "
xcopy_dest: .asciz "?:\\ /S /E"
.section .bss
.balign 16
info: .skip 32
line: .skip 16
mbr: .skip 4096
zeros: .skip ZERO_BUF
