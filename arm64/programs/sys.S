// SPDX-License-Identifier: MIT
// SYS d: (v4.0/src/CMD/SYS): transfers the system to a formatted drive,
// making it bootable. Here that is the UEFI image \EFI\BOOT\BOOTAA64.EFI
// (see sysxfer.inc), taken from the boot drive.
.include "lib.inc"
.include "cds.inc"
.include "sysxfer.inc"

main:
    enter
    mov x19, x0
    bl cds_init
    mov x0, x19
    bl next_arg
    mov x19, x1
    ldrb w2, [x0]
    cbz w2, missing
    mov x1, #0
    bl cds_parse_drive
    cmn x0, #1
    b.eq bad_drive
    mov x20, x0
    mov x0, x19
    bl next_arg
    ldrb w2, [x0]
    cbnz w2, bad_parm
    // A formatted drive other than the boot drive.
    add x0, x20, #1
    dos 0x36
    cbnz x1, bad_drive
    address x1, truename_in
    mov w2, #'A'
    add w2, w2, w20
    strb w2, [x1]
    address x0, truename_in
    address x1, truename
    dos 0x60
    cbnz x1, bad_drive
    address x9, truename
    ldrb w2, [x9]
    sub x20, x2, #'A'           // after SUBST, ASSIGN and JOIN
    cbz x20, boot_drive
    mov x0, x20
    bl sys_transfer
    cbnz x1, 1f
    say "System transferred\r\n"
    mov x0, #0
    leave
1:
    cmp x0, #1
    b.ne 2f
    say "No system on default drive\r\n"
    mov x0, #1
    leave
2:
    say "No room for system on destination disk\r\n"
    mov x0, #1
    leave
missing:
    say "Required parameter missing\r\n"
    mov x0, #1
    leave
bad_parm:
    say "Invalid parameter\r\n"
    mov x0, #1
    leave
bad_drive:
    say "Invalid drive specification\r\n"
    mov x0, #1
    leave
boot_drive:
    say "Cannot transfer the system onto the drive it runs from\r\n"
    mov x0, #1
    leave

.section .data
truename_in: .asciz "?:\\"
.section .bss
truename: .skip 128
