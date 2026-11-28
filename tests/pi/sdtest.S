// SPDX-License-Identifier: MIT
// Bare-metal check of the Raspberry Pi 3 drivers (src/sdhci.S and the mini
// UART) on QEMU's raspi3b model, run by `make pi-test`: initialise the SD
// card, read the MBR, write and read back sectors outside the partition.
// Output goes to the PL011 (first serial port) and the mini UART (second).
.macro address reg, name
    adrp \reg, \name
    add \reg, \reg, :lo12:\name
.endm
.macro say text
    .pushsection .rodata
9876:
    .asciz "\text"
    .popsection
    address x0, 9876b
    bl print
.endm
.equ PL011, 0x3f201000
.equ MINI_UART, 0x3f215040
.equ EMMC, 0x3f300000

.section .text.boot
.global _start
_start:
    mrs x0, mpidr_el1
    and x0, x0, #3
    cbnz x0, halt
    mov x0, #0x80000
    mov sp, x0
    movz x1, #(PL011 & 0xffff)  // PL011 on: 8 bits, FIFO, transmit/receive
    movk x1, #(PL011 >> 16), lsl #16
    str wzr, [x1, #0x30]
    mov w2, #0x70
    str w2, [x1, #0x2c]
    mov w2, #0x301
    str w2, [x1, #0x30]
    say "SDTEST start\r\n"
    movz x0, #(EMMC & 0xffff)
    movk x0, #(EMMC >> 16), lsl #16
    bl sd_init
    cbz x0, 1f
    mov x19, x0
    say "SDTEST FAIL init step "
    add x0, x19, #'0'
    bl putc
    b halt
1:
    address x9, sd_block_addressing
    ldr x0, [x9]
    cbz x0, 11f
    say "card: block addressed\r\n"
11:
    mov x0, #0                  // MBR
    mov x1, #1
    address x2, buffer
    mov x3, #0
    bl sd_rw
    cbnz x0, fail_read
    address x2, buffer
    ldrb w3, [x2, #510]
    ldrb w4, [x2, #511]
    cmp w3, #0x55
    b.ne fail_mbr
    cmp w4, #0xaa
    b.ne fail_mbr
    say "MBR signature 55AA, partition type "
    address x2, buffer
    ldrb w0, [x2, #0x1c2]
    bl put_hex8
    say "\r\n"
    // Four sectors at 100 (before the partition at 2048): write, read back.
    address x2, pattern
    mov x3, #0
2:
    mov w4, #0x5a
    eor w4, w4, w3
    add w4, w4, w3, lsr #9
    strb w4, [x2, x3]
    add x3, x3, #1
    cmp x3, #2048
    b.lo 2b
    mov x0, #100
    mov x1, #4
    address x2, pattern
    mov x3, #1
    bl sd_rw
    cbnz x0, fail_write
    mov x0, #100
    mov x1, #4
    address x2, readback
    mov x3, #0
    bl sd_rw
    cbnz x0, fail_read
    address x2, pattern
    address x3, readback
    mov x4, #0
3:
    ldrb w5, [x2, x4]
    ldrb w6, [x3, x4]
    cmp w5, w6
    b.ne fail_compare
    add x4, x4, #1
    cmp x4, #2048
    b.lo 3b
    say "4-sector write/read-back matches\r\n"
    mov x0, #'M'
    bl mini_putc
    mov x0, #'U'
    bl mini_putc
    mov x0, #' '
    bl mini_putc
    mov x0, #'O'
    bl mini_putc
    mov x0, #'K'
    bl mini_putc
    mov x0, #'\n'
    bl mini_putc
    // The kernel's raw checkpoint output (src/dbguart.S) on both UARTs.
    movz x0, #(PL011 & 0xffff)
    movk x0, #(PL011 >> 16), lsl #16
    mov x1, #0
    bl dbg_check_line
    movz x0, #(MINI_UART & 0xffff)
    movk x0, #(MINI_UART >> 16), lsl #16
    mov x1, #1
    bl dbg_check_line
    say "SDTEST PASS\r\n"
halt:
    wfe
    b halt
fail_read:
    say "SDTEST FAIL read\r\n"
    b halt
fail_write:
    say "SDTEST FAIL write\r\n"
    b halt
fail_mbr:
    say "SDTEST FAIL MBR signature\r\n"
    b halt
fail_compare:
    say "SDTEST FAIL compare\r\n"
    b halt

// x0 = string.
print:
    mov x7, x30
    mov x6, x0
1:
    ldrb w0, [x6], #1
    cbz w0, 2f
    bl putc
    b 1b
2:
    br x7

// w0 = byte to the PL011.
putc:
    movz x1, #(PL011 & 0xffff)
    movk x1, #(PL011 >> 16), lsl #16
1:
    ldr w2, [x1, #0x18]
    tbnz w2, #5, 1b
    str w0, [x1]
    ret

// w0 = byte to the mini UART (8250 layout, 4-byte registers).
mini_putc:
    movz x1, #(MINI_UART & 0xffff)
    movk x1, #(MINI_UART >> 16), lsl #16
1:
    ldr w2, [x1, #0x14]
    tbz w2, #5, 1b
    str w0, [x1]
    ret

// w0 = byte: two hex digits.
put_hex8:
    mov x8, x30
    mov x5, x0
    ubfx x0, x5, #4, #4
    bl 1f
    and x0, x5, #15
    bl 1f
    br x8
1:
    cmp x0, #10
    add x1, x0, #'0'
    add x2, x0, #('A' - 10)
    csel x0, x1, x2, lo
    b putc

// x0 = UART base, x1 = type: one checkpoint line, as the kernel prints it.
dbg_check_line:
    mov x10, x30                // dbg_uart_* clobber x2-x8
    address x2, dbg_check_text
    bl dbg_uart_puts
    movz x2, #0xc3c3
    movk x2, #0xa5a5, lsl #16
    bl dbg_uart_hex
    address x2, dbg_check_crlf
    bl dbg_uart_puts
    br x10

.include "src/sdhci.S"
.include "src/dbguart.S"

.section .rodata
dbg_check_text: .asciz "ARMDOS: sdhci init ok, raw UART check="
dbg_check_crlf: .asciz "\r\n"

.section .bss
.balign 16
buffer: .skip 512
pattern: .skip 2048
readback: .skip 2048
