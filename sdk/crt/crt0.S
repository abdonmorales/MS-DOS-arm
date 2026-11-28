// SPDX-License-Identifier: MIT
// C runtime entry for ARM DOS native programs (see sdk/README.md).
//
// The kernel calls the PE entry point with x0 = ARMDOS64 descriptor on its
// own stack. We validate the descriptor, zero .bss (the loader already
// zeroes the image; doing it again keeps the runtime independent of that),
// save the service pointer, move to a private stack allocated with 48h and
// hand over to __armdos_start (start.c), which never returns: it ends the
// program with 4Ch. The original sp/lr stay in callee-saved registers only
// for the fallback path where 4Ch itself fails.
.section .text.start, "ax"
.global _start
.type _start, %function
_start:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    // Validate before touching any pointer in the descriptor.
    cbz x0, bad_descriptor
    tst x0, #7
    b.ne bad_descriptor
    ldr x1, [x0]
    adrp x2, signature
    ldr x2, [x2, :lo12:signature]
    cmp x1, x2
    b.ne bad_descriptor
    ldr x1, [x0, #8]            // ABI version
    cmp x1, #1
    b.ne bad_descriptor
    ldr x1, [x0, #16]           // descriptor size
    cmp x1, #64
    b.lo bad_descriptor
    ldr x1, [x0, #24]           // service entry
    cbz x1, bad_descriptor
    mov x19, x0
    // Zero .bss: 16-byte aligned bounds from sdk/link.ld.
    adrp x2, __bss_start
    add x2, x2, :lo12:__bss_start
    adrp x3, __bss_end
    add x3, x3, :lo12:__bss_end
1:
    cmp x2, x3
    b.hs 2f
    stp xzr, xzr, [x2], #16
    b 1b
2:
    adrp x2, __armdos_service
    ldr x1, [x19, #24]
    str x1, [x2, :lo12:__armdos_service]
    adrp x2, __armdos_descriptor
    str x19, [x2, :lo12:__armdos_descriptor]
    // Private stack: programs otherwise share the kernel's (firmware's)
    // stack, whose size we do not control. __armdos_stack_size is a weak
    // constant a program may override; 0 keeps the inherited stack.
    adrp x0, __armdos_stack_size
    ldr x0, [x0, :lo12:__armdos_stack_size]
    mov x20, sp
    cbz x0, 3f
    mov x21, x0
    mov w8, #0x48
    blr x1
    cbnz x1, 3f                 // no memory: stay on the inherited stack
    add x0, x0, x21
    and x0, x0, #~15
    mov sp, x0
3:
    mov x29, #0                 // end of the frame chain for debuggers
    mov x0, x19
    bl __armdos_start           // runs main() and calls 4Ch
    // Only reached if 4Ch failed (it cannot for a loaded program).
    mov sp, x20
    mov x0, #1
    b 4f
bad_descriptor:
    mov x0, #1                  // nonzero return: the parent sees type 2
4:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.size _start, . - _start

.section .rodata.crt0, "a"
.balign 8
signature: .ascii "ARMDOS64"

// Default private stack size: 256 KiB (four 64 KiB allocation granules).
.section .rodata.crt0.stack, "a"
.balign 8
.weak __armdos_stack_size
__armdos_stack_size: .quad 0x40000

.section .bss
.balign 8
.global __armdos_service
__armdos_service: .skip 8
.global __armdos_descriptor
__armdos_descriptor: .skip 8
