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
    // Native process ABI: x0 = ARMDOS64 process descriptor.
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
    cmp w0, #'d'               // "disk": DOS error semantics around files
    b.ne program_check_r
    // Disk reset and commit must succeed while read-only handles are open.
    mov w8, #0x0d
    blr x19
    cbnz x1, program_failed
    mov x0, x21
    mov w8, #0x68
    blr x19
    cbnz x1, program_failed
    // Missing parent: 3; missing file: 2; wildcards in a path: 2.
    address x0, missing_parent
    mov x1, #0
    mov w8, #0x3d
    blr x19
    cbz x1, program_failed
    cmp x0, #3
    b.ne program_failed
    address x0, missing_parent
    mov w8, #0x3b
    blr x19
    cbz x1, program_failed
    cmp x0, #3
    b.ne program_failed
    address x0, missing_file
    mov x1, #0
    mov w8, #0x3d
    blr x19
    cbz x1, program_failed
    cmp x0, #2
    b.ne program_failed
    address x0, wildcard_file
    mov w8, #0x41
    blr x19
    cbz x1, program_failed
    cmp x0, #2
    b.ne program_failed
    b program_print
program_check_r:
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
    mov x2, #0                  // 4Bh mode 0: load and execute
    mov w8, #0x4b
    blr x19
    cbnz x1, program_failed
    mov w8, #0x4d
    blr x19
    cbnz x1, program_failed
    cmp x0, #7
    b.ne program_failed
program_print:
    cbz x20, 3f
    ldrb w0, [x20]
    cmp w0, #'f'               // "fault": touch unmapped memory on purpose
    b.ne 3f
    ldrb w0, [x20, #5]          // "fault" variants for memory protection:
    cmp w0, #'w'                // faultw: write to the kernel's code
    b.ne 4f
    str xzr, [x19]
4:
    cmp w0, #'n'                // faultn: read through a null pointer
    b.ne 5f
    mov x0, #0x18
    ldr x0, [x0]
5:
    cmp w0, #'x'                // faultx: execute kernel memory (a block
    b.eq 7f                     // given back with 49h is kernel-only)
    cmp w0, #'p'                // faultp: pass that block to DOS (09h)
    b.ne 6f
7:
    mov w21, w0
    mov x0, #4096
    mov w8, #0x48
    blr x19
    mov x22, x0
    mov w8, #0x49
    blr x19
    mov x0, x22
    cmp w21, #'x'
    b.ne 8f
    blr x0
8:
    mov w8, #0x09
    blr x19
6:
    mov x0, #0xdead0000
    movk x0, #0xbeef, lsl #32
    ldr x0, [x0]
3:
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
signature: .ascii "ARMDOS64"
filename: .asciz "\\ARMTEST.TXT"
own_name: .asciz "\\NATIVE.EXE"
exit_argument: .asciz "exit7"
message: .asciz "Native AArch64 program OK\r\n$"
input_message: .asciz "INPUT> $"
missing_parent: .asciz "\\NOSUCH\\X.TXT"
missing_file: .asciz "\\NOSUCH.TXT"
wildcard_file: .asciz "\\ARM*.TXT"
expected: .ascii "ARM64 FAT read\r\n"
