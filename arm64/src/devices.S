// SPDX-License-Identifier: MIT
// Character devices (DEV.ASM, the BIOS device chain): CON, AUX, PRN, NUL and
// CLOCK$. Each device is an object shaped like the file objects, so handles,
// duplication, inheritance and close work unchanged; dos_read/dos_write send
// device handles here instead of to the filesystem.
//
// AUX shares the console UART. PRN has no printer behind it on QEMU virt and
// discards output until PRINTER.SYS takes it over.
.equ DEV_CON, 0
.equ DEV_AUX, 1
.equ DEV_PRN, 2
.equ DEV_NUL, 3
.equ DEV_CLOCK, 4
.equ DEV_COUNT, 5
.equ DEV_MAX, 16                // standard devices plus DEVICE= drivers
.equ DEV_OBJ_SIZE, 128
.equ DEV_ID, 88
.equ DEV_ATTR, 96
.equ DEV_NAME, 104
.equ DEV_DRV_READ, 112          // installed driver: read(buf, count) -> bytes
.equ DEV_DRV_WRITE, 120         // and write(buf, count) -> bytes
.section .text

// Fill each object's function table (the kernel image has no absolute
// relocations in data) and give the standard AUX/PRN handles 3 and 4.
dev_init:
    frame
    stp x19, x20, [sp, #-16]!
    address x19, dev_objects
    mov x20, #0
1:
    mov x9, #DEV_OBJ_SIZE
    madd x0, x20, x9, x19
    bl dev_obj_init
    address x1, dev_attributes
    ldrh w1, [x1, x20, lsl #1]
    str x1, [x0, #DEV_ATTR]
    address x1, dev_display_names
    add x1, x1, x20, lsl #3
    str x1, [x0, #DEV_NAME]
    add x20, x20, #1
    cmp x20, #DEV_COUNT
    b.lo 1b
    address x0, handles
    add x1, x19, #(DEV_AUX * DEV_OBJ_SIZE)
    str x1, [x0, #24]
    add x1, x19, #(DEV_PRN * DEV_OBJ_SIZE)
    str x1, [x0, #32]
    address x0, handle_modes
    mov w1, #2
    strb w1, [x0, #3]
    strb w1, [x0, #4]
    ldp x19, x20, [sp], #16
    unframe

// x0 = object, x20 = id: the function table and id. Keeps x0.
dev_obj_init:
    mov x1, #0x10000            // EFI_FILE_PROTOCOL_REVISION
    str x1, [x0]
    address x1, dev_efi_unsupported
    str x1, [x0, #8]            // Open
    address x1, dev_efi_ok
    str x1, [x0, #16]           // Close
    address x1, dev_efi_denied
    str x1, [x0, #24]           // Delete
    address x1, dev_efi_zero_size
    str x1, [x0, #32]           // Read (dos_read bypasses it)
    address x1, dev_efi_ok
    str x1, [x0, #40]           // Write (dos_write bypasses it)
    address x1, dev_efi_get_position
    str x1, [x0, #48]
    address x1, dev_efi_ok
    str x1, [x0, #56]           // SetPosition
    address x1, dev_efi_get_info
    str x1, [x0, #64]
    address x1, dev_efi_ok
    str x1, [x0, #72]           // SetInfo
    address x1, dev_efi_ok
    str x1, [x0, #80]           // Flush
    str x20, [x0, #DEV_ID]
    str xzr, [x0, #DEV_DRV_READ]
    str xzr, [x0, #DEV_DRV_WRITE]
    ret

// x0 = driver request (see ABI.md, "Installable device drivers"): +16 name,
// +24 read, +32 write, +40 attribute. A driver named like a standard device
// (CON, PRN...) takes over that device; otherwise a new device is added.
// Returns x1 = 0, or x1 = 1 when the device table is full.
dev_install:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x21, x0
    add x0, x21, #16            // upper-case the name in place
    mov x2, #0
1:
    ldrb w3, [x0, x2]
    cmp w3, #'a'
    b.lo 2f
    cmp w3, #'z'
    b.hi 2f
    sub w3, w3, #32
    strb w3, [x0, x2]
2:
    add x2, x2, #1
    cmp x2, #8
    b.lo 1b
    strb wzr, [x21, #23]        // names are at most 7 characters
    add x0, x21, #16
    bl dev_lookup
    cbnz x0, 4f
    address x9, dev_installed
    ldr x20, [x9]
    add x20, x20, #DEV_COUNT
    cmp x20, #DEV_MAX
    b.hs 9f
    ldr x10, [x9]
    add x10, x10, #1
    str x10, [x9]
    address x19, dev_objects
    mov x9, #DEV_OBJ_SIZE
    madd x0, x20, x9, x19
    bl dev_obj_init
    mov x22, x0
    address x1, dev_installed_names
    sub x2, x20, #DEV_COUNT
    add x1, x1, x2, lsl #3
    str x1, [x22, #DEV_NAME]
    ldr x2, [x21, #16]
    str x2, [x1]
    ldr x1, [x21, #40]
    orr x1, x1, #0x80           // always a character device
    str x1, [x22, #DEV_ATTR]
    mov x0, x22
4:
    ldr x1, [x21, #24]
    str x1, [x0, #DEV_DRV_READ]
    ldr x1, [x21, #32]
    str x1, [x0, #DEV_DRV_WRITE]
    mov x1, #0
    b 10f
9:
    mov x1, #1
10:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// x0 = object. Returns x0 = device id, or -1 for a file object.
dev_id_of:
    address x1, dev_objects
    sub x1, x0, x1
    cmp x1, #(DEV_MAX * DEV_OBJ_SIZE)
    b.hs 1f
    ldr x0, [x0, #DEV_ID]
    ret
1:
    mov x0, #-1
    ret

// x0 = ASCII path. A device name may carry any directory and extension
// ("\TMP\NUL.TXT" is NUL), as in DOS. Returns x0 = object or 0.
dev_lookup:
    mov x9, x0
    mov x10, x0                 // start of the last component
1:
    ldrb w2, [x9], #1
    cbz w2, 2f
    cmp w2, #'\\'
    b.eq 11f
    cmp w2, #'/'
    b.eq 11f
    cmp w2, #':'
    b.ne 1b
11:
    mov x10, x9
    b 1b
2:
    address x11, dev_lookup_names
3:
    ldrb w2, [x11]
    cbz w2, 9f
    mov x12, x10
    mov x13, x11
4:
    ldrb w3, [x13], #1
    ldrb w4, [x12], #1
    cmp w4, #'a'
    b.lo 5f
    cmp w4, #'z'
    b.hi 5f
    sub w4, w4, #32
5:
    cbz w3, 6f
    cmp w3, w4
    b.eq 4b
    b 7f
6:
    cbz w4, 8f                  // name ends: exact device
    cmp w4, #'.'
    b.eq 8f                     // extension is ignored
7:
    add x11, x11, #8
    b 3b
8:
    ldrb w2, [x11, #7]          // device id
    address x0, dev_objects
    mov x3, #DEV_OBJ_SIZE
    madd x0, x2, x3, x0
    ret
9:
    address x11, dev_installed_names // second pass: DEVICE= names
    address x14, dev_installed
    ldr x14, [x14]
    add x14, x11, x14, lsl #3
    b 92f
91:
    mov x0, #0
    ret
92:
    cmp x11, x14
    b.hs 91b
    mov x12, x10
    mov x13, x11
93:
    ldrb w3, [x13], #1
    ldrb w4, [x12], #1
    cmp w4, #'a'
    b.lo 94f
    cmp w4, #'z'
    b.hi 94f
    sub w4, w4, #32
94:
    cbz w3, 95f
    cmp w3, w4
    b.eq 93b
    b 96f
95:
    cbz w4, 97f
    cmp w4, #'.'
    b.eq 97f
96:
    add x11, x11, #8
    b 92b
97:
    address x2, dev_installed_names
    sub x2, x11, x2
    lsr x2, x2, #3
    add x2, x2, #DEV_COUNT
    address x0, dev_objects
    mov x3, #DEV_OBJ_SIZE
    madd x0, x2, x3, x0
    ret

// x0 = object, x1 = buffer, x2 = count. Returns x0 = bytes, x1 = 0.
dev_read:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x1
    mov x20, x2
    ldr x9, [x0, #DEV_DRV_READ]
    cbz x9, 1f
    ldr x10, [x0, #DEV_ID]
    cmp x10, #DEV_CON
    b.eq 1f                     // CON drivers supply keys to the line editor
    mov x0, x19
    mov x1, x20
    blr x9
    b dev_read_return
1:
    ldr x21, [x0, #DEV_ID]
    cmp x21, #DEV_AUX
    b.ls dev_read_console
    cmp x21, #DEV_CLOCK
    b.eq dev_read_clock
    mov x0, #0                  // NUL and PRN: end of file
    b dev_read_return
dev_read_console:
    address x9, con_direct
    mov x10, #1
    str x10, [x9]
    ldr x10, [x0, #DEV_ATTR]
    tbz x10, #5, 1f             // raw (binary) mode: one key, no editing
    cbz x20, 2f
    bl read_key
    strb w0, [x19]
    address x9, con_direct
    str xzr, [x9]
    mov x0, #1
    b dev_read_return
2:
    str xzr, [x9]
    mov x0, #0
    b dev_read_return
1:
    mov x1, x19
    mov x2, x20
    bl read_console_handle
    address x9, con_direct
    str xzr, [x9]
    b dev_read_return
// CLOCK$: u16 days since 1980-01-01, minutes, hours, hundredths, seconds.
dev_read_clock:
    cmp x20, #6
    b.lo 1f
    bl dos_get_date
    mov x1, x2
    mov x2, x3
    bl date_to_days
    strb w0, [x19]
    lsr w0, w0, #8
    strb w0, [x19, #1]
    bl dos_get_time
    strb w2, [x19, #2]
    strb w0, [x19, #3]
    strb w4, [x19, #4]
    strb w3, [x19, #5]
    mov x0, #6
    b dev_read_return
1:
    mov x0, #0
dev_read_return:
    mov x1, #0
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// x0 = object, x1 = buffer, x2 = count. Returns x0 = bytes, x1 = 0.
dev_write:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x1
    mov x20, x2
    ldr x9, [x0, #DEV_DRV_WRITE]
    cbz x9, 1f
    mov x0, x19
    mov x1, x20
    blr x9
    b dev_write_return
1:
    ldr x21, [x0, #DEV_ID]
    cmp x21, #DEV_AUX
    b.ls dev_write_console
    cmp x21, #DEV_PRN
    b.eq dev_write_printer
    cmp x21, #DEV_CLOCK
    b.eq dev_write_clock
    mov x0, x20                 // NUL swallows everything
    b dev_write_return
dev_write_printer:
    mov x0, x19
    mov x1, x20
    bl prn_output
    mov x0, x20
    b dev_write_return
dev_write_console:
    mov x21, #0
1:
    cmp x21, x20
    b.hs 2f
    ldrb w0, [x19, x21]
    bl putc
    add x21, x21, #1
    b 1b
2:
    mov x0, x20
    b dev_write_return
dev_write_clock:
    cmp x20, #6
    b.lo 3f
    ldrb w0, [x19]
    ldrb w1, [x19, #1]
    orr w0, w0, w1, lsl #8
    bl days_to_date
    bl dos_set_date
    cbnz x1, 3f
    ldrb w0, [x19, #3]
    ldrb w1, [x19, #2]
    ldrb w2, [x19, #5]
    ldrb w3, [x19, #4]
    bl dos_set_time
    cbnz x1, 3f
    mov x0, #6
    b dev_write_return
3:
    mov x0, #0
dev_write_return:
    mov x1, #0
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// x0 = bytes, x1 = count. Without PRINTER.SYS output is discarded (no
// parallel port on the supported boards).
prn_output:
    ret

// 03h: read one byte from AUX (the console UART), no echo.
dos_aux_input:
    frame
    bl plat_read_key
    mov x1, #0
    unframe
// 04h: x0 = byte to AUX.
dos_aux_output:
    frame
    str x19, [sp, #-16]!
    and x19, x0, #255
    mov x0, x19
    bl plat_putc
    mov x0, x19
    mov x1, #0
    ldr x19, [sp], #16
    unframe
// 05h: x0 = byte to PRN.
dos_printer_output:
    frame
    sub sp, sp, #16
    strb w0, [sp]
    mov x0, sp
    mov x1, #1
    bl prn_output
    ldrb w0, [sp]
    mov x1, #0
    add sp, sp, #16
    unframe

// Object functions used by generic file code that reaches a device.
dev_efi_ok:
    mov x0, #0
    ret
dev_efi_unsupported:
    mov x0, #3
    orr x0, x0, #0x8000000000000000
    ret
dev_efi_denied:
    mov x0, #15
    orr x0, x0, #0x8000000000000000
    ret
dev_efi_zero_size:
    str xzr, [x1]
    mov x0, #0
    ret
dev_efi_get_position:
    str xzr, [x1]
    mov x0, #0
    ret
// GetInfo: an empty, attribute-less entry named after the device.
dev_efi_get_info:
    ldr x4, [x2]
    cmp x4, #96
    b.lo 2f
    mov x4, #96
    str x4, [x2]
    mov x5, #0
1:
    str xzr, [x3, x5]
    add x5, x5, #8
    cmp x5, #96
    b.lo 1b
    str x4, [x3]
    ldr x5, [x0, #DEV_NAME]
    add x6, x3, #80
3:
    ldrb w7, [x5], #1
    strh w7, [x6], #2
    cbnz w7, 3b
    mov x0, #0
    ret
2:
    mov x4, #96
    str x4, [x2]
    mov x0, #5                  // EFI_BUFFER_TOO_SMALL
    orr x0, x0, #0x8000000000000000
    ret

.section .rodata
.balign 2
// Device information word (IOCTL 4400h): 80h device, 40h not EOF,
// 10h special (CON), 8 clock, 4 null, 2 standard output, 1 standard input.
dev_attributes: .short 0xd3, 0xc0, 0xc0, 0xc4, 0xc8
.balign 8
dev_display_names:
    .ascii "CON\0\0\0\0\0"
    .ascii "AUX\0\0\0\0\0"
    .ascii "PRN\0\0\0\0\0"
    .ascii "NUL\0\0\0\0\0"
    .ascii "CLOCK$\0\0"
// Lookup names: 7 bytes NUL-padded name, then device id.
dev_lookup_names:
    .ascii "CON\0\0\0\0"
    .byte DEV_CON
    .ascii "AUX\0\0\0\0"
    .byte DEV_AUX
    .ascii "COM1\0\0\0"
    .byte DEV_AUX
    .ascii "PRN\0\0\0\0"
    .byte DEV_PRN
    .ascii "LPT1\0\0\0"
    .byte DEV_PRN
    .ascii "NUL\0\0\0\0"
    .byte DEV_NUL
    .ascii "CLOCK$\0"
    .byte DEV_CLOCK
    .byte 0

.section .bss
.balign 16
dev_objects: .skip DEV_MAX * DEV_OBJ_SIZE
dev_installed: .skip 8
dev_installed_names: .skip 8 * (DEV_MAX - DEV_COUNT)

con_direct: .skip 8
