// SPDX-License-Identifier: MIT
// Pointer checks for protected (EL0) programs. Before the kernel runs a DOS
// call for a program at EL0, every pointer argument the call dereferences
// must name memory the program itself could read (or write). The test is the
// MMU's own: AT S1E0R / S1E0W per page, so kernel memory, kernel-owned arena
// blocks and devices all fail.

.equ UC_NONE, 0
.equ UC_STR, 1                      // ASCIIZ (at most UC_STRING_MAX bytes)
.equ UC_WRITE, 2                    // fixed size, written
.equ UC_READ, 3                     // fixed size, read
.equ UC_BUF_WRITE, 4                // length in register a, written
.equ UC_BUF_READ, 5                 // length in register a, read
.equ UC_FCB, 6                      // 37 bytes, or 44 for an extended FCB
.equ UC_SPECIAL, 7                  // case a, below
.equ UC_WRITE_NZ, 8                 // UC_WRITE unless the pointer is 0
.equ UC_READ_NZ, 9                  // UC_READ unless the pointer is 0
.equ UC_STR_NZ, 10
.equ UC_STRING_MAX, 4096
.equ UC_SECTOR_MAX, 4096            // largest sector: bounds raw transfers

.section .text

// x0 = address, x1 = length, x2 = 0 read / 1 write. Returns x0 = 0 when
// every page of the range is accessible to EL0 that way.
user_range_ok:
    cbz x1, 3f
    mov x3, #0x1000000
    cmp x1, x3
    b.hi 4f
    adds x3, x0, x1             // end
    b.cs 4f
    bic x4, x0, #0xfff
1:
    cbnz x2, 2f
    at s1e0r, x4
    b 21f
2:
    at s1e0w, x4
21:
    isb
    mrs x5, par_el1
    tbnz x5, #0, 4f
    add x4, x4, #4096
    cmp x4, x3
    b.lo 1b
3:
    mov x0, #0
    ret
4:
    mov x0, #1
    ret

// x0 = address, x1 = maximum bytes, x2 = 0 NUL / 1 NUL or '$' terminates.
// Each page is checked before any byte of it is read. Returns x0 = 0 and
// x1 = length (without the terminator) when a terminator is found in time.
user_string_ok:
    mov x6, x0
    mov x7, #1                  // no page checked yet (never page aligned)
    mov x8, #0
1:
    cmp x8, x1
    b.hs 4f
    adds x3, x6, x8
    b.cs 4f
    bic x4, x3, #0xfff
    cmp x4, x7
    b.eq 2f
    at s1e0r, x4
    isb
    mrs x5, par_el1
    tbnz x5, #0, 4f
    mov x7, x4
2:
    ldrb w5, [x3]
    cbz w5, 3f
    cbz x2, 21f
    cmp w5, #'$'
    b.eq 3f
21:
    add x8, x8, #1
    b 1b
3:
    mov x0, #0
    mov x1, x8
    ret
4:
    mov x0, #1
    ret

// x0 = the program's saved registers (x0 at offset 0, 8 bytes each).
// Returns x0 = 0 when the call's pointer arguments are the program's own.
user_check_args:
    enter
    mov x19, x0
    ldr w20, [x19, #64]         // w8, as dos_call reads it
    cmp w20, #DOS_MAX_FUNCTION
    b.ls 1f
    cmp w20, #ARMDOS_DISK_FUNCTION
    b.ne uc_ok                  // invalid function: no memory is touched
    mov w20, #(DOS_MAX_FUNCTION + 1)
1:
    address x21, uc_table
    add x21, x21, x20, lsl #3
    mov x22, #2                 // two argument slots per function
2:
    ldrb w23, [x21]             // kind
    ldrb w24, [x21, #1]         // register
    ldrb w25, [x21, #2]
    ldrb w26, [x21, #3]
    orr x25, x25, x26, lsl #8   // size, register or case
    ldr x0, [x19, x24, lsl #3]  // the pointer
    bl uc_check_one
    cbnz x0, uc_bad
    add x21, x21, #4
    subs x22, x22, #1
    b.ne 2b
uc_ok:
    mov x0, #0
    leave
uc_bad:
    mov x0, #1
    leave

// x0 = pointer, w23 = kind, x25 = size/register/case, x19 = registers.
// Returns x0 = 0 when valid.
uc_check_one:
    frame
    cmp w23, #UC_NONE
    b.eq 90f
    cmp w23, #UC_STR
    b.eq 10f
    cmp w23, #UC_STR_NZ
    b.ne 1f
    cbz x0, 90f
10:
    mov x1, #UC_STRING_MAX
    mov x2, #0
    bl user_string_ok
    unframe
1:
    cmp w23, #UC_WRITE_NZ
    b.ne 2f
    cbz x0, 90f
    b 20f
2:
    cmp w23, #UC_WRITE
    b.ne 3f
20:
    mov x1, x25
    mov x2, #1
    bl user_range_ok
    unframe
3:
    cmp w23, #UC_READ_NZ
    b.ne 4f
    cbz x0, 90f
    b 40f
4:
    cmp w23, #UC_READ
    b.ne 5f
40:
    mov x1, x25
    mov x2, #0
    bl user_range_ok
    unframe
5:
    cmp w23, #UC_BUF_WRITE
    b.ne 6f
    ldr x1, [x19, x25, lsl #3]
    mov x2, #1
    bl user_range_ok
    unframe
6:
    cmp w23, #UC_BUF_READ
    b.ne 7f
    ldr x1, [x19, x25, lsl #3]
    mov x2, #0
    bl user_range_ok
    unframe
7:
    cmp w23, #UC_FCB
    b.ne 8f
    bl uc_fcb
    unframe
8:
    bl uc_special
    unframe
90:
    mov x0, #0
    unframe

// x0 = FCB (written by most FCB calls).
uc_fcb:
    frame
    str x0, [sp, #-16]!
    mov x1, #1
    mov x2, #1
    bl user_range_ok
    cbnz x0, 1f
    ldr x0, [sp]
    ldrb w3, [x0]
    mov x1, #37
    cmp w3, #0xff               // extended FCB: 7-byte prefix
    mov x2, #44
    csel x1, x2, x1, eq
    mov x2, #1
    bl user_range_ok
1:
    add sp, sp, #16
    unframe

// Calls whose pointers depend on other arguments. x25 = case, x19 = regs.
uc_special:
    frame
    stp x20, x21, [sp, #-16]!
    ldp x9, x10, [x19]          // x0, x1
    ldp x11, x12, [x19, #16]    // x2, x3
    ldr x13, [x19, #32]         // x4
    cmp x25, #1
    b.eq uc_09
    cmp x25, #2
    b.eq uc_0a
    cmp x25, #3
    b.eq uc_0c
    cmp x25, #4
    b.eq uc_44
    cmp x25, #5
    b.eq uc_4b
    cmp x25, #6
    b.eq uc_5a
    cmp x25, #7
    b.eq uc_65
    cmp x25, #8
    b.eq uc_69
    cmp x25, #9
    b.eq uc_e0
    b uc_sp_bad
uc_09:                          // print until '$' or NUL
    mov x0, x9
    mov x1, #0x100000
    mov x2, #1
    bl user_string_ok
    b uc_sp_return
uc_0c:                          // flush, then 01/06/07/08/0Ah with x1
    and x9, x9, #0xff
    cmp x9, #0x0a
    b.ne uc_sp_ok
    mov x9, x10
uc_0a:                          // line buffer: capacity byte, count, text
    mov x20, x9
    mov x0, x9
    mov x1, #1
    mov x2, #1
    bl user_range_ok
    cbnz x0, uc_sp_return
    ldrb w1, [x20]
    add x1, x1, #2
    mov x0, x20
    mov x2, #1
    bl user_range_ok
    b uc_sp_return
uc_44:                          // IOCTL: only 0Dh generic requests use x3
    cmp x10, #0x0d
    b.ne uc_sp_ok
    and x11, x11, #0xffff
    mov x0, x12
    mov x1, #25
    mov x2, #1
    cmp x11, #0x866             // get media ID
    b.eq 1f
    mov x2, #0
    cmp x11, #0x846             // set media ID
    b.eq 1f
    mov x1, #96
    mov x2, #1
    cmp x11, #0x860             // device parameters
    b.eq 1f
    mov x21, #1
    cmp x11, #0x861             // read sectors: into the buffer
    b.eq 2f
    mov x21, #0
    cmp x11, #0x841             // write sectors: from the buffer
    b.ne uc_sp_ok
2:
    mov x20, x12                // u64 first sector, count, buffer
    mov x0, x12
    mov x1, #24
    mov x2, #0
    bl user_range_ok
    cbnz x0, uc_sp_return
    ldr x1, [x20, #8]
    mov x3, #0x1000             // more sectors fail the 16 MiB bound anyway
    cmp x1, x3
    b.hi uc_sp_bad
    lsl x1, x1, #12             // UC_SECTOR_MAX bytes per sector
    ldr x0, [x20, #16]
    mov x2, x21
1:
    bl user_range_ok
    b uc_sp_return
uc_4b:                          // path, command tail; mode 3: destination
    mov x20, x10
    mov x21, x11
    mov x0, x9
    mov x1, #UC_STRING_MAX
    mov x2, #0
    bl user_string_ok
    cbnz x0, uc_sp_return
    cbz x20, 1f
    mov x0, x20
    mov x1, #UC_STRING_MAX
    mov x2, #0
    bl user_string_ok
    cbnz x0, uc_sp_return
1:
    cmp x21, #3
    b.ne uc_sp_ok
    ldp x0, x1, [x19, #24]      // x3 destination, x4 bytes
    mov x2, #1
    bl user_range_ok
    b uc_sp_return
uc_5a:                          // directory; a 13-byte name is appended
    mov x20, x9
    mov x0, x9
    mov x1, #UC_STRING_MAX
    mov x2, #0
    bl user_string_ok
    cbnz x0, uc_sp_return
    add x1, x1, #14
    mov x0, x20
    mov x2, #1
    bl user_range_ok
    b uc_sp_return
uc_65:                          // extended country information
    and x9, x9, #0xff
    cmp x9, #0x20
    b.hs 3f
    mov x20, x12                // ids 01h-07h: buffer x3, size x4
    mov x21, x13
    mov x0, x12
    mov x1, x13
    mov x2, #1
    bl user_range_ok
    cbnz x0, uc_sp_return
    ldr x9, [x19]
    and x9, x9, #0xff
    cmp x9, #1
    b.eq uc_sp_ok
    mov x0, x20                 // table ids write id + pointer
    mov x1, #9
    mov x2, #1
    bl user_range_ok
    b uc_sp_return
3:
    cmp x9, #0x21               // upper-case a buffer
    b.ne 4f
    mov x0, x10
    mov x1, x11
    mov x2, #1
    bl user_range_ok
    b uc_sp_return
4:
    cmp x9, #0x22               // upper-case an ASCIIZ string in place
    b.ne uc_sp_ok
    mov x20, x10
    mov x0, x10
    mov x1, #UC_STRING_MAX
    mov x2, #0
    bl user_string_ok
    cbnz x0, uc_sp_return
    add x1, x1, #1
    mov x0, x20
    mov x2, #1
    bl user_range_ok
    b uc_sp_return
uc_69:                          // media ID: get writes, set reads 25 bytes
    cmp x9, #1
    cset x2, ne
    mov x0, x11
    mov x1, #25
    bl user_range_ok
    b uc_sp_return
uc_e0:                          // raw disk services
    cmp x9, #1
    b.ne 1f
    mov x0, x11
    mov x1, #32
    mov x2, #1
    bl user_range_ok
    b uc_sp_return
1:
    cmp x9, #2
    cset x2, eq                 // 2 reads into the buffer, 3 writes from it
    b.eq 2f
    cmp x9, #3
    b.ne uc_sp_ok
2:
    mov x3, #0x1000
    cmp x12, x3
    b.hi uc_sp_bad
    lsl x1, x12, #12
    mov x0, x13
    bl user_range_ok
    b uc_sp_return
uc_sp_ok:
    mov x0, #0
uc_sp_return:
    ldp x20, x21, [sp], #16
    unframe
uc_sp_bad:
    mov x0, #1
    b uc_sp_return

.section .rodata
// Per function 00h-6Ch, then E0h: two slots of kind, register, a (u16).
uc_table:
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 00h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 01h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 02h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 03h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 04h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 05h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 06h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 07h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 08h
    .byte UC_SPECIAL, 0, 1, 0, UC_NONE, 0, 0, 0   // 09h
    .byte UC_SPECIAL, 0, 2, 0, UC_NONE, 0, 0, 0   // 0Ah
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 0Bh
    .byte UC_SPECIAL, 0, 3, 0, UC_NONE, 0, 0, 0   // 0Ch
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 0Dh
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 0Eh
    .byte UC_FCB, 0, 0, 0, UC_NONE, 0, 0, 0   // 0Fh
    .byte UC_FCB, 0, 0, 0, UC_NONE, 0, 0, 0   // 10h
    .byte UC_FCB, 0, 0, 0, UC_NONE, 0, 0, 0   // 11h
    .byte UC_FCB, 0, 0, 0, UC_NONE, 0, 0, 0   // 12h
    .byte UC_FCB, 0, 0, 0, UC_NONE, 0, 0, 0   // 13h
    .byte UC_FCB, 0, 0, 0, UC_NONE, 0, 0, 0   // 14h
    .byte UC_FCB, 0, 0, 0, UC_NONE, 0, 0, 0   // 15h
    .byte UC_FCB, 0, 0, 0, UC_NONE, 0, 0, 0   // 16h
    .byte UC_FCB, 0, 0, 0, UC_NONE, 0, 0, 0   // 17h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 18h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 19h
    .byte UC_BUF_WRITE, 0, 1, 0, UC_NONE, 0, 0, 0   // 1Ah
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 1Bh
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 1Ch
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 1Dh
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 1Eh
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 1Fh
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 20h
    .byte UC_FCB, 0, 0, 0, UC_NONE, 0, 0, 0   // 21h
    .byte UC_FCB, 0, 0, 0, UC_NONE, 0, 0, 0   // 22h
    .byte UC_FCB, 0, 0, 0, UC_NONE, 0, 0, 0   // 23h
    .byte UC_FCB, 0, 0, 0, UC_NONE, 0, 0, 0   // 24h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 25h
    .byte UC_WRITE, 0, 64, 0, UC_NONE, 0, 0, 0   // 26h
    .byte UC_FCB, 0, 0, 0, UC_NONE, 0, 0, 0   // 27h
    .byte UC_FCB, 0, 0, 0, UC_NONE, 0, 0, 0   // 28h
    .byte UC_STR, 0, 0, 0, UC_FCB, 1, 0, 0   // 29h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 2Ah
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 2Bh
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 2Ch
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 2Dh
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 2Eh
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 2Fh
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 30h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 31h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 32h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 33h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 34h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 35h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 36h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 37h
    .byte UC_WRITE_NZ, 0, 34, 0, UC_NONE, 0, 0, 0   // 38h
    .byte UC_STR, 0, 0, 0, UC_NONE, 0, 0, 0   // 39h
    .byte UC_STR, 0, 0, 0, UC_NONE, 0, 0, 0   // 3Ah
    .byte UC_STR, 0, 0, 0, UC_NONE, 0, 0, 0   // 3Bh
    .byte UC_STR, 0, 0, 0, UC_NONE, 0, 0, 0   // 3Ch
    .byte UC_STR, 0, 0, 0, UC_NONE, 0, 0, 0   // 3Dh
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 3Eh
    .byte UC_BUF_WRITE, 1, 2, 0, UC_NONE, 0, 0, 0   // 3Fh
    .byte UC_BUF_READ, 1, 2, 0, UC_NONE, 0, 0, 0   // 40h
    .byte UC_STR, 0, 0, 0, UC_NONE, 0, 0, 0   // 41h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 42h
    .byte UC_STR, 0, 0, 0, UC_NONE, 0, 0, 0   // 43h
    .byte UC_SPECIAL, 0, 4, 0, UC_NONE, 0, 0, 0   // 44h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 45h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 46h
    .byte UC_BUF_WRITE, 0, 1, 0, UC_NONE, 0, 0, 0   // 47h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 48h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 49h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 4Ah
    .byte UC_SPECIAL, 0, 5, 0, UC_NONE, 0, 0, 0   // 4Bh
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 4Ch
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 4Dh
    .byte UC_STR, 0, 0, 0, UC_NONE, 0, 0, 0   // 4Eh
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 4Fh
    .byte UC_READ_NZ, 0, 64, 0, UC_NONE, 0, 0, 0   // 50h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 51h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 52h
    .byte UC_READ, 0, 64, 0, UC_WRITE, 1, 64, 0   // 53h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 54h
    .byte UC_WRITE, 0, 64, 0, UC_NONE, 0, 0, 0   // 55h
    .byte UC_STR, 0, 0, 0, UC_STR, 1, 0, 0   // 56h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 57h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 58h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 59h
    .byte UC_SPECIAL, 0, 6, 0, UC_NONE, 0, 0, 0   // 5Ah
    .byte UC_STR, 0, 0, 0, UC_NONE, 0, 0, 0   // 5Bh
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 5Ch
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 5Dh
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 5Eh
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 5Fh
    .byte UC_STR, 0, 0, 0, UC_WRITE, 1, 128, 0   // 60h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 61h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 62h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 63h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 64h
    .byte UC_SPECIAL, 0, 7, 0, UC_NONE, 0, 0, 0   // 65h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 66h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 67h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 68h
    .byte UC_SPECIAL, 0, 8, 0, UC_NONE, 0, 0, 0   // 69h
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 6Ah
    .byte UC_NONE, 0, 0, 0, UC_NONE, 0, 0, 0   // 6Bh
    .byte UC_STR, 0, 0, 0, UC_NONE, 0, 0, 0   // 6Ch
    .byte UC_SPECIAL, 0, 9, 0, UC_NONE, 0, 0, 0   // E0h
