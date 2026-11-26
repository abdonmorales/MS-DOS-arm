// SPDX-License-Identifier: MIT
// System transfer for SYS and FORMAT /S. On this port the system is one
// UEFI image, \EFI\BOOT\BOOTAA64.EFI (the BIOS, DOS and COMMAND in one, as
// IO.SYS, MSDOS.SYS and COMMAND.COM were), which the firmware loads from
// the removable-media path. It is copied from the boot drive, A:.
.equ SX_BUF, 65536

// x0 = target drive (0-based). Returns x1 = 0 with x0 = bytes copied, or
// x1 = 1 with x0 = 1 (no system on the boot drive), 2 (no room on the
// target) or 3 (another error).
sys_transfer:
    enter
    add w2, w0, #'A'
    address x9, sx_target
    strb w2, [x9]
    address x9, sx_dir1
    strb w2, [x9]
    address x9, sx_dir2
    strb w2, [x9]
    address x0, sx_source
    mov x1, #0
    dos 0x3d
    cbz x1, 1f
    mov x0, #1
    mov x1, #1
    leave
1:
    mov x19, x0
    address x0, sx_dir1         // \EFI and \EFI\BOOT (they may exist)
    dos 0x39
    address x0, sx_dir2
    dos 0x39
    address x0, sx_target
    mov x1, #0                  // replaced if it is there
    dos 0x3c
    cbnz x1, 7f
    mov x20, x0
    mov x21, #0                 // bytes
2:
    mov x0, x19
    address x1, sx_buffer
    mov x2, #SX_BUF
    dos 0x3f
    cbnz x1, 6f
    cbz x0, 4f
    mov x22, x0
    mov x2, x0
    mov x0, x20
    address x1, sx_buffer
    dos 0x40
    cbnz x1, 6f
    cmp x0, x22
    b.ne 5f
    add x21, x21, x22
    b 2b
4:
    mov x0, x19                 // the copy keeps the date and time
    mov x1, #0
    dos 0x57
    mov x0, x20
    mov x1, #1
    dos 0x57
    mov x0, x19
    dos 0x3e
    mov x0, x20
    dos 0x3e
    mov x0, x21
    mov x1, #0
    leave
5:
    mov x0, x19                 // the disk is full: take the partial copy away
    dos 0x3e
    mov x0, x20
    dos 0x3e
    address x0, sx_target
    dos 0x41
    mov x0, #2
    mov x1, #1
    leave
6:
    mov x0, x20
    dos 0x3e
7:
    mov x0, x19
    dos 0x3e
    mov x0, #3
    mov x1, #1
    leave

.section .rodata
sx_source: .asciz "A:\\EFI\\BOOT\\BOOTAA64.EFI"
.section .data
sx_dir1: .asciz "?:\\EFI"
sx_dir2: .asciz "?:\\EFI\\BOOT"
sx_target: .asciz "?:\\EFI\\BOOT\\BOOTAA64.EFI"
.section .bss
.balign 16
sx_buffer: .skip SX_BUF
.section .text
