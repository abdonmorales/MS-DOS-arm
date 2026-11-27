// SPDX-License-Identifier: MIT
// Boot checkpoints for bringing up new hardware (first boot on a physical
// Raspberry Pi 3). Off by default: nothing here prints unless the kernel
// was assembled with --defsym ARMDOS_DEBUG=1 (make ARMDOS_DEBUG=1), which
// turns it on from the first instruction, or the boot volume has a file
// \DEBUG.ON, which turns it on as soon as the volume can be read.
//
// Each checkpoint is one line, "ARMDOS: <step>", so the last line printed
// says where a boot stopped. While UEFI owns the machine the lines go to the
// firmware console (ConOut: the serial port and HDMI on the Pi 3 UEFI
// firmware); writing the UART registers behind the firmware's back is
// avoided there. Once ExitBootServices has succeeded they are written
// straight to the transmit register of the UART that ACPI SPCR named (the
// one the firmware used as its serial console, so its baud rate and GPIO
// pin function are already set), bypassing dos_write, CON drivers and
// redirection. A CPU exception in native mode also dumps every register.

.ifndef ARMDOS_DEBUG
.equ ARMDOS_DEBUG, 0
.endif

.section .text

// x0 = string: one checkpoint line. Clobbers x0-x18 (calls the firmware).
dbg_mark:
    mov x2, #0
    b dbg_line
// x0 = string, x1 = value: the line ends with the value in hex.
dbg_mark_hex:
    mov x2, #1
dbg_line:
    adrp x9, plat_debug
    ldr x9, [x9, :lo12:plat_debug]
    cbnz x9, 1f
    ret
1:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov x19, x0
    mov x20, x1
    mov x21, x2
    address x0, dbg_prefix
    bl dbg_str
    mov x0, x19
    bl dbg_str
    cbz x21, 2f
    mov x0, x20
    bl dbg_hex
2:
    address x0, dbg_crlf
    bl dbg_str
    ldp x19, x20, [sp, #16]
    ldr x21, [sp, #32]
    ldp x29, x30, [sp], #48
    ret

// x0 = string, to the UART in native mode, else to the firmware console.
dbg_str:
    adrp x9, platform_native
    ldr x9, [x9, :lo12:platform_native]
    cbz x9, 1f
    mov x2, x0
    ldv x0, plat_uart
    ldv x1, plat_uart_type
    b dbg_uart_puts
1:
    frame
    str x19, [sp, #-16]!
    mov x19, x0
2:
    ldrb w0, [x19], #1
    cbz w0, 3f
    bl plat_putc
    b 2b
3:
    ldr x19, [sp], #16
    unframe

// x0 = value: 16 hex digits.
dbg_hex:
    adrp x9, platform_native
    ldr x9, [x9, :lo12:platform_native]
    cbz x9, 1f
    mov x2, x0
    ldv x0, plat_uart
    ldv x1, plat_uart_type
    b dbg_uart_hex
1:
    frame
    sub sp, sp, #32
    mov x2, #60
    mov x3, sp
2:
    lsr x4, x0, x2
    and x4, x4, #15
    cmp x4, #10
    add x5, x4, #'0'
    add x4, x4, #('a' - 10)
    csel x4, x5, x4, lo
    strb w4, [x3], #1
    subs x2, x2, #4
    b.pl 2b
    strb wzr, [x3]
    mov x0, sp
    bl dbg_str
    add sp, sp, #32
    unframe

// Called once system_table is set: the first checkpoints of a debug build.
dbg_entry:
    frame
    bl dbg_early
    unframe

// "entry" and the exception level; again after \DEBUG.ON turned output on.
dbg_early:
    frame
    address x0, dbg_msg_entry
    bl dbg_mark
    address x0, dbg_msg_el
    mrs x1, CurrentEL
    lsr x1, x1, #2
    bl dbg_mark_hex
    unframe

// After filesystem_init.
dbg_mount:
    frame
    address x0, dbg_msg_fat
    ldv x1, fat_mounted
    cbnz x1, 1f
    address x0, dbg_msg_fat_fw
1:
    bl dbg_mark
    unframe

// Before leaving firmware: a boot volume with \DEBUG.ON turns output on.
dbg_check_flag:
    frame
    ldv x0, plat_debug
    cbnz x0, 1f
    address x0, dbg_flag_name
    mov x1, #0
    bl dos_open
    cbnz x1, 1f
    bl dos_close
    mov x0, #1
    stv x0, plat_debug, x1
    bl dbg_early
    bl dbg_mount
    address x0, dbg_msg_flag
    bl dbg_mark
1:
    unframe

// After a failed sd_init (x0 = its step code): the controller's state.
dbg_sd_failed:
    frame
    stp x19, x20, [sp, #-16]!
    mov x1, x0
    address x0, dbg_msg_sd_err
    bl dbg_mark_hex
    ldv x19, sd_base
    address x20, dbg_sd_regs
1:
    ldrb w2, [x20]
    cmp w2, #0xff
    b.eq 2f
    ldr w1, [x19, x2]
    add x0, x20, #1
    bl dbg_mark_hex
    add x20, x20, #32
    b 1b
2:
    sub x2, x19, #0x100000      // GPIO: GPFSEL1 (pins 14/15), 4, 5 (SD slot)
    ldr w1, [x2, #0x04]
    address x0, dbg_msg_gpfsel1
    bl dbg_mark_hex
    sub x2, x19, #0x100000
    ldr w1, [x2, #0x10]
    address x0, dbg_msg_gpfsel4
    bl dbg_mark_hex
    sub x2, x19, #0x100000
    ldr w1, [x2, #0x14]
    address x0, dbg_msg_gpfsel5
    bl dbg_mark_hex
    ldp x19, x20, [sp], #16
    unframe

// From plat_exception with sp = the saved x0-x30 frame, x19 = vector,
// x20 = ESR, x21 = ELR, x22 = FAR (native mode only). Uses x23-x25.
dbg_exception:
    adrp x9, plat_debug
    ldr x9, [x9, :lo12:plat_debug]
    cbnz x9, 1f
    ret
1:
    mov x25, x30
    mov x24, sp                 // the frame (calls below keep sp balanced)
    address x0, dbg_msg_exc
    mov x1, x19
    bl dbg_mark_hex
    address x0, dbg_msg_esr
    mov x1, x20
    bl dbg_mark_hex
    address x0, dbg_msg_elr
    mov x1, x21
    bl dbg_mark_hex
    address x0, dbg_msg_elr_elf // the same PC as an address in kernel.elf
    address x1, efi_main
    sub x1, x1, #0x1000
    sub x1, x21, x1
    bl dbg_mark_hex
    address x0, dbg_msg_far
    mov x1, x22
    bl dbg_mark_hex
    mrs x1, spsr_el1
    mrs x2, CurrentEL
    cmp x2, #8
    b.ne 2f
    mrs x1, spsr_el2
2:
    address x0, dbg_msg_spsr
    bl dbg_mark_hex
    address x0, dbg_msg_sp
    add x1, x24, #256
    bl dbg_mark_hex
    mov x23, #0
3:
    address x0, dbg_reg_names
    add x0, x0, x23, lsl #3
    ldr x1, [x24, x23, lsl #3]
    bl dbg_mark_hex
    add x23, x23, #1
    cmp x23, #31
    b.lo 3b
    br x25

.section .rodata
dbg_prefix: .asciz "ARMDOS: "
dbg_crlf: .asciz "\r\n"
dbg_flag_name: .asciz "A:\\DEBUG.ON"
dbg_msg_entry: .asciz "entry"
dbg_msg_el: .asciz "EL="
dbg_msg_fat: .asciz "FAT mount ok (native FAT driver)"
dbg_msg_fat_fw: .asciz "FAT mount: native driver declined, firmware file system"
dbg_msg_flag: .asciz "debug output on (\\DEBUG.ON)"
dbg_msg_banner: .asciz "platform ready, printing banner"
dbg_msg_selftest: .asciz "boot self-test"
dbg_msg_config: .asciz "CONFIG.SYS"
dbg_msg_command: .asciz "COMMAND (AUTOEXEC.BAT, then the prompt)"
dbg_msg_sd_err: .asciz "sdhci init err step="
dbg_msg_gpfsel1: .asciz "  GPFSEL1="
dbg_msg_gpfsel4: .asciz "  GPFSEL4="
dbg_msg_gpfsel5: .asciz "  GPFSEL5="
dbg_msg_exc: .asciz "CPU exception, vector="
dbg_msg_esr: .asciz "  ESR="
dbg_msg_elr: .asciz "  ELR="
dbg_msg_elr_elf: .asciz "  ELR in kernel.elf="
dbg_msg_far: .asciz "  FAR="
dbg_msg_spsr: .asciz "  SPSR="
dbg_msg_sp: .asciz "  SP="
// Offset byte, then the name, 32 bytes per entry: SDHCI registers dumped on failure.
.balign 32
dbg_sd_regs:
    .byte 0x24
    .asciz "  SD STATUS="
    .balign 32
    .byte 0x28
    .asciz "  SD CONTROL0="
    .balign 32
    .byte 0x2c
    .asciz "  SD CONTROL1="
    .balign 32
    .byte 0x30
    .asciz "  SD INTERRUPT="
    .balign 32
    .byte 0x40
    .asciz "  SD CAPS="
    .balign 32
    .byte 0xfc
    .asciz "  SD VERSION="
    .balign 32
    .byte 0xff
.balign 8
dbg_reg_names:
.irp r, 00,01,02,03,04,05,06,07,08,09,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30
    .balign 8
    .asciz "  x\r="
.endr

.section .data
.balign 8
plat_debug: .quad ARMDOS_DEBUG
