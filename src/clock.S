// SPDX-License-Identifier: MIT
// DOS date and time. The clock is an anchor (seconds since 1980-01-01 00:00,
// hundredths) plus the architectural virtual counter at the moment it was
// set, so sub-second ticks come from the generic timer.
//
// The anchor is loaded at boot from the real-time clock (rtc_read_unix) and
// SET DATE / SET TIME (2Bh/2Dh, the DATE and TIME commands, CLOCK$) write it
// back (rtc_write_unix), so the setting survives a reboot:
//   native mode, QEMU virt: the PL031 directly (RTCDR read, RTCLR write);
//   firmware mode: UEFI runtime GetTime / SetTime;
//   native mode on any other board (no PL031 at 09010000h; the Raspberry
//   Pi 3 has no battery-backed clock at all):
//   the boot-time firmware value only, and nothing is persisted.
// The RTC counts seconds since 1970-01-01 and DOS has no time zones, so it
// is taken as local time. Values before 1980 read as 1980-01-01 00:00; the
// 32-bit PL031 cannot hold dates after 2106-02-07 06:28:15, so in native mode
// those are kept for this session only (firmware mode: what SetTime accepts).
.macro day_seconds reg
    movz \reg, #0x5180
    movk \reg, #1, lsl #16
.endm
.macro unix_1980 reg                    // 315532800: 1980-01-01 in Unix time
    movz \reg, #0xa600
    movk \reg, #0x12ce, lsl #16
.endm
.macro dos_clock_max reg                // 2107-12-31 23:59:59, DOS seconds
    movz \reg, #0x9e7f
    movk \reg, #0xf0c2, lsl #16
.endm
.equ PL031_DR, 0x00
.equ PL031_LR, 0x08
.section .text
// Load the clock from the RTC (or 1980-01-01 when there is none). Called
// once in firmware mode at boot and again after the platform switches to
// native mode and has probed its RTC.
clock_init:
    frame
    bl rtc_read_unix
    cbnz x1, clock_default
    bl clock_unix_to_dos
    b clock_anchor_init
clock_default:
    mov x0, #0
clock_anchor_init:
    mov x1, #0
    bl clock_anchor
    unframe

// Returns x0 = Unix seconds, x1 = 0, or x1 = 1 when no clock can be read.
rtc_read_unix:
    adrp x0, plat_rtc
    ldr x0, [x0, :lo12:plat_rtc]
    cbz x0, 1f
    ldr w0, [x0, #PL031_DR]
    mov x1, #0
    ret
1:
    adrp x0, platform_native
    ldr x0, [x0, :lo12:platform_native]
    cbnz x0, 2f
    frame
    address x0, clock_efi_time
    mov x1, #0
    address x2, system_table
    ldr x2, [x2]
    ldr x2, [x2, #88]           // RuntimeServices
    ldr x2, [x2, #24]           // GetTime
    blr x2
    cbnz x0, 3f
    address x0, clock_efi_time
    bl efi_time_to_unix
    unframe
3:
    mov x1, #1
    unframe
2:
    mov x1, #1
    ret

// x0 = Unix seconds. Returns x0 = 0 when the clock was stored, 1 when there
// is no writable RTC or the value does not fit it.
rtc_write_unix:
    unix_1980 x1
    cmp x0, x1
    b.lo 9f
    adrp x1, plat_rtc
    ldr x1, [x1, :lo12:plat_rtc]
    cbz x1, 1f
    lsr x2, x0, #32             // PL031 is a 32-bit counter
    cbnz x2, 9f
    str w0, [x1, #PL031_LR]
    mov x0, #0
    ret
1:
    adrp x1, platform_native
    ldr x1, [x1, :lo12:platform_native]
    cbnz x1, 9f
    frame
    str x0, [sp, #-16]!
    // Keep the firmware's TimeZone and Daylight: read them with GetTime
    // first, so SetTime neither shifts the stored time nor drops the zone.
    address x0, clock_efi_time
    mov x1, #0
    address x2, system_table
    ldr x2, [x2]
    ldr x2, [x2, #88]           // RuntimeServices
    ldr x2, [x2, #24]           // GetTime
    blr x2
    mov x3, x0
    ldr x0, [sp], #16
    str x3, [sp, #-16]!
    address x1, clock_set_efi_time
    bl unix_to_efi_time
    ldr x3, [sp], #16
    cbnz x3, 4f                 // GetTime failed: leave unspecified zone
    address x0, clock_efi_time
    address x1, clock_set_efi_time
    ldrh w2, [x0, #12]          // TimeZone
    strh w2, [x1, #12]
    ldrb w2, [x0, #14]          // Daylight
    strb w2, [x1, #14]
4:
    address x0, clock_set_efi_time
    address x2, system_table
    ldr x2, [x2]
    ldr x2, [x2, #88]           // RuntimeServices
    ldr x2, [x2, #32]           // SetTime
    blr x2
    cmp x0, #0
    cset x0, ne
    unframe
9:
    mov x0, #1
    ret

// x0 = Unix seconds. Returns x0 = DOS seconds since 1980-01-01 00:00,
// clamped to 1980-01-01 00:00:00 .. 2107-12-31 23:59:59; x1 = 1 if clamped.
clock_unix_to_dos:
    unix_1980 x1
    subs x0, x0, x1
    b.lo 1f
    dos_clock_max x1
    cmp x0, x1
    b.hi 2f
    mov x1, #0
    ret
1:
    mov x0, #0
    mov x1, #1
    ret
2:
    mov x0, x1
    mov x1, #1
    ret

// x0 = DOS seconds since 1980-01-01. Returns x0 = Unix seconds.
clock_dos_to_unix:
    unix_1980 x1
    add x0, x0, x1
    ret

// x0 = EFI_TIME. Returns x0 = Unix seconds, x1 = 0; x1 = 1 when the fields
// are not a valid DOS date and time (1980-2107). Time zone fields are ignored.
efi_time_to_unix:
    frame
    str x19, [sp, #-16]!
    mov x19, x0
    ldrb w2, [x19, #4]
    cmp w2, #23
    b.hi 1f
    ldrb w2, [x19, #5]
    cmp w2, #59
    b.hi 1f
    ldrb w2, [x19, #6]
    cmp w2, #59
    b.hi 1f
    ldrh w0, [x19]
    ldrb w1, [x19, #2]
    ldrb w2, [x19, #3]
    bl validate_date
    cbnz x0, 1f
    ldrh w0, [x19]
    ldrb w1, [x19, #2]
    ldrb w2, [x19, #3]
    bl date_to_days
    day_seconds x1
    mul x0, x0, x1
    ldrb w1, [x19, #4]
    mov x2, #3600
    madd x0, x1, x2, x0
    ldrb w1, [x19, #5]
    mov x2, #60
    madd x0, x1, x2, x0
    ldrb w1, [x19, #6]
    add x0, x0, x1
    bl clock_dos_to_unix
    mov x1, #0
    b 2f
1:
    mov x0, #0
    mov x1, #1
2:
    ldr x19, [sp], #16
    unframe

// x0 = Unix seconds (1980 or later), x1 = 16-byte EFI_TIME to fill. The
// time zone is EFI_UNSPECIFIED_TIMEZONE (local time), no daylight flags;
// rtc_write_unix then copies the firmware's own TimeZone/Daylight over them.
unix_to_efi_time:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x1
    unix_1980 x2
    sub x0, x0, x2
    day_seconds x2
    udiv x3, x0, x2
    msub x20, x3, x2, x0        // seconds within the day
    stp xzr, xzr, [x19]
    mov x0, x3
    bl days_to_date
    strh w0, [x19]
    strb w1, [x19, #2]
    strb w2, [x19, #3]
    mov x2, #3600
    udiv x0, x20, x2
    strb w0, [x19, #4]
    msub x20, x0, x2, x20
    mov x2, #60
    udiv x0, x20, x2
    strb w0, [x19, #5]
    msub x20, x0, x2, x20
    strb w20, [x19, #6]
    mov w0, #0x07ff             // TimeZone: EFI_UNSPECIFIED_TIMEZONE
    strh w0, [x19, #12]
    ldp x19, x20, [sp], #16
    unframe

// Write the running DOS clock to the RTC. Returns x0 as rtc_write_unix.
// Does nothing while clock_no_persist is set (the boot self-test sets and
// then restores the clock and must not leave its test dates in the RTC).
clock_persist:
    adrp x0, clock_no_persist
    ldr x0, [x0, :lo12:clock_no_persist]
    cbz x0, 1f
    mov x0, #1
    ret
1:
    frame
    bl clock_now
    day_seconds x3
    madd x0, x0, x3, x1
    bl clock_dos_to_unix
    bl rtc_write_unix
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
    bl clock_persist
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
    bl clock_persist
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
clock_set_efi_time: .skip 16
clock_no_persist: .skip 8
plat_rtc: .skip 8                       // PL031 base, 0 when none (native only)
