// SPDX-License-Identifier: MIT
// Initialize local DOS time from EFI, then advance it using the architectural
// virtual counter. SetDate/SetTime affect this runtime, not firmware NVRAM.
.macro day_seconds reg
    movz \reg, #0x5180
    movk \reg, #1, lsl #16
.endm
.section .text
clock_init:
    frame
    address x0, clock_efi_time
    mov x1, #0
    address x2, system_table
    ldr x2, [x2]
    ldr x2, [x2, #88]
    ldr x2, [x2, #24]
    blr x2
    cbnz x0, clock_default
    address x3, clock_efi_time
    ldrh w0, [x3]
    ldrb w1, [x3, #2]
    ldrb w2, [x3, #3]
    bl validate_date
    cbnz x0, clock_default
    address x3, clock_efi_time
    ldrh w0, [x3]
    ldrb w1, [x3, #2]
    ldrb w2, [x3, #3]
    bl date_to_days
    day_seconds x1
    mul x0, x0, x1
    address x3, clock_efi_time
    ldrb w1, [x3, #4]
    mov x2, #3600
    madd x0, x1, x2, x0
    ldrb w1, [x3, #5]
    mov x2, #60
    madd x0, x1, x2, x0
    ldrb w1, [x3, #6]
    add x0, x0, x1
    b clock_anchor_init
clock_default:
    mov x0, #0
clock_anchor_init:
    mov x1, #0
    bl clock_anchor
    unframe
clock_anchor:
    address x2, clock_epoch
    str x0, [x2]
    str x1, [x2, #8]
    isb
    mrs x3, cntvct_el0
    str x3, [x2, #16]
    ret
// x0=days since 1980-01-01, x1=seconds within day, x2=hundredths.
clock_now:
    address x3, clock_epoch
    ldp x4, x5, [x3]
    ldr x6, [x3, #16]
    isb
    mrs x7, cntvct_el0
    mrs x8, cntfrq_el0
    sub x7, x7, x6
    udiv x6, x7, x8
    msub x7, x6, x8, x7
    mov x2, #100
    mul x7, x7, x2
    udiv x7, x7, x8
    add x7, x7, x5
    udiv x5, x7, x2
    msub x2, x5, x2, x7
    add x4, x4, x6
    add x4, x4, x5
    day_seconds x3
    udiv x0, x4, x3
    msub x1, x0, x3, x4
    ret
dos_get_date:
    frame
    bl clock_now
    add x4, x0, #2             // 1980-01-01 was Tuesday (Sunday=0)
    mov x5, #7
    udiv x6, x4, x5
    msub x4, x6, x5, x4
    bl days_to_date
    mov x3, x2
    mov x2, x1
    mov x1, #0
    unframe
dos_set_date:
    frame
    stp x19, x20, [sp, #-16]!
    str x21, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x21, x2
    bl validate_date
    cbnz x0, clock_invalid
    mov x0, x19
    mov x1, x20
    mov x2, x21
    bl date_to_days
    mov x19, x0
    bl clock_now
    day_seconds x3
    madd x0, x19, x3, x1
    mov x1, x2
    bl clock_anchor
    mov x0, #0
    mov x1, #0
    b set_date_return
clock_invalid:
    mov x0, #1
    mov x1, #1
set_date_return:
    ldr x21, [sp], #16
    ldp x19, x20, [sp], #16
    unframe
dos_get_time:
    frame
    bl clock_now
    mov x4, x2
    mov x5, #3600
    udiv x0, x1, x5
    msub x1, x0, x5, x1
    mov x5, #60
    udiv x2, x1, x5
    msub x3, x2, x5, x1
    mov x1, #0
    unframe
dos_set_time:
    frame
    stp x19, x20, [sp, #-16]!
    cmp x0, #23
    b.hi set_time_invalid
    cmp x1, #59
    b.hi set_time_invalid
    cmp x2, #59
    b.hi set_time_invalid
    cmp x3, #99
    b.hi set_time_invalid
    mov x4, #3600
    mul x19, x0, x4
    mov x4, #60
    madd x19, x1, x4, x19
    add x19, x19, x2
    mov x20, x3
    bl clock_now
    day_seconds x3
    madd x0, x0, x3, x19
    mov x1, x20
    bl clock_anchor
    mov x0, #0
    mov x1, #0
    b set_time_return
set_time_invalid:
    mov x0, #1
    mov x1, #1
set_time_return:
    ldp x19, x20, [sp], #16
    unframe

validate_date:
    cmp x0, #1980
    b.lo 3f
    cmp x0, #2107
    b.hi 3f
    cmp x1, #1
    b.lo 3f
    cmp x1, #12
    b.hi 3f
    cbz x2, 3f
    address x3, month_lengths
    sub x4, x1, #1
    ldrb w3, [x3, x4]
    cmp x1, #2
    b.ne 1f
    tst x0, #3
    b.ne 1f
    cmp x0, #2100
    b.eq 1f
    add x3, x3, #1
1:
    cmp x2, x3
    b.hi 3f
    mov x0, #0
    ret
3:
    mov x0, #1
    ret
date_to_days:
    mov x9, x0
    mov x10, x1
    sub x11, x2, #1
    mov x12, #1980
1:
    cmp x12, x9
    b.hs 3f
    add x11, x11, #365
    tst x12, #3
    b.ne 2f
    cmp x12, #2100
    b.eq 2f
    add x11, x11, #1
2:
    add x12, x12, #1
    b 1b
3:
    mov x12, #1
    address x13, month_lengths
4:
    cmp x12, x10
    b.hs 6f
    sub x14, x12, #1
    ldrb w14, [x13, x14]
    add x11, x11, x14
    cmp x12, #2
    b.ne 5f
    tst x9, #3
    b.ne 5f
    cmp x9, #2100
    b.eq 5f
    add x11, x11, #1
5:
    add x12, x12, #1
    b 4b
6:
    mov x0, x11
    ret
days_to_date:
    mov x9, #1980
    mov x10, x0
1:
    mov x11, #365
    tst x9, #3
    b.ne 2f
    cmp x9, #2100
    b.eq 2f
    add x11, x11, #1
2:
    cmp x10, x11
    b.lo 3f
    sub x10, x10, x11
    add x9, x9, #1
    b 1b
3:
    mov x12, #1
    address x13, month_lengths
4:
    sub x14, x12, #1
    ldrb w14, [x13, x14]
    cmp x12, #2
    b.ne 5f
    tst x9, #3
    b.ne 5f
    cmp x9, #2100
    b.eq 5f
    add x14, x14, #1
5:
    cmp x10, x14
    b.lo 6f
    sub x10, x10, x14
    add x12, x12, #1
    b 4b
6:
    mov x0, x9
    mov x1, x12
    add x2, x10, #1
    ret

cmd_date:
    frame
    stp x19, x20, [sp, #-16]!
    str x21, [sp, #-16]!
    bl dos_get_date
    mov x19, x0
    mov x20, x2
    mov x21, x3
    mov x1, #4
    bl print_padded_number
    mov x0, #'-'
    bl stdout_putc
    mov x0, x20
    mov x1, #2
    bl print_padded_number
    mov x0, #'-'
    bl stdout_putc
    mov x0, x21
    mov x1, #2
    bl print_padded_number
    address x0, newline
    bl puts
    ldr x21, [sp], #16
    ldp x19, x20, [sp], #16
    unframe
cmd_time:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    bl dos_get_time
    mov x19, x0
    mov x20, x2
    mov x21, x3
    mov x22, x4
    mov x1, #2
    bl print_padded_number
    mov x0, #':'
    bl stdout_putc
    mov x0, x20
    mov x1, #2
    bl print_padded_number
    mov x0, #':'
    bl stdout_putc
    mov x0, x21
    mov x1, #2
    bl print_padded_number
    mov x0, #'.'
    bl stdout_putc
    mov x0, x22
    mov x1, #2
    bl print_padded_number
    address x0, newline
    bl puts
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe
print_padded_number:
    frame
    stp x19, x20, [sp, #-16]!
    sub sp, sp, #32
    mov x20, x1
    mov x1, sp
    bl unsigned_to_string
    mov x19, x0
    mov x2, #0
1:
    ldrb w3, [x19, x2]
    cbz w3, 2f
    add x2, x2, #1
    b 1b
2:
    subs x20, x20, x2
    b.ls 4f
3:
    mov x0, #'0'
    bl stdout_putc
    subs x20, x20, #1
    b.ne 3b
4:
    mov x0, x19
    bl puts
    add sp, sp, #32
    ldp x19, x20, [sp], #16
    unframe
.section .rodata
month_lengths: .byte 31,28,31,30,31,30,31,31,30,31,30,31
.section .bss
.balign 16
clock_epoch: .skip 24
clock_efi_time: .skip 16
