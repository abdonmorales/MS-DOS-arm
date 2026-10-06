// SPDX-License-Identifier: MIT
// A separately linked native DOS program, never part of the runtime ELF.
// Exercises the process API, inherited descriptors and automatic cleanup.
.macro address reg, name
    adrp \reg, \name
    add \reg, \reg, :lo12:\name
.endm
.section .text
.global efi_main
efi_main:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    sub sp, sp, #16
    ldr x3, [x1, #96]
    address x1, loaded_image_guid
    mov x2, sp
    ldr x3, [x3, #152]
    blr x3
    cbnz x0, program_failed
    ldr x0, [sp]
    ldr w1, [x0, #48]
    cmp w1, #64
    b.lo program_failed
    ldr x0, [x0, #56]
    cbz x0, program_failed
    ldr x1, [x0]
    address x2, signature
    ldr x2, [x2]
    cmp x1, x2
    b.ne program_failed
    ldr x1, [x0, #8]
    cmp x1, #1
    b.ne program_failed
    ldr x19, [x0, #24]
    ldr x20, [x0, #32]
    mov w8, #0x30
    blr x19
    cbnz x1, program_failed
    cmp x0, #4
    b.ne program_failed
    mov x0, #5                 // close an inherited descriptor if present
    mov w8, #0x3e
    blr x19
    mov x0, #32
    mov w8, #0x48
    blr x19
    cbnz x1, program_failed
    // Deliberately leave this allocation and file open at termination.
    // The parent must reclaim both without closing its inherited reference.
    mov x22, x0
    address x0, filename
    mov x1, #0
    mov w8, #0x3d
    blr x19
    cbnz x1, program_failed
    mov x21, x0
    mov x1, x22
    mov x2, #16
    mov w8, #0x3f
    blr x19
    cbnz x1, program_failed
    cmp x0, #16
    b.ne program_failed
    address x1, expected
    mov x2, #16
1:
    ldrb w3, [x1], #1
    ldrb w4, [x22], #1
    cmp w3, w4
    b.ne program_failed
    subs x2, x2, #1
    b.ne 1b
    cbz x20, program_print
    ldrb w0, [x20]
    cmp w0, #'i'
    b.ne program_check_readin
    address x0, input_message
    mov w8, #0x09
    blr x19
    mov w0, #8
    strb w0, [x22]
    strb wzr, [x22, #1]
    mov x0, x22
    mov w8, #0x0a
    blr x19
    cbnz x1, program_failed
    ldrb w0, [x22, #1]
    cmp w0, #3
    b.ne program_failed
    ldr w0, [x22, #2]
    movz w1, #0x6361
    movk w1, #0x0d64, lsl #16 // "acd" + carriage return
    cmp w0, w1
    b.ne program_failed
    b program_print
program_check_readin:
    cmp w0, #'r'
    b.ne 2f
    mov x0, #0
    mov x1, x22
    mov x2, #16
    mov w8, #0x3f
    blr x19
    cbnz x1, program_failed
    cmp x0, #16
    b.ne program_failed
    address x1, expected
    mov x2, #16
1:
    ldrb w3, [x1], #1
    ldrb w4, [x22], #1
    cmp w3, w4
    b.ne program_failed
    subs x2, x2, #1
    b.ne 1b
    b program_print
2:
    cmp w0, #'n'
    b.ne program_print
    address x0, own_name
    address x1, exit_argument
    mov w8, #0x4b
    blr x19
    cbnz x1, program_failed
    mov w8, #0x4d
    blr x19
    cbnz x1, program_failed
    cmp x0, #7
    b.ne program_failed
program_print:
    address x0, message
    mov w8, #0x09
    blr x19
    cbz x20, program_success
    ldrb w0, [x20]
    cmp w0, #'e'
    b.ne program_success
    mov x0, #7
    mov w8, #0x4c
    blr x19
    b program_failed           // 4Ch must not return into child code
program_success:
    mov x0, #0
    b program_return
program_failed:
    mov x0, #0x8000000000000001
program_return:
    add sp, sp, #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.section .rodata
.balign 8
loaded_image_guid:
    .long 0x5b1b31a1
    .short 0x9562, 0x11d2
    .byte 0x8e,0x3f,0x00,0xa0,0xc9,0x69,0x72,0x3b
signature: .ascii "ARMDOS64"
filename: .asciz "\\ARMTEST.TXT"
own_name: .asciz "\\NATIVE.EXE"
exit_argument: .asciz "exit7"
message: .asciz "Native AArch64 program OK\r\n$"
input_message: .asciz "INPUT> $"
expected: .ascii "ARM64 FAT read\r\n"
