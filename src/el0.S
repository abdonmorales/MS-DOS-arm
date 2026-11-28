// SPDX-License-Identifier: MIT
// Protected programs (native mode with the kernel's own page tables).
//
// A program runs at EL0 unless its PE header asks for kernel access
// (LoaderFlags bit 0, see ABI.md) and its parent is not itself protected.
// Its image, its 48h blocks and a 256 KiB process block (descriptor, copies
// of the command tail, environment and current directory, default DTA,
// stack) are the only memory it can touch; the kernel, other programs'
// kernel-owned blocks and devices are EL1-only.
//
// The ABI is unchanged: the descriptor's service pointer leads to a user
// trampoline that executes SVC #0, and the entry point returns into one that
// executes SVC #1. The SVC handler checks every pointer argument with
// user_check_args (src/usercheck.S) before calling dos_call, so a program
// cannot make the kernel read or write memory the program could not.

.equ EL0_FRAME, 272                 // x0-x30, SP_EL0, ELR, SPSR
.equ EL0_BLOCK, 0x40000             // process block: 256 KiB
.equ EL0_DESC, 0                    // 64-byte descriptor
.equ EL0_DTA, 128                   // default DTA (280 bytes)
.equ EL0_TAIL, 512                  // command tail copy (256)
.equ EL0_CWD, 1024                  // current directory copy (256)
.equ EL0_SCRATCH, 2048              // copies of kernel data handed out (256)
.equ EL0_ENV, 4096                  // environment copy (ENV_SIZE)

.section .text

// SVC or fault from EL0 (vector 8). The vector entry saved x0/x1 at [sp]
// after reserving 64 bytes; rebuild one full frame.
el0_sync:
    ldp x0, x1, [sp]
    add sp, sp, #64
    sub sp, sp, #EL0_FRAME
    stp x0, x1, [sp]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x9, [sp, #64]
    stp x10, x11, [sp, #80]
    stp x12, x13, [sp, #96]
    stp x14, x15, [sp, #112]
    stp x16, x17, [sp, #128]
    stp x18, x19, [sp, #144]
    stp x20, x21, [sp, #160]
    stp x22, x23, [sp, #176]
    stp x24, x25, [sp, #192]
    stp x26, x27, [sp, #208]
    stp x28, x29, [sp, #224]
    mrs x9, sp_el0
    stp x30, x9, [sp, #240]
    mrs x9, elr_el1
    mrs x10, spsr_el1
    stp x9, x10, [sp, #256]
    mrs x9, esr_el1
    ubfx x10, x9, #26, #6
    cmp x10, #0x15              // SVC from AArch64
    b.ne el0_fault
    and x9, x9, #0xffff
    cbz x9, el0_dos_call
    cmp x9, #1
    b.eq el0_return
el0_fault:
    // A CPU exception: report it and end the program, as at EL1.
    sub sp, sp, #64             // plat_exception stores into [sp, #16..47]
    mov x0, #8
    b plat_exception_fault

// SVC #1: the program's entry point (or a vector handler) returned.
el0_return:
    ldr x0, [sp]
    ldv x2, el0_ctx
    b proc_restore

el0_dos_call:
    ldr w9, [sp, #64]           // function number
    and w9, w9, #0xff
    // Kernel structures a protected program may not see.
    cmp w9, #0x52               // list of lists
    b.eq el0_refuse
    cmp w9, #0x5d
    b.ne 1f
    ldr x10, [sp]
    cmp x10, #6                 // 5D06h swappable data area
    b.eq el0_refuse
1:
    mov x0, sp
    bl user_check_args
    cbnz x0, el0_bad_pointer
    ldp x0, x1, [sp]
    ldp x2, x3, [sp, #16]
    ldp x4, x5, [sp, #32]
    ldp x6, x7, [sp, #48]
    ldr x8, [sp, #64]
    bl dos_call
    stp x0, x1, [sp]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    cbnz x1, el0_resume
    // Results that point into the kernel get a copy in the process block.
    ldr w9, [sp, #64]
    and w9, w9, #0xff
    cmp w9, #0x1f
    b.eq 2f
    cmp w9, #0x32
    b.eq 2f
    cmp w9, #0x1b
    b.eq 3f
    cmp w9, #0x1c
    b.eq 3f
    cmp w9, #0x63
    b.eq 4f
    b el0_resume
2:
    ldr x0, [sp]                // drive parameter block: 64 bytes
    mov x2, #64
    b 5f
3:
    ldr x0, [sp, #40]           // x5: media byte
    ldv x1, el0_page
    add x1, x1, #(EL0_SCRATCH + 64)
    ldrb w2, [x0]
    strb w2, [x1]
    str x1, [sp, #40]
    b el0_resume
4:
    ldr x0, [sp]                // DBCS lead-byte table: 32 bytes
    mov x2, #32
5:
    ldv x1, el0_page
    add x1, x1, #EL0_SCRATCH
    str x1, [sp]
    bl copy_bytes
    b el0_resume
el0_refuse:
    mov x0, #1                  // invalid function
    mov x1, #1
    stp x0, x1, [sp]
el0_resume:
    ldp x9, x10, [sp, #256]
    msr elr_el1, x9
    msr spsr_el1, x10
    ldr x9, [sp, #248]
    msr sp_el0, x9
    ldp x0, x1, [sp]
    ldp x2, x3, [sp, #16]
    ldp x4, x5, [sp, #32]
    ldp x6, x7, [sp, #48]
    ldp x8, x9, [sp, #64]
    ldp x10, x11, [sp, #80]
    ldp x12, x13, [sp, #96]
    ldp x14, x15, [sp, #112]
    ldp x16, x17, [sp, #128]
    ldp x18, x19, [sp, #144]
    ldp x20, x21, [sp, #160]
    ldp x22, x23, [sp, #176]
    ldp x24, x25, [sp, #192]
    ldp x26, x27, [sp, #208]
    ldp x28, x29, [sp, #224]
    ldr x30, [sp, #240]
    add sp, sp, #EL0_FRAME
    eret

el0_bad_pointer:
    address x0, newline
    bl puts
    address x0, el0_pointer_message
    bl puts
    ldr w0, [sp, #64]
    and w0, w0, #0xff
    bl el0_print_byte
    address x0, el0_pointer_tail
    bl puts
    address x0, plat_exc_process
    bl puts
    b proc_abort

// w0 = byte: two hex digits.
el0_print_byte:
    frame
    str x19, [sp, #-16]!
    mov w19, w0
    lsr w0, w19, #4
    bl 1f
    and w0, w19, #15
    bl 1f
    ldr x19, [sp], #16
    unframe
1:
    cmp w0, #10
    add w1, w0, #'0'
    add w2, w0, #('A' - 10)
    csel w0, w1, w2, lo
    b plat_putc

// x0 = handler, x1 = argument: call a protected program's vector handler
// (23h) on its own stack. Returns x0 = the handler's x0.
el0_upcall:
    frame
    sub sp, sp, #112
    mrs x3, sp_el0
    sub x3, x3, #256
    bic x3, x3, #15
    mov x2, sp
    bl proc_call
    add sp, sp, #112
    unframe

// x0 = image base, x1 = bytes: let EL0 (and only it) use a block.
el0_grant:
    ldv x2, mmu_live
    cbz x2, 1f
    mov x2, #1
    b mmu_user_range
1:
    ret

// x0 = image base, x1 = image size: does the image ask for kernel access?
// Returns x0 = 1 for kernel access (EL1), 0 for a protected program.
el0_image_wants_el1:
    ldr w2, [x0, #60]
    add x2, x0, x2
    ldr w2, [x2, #(24 + 104)]   // optional header LoaderFlags
    and x0, x2, #1
    ret

// Set up the process block of a protected child. x0 = block (owned by the
// child), x1 = descriptor built by dos_exec (kernel copy, updated so that
// 26h hands out the user pointers). Returns x0 = user descriptor,
// x1 = initial stack pointer.
el0_build_block:
    enter
    mov x19, x0
    mov x20, x1
    mov x1, #EL0_BLOCK
    bl el0_grant
    stv x19, el0_page, x0
    address x0, user_dos_entry
    str x0, [x20, #24]
    // Command tail (NUL terminated, at most 255 characters).
    ldr x0, [x20, #32]
    add x1, x19, #EL0_TAIL
    mov x2, #255
    bl el0_copy_string
    add x0, x19, #EL0_TAIL
    str x0, [x20, #32]
    address x0, env_block
    add x1, x19, #EL0_ENV
    mov x2, #ENV_SIZE
    bl copy_bytes
    add x0, x19, #EL0_ENV
    str x0, [x20, #40]
    address x0, current_directory
    add x1, x19, #EL0_CWD
    mov x2, #255
    bl el0_copy_string
    add x0, x19, #EL0_CWD
    str x0, [x20, #48]
    mov x0, x20
    add x1, x19, #EL0_DESC
    mov x2, #64
    bl copy_bytes
    add x0, x19, #EL0_DTA       // the default DTA must be the program's
    address x1, current_dta
    str x0, [x1]
    add x0, x19, #EL0_DESC
    mov x1, #EL0_BLOCK
    add x1, x19, x1
    leave

// x0 = source, x1 = destination, x2 = maximum characters: copy and terminate.
el0_copy_string:
    cbz x0, 2f
1:
    cbz x2, 2f
    ldrb w3, [x0], #1
    cbz w3, 2f
    strb w3, [x1], #1
    sub x2, x2, #1
    b 1b
2:
    strb wzr, [x1]
    ret

// The only kernel code EL0 can execute (mapped user read-only, executable).
.section .user_text, "ax"
user_dos_entry:
    svc #0
    ret
user_return:
    svc #1
    b user_return

.section .rodata
el0_pointer_message: .asciz "Protection fault: invalid pointer passed to DOS function "
el0_pointer_tail: .asciz "h\r\n"

.section .bss
.balign 8
el0_ctx: .skip 8                    // proc_call context of the newest EL0 call
cur_el0: .skip 8                    // 1 while the running program is at EL0
el0_page: .skip 8                   // its process block
