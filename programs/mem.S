// SPDX-License-Identifier: MIT

// ARM DOS kernel access: this program reads or edits kernel tables (list of
// lists, drive table, block drivers), so it runs at EL1 (ABI.md).
.globl __armdos_kernel_access
.set __armdos_kernel_access, 1
// MEM [/PROGRAM | /DEBUG] (MS-DOS 4.0 src/CMD/MEM): memory totals, and with
// /PROGRAM or /DEBUG the allocated blocks and their owners, from the list
// of lists (52h).
.include "lib.inc"

main:
    enter
    mov x19, x0
    mov x20, #0                 // 1 /PROGRAM, 2 /DEBUG
1:
    mov x0, x19
    bl next_arg
    mov x19, x1
    ldrb w2, [x0]
    cbz w2, 3f
    cmp w2, #'/'
    b.ne bad
    ldrb w0, [x0, #1]
    bl toupper
    cmp w0, #'P'
    b.ne 2f
    orr x20, x20, #1
    b 1b
2:
    cmp w0, #'D'
    b.ne bad
    orr x20, x20, #3
    b 1b
3:
    dos 0x52
    mov x21, x0                 // list of lists
    cbz x20, 4f
    bl list_blocks
4:
    bl crlf
    ldr x22, [x21, #88]         // arena bytes
    ldr x23, [x21, #96]         // free bytes
    cbnz x22, 5f
    bl used_bytes
    mov x22, x0
    mov x0, x22
    mov x1, #10
    bl put_dec
    say " bytes allocated (memory is managed by UEFI firmware)\r\n"
    b 6f
5:
    mov x0, x22
    mov x1, #10
    bl put_dec
    say " bytes total memory\r\n"
    mov x0, x23
    mov x1, #10
    bl put_dec
    say " bytes available\r\n"
6:
    bl largest_block
    mov x1, #10
    bl put_dec
    say " largest executable program size\r\n"
    mov x0, #0
    leave
bad:
    say "Invalid parameter\r\n"
    mov x0, #1
    leave

// Returns x0 = bytes reserved by every allocated block.
used_bytes:
    ldr x2, [x21, #72]
    ldr x3, [x21, #80]
    mov x0, #0
1:
    cbz x3, 3f
    ldr x4, [x2]
    cbz x4, 2f
    ldr x4, [x2, #16]
    add x0, x0, x4
2:
    add x2, x2, #32
    sub x3, x3, #1
    b 1b
3:
    ret

// Largest block 48h will grant (binary search in 64 KiB steps, freed again).
largest_block:
    enter
    mov x19, #0                 // known good
    mov x20, #0x1000000         // upper bound (16 MiB request limit)
    add x20, x20, #0x10000
1:
    sub x2, x20, x19
    cmp x2, #0x10000
    b.ls 3f
    add x21, x19, x20
    lsr x21, x21, #1
    and x21, x21, #0xffffffffffff0000
    cmp x21, x19
    b.hi 11f
    add x21, x19, #0x10000
11:
    mov x0, x21
    dos 0x48
    cbnz x1, 2f
    dos 0x49
    mov x19, x21
    b 1b
2:
    mov x20, x21
    b 1b
3:
    mov x0, x19
    leave

// /PROGRAM: each allocated block with its owner.
list_blocks:
    enter
    bl crlf
    say "Address           Size          Owner\r\n"
    say "----------------  ------------  ----------------\r\n"
    ldr x19, [x21, #72]
    ldr x20, [x21, #80]
    ldr x22, [x21, #104]        // kernel owner
    address x0, lib_descriptor
    ldr x0, [x0]
    ldr x23, [x0, #56]          // this program
1:
    cbz x20, 9f
    ldr x24, [x19]
    cbz x24, 8f
    mov x0, x24
    mov x1, #16
    bl put_hex
    mov x0, #2
    bl spaces
    ldr x0, [x19, #16]
    mov x1, #12
    bl put_dec
    mov x0, #2
    bl spaces
    ldr x25, [x19, #24]
    cmp x25, x22
    b.ne 2f
    say "SYSTEM"
    b 7f
2:
    cmp x25, x23
    b.ne 3f
    say "MEM"
    b 7f
3:
    say "program at "
    mov x0, x25
    mov x1, #16
    bl put_hex
7:
    bl crlf
8:
    add x19, x19, #32
    sub x20, x20, #1
    b 1b
9:
    leave
